`timescale 1ns/1ps
// ============================================================================
// Item C: SD read -> BMP decode -> E3 scaler -> SDRAM write, full real-RTL
// co-simulation with a simulated card. No physical TF card is touched.
//
// Real RTL under test : spi_master + sd_card_cmd + sd_card_sec_read_write +
//                       sd_card_top + bmp_read + bmp_scaler (vendor
//                       EG_LOGIC_BRAM model) + sd_card_bmp + frame_read_write
//                       + frame_fifo_write/read + afifo IP + sdram.v.
// Simulated card      : SPI-mode slave below. Command set CMD0/8/55/41/16/17,
//                       R1 responses, 0xFE start token, 512-byte sectors.
//                       Sector 0 holds a synthetic 1280x720 24bpp BMP whose
//                       bytes are computed on the fly (no giant array).
// SDRAM device        : diagnostic EG_PHY_SDRAM_2M_32 (declared NOT
//                       manufacturer-qualified) instantiated inside sdram.v;
//                       it enforces write protocol legality and stores data.
// Verification        : frame pixels are captured at the SDRAM controller's
//                       App write port (32-bit, one pixel per beat) and
//                       compared against the analytic expected frame:
//                       640x480, 60-row letterbox top/bottom, nearest
//                       neighbour sx=2c, sy=2(j-60), word={x^y, y, x, 8'h0}.
//                       WRITE_V_FLIP puts output row j at base+(479-j)*640.
// ============================================================================
module tb;

// SPI bus wires (shared by device model below and the DUT instance)
wire SD_nCS, SD_DCLK, SD_MOSI;

// ---------------------------------------------------------------- clocks ---
reg wc=0, mc=0, vc=0, rst=1;
wire shifted_clk;
assign #9 shifted_clk = mc;
always #5  wc = ~wc;   // 100 MHz sd_card / write domain
always #10 mc = ~mc;   // 50 MHz SDRAM domain
always #20 vc = ~vc;   // 25 MHz video read domain (idle here)

// ------------------------------------------------------- SD SPI device ----
reg [7:0] rsp_q [0:1023];
integer rsp_wr = 0, rsp_rd = 0;
reg stream_mode = 0;
integer stream_state = 0, stream_total = 0, file_pos = 0;

function [7:0] card_byte(input integer o);
    integer p, x, y, k;
    begin
        if (o < 54) begin
            case (o)
                0: card_byte = "B";
                1: card_byte = "M";
                2,3,4,5: card_byte = (o == 2) ? 8'h36 : (o == 3) ? 8'h30 :
                                    (o == 4) ? 8'h2A : 8'h00;      // len 2764854
                10: card_byte = 8'h36;                             // offset 54
                14: card_byte = 8'h28;                             // hdr size 40
                18: card_byte = 8'h00;                             // width 1280
                19: card_byte = 8'h05;
                22: card_byte = 8'hD0;                             // height 720
                23: card_byte = 8'h02;
                26: card_byte = 8'h01;                             // planes
                28: card_byte = 8'h18;                             // 24bpp
                34: card_byte = 8'h00;                             // image size
                35: card_byte = 8'h30;
                36: card_byte = 8'h2A;
                default: card_byte = 8'h00;
            endcase
        end else if (o < 54 + 1280*720*3) begin
            p = (o - 54) / 3;
            k = (o - 54) % 3;
            x = p % 1280;
            y = p / 1280;
            card_byte = (k == 0) ? (x ^ y) : (k == 1) ? y : x;     // B,G,R
        end else
            card_byte = 8'h00;                                     // pad
    end
endfunction

reg [7:0] tx_byte = 8'hFF, rx_shift = 0;
reg [4:0] edge_cnt = 0;        // 0..15 within one SPI byte
reg [3:0] rx_bits = 0;
reg [47:0] cmd_acc = 0;
reg [3:0] cmd_cnt = 0;
integer cmd17_cnt = 0;         // diagnostics: CMD17 running count
// rx byte value at the completing edge
wire [7:0] rx_shift_next = {rx_shift[6:0], SD_MOSI};
// MISO bit presented during the byte: bit7 at device edge 0/1 ... bit0 at 14/15
wire [2:0] tx_bit_idx = edge_cnt[4:1];

// SPI edge engine (parity FIXED round 3): falling edges carry even counts
// (device updates MISO), rising edges carry odd counts (device samples MOSI).
// edge_cnt now increments on every edge; the old version gated the increment
// on the pre-edge parity, which was always even at rising edges, so the
// counter never left 0, the card never received a command and MISO stayed
// 0xFF forever -> sd_card_cmd S_ERR -> sd_init_done never asserted.
always @(negedge SD_DCLK) begin
    if (SD_nCS) begin
        edge_cnt <= 0; rx_bits <= 0; cmd_cnt <= 0;
    end else begin
        if (edge_cnt[0] == 1'b0) begin
            if (edge_cnt == 5'd0) begin
                if (rsp_rd != rsp_wr) begin
                    tx_byte <= rsp_q[rsp_rd];
                    rsp_rd  <= rsp_rd + 1;
                end else if (stream_mode) begin
                    if (stream_state == 0) begin
                        tx_byte <= 8'hFE;
                        stream_state <= 1;
                    end else if (stream_state <= stream_total) begin
                        tx_byte <= card_byte(file_pos);
                        file_pos <= file_pos + 1;
                        stream_state <= stream_state + 1;
                    end else begin
                        tx_byte <= 8'hFF;                      // CRC bytes
                        if (stream_state >= stream_total + 2)
                            stream_mode <= 0;
                        else
                            stream_state <= stream_state + 1;
                    end
                end else
                    tx_byte <= 8'hFF;
            end
        end
        edge_cnt <= (edge_cnt == 5'd15) ? 5'd0 : edge_cnt + 5'd1;
    end
end

always @(posedge SD_DCLK) begin
    if (SD_nCS) begin
        edge_cnt <= 0; rx_bits <= 0; cmd_cnt <= 0;
    end else if (edge_cnt[0] == 1'b1) begin
        rx_shift <= rx_shift_next;
        if (rx_bits == 4'd7) begin
            rx_bits <= 0;
            // byte complete
            if (cmd_cnt != 0) begin
                cmd_acc   <= {cmd_acc[39:0], rx_shift_next};
                cmd_cnt   <= cmd_cnt + 1;
                if (cmd_cnt == 4'd5) begin
                    cmd_cnt <= 0;
                    decode_cmd({cmd_acc[39:0], rx_shift_next});
                end
            end else if (rx_shift_next[7:6] == 2'b01) begin // 0x40|cmd
                cmd_acc <= {40'd0, rx_shift_next};
                cmd_cnt <= 1;
            end
        end else
            rx_bits <= rx_bits + 1;
        edge_cnt <= (edge_cnt == 5'd15) ? 5'd0 : edge_cnt + 5'd1;
    end
end

task decode_cmd(input [47:0] c);
    reg [31:0] arg;
    begin
        arg = {c[39:32], c[31:24], c[23:16], c[15:8]};
        // diagnostic: every command is printed (init issues ~10 total;
        // CMD17 prints only the first 3 and then a running count)
        if (c[45:40] == 6'd17) begin
            cmd17_cnt = cmd17_cnt + 1;
            if (cmd17_cnt <= 3)
                $display("DIAG %0t CMD17 sector=%0d", $time, arg/512);
        end else
            $display("DIAG %0t CMD%0d arg=%h", $time, c[45:40], arg);
        case (c[45:40])
            6'd0:  enqueue(8'h01);                    // CMD0 -> idle
            6'd8:  begin enqueue(8'h01); enqueue(8'h00);
                         enqueue(8'h00); enqueue(8'h01); enqueue(8'hAA); end // R7: R1+4B
            6'd55: enqueue(8'h01);
            6'd41: enqueue(8'h00);                    // ready
            6'd16: enqueue(8'h00);
            6'd17: begin                              // single block read
                       enqueue(8'h00);
                       stream_mode  <= 1;
                       stream_state <= 0;
                       stream_total <= 512;
                       file_pos     <= arg * 512;
                   end
            default: enqueue(8'h00);
        endcase
    end
endtask

task enqueue(input [7:0] b);
    begin
        rsp_q[rsp_wr] = b;
        rsp_wr = rsp_wr + 1;
    end
endtask

assign SD_MISO = SD_nCS ? 1'b1 : tx_byte[3'd7 - tx_bit_idx];

// -------------------------------------------------------- DUT wiring ------
reg  enable_e3 = 1;
reg  key_next = 0;             // tb-driven next-image request (debounced in DUT)
reg  read_req = 0;             // video-side display read request
reg  read_en = 0;              // per-word read FIFO pop (dout valid next clk)

wire        write_req, write_req_ack, write_en, write_finish_toggle_w;
wire [31:0] write_data;
wire        display_valid;
wire  [3:0] state_code;
wire  [1:0] write_buf_idx, disp_buf_idx;
wire        Sdr_init_done, Sdr_init_ref_vld, Sdr_busy;
wire        App_wr_en, App_rd_en, Sdr_rd_en;
wire [20:0] App_wr_addr, App_rd_addr;
wire [31:0] App_wr_din, Sdr_rd_dout;
wire [3:0]  App_wr_dm;
wire        frame_write_finish;
wire        read_req_ack, read_finish;
wire [31:0] read_data;
wire [1:0]  read_active_index;
wire        read_commit_toggle;
reg         frame_write_toggle = 0;

localparam FRAME_PIXELS = 21'd307200;
localparam BUF0_ADDR = 21'd0, BUF1_ADDR = 21'd307200;

sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd6144),
    .SCAN_TARGET_COUNT (4'd1)
) u_bmp (
    .clk               (wc),
    .rst               (rst),
    .key_next          (key_next),
    .key_auto          (1'b0),
    .enable_e3         (enable_e3),
    .display_valid     (display_valid),
    .state_code        (state_code),
    .osd_display_page  (),
    .osd_image_total   (),
    .osd_auto_play     (),
    .osd_e3_on         (),
    .write_finish_toggle(frame_write_toggle),
    .read_commit_toggle(read_commit_toggle),
    .read_active_index (read_active_index),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),
    .write_req         (write_req),
    .write_req_ack     (write_req_ack),
    .write_en          (write_en),
    .write_data        (write_data),
    .SD_nCS            (SD_nCS),
    .SD_DCLK           (SD_DCLK),
    .SD_MOSI           (SD_MOSI),
    .SD_MISO           (SD_MISO)
);

frame_read_write #(
    .ENABLE_WIPE      (1),
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) u_fr (
    .mem_clk           (mc),
    .rst               (rst),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),
    .read_clk          (vc),
    .read_req          (read_req),
    .read_req_ack      (read_req_ack),
    .read_finish       (read_finish),
    .read_commit_toggle(),
    .read_active_index (),
    .osd_transition_mode(),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (21'd0),
    .read_addr_3       (21'd0),
    .transition_mode   (2'd0),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (read_en),
    .read_data         (read_data),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),
    .write_clk         (wc),
    .write_req         (write_req),
    .write_req_ack     (write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (21'd0),
    .write_addr_3      (21'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (write_en),
    .write_data        (write_data)
);

sdram u_sdram (
    .Clk               (mc),
    .Clk_sft           (shifted_clk),
    .Rst               (rst),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// mem-domain toggle of write_finish, as top_tf_hdmi_audio.v does
always @(posedge mc or posedge rst) begin
    if (rst) frame_write_toggle <= 0;
    else if (frame_write_finish) frame_write_toggle <= ~frame_write_toggle;
end

// ----------------------------------------------- sparse event diagnostics --
// Edge-triggered only: state_code changes, one-shot handshakes. No per-clock
// prints. (round-3 authorization item 2)
reg [3:0]  last_state = 4'hF;
reg        init_seen=0, wr_req_seen=0, wr_ack_seen=0, appwr_seen=0;
integer    fw_finish_cnt = 0;
always @(posedge wc) begin
    if (state_code !== last_state) begin
        $display("DIAG %0t bmp_read state %0d->%0d sd_init_done=%0d",
                 $time, last_state, state_code, u_bmp.sd_init_done);
        last_state <= state_code;
    end
    if (!init_seen && u_bmp.sd_init_done) begin
        $display("DIAG %0t sd_init_done asserted", $time);
        init_seen <= 1;
    end
    if (!wr_req_seen && write_req) begin
        $display("DIAG %0t first write_req", $time);
        wr_req_seen <= 1;
    end
    if (!wr_ack_seen && write_req_ack) begin
        $display("DIAG %0t first write_req_ack", $time);
        wr_ack_seen <= 1;
    end
    if (!appwr_seen && App_wr_en) begin
        $display("DIAG %0t first App_wr_en addr=%0d", $time, App_wr_addr);
        appwr_seen <= 1;
    end
    if (frame_write_finish) begin
        fw_finish_cnt = fw_finish_cnt + 1;
        if (fw_finish_cnt <= 2)
            $display("DIAG %0t frame_write_finish #%0d", $time, fw_finish_cnt);
    end
end

// ------------------------------------------------------ verification ------
reg [31:0] shadow [0:614399];
reg [31:0] rb      [0:307199];
integer f1_wr = 0, f2_wr = 0;
integer f1_first = -1, f2_first = -1;
reg f1_done = 0, f2_done = 0;

always @(posedge mc) begin
    if (!rst && App_wr_en) begin
        shadow[App_wr_addr] <= App_wr_din;
        if (!f1_done) begin
            if (f1_wr == 0) f1_first <= App_wr_addr;
            f1_wr <= f1_wr + 1;
            if (f1_wr + 1 == FRAME_PIXELS) f1_done <= 1;
        end else begin
            if (f2_wr == 0) f2_first <= App_wr_addr;
            f2_wr <= f2_wr + 1;
            if (f2_wr + 1 == FRAME_PIXELS) f2_done <= 1;
        end
    end
end

function [31:0] expected_word(input integer k);
    integer c, j, x, y;
    begin
        c = k % 640;
        j = 479 - (k / 640);                   // memory row r -> output row j
        if (j >= 60 && j < 420) begin
            x = 2 * c;
            y = 2 * (j - 60);
            expected_word = {8'(x ^ y), 8'(y), 8'(x), 8'h00};
        end else
            expected_word = 32'h0;
    end
endfunction

integer k, t, errors, total_errors;
reg [31:0] got_word;
task verify_buf(input integer base, input [127:0] name);
    begin
        errors = 0;
        if (base < 0 || base > 307200) begin
            $display("CHAIN FAIL: %0s unexpected base %0d", name, base);
            total_errors = total_errors + 1;
            return;
        end
        for (k = 0; k < 307200; k = k + 1) begin
            got_word = shadow[base + k];
            if (got_word !== expected_word(k)) begin
                if (errors < 8)
                    $display("CHAIN MISMATCH %0s k=%0d got=%h exp=%h", name, k, got_word, expected_word(k));
                errors = errors + 1;
            end
        end
        $display("CHAIN %0s base=%0d errors=%0d", name, base, errors);
        total_errors = total_errors + errors;
    end
endtask

// display read-back: drive read_req, drain read FIFO, collect 307200 words
task do_readback(output integer rb_errors, output integer rb_cnt, output integer rb_idx);
    begin
        rb_errors = 0;
        @(negedge vc);
        read_req = 1;
        t = 0;
        while (!read_req_ack && t < 100000) begin @(negedge vc); t = t + 1; end
        if (!read_req_ack) begin
            $display("CHAIN FAIL: read_req_ack timeout");
            rb_errors = rb_errors + 1;
            rb_cnt = 0; rb_idx = -1;
            return;
        end
        read_req = 0;
        rb_idx = read_active_index;
        for (k = 0; k < FRAME_PIXELS; k = k + 1) begin
            read_en = 1; @(negedge vc);
            read_en = 0; @(negedge vc);          // NOREG: dout valid this cycle
            rb[k] = read_data;
        end
        t = 0;
        while (!read_finish && t < 200000) begin @(negedge vc); t = t + 1; end
        if (!read_finish) begin
            $display("CHAIN FAIL: read_finish timeout");
            rb_errors = rb_errors + 1;
        end
        for (k = 0; k < FRAME_PIXELS; k = k + 1) begin
            if (rb[k] !== expected_word(k)) begin
                if (rb_errors < 8)
                    $display("CHAIN RB MISMATCH k=%0d got=%h exp=%h", k, rb[k], expected_word(k));
                rb_errors = rb_errors + 1;
            end
        end
        rb_cnt = FRAME_PIXELS;
    end
endtask

integer rb_errors, rb_cnt, rb_idx, cnt_at_next;
integer disp_after_commit;
initial begin
    total_errors = 0;
    for (k = 0; k < 614400; k = k + 1) shadow[k] = 32'hFEED0000 + k;
    repeat(10) @(negedge wc);
    rst = 0;
    // ---- stage 1: first image -> buffer 0 ----
    t = 0;
    while (!f1_done && t < 120000000) begin @(negedge wc); t = t + 1; end // 12 s
    if (!f1_done) $fatal(1, "CHAIN FAIL: frame1 not written (f1_wr=%0d state=%0d)", f1_wr, state_code);
    repeat(50000) @(negedge mc);
    verify_buf(f1_first - (479 * 640), "buffer0");
    cnt_at_next = f1_wr;
    if (cnt_at_next != FRAME_PIXELS) begin
        $display("CHAIN FAIL: exact pixel count frame1=%0d (expected %0d)", cnt_at_next, FRAME_PIXELS);
        total_errors = total_errors + 1;
    end
    if (!u_bmp.display_valid) begin
        $display("CHAIN FAIL: display_valid low after first commit");
        total_errors = total_errors + 1;
    end
    $display("DIAG %0t frame1 verified, app_writes=%0d disp_buf_idx=%0d write_buf_idx=%0d",
             $time, f1_wr, disp_buf_idx, write_buf_idx);
    // ---- stage 2: key_next -> second image -> buffer 1 ----
    key_next = 1;  repeat(2500) @(negedge wc);  key_next = 0;   // 25 us high, debounce fires ~1 ms after release
    t = 0;
    while (!f2_done && t < 120000000) begin @(negedge wc); t = t + 1; end // 12 s
    if (!f2_done) $fatal(1, "CHAIN FAIL: frame2 not written (f2_wr=%0d state=%0d)", f2_wr, state_code);
    repeat(50000) @(negedge mc);
    if (f1_wr != FRAME_PIXELS || f2_wr != FRAME_PIXELS) begin
        $display("CHAIN FAIL: exact pixel counts f1=%0d f2=%0d", f1_wr, f2_wr);
        total_errors = total_errors + 1;
    end
    verify_buf(f2_first - (479 * 640), "buffer1");
    if (f2_first != BUF1_ADDR) begin
        $display("CHAIN FAIL: frame2 base %0d != BUF1_ADDR %0d", f2_first, BUF1_ADDR);
        total_errors = total_errors + 1;
    end
    // ---- stage 3: display read-back of the committed buffer ----
    do_readback(rb_errors, rb_cnt, rb_idx);
    total_errors = total_errors + rb_errors;
    $display("DIAG readback cnt=%0d active_index=%0d errors=%0d", rb_cnt, rb_idx, rb_errors);
    if (rb_idx != disp_buf_idx) begin
        $display("CHAIN FAIL: read_active_index %0d != disp_buf_idx %0d", rb_idx, disp_buf_idx);
        total_errors = total_errors + 1;
    end
    // commit propagates: disp_buf_idx must toggle to the other buffer
    disp_after_commit = disp_buf_idx;
    t = 0;
    while (disp_buf_idx == disp_after_commit && t < 20000000) begin @(negedge wc); t = t + 1; end
    if (disp_buf_idx == disp_after_commit) begin
        $display("CHAIN FAIL: disp_buf_idx did not toggle after read commit");
        total_errors = total_errors + 1;
    end
    if (total_errors) $fatal(1, "CHAIN FAIL total_errors=%0d", total_errors);
    $display("PASS SD->BMP->scaler->SDRAM chain 1280x720: buffer0+buffer1 verified (%0d+%0d pixels exact), display read-back %0d pixels verified, disp_buf_idx %0d->%0d, black_rest=%0d",
             f1_wr, f2_wr, rb_cnt, disp_after_commit, disp_buf_idx, u_bmp.bmp_scaler_m0.black_rest);
    $finish;
end

initial begin
    #20000000000.0;
    $display("CHAIN WATCHDOG state=%0d f1_wr=%0d f2_wr=%0d f1_first=%0d f2_first=%0d",
             state_code, f1_wr, f2_wr, f1_first, f2_first);
    $fatal(1, "CHAIN WATCHDOG");
end
endmodule
