
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    // 最多支持的图片张数（0~8）。索引位宽、扇区表、OSD 均已按 8 放宽。
    parameter [3:0]   SCAN_TARGET_COUNT = 4'd8
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    // E3 kill switch (SW4=C5): 1 = adaptive scaling, 0 = pre-E3 640x480 only.
    input                       enable_e3,
    output reg                  display_valid,
    output      [3:0]           state_code,
    output reg [2:0]            osd_display_page,
    output [3:0]                osd_image_total,
    output                      osd_auto_play,
    output                      osd_e3_on,

    input                       write_finish_toggle,
    input                       read_commit_toggle,
    input [1:0]                 read_active_index,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    // Write-side backpressure from the frame write FIFO (almost full).
    // Legacy (E3 off) tests may leave this unconnected: the scaler is held in
    // reset in that mode and the stall is gated with e3_active below.
    input                       wr_afull,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;
wire key_auto_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
// E3 switch debounce + change detect.
// A DIP switch bounces mechanically, so the raw input is only accepted after
// it held one level for ~10 ms (2^20 cycles at 100 MHz). e3_stable is the level
// actually used by the logic; e3_turned pulses for one clock on a real change.
reg [1:0]  e3_sync;
reg [19:0] e3_stable_cnt;
reg        e3_stable;
reg        e3_stable_d;
wire       e3_turned;
reg e3_active; // committed mode: held throughout scan/load/display commit
wire e3_mode_pending = (e3_stable != e3_active);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        e3_sync       <= 2'b00;
        e3_stable     <= 1'b0;
        e3_stable_cnt <= 20'd0;
        e3_stable_d   <= 1'b0;
    end else begin
        e3_sync     <= {e3_sync[0], enable_e3};
        e3_stable_d <= e3_stable;
        if (e3_sync[1] != e3_stable) begin
            e3_stable_cnt <= e3_stable_cnt + 20'd1;
            if (e3_stable_cnt[19])
                e3_stable <= e3_sync[1];
        end else begin
            e3_stable_cnt <= 20'd0;
        end
    end
end
assign e3_turned = e3_stable ^ e3_stable_d;

// (e3_rescan_now is declared further down, together with the other playback
// handshake wires: it needs bmp_ready / scan_done / load_busy, which are
// declared after this debounce block.)

