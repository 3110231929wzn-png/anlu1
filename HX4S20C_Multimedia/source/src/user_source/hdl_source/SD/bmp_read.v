module bmp_read(
    input                       clk,
    input                       rst,
    // E3 kill switch (SW4=C5). 1 = adaptive: accept any 24bpp BMP inside the
    // supported size window and let bmp_scaler fit it. 0 = legacy: accept
    // 640x480 only, exactly the pre-E3 behaviour (scaler bypassed upstream).
    input                       enable_e3,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [3:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [3:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,

    // E3: accept any 24bpp uncompressed BMP within the supported size window
    output reg                  info_valid,               // 1-clk pulse: header accepted, size latched
    output reg [10:0]           src_width,                // BMP header width  (pixels)
    output reg [10:0]           src_height,               // BMP header height (pixels, positive only)
    output reg [10:0]           px_x,                     // source pixel column of the strobed pixel
    output reg [10:0]           px_y,                     // source pixel row    of the strobed pixel

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
localparam ST_SCAN_CHECK = 3'd5;
localparam ST_LOAD_CHECK = 3'd6;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [15:0] color_planes;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg        header_match_latched;
reg [31:0] scan_match_next_latched;
reg [31:0] scan_miss_next_latched;

// E3: row-aware pixel assembly. BMP rows are padded to a 4-byte boundary,
// so pixel triplets are tracked by byte offset inside the row instead of a
// free-running mod-3 counter (which would desync on padded rows).
reg [11:0] row_bytes;         // width*3 + row pad, latched from the header
reg [11:0] width_x3;          // width*3, latched from the header
reg [10:0] width_m1;          // width-1
reg [10:0] height_m1;         // height-1
reg [12:0] byte_in_row;       // byte offset within the current pixel row

wire [11:0] width_x3_c = {width[10:0], 1'b0} + {1'b0, width[10:0]};
// For 24bpp, (-3*width) mod 4 equals width mod 4.
wire [1:0] row_pad_c = width[1:0];
wire [11:0] row_bytes_c = width_x3_c + {10'd0, row_pad_c};

wire header_match;
wire bmp_data_valid;
wire [31:0] file_sector_count;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;

// E3: supported source window. Lower bound keeps per-row duplicate emission
// provably faster than SD byte arrival (see bmp_scaler.v); upper bound is the
// on-chip row buffer capacity. Top-down (negative height) BMPs stay rejected.
localparam [31:0] SRC_W_MIN = 32'd120;
localparam [31:0] SRC_W_MAX = 32'd1280;
localparam [31:0] SRC_H_MIN = 32'd60;
localparam [31:0] SRC_H_MAX = 32'd1024;
// Header fields finish by byte 33; matching happens only after the full
// 512-byte sector. Precompute metadata in those existing idle cycles.
// No pixel-path latency or FSM/handshake timing changes.
reg [11:0] hdr_stride_q;
reg [10:0] hdr_height_q;
reg [31:0] hdr_pixel_bytes;
reg [31:0] hdr_available_q;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        hdr_stride_q <= 0;
        hdr_height_q <= 0;
        hdr_pixel_bytes <= 0;
        hdr_available_q <= 0;
    end else begin
        hdr_stride_q <= row_bytes_c;
        hdr_height_q <= height[10:0];
        hdr_pixel_bytes <= hdr_stride_q * hdr_height_q;
        hdr_available_q <= file_len - pixel_offset;
    end
end
reg [1:0] write_ack_sync;
always @(posedge clk or posedge rst) begin
    if (rst)
        write_ack_sync <= 2'b00;
    else
        write_ack_sync <= {write_ack_sync[0], write_req_ack};
end

assign ready = (state == ST_IDLE);
// Size acceptance is selected by the E3 switch:
//   enable_e3=1 -> supported window, any aspect ratio, scaler fits it
//   enable_e3=0 -> 640x480 only (pre-E3 behaviour; non-matching files are
//                  skipped as scan_miss, so they neither show nor count)
// Every other header field is checked identically in both modes.
wire size_window_ok = (width  >= SRC_W_MIN) && (width  <= SRC_W_MAX) && !width[31] &&
                      (height >= SRC_H_MIN) && (height <= SRC_H_MAX) && !height[31];
wire size_legacy_ok = (width == 32'd640) && (height == 32'd480);
wire size_ok        = enable_e3 ? size_window_ok : size_legacy_ok;

assign header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      (color_planes == 16'd1) &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0) &&
                      (pixel_offset >= 32'd54) &&
                      (file_len >= pixel_offset) &&
                      size_ok &&
                      (hdr_available_q >= hdr_pixel_bytes);
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt <  file_len);
assign file_sector_count = (file_len == 32'd0) ? 32'd1 : ((file_len + 32'd511) >> 9);
assign next_scan_sector_if_match = scan_sector + file_sector_count;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        color_planes <= 16'd0;
        compression  <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd26: color_planes[7:0] <= sd_sec_read_data;
            10'd27: color_planes[15:8] <= sd_sec_read_data;
            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        byte_in_row <= 13'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid && (bmp_len_cnt >= pixel_offset))
            byte_in_row <= (byte_in_row == {1'b0, row_bytes} - 13'd1) ? 13'd0
                                                                       : byte_in_row + 13'd1;
    end else begin
        byte_in_row <= 13'd0;
    end
end

// Coordinate outputs and RGB are registered together on the third byte.
// Private counters advance afterwards, preserving the final pixel.
reg [10:0] pixel_x, pixel_y;
reg [1:0] component;
reg pixels_done;
wire px_byte = (state == ST_LOAD_DATA) && sd_sec_read_data_valid &&
               (bmp_len_cnt >= pixel_offset) && (bmp_len_cnt < file_len) &&
               (byte_in_row < width_x3) && !pixels_done;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        px_x <= 0; px_y <= 0; pixel_x <= 0; pixel_y <= 0;
        component <= 0; pixels_done <= 0;
        bmp_data_wr_en <= 0; bmp_data <= 0;
    end else begin
        bmp_data_wr_en <= 0;
        if (state != ST_LOAD_DATA) begin
            pixel_x <= 0; pixel_y <= 0; component <= 0; pixels_done <= 0;
        end else if (px_byte) begin
            case (component)
                0: begin bmp_data[7:0] <= sd_sec_read_data; component <= 1; end
                1: begin bmp_data[15:8] <= sd_sec_read_data; component <= 2; end
                2: begin
                    bmp_data[23:16] <= sd_sec_read_data;
                    bmp_data_wr_en <= 1;
                    px_x <= pixel_x; px_y <= pixel_y;
                    component <= 0;
                    if (pixel_x == width_m1) begin
                        pixel_x <= 0;
                        if (pixel_y == height_m1) pixels_done <= 1;
                        else pixel_y <= pixel_y + 11'd1;
                    end else pixel_x <= pixel_x + 11'd1;
                end
                default: component <= 0;
            endcase
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 4'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
            header_match_latched <= 1'b0;
            scan_match_next_latched <= 32'd0;
            scan_miss_next_latched <= 32'd0;
            info_valid <= 1'b0;
            src_width  <= 11'd0;
            src_height <= 11'd0;
            row_bytes  <= 12'd0;
            width_x3   <= 12'd0;
            width_m1   <= 11'd0;
            height_m1  <= 11'd0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 4'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
    end else if (load_abort) begin
        // A failed load does not invalidate the completed media scan.
        // Keep scan_done/scan_found_total so the scheduler can retry.
        state             <= ST_IDLE;
        state_code        <= 4'd1;
        sd_sec_read       <= 1'b0;
        write_req         <= 1'b0;
        scan_found_valid  <= 1'b0;
    end else begin
        scan_found_valid <= 1'b0;
        info_valid       <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 4'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    // Split header arithmetic from the scan commit/limit check.
                    // Capture the decision and next addresses for this sector.
                    header_match_latched <= header_match;
                    scan_match_next_latched <= next_scan_sector_if_match;
                    scan_miss_next_latched <= next_scan_sector_if_miss;
                    state <= ST_SCAN_CHECK;
                end
            end

            ST_SCAN_CHECK: begin
                    sd_sec_read <= 1'b0;
                    if (header_match_latched) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 4'd1;

                        if ((scan_found_total + 4'd1 >= scan_target_count) || (scan_match_next_latched > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= scan_match_next_latched;
                            scan_sector      <= scan_match_next_latched;
                        end else begin
                            sd_sec_read_addr <= scan_match_next_latched;
                            scan_sector      <= scan_match_next_latched;
                            state            <= ST_SCAN;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= scan_miss_next_latched;
                            scan_sector      <= scan_miss_next_latched;
                            state            <= ST_SCAN;
                        end
                    end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    header_match_latched <= header_match;
                    state <= ST_LOAD_CHECK;
                end
            end

            ST_LOAD_CHECK: begin
                    sd_sec_read <= 1'b0;
                    if (header_match_latched) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        // E3: publish the real image geometry to the scaler
                        info_valid <= 1'b1;
                        src_width  <= width[10:0];
                        src_height <= height[10:0];
                        width_x3   <= width_x3_c;
                        row_bytes  <= row_bytes_c;
                        width_m1   <= width[10:0] - 11'd1;
                        height_m1  <= height[10:0] - 11'd1;
                        state      <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_ack_sync[1]) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (bmp_len_cnt >= file_len) begin
                        state <= ST_IDLE;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
