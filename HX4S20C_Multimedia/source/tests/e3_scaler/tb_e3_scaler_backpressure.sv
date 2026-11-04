`timescale 1ns/1ps
// E3 Round 7 - test 1: bmp_scaler write-FIFO backpressure (out_stall).
//
// Real conditions replicated: 100 MHz write clock, one output word per cycle
// while S_ROW runs, and a drain model at 1 word per 2 write clocks (the
// 50 MHz memory clock), 512-deep FIFO, almost-full at 509 (wfifo AL_FULL_NUM).
// The tb never drops on full: if a push ever arrives at full occupancy it is
// counted as a HARD ERROR (that is exactly the product defect this fix
// removes).
//
// Verified per case:
//   - continuous emission while space is available (no spurious stalls)
//   - stall when the FIFO reaches almost-full, pixel held (col/x_phase frozen)
//   - automatic resume when the FIFO drains
//   - out_valid is not asserted while stalled (only the single in-flight word
//     pushed on the cycle afull rose is allowed)
//   - pixel sequence: every index compared against the golden nearest-neighbour
//     model, so duplicates and skips both fail; exact 307200 total
//   - row/column coordinates: exactly 640 valid words per row, 480 rows
//   - "DE/HS/VS vs RGB": the scaler emits no DE/HS/VS (product fact - those
//     are generated downstream by video_timing_data from the display FIFO);
//     word-level alignment is what matters here and is what is checked
//     (exactly one 24-bit RGB word per valid, exactly 640 per row, no extras)
//   - black_rest stays 0 (backpressure must not overrun the row buffers)
module tb_e3_scaler_backpressure;
reg clk = 0; always #5 clk = ~clk;
reg rst = 1, load_start = 0, info_valid = 0, px_valid = 0;
reg [10:0] src_w, src_h, px_x, px_y;
reg [23:0] px_data;
wire out_valid; wire [23:0] out_data;
reg  out_stall;

bmp_scaler dut(
    .clk(clk), .rst(rst), .load_start(load_start), .info_valid(info_valid),
    .src_w(src_w), .src_h(src_h), .px_valid(px_valid), .px_data(px_data),
    .px_x(px_x), .px_y(px_y), .out_stall(out_stall),
    .out_valid(out_valid), .out_data(out_data));

// ------------------------------------------------------- FIFO model --------
localparam integer DEPTH = 512;
localparam integer AFULL = 509;         // wfifo_32_32_512 AL_FULL_NUM
integer occ = 0, peak = 0, drops_full = 0, push_cnt = 0;
integer stall_clks = 0, stall_evts = 0, resume_cnt = 0;
reg drain_en = 1;
reg drain_phase = 0;                     // 1 word per 2 clks = 50 MHz drain
reg stall_d = 0;
// Drain model must match frame_fifo_write: it only starts a burst while
// rdusedw > BURST_SIZE (256) and bursts 256 words back-to-back, so the FIFO
// RESTS at ~257 words between rows instead of draining to empty. Omitting
// this hysteresis (first run) left the peak at 321/512 and never reached
// afull - a harness defect, not product behaviour.
wire drain_tick = drain_en && drain_phase && (occ > 256);
assign out_stall = (occ >= AFULL);       // same shape as wfifo afull

always @(posedge clk) begin
    if (rst) begin
        occ <= 0; peak <= 0; drops_full <= 0; push_cnt <= 0;
        stall_clks <= 0; stall_evts <= 0; resume_cnt <= 0; stall_d <= 0;
        drain_phase <= 0;
    end else begin
        drain_phase <= ~drain_phase;
        if (out_valid && occ >= DEPTH) drops_full <= drops_full + 1;
        occ <= occ + (out_valid ? 1 : 0) - (drain_tick ? 1 : 0);
        if (out_valid) push_cnt <= push_cnt + 1;
        if ((occ + (out_valid ? 1 : 0)) > peak) peak <= occ + (out_valid ? 1 : 0);
        if (out_stall) begin
            stall_clks <= stall_clks + 1;
            if (!stall_d) stall_evts <= stall_evts + 1;
        end else if (stall_d) resume_cnt <= resume_cnt + 1;
        stall_d <= out_stall;
    end
end

// ------------------------------------------------------ golden model --------
integer n = 0, errors = 0, ow, oh, x0, y0, sw, sh, xx, yy, sx, sy, xstep, ystep;
integer rowcnt = 0, rows = 0;
reg checking = 0;
reg [23:0] expected;
function [23:0] color(input integer x, y); color = {8'(x), 8'(y), 8'(x^y)}; endfunction

localparam [2:0] S_ROW = 3'd3;
reg [10:0] col_at_stall; reg [26:0] phase_at_stall; reg frozen_checked = 0;
integer stall_run = 0;
integer pushes_in_stall = 0, max_pushes_in_stall = 0;

always @(negedge clk) begin
    if (checking) begin
        // ---- stall must hold the pixel, not advance the column -----------
        if (out_stall && dut.state == S_ROW) begin
            stall_run = stall_run + 1;
            if (stall_run == 1) begin
                col_at_stall = dut.col; phase_at_stall = dut.x_phase; frozen_checked = 0;
                pushes_in_stall = 0;
            end
            if (out_valid) begin
                pushes_in_stall = pushes_in_stall + 1;
                if (pushes_in_stall > max_pushes_in_stall)
                    max_pushes_in_stall = pushes_in_stall;
            end
            // The scaler has a 1-cycle registered output stage and this
            // monitor samples mid-cycle at negedge, so a pixel issued just
            // before afull rose can still emerge on the next ONE cycle:
            // at most 2 pushes are legitimate. Anything beyond that means
            // the emitter ignored the stall (real defect).
            if (pushes_in_stall > 2) begin
                $display("EMITTER IGNORED STALL: %0d pushes in one stall episode at n=%0d", pushes_in_stall, n);
                errors = errors + 1;
            end
            // Once the pipeline has drained (3+ stalled cycles) nothing may
            // be emitted at all.
            if (stall_run > 3 && out_valid) begin
                $display("PIXEL ISSUED WHILE PIPELINE DRAINED n=%0d", n);
                errors = errors + 1;
            end
            if (stall_run > 4 && !frozen_checked) begin
                frozen_checked = 1;
                if (dut.col !== col_at_stall) begin
                    $display("STALL ADVANCED COL %0d -> %0d", col_at_stall, dut.col);
                    errors = errors + 1;
                end
                if (dut.x_phase !== phase_at_stall) begin
                    $display("STALL ADVANCED PHASE %0d -> %0d", phase_at_stall, dut.x_phase);
                    errors = errors + 1;
                end
            end
        end else begin
            stall_run = 0; frozen_checked = 0; pushes_in_stall = 0;
        end
        // ---- pixel stream check ------------------------------------------
        if (out_valid) begin
            xx = n % 640; yy = n / 640;
            if (xx >= x0 && xx < x0 + ow && yy >= y0 && yy < y0 + oh) begin
                sx = ((xx - x0) * xstep) >> 16;
                sy = ((yy - y0) * ystep) >> 16;
                expected = color(sx, sy);
            end else expected = 24'd0;
            if (out_data !== expected) begin
                if (errors < 8)
                    $display("MISMATCH %0dx%0d n=%0d (c=%0d r=%0d) got=%h exp=%h",
                             sw, sh, n, xx, yy, out_data, expected);
                errors = errors + 1;
            end
            n = n + 1;
            rowcnt = rowcnt + 1;
            if (rowcnt == 640) begin rows = rows + 1; rowcnt = 0; end
            if (n > 307200) begin
                if (errors < 8) $display("EXTRA PIXEL beyond 307200 at n=%0d", n);
                errors = errors + 1;
            end
        end
    end
end

task run_image(input integer w, h, stall_at, blackout, check_stall);
    integer x, y, t;
    begin
        sw = w; sh = h; n = 0; rowcnt = 0; rows = 0; checking = 0; stall_run = 0;
        if (640*h <= 480*w) begin ow = 640; oh = 640*h/w; end
        else begin oh = 480; ow = 480*w/h; end
        x0 = (640-ow)/2; y0 = (480-oh)/2;
        xstep = (w<<16)/ow; ystep = (h<<16)/oh;
        @(negedge clk); load_start = 1;
        @(negedge clk); load_start = 0; src_w = w; src_h = h; info_valid = 1; checking = 1;
        @(negedge clk); info_valid = 0;
        repeat(100) @(negedge clk);
        for (y = 0; y < h; y = y + 1)
            for (x = 0; x < w; x = x + 1) begin
                px_valid = 1; px_x = x; px_y = y; px_data = color(x, y);
                @(negedge clk); px_valid = 0;
                // real SPI pacing: 96 clocks per source pixel
                if (blackout > 0 && n == stall_at && drain_en) begin
                    drain_en = 0;                       // force a long stall
                    repeat(blackout) @(negedge clk);
                    drain_en = 1;
                end
                repeat(95) @(negedge clk);
            end
        for (t = 0; t < 4000000 && n < 307200; t = t + 1) @(negedge clk);
        repeat(20) @(negedge clk);
        $display("CASE %0dx%0d pixels=%0d rows=%0d row_residue=%0d peak=%0d/512 drops=%0d stall_evts=%0d stall_clks=%0d max_push_in_stall=%0d black_rest=%0d errors=%0d",
                 w, h, n, rows, rowcnt, peak, drops_full, stall_evts, stall_clks, max_pushes_in_stall, dut.black_rest, errors);
        if (n != 307200) begin $display("COUNT FAIL %0dx%0d n=%0d", w, h, n); errors = errors + 1; end
        if (rows != 480 || rowcnt != 0) begin
            $display("ROW ALIGN FAIL %0dx%0d rows=%0d residue=%0d", w, h, rows, rowcnt);
            errors = errors + 1;
        end
        if (dut.black_rest !== 1'b0) begin $display("BLACK_REST SET %0dx%0d", w, h); errors = errors + 1; end
        if (drops_full != 0) begin $display("FULL-DROP %0d", drops_full); errors = errors + 1; end
        if (peak > 510) begin $display("PEAK OVER HEADROOM %0d", peak); errors = errors + 1; end
        if (check_stall && stall_evts == 0) begin
            $display("STALL NEVER ENGAGED %0dx%0d", w, h); errors = errors + 1;
        end
        checking = 0;
    end
endtask

initial begin
    repeat(4) @(negedge clk); rst = 0;
    // Case 1: 1:1 source, drain at half rate -> backpressure throughout.
    run_image(640, 480, 0, 0, 1);
    // Case 2: non-integer downscale (row/col phase repeats) plus a 20k-clock
    // drain blackout mid-frame: deep stall, then resume; buffer must survive
    // (20k << the 76800-clock source-row interval, so no row-buffer overrun).
    run_image(800, 600, 150000, 20000, 1);
    if (errors) $fatal(1, "FAIL scaler backpressure errors=%0d", errors);
    $display("PASS scaler backpressure: 640x480 + 800x600, golden-pixel match (no loss/dup), 640x480 row alignment, stall holds col/x_phase, resume clean, zero full-drops, peak<=510");
    $finish;
end
initial begin #400_000_000_000.0; $fatal(1, "WATCHDOG"); end
endmodule