// E3 scaler stream
wire             scl_info_valid;
wire [10:0]      scl_src_w, scl_src_h;
wire [10:0]      scl_px_x, scl_px_y;
wire             scl_out_valid;
wire [23:0]      scl_out_data;
wire             sd_init_done;
wire             bmp_ready;
// E3 backpressure: gated with e3_active so legacy (E3 off) paths, where the
// scaler is held in reset and wr_afull may be left unconnected, never see X.
wire             scl_stall = (wr_afull & e3_active);
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [3:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [3:0]        img_found_count;
reg [2:0]        img_idx;              // 当前真正显示中的图片编号
reg [2:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg [31:0]       img_sector4;
reg [31:0]       img_sector5;
reg [31:0]       img_sector6;
reg [31:0]       img_sector7;
reg              next_req_pending;
reg              load_busy;
reg [31:0]       load_timeout_cnt;

reg              load_abort;
reg              display_commit_pending;
reg [2:0]        read_commit_sync;
reg [1:0]        read_index_d0, read_index_d1;
wire             display_accept_pulse = read_commit_sync[2] ^ read_commit_sync[1];

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              source_started_seen;
reg              write_done_seen;
reg              write_started_seen;
reg              write_req_d;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [2:0] next_from_current;

// E3: aspect-fit scaler sits between the BMP reader and the SDRAM write
// path; the frame buffer still receives exactly 640x480 pixels per image.
// With the switch off this is a true bypass, not just a looser header check:
// the scaler is held in reset (so it never consumes the stream) and the
// reader's raw pixels go straight to SDRAM -- byte-for-byte the pre-E3 path.
assign write_en   = e3_active ? scl_out_valid : bmp_data_wr_en;
assign write_data = e3_active
                  ? {scl_out_data[23:16], scl_out_data[15:8], scl_out_data[7:0], 8'b0}
                  : {bmp_data[23:16],     bmp_data[15:8],     bmp_data[7:0],     8'b0};

bmp_scaler #(
    .OUT_W              (640),
    .OUT_H              (480),
    .SRC_MAX            (1280)
) bmp_scaler_m0(
    .clk                (clk),
    .rst                (rst | ~e3_active),
    .load_start         (load_start_pulse),
    .info_valid         (scl_info_valid),
    .src_w              (scl_src_w),
    .src_h              (scl_src_h),
    .px_valid           (bmp_data_wr_en),
    .px_data            (bmp_data),
    .px_x               (scl_px_x),
    .px_y               (scl_px_y),
    .out_stall          (scl_stall),
    .out_valid          (scl_out_valid),
    .out_data           (scl_out_data)
);
// Wait until the card is idle before re-scanning: aborting a load mid-frame
// would leave a half-written frame buffer. bmp_ready means the reader is back
// in ST_IDLE and scan_done means the previous pass is finished.
// A persistent desired-vs-active mismatch queues the latest stable request.
// Commit only between transactions, including the downstream display handshake.
wire e3_mode_apply = e3_mode_pending && bmp_ready && !load_busy &&
                     !display_commit_pending && !scan_start_pulse &&
                     !load_start_pulse && !write_req && (!scan_kicked || scan_done);
wire e3_rescan_now = e3_mode_apply && scan_kicked;
always @(posedge clk or posedge rst) begin
    if (rst) e3_active <= 1'b0;
    else if (e3_mode_apply) e3_active <= e3_stable;
end

assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign state_code = state_code_i;
assign osd_image_total = img_found_count;
assign osd_auto_play = auto_play_en;
assign osd_e3_on = e3_active;
// Read-only observer: img_idx is the loaded target, not necessarily displayed.
// Publish only when the existing commit protection accepts the final buffer.
// This block never drives playback state, load requests, or read handshakes.
always @(posedge clk or posedge rst) begin
    if(rst) osd_display_page <= 0;
    else if(!sd_init_done) osd_display_page <= 0;
    else if(display_commit_pending && display_accept_pulse && read_index_d1==disp_buf_idx)
        osd_display_page <= img_idx;
end


key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);

// 下一张 = (cur+1) mod count。count 为 0/1 时恒为 0。
function [2:0] next_index_limited;
    input [2:0] cur;
    input [3:0] count;
    reg   [2:0] nxt;
    begin
        nxt = cur + 3'd1;                 // 3 位自然回绕（7 -> 0）
        if (count == 4'd0)
            next_index_limited = 3'd0;
        else if ({1'b0, nxt} >= count)
            next_index_limited = 3'd0;    // 回绕到第一张
        else
            next_index_limited = nxt;
    end
endfunction

function [31:0] sector_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: sector_lut = img_sector0;
            3'd1: sector_lut = img_sector1;
            3'd2: sector_lut = img_sector2;
            3'd3: sector_lut = img_sector3;
            3'd4: sector_lut = img_sector4;
            3'd5: sector_lut = img_sector5;
            3'd6: sector_lut = img_sector6;
            3'd7: sector_lut = img_sector7;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        read_commit_sync      <= 3'b000;
        read_index_d0         <= 2'd0;
        read_index_d1         <= 2'd0;
        display_commit_pending <= 1'b0;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 4'd0;
        img_idx               <= 3'd0;
        load_idx              <= 3'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;
        img_sector5           <= 32'd0;
        img_sector6           <= 32'd0;
        img_sector7           <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        source_started_seen   <= 1'b0;
        write_done_seen       <= 1'b0;
        write_started_seen    <= 1'b0;
        write_req_d           <= 1'b0;
        display_valid         <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        read_commit_sync <= {read_commit_sync[1:0], read_commit_toggle};
        read_index_d0    <= read_active_index;
        read_index_d1    <= read_index_d0;
        write_req_d      <= write_req;
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;
        // Bundled index is stable before the synchronized commit event.
        if (display_commit_pending && display_accept_pulse && read_index_d1 == disp_buf_idx)
            display_commit_pending <= 1'b0;

        // E3 switch flipped: drop the cached sector table and scan again so the
        // denominator in "PIC n/N" changes live. Reuses the same cleanup the
        // SD-init path performs; scan_kicked=0 re-arms the start-of-day scan.
        if (!sd_init_done || e3_rescan_now) begin
            display_commit_pending <= 1'b0;
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 4'd0;

            load_idx              <= 3'd0;



            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            img_sector4           <= 32'd0;
            img_sector5           <= 32'd0;
            img_sector6           <= 32'd0;
            img_sector7           <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            load_abort            <= 1'b0;
            source_done_seen      <= 1'b0;
            source_started_seen   <= 1'b0;
            write_done_seen       <= 1'b0;
            write_started_seen       <= 1'b0;

            // A media rescan is not a display reset. Keep the proven frame
            // and reader ownership until a replacement is fully written.
            if (!sd_init_done) begin
                img_idx <= 0;
                pending_buf_idx <= 0;
                write_buf_idx <= 0;
                disp_buf_idx <= 0;
                display_valid <= 0;
            end
        end else begin
            // 扫描阶段缓存前 SCAN_TARGET_COUNT 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    4'd0: img_sector0 <= scan_found_sector;
                    4'd1: img_sector1 <= scan_found_sector;
                    4'd2: img_sector2 <= scan_found_sector;
                    4'd3: img_sector3 <= scan_found_sector;
                    4'd4: img_sector4 <= scan_found_sector;
                    4'd5: img_sector5 <= scan_found_sector;
                    4'd6: img_sector6 <= scan_found_sector;
                    4'd7: img_sector7 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < SCAN_TARGET_COUNT)
                    img_found_count <= img_found_count + 4'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && !bmp_ready)
                source_started_seen <= 1'b1;
            if (load_busy && source_started_seen && bmp_ready)
                source_done_seen <= 1'b1;

            // 记住写帧完成脉冲，避免“先写完后源结束”导致脉冲丢失而卡死
            // write_req falls only after the current frame writer ACK.
            // Ignore a previous transaction's late completion during header reading.
            if (load_busy && write_req_d && !write_req)
                write_started_seen <= 1'b1;
            if (load_busy && write_started_seen && write_finish_pulse)
                write_done_seen <= 1'b1;

            // 只有“源图送完 + 整帧写完”都满足，才提交新图并切换显示缓冲区
            if (load_busy && source_done_seen && write_done_seen) begin
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                source_done_seen      <= 1'b0;
                source_started_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                write_started_seen       <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                display_commit_pending <= 1'b1;
                img_idx               <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
            end else if (load_busy) begin
                if (load_timeout_cnt >= 4 * CLK_FREQ_HZ - 1) begin
                    // 超时（例如读到坏图或截断的文件导致死锁），强制释放 busy 以恢复按键响应
                    load_busy             <= 1'b0;
                    load_timeout_cnt      <= 32'd0;
                    source_done_seen      <= 1'b0;
                    source_started_seen      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    write_started_seen       <= 1'b0;
                    load_abort            <= 1'b1;
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // Startup scan of up to eight BMP images.
            if (!scan_kicked && bmp_ready && !e3_mode_apply) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 4'd0;

                load_idx              <= 3'd0;



                next_req_pending      <= 1'b0;

                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                source_started_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                write_started_seen       <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (key_next_press && scan_done && (img_found_count > 4'd0))
                    next_req_pending <= 1'b1;

                // 自动播放开/关
                if (key_auto_press && scan_done && (img_found_count > 4'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // 自动播放 1s 计数：只有当前没有写图任务时才计时
                if (scan_done && auto_play_en && display_valid && !load_busy && !display_commit_pending && first_image_committed && (img_found_count > 4'd1)) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // First image after scan: keep a live display and write its other buffer.
                if (scan_done && !first_image_committed && bmp_ready && !load_busy && (img_found_count != 4'd0)) begin
                    load_idx         <= 3'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_started_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    write_started_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && !display_commit_pending && next_req_pending && (img_found_count != 4'd0)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_started_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    write_started_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && !display_commit_pending && auto_play_en && auto_tick && (img_found_count > 4'd1)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_started_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    write_started_seen  <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .enable_e3              (e3_active),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .info_valid             (scl_info_valid),
    .src_width              (scl_src_w),
    .src_height             (scl_src_h),
    .px_x                   (scl_px_x),
    .px_y                   (scl_px_y),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .abort_req              (load_abort),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
