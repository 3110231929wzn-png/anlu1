`timescale 1ns/1ps
// ============================================================================
// E3: aspect-fit nearest-neighbor scaler on the TF-card load path.
//
// Input : pixel stream from bmp_read (source rows in BMP bottom-up order,
//         with per-pixel px_x/px_y and one info_valid pulse carrying W/H).
// Output: exactly OUT_W*OUT_H pixels per image (out_valid/out_data), rows
//         still in bottom-up order so the WRITE_V_FLIP addressing downstream
//         keeps working unchanged.
//
// Geometry: scale = min(OUT_W/W, OUT_H/H), centred, letterbox black.
// Sampling: nearest neighbour via 16.16 fixed-point phase stepping over the
//           content window only:
//           x_step = (W << 16) / out_w,  src_col = (x_phase) >> 16
//             y_step = (H << 16) / out_h,  src_row = (y_phase) >> 16
//           phases restart at zero for each content row / at the first
//           content column, so letterbox columns never disturb the mapping.
//           Phase drift over a full line/frame stays far below one source
//           pixel. The three divisions run once per image on a small
//           sequential divider; no variable division sits in any per-pixel
//           path.
//
// Buffering: two source-row ping-pong buffers. SD delivers pixels far slower
//           than clk, so writes are passive; the emitter drains one buffer
//           while the other absorbs the next row. For the accepted source
//           window (W>=120, H>=60, enforced in bmp_read.v) the worst-case
//           duplicate burst (<= ceil(480/60)+1 rows x 640 px) always finishes
//           long before the same buffer is written again.
// Safety   : if a buffer is ever overwritten before consumption (impossible
//           inside the accepted window), the rest of the frame is emitted
//           black instead of deadlocking the write path.
//
// Backpressure (E3 Round 7): out_stall is the write FIFO almost-full flag.
// The emitter runs on the 100 MHz write clock while the FIFO drains at the
// 50 MHz memory clock, so a 640-pixel row cannot be absorbed by a 512-deep
// FIFO without flow control. While out_stall is high, S_ROW freezes col and
// x_phase and suppresses vld_d: the pending pixel is HELD and re-issued
// unchanged when the FIFO drains, so no pixel is lost, duplicated or
// shifted. The 1-cycle registered output stage keeps its alignment because
// the frozen phase keeps rd_addr (and thus rd_data) stable; at most one
// already-issued pixel is in flight when afull rises (509 + 1 = 510/512).
// ============================================================================
module bmp_scaler #(
    parameter integer OUT_W   = 640,
    parameter integer OUT_H   = 480,
    parameter integer SRC_MAX = 1280   // keep equal to bmp_read.v SRC_W_MAX
)(
    input                       clk,
    input                       rst,
    input                       load_start,   // new image starts: full reset
    input                       info_valid,   // 1-clk pulse: W/H valid
    input  [10:0]               src_w,
    input  [10:0]               src_h,
    input                       px_valid,
    input  [23:0]               px_data,
    input  [10:0]               px_x,
    input  [10:0]               px_y,
    input                       out_stall,    // FIFO almost-full: hold, never drop
    output reg                  out_valid,
    output reg [23:0]           out_data
);

    localparam [23:0] BLACK = 24'h000000;

    localparam S_IDLE = 3'd0, S_DIV = 3'd1, S_RUN = 3'd2,
               S_ROW  = 3'd3, S_FLUSH = 3'd4, S_NEXT = 3'd5, S_DONE = 3'd6;

    // ------------------------------------------------------------------
    // source row ping-pong buffers: 2 x (2048 x 24) block RAM.
    // The behavioural arrays were inferred as distributed (LUT) RAM by TD
    // and cost ~7.2k LUTs, so EG_LOGIC_BRAM is instantiated explicitly.
    //   port A : write side (SD pixel capture), no output register
    //   port B : read side  (emitter), NOREG -> 1-cycle sync-read latency,
    //            matching the FSM alignment. Vendor EG_LOGIC_BRAM probe
    //            (tests/e3_bram, ModelSim + TD sim_release model) measured
    //            OUTREG at 2 cycles, which shifts every row one source pixel;
    //            NOREG matches the behavioural arrays the image tests used.
    // ------------------------------------------------------------------
    reg        ready_f [0:1];
    reg [10:0] ready_r [0:1];

    reg [2:0]  state;
    reg        run_en;              // geometry latched, accepting pixels
    reg        black_rest;          // defensive: emit remaining frame black
    reg [10:0] w, h;
    reg [10:0] out_w, out_h;
    reg [10:0] x0, y0;
    reg [1:0]  div_stage;           // 0: fit size, 1: x_step, 2: y_step
    wire [26:0] fit_num_w = src_h * OUT_W;
    wire [26:0] fit_num_h = src_w * OUT_H;
    wire fit_width_now = fit_num_w <= fit_num_h;
    reg        fit_width;           // 640*H <= 480*W

    // ---------------- sequential divider (one-shot per stage) ----------
    // restoring division: num(27 bit) / den(11 bit) -> quo in dreg[26:0]
    reg [37:0] dreg;                // {rem[10:0], num[26:0]}
    reg [10:0] d_den;
    reg [4:0]  d_cnt;
    wire [11:0] d_rem_sh  = {dreg[37:27], dreg[26]};   // rem<<1 | num msb
    wire        d_sub     = (d_rem_sh >= d_den);
    wire [11:0] d_rem_nxt = d_sub ? (d_rem_sh - {1'b0,d_den}) : d_rem_sh;
    wire [37:0] dreg_nxt  = {d_rem_nxt[10:0], dreg[25:0], d_sub};

    reg [26:0] x_step;              // (W<<16)/out_w
    reg [26:0] y_step;              // (H<<16)/out_h
    reg [26:0] x_phase;             // source column phase (content cols only)
    reg [26:0] y_phase;             // source row phase (content rows only)

    // ---------------- emission engine ---------------------------------
    reg [10:0] cur_row;             // source row being emitted
    reg [10:0] j;                   // output row index
    reg [10:0] col;                 // output column being issued
    reg        vld_d, span_d;
    reg        buf_sel;             // parity of cur_row

    wire        row_in     = (j >= y0) && (j < y0 + out_h);
    wire        in_content = (col >= x0) && (col < x0 + out_w);
    wire        x_clamp    = (x_phase >= {w, 16'd0});
    // combinational read address; rd_data then aligns with span_d exactly
    // one cycle later (sync-read BRAM, no extra stage)
    wire [10:0] rd_addr    = (state == S_ROW && in_content)
                         ? (x_clamp ? (w - 11'd1) : x_phase[26:16])
                         : 11'd0;

    wire [26:0] y_nxt    = y_phase + y_step;
    wire [10:0] srow_nxt = y_nxt[26:16];

    // block-RAM read ports (registered inside the macro: 1-cycle latency)
    wire [23:0] rd0_q, rd1_q;
    wire [23:0] rd_data = buf_sel ? rd1_q : rd0_q;

    // ---------------- passive pixel capture ---------------------------
    wire       wr_sel  = px_y[0];
    wire       wr_en   = run_en && px_valid && !black_rest;
    wire       buf_row_last = run_en && px_valid && (px_x == w - 11'd1);
    reg        consume;        // single-writer handshake: emitter drains a row
    reg        consume_sel;
    wire       we0 = wr_en && !wr_sel;
    wire       we1 = wr_en &&  wr_sel;

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A (24    ), .DATA_WIDTH_B (24      ),
        .ADDR_WIDTH_A (11    ), .ADDR_WIDTH_B (11      ),
        .DATA_DEPTH_A (2048  ), .DATA_DEPTH_B (2048    ),
        .BYTE_ENABLE  (0     ),
        .MODE         ("DP"  ),
        .REGMODE_A    ("NOREG" ),
        .REGMODE_B    ("NOREG"),
        .WRITEMODE_A  ("NORMAL"),
        .WRITEMODE_B  ("NORMAL"),
        .RESETMODE    ("SYNC"  ),
        .IMPLEMENT    ("9K"    )
    ) u_row_buf0 (
        .dia   (px_data), .addra (px_x   ), .cea (1'b1), .ocea (1'b1),
        .clka  (clk    ), .wea   (we0    ), .rsta (1'b0), .bea  (1'b1),
        .dib   (24'd0  ), .addrb (rd_addr), .ceb (1'b1), .oceb (1'b1),
        .clkb  (clk    ), .web   (1'b0   ), .rstb (1'b0), .beb  (1'b1),
        .doa   (       ), .dob   (rd0_q  )
    );

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A (24    ), .DATA_WIDTH_B (24      ),
        .ADDR_WIDTH_A (11    ), .ADDR_WIDTH_B (11      ),
        .DATA_DEPTH_A (2048  ), .DATA_DEPTH_B (2048    ),
        .BYTE_ENABLE  (0     ),
        .MODE         ("DP"  ),
        .REGMODE_A    ("NOREG" ),
        .REGMODE_B    ("NOREG"),
        .WRITEMODE_A  ("NORMAL"),
        .WRITEMODE_B  ("NORMAL"),
        .RESETMODE    ("SYNC"  ),
        .IMPLEMENT    ("9K"    )
    ) u_row_buf1 (
        .dia   (px_data), .addra (px_x   ), .cea (1'b1), .ocea (1'b1),
        .clka  (clk    ), .wea   (we1    ), .rsta (1'b0), .bea  (1'b1),
        .dib   (24'd0  ), .addrb (rd_addr), .ceb (1'b1), .oceb (1'b1),
        .clkb  (clk    ), .web   (1'b0   ), .rstb (1'b0), .beb  (1'b1),
        .doa   (       ), .dob   (rd1_q  )
    );
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ready_f[0] <= 1'b0; ready_f[1] <= 1'b0;
            ready_r[0] <= 11'd0; ready_r[1] <= 11'd0;
        end else if (load_start || (state == S_IDLE)) begin
            ready_f[0] <= 1'b0; ready_f[1] <= 1'b0;
        end else begin
            if (consume)
                ready_f[consume_sel] <= 1'b0;
            if (buf_row_last) begin
                ready_f[wr_sel] <= 1'b1;
                ready_r[wr_sel] <= px_y;
            end
        end
    end

    // ---------------- output pipeline (1-cycle sync-read latency) ------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_data  <= BLACK;
        end else begin
            out_valid <= vld_d;
            out_data  <= span_d ? rd_data : BLACK;
        end
    end

    // ---------------- main FSM -----------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE; run_en <= 1'b0; black_rest <= 1'b0;
            vld_d <= 1'b0; span_d <= 1'b0;
            consume <= 1'b0; consume_sel <= 1'b0;
            w <= 11'd0; h <= 11'd0; out_w <= 11'd0; out_h <= 11'd0;
            x0 <= 11'd0; y0 <= 11'd0; fit_width <= 1'b0; div_stage <= 2'd0;
            dreg <= 38'd0; d_den <= 11'd0; d_cnt <= 5'd0;
            x_step <= 27'd0; y_step <= 27'd0;
            x_phase <= 27'd0; y_phase <= 27'd0;
            cur_row <= 11'd0; j <= 11'd0; col <= 11'd0;
            buf_sel <= 1'b0;
        end else if (load_start) begin
            state   <= S_IDLE;
            run_en  <= 1'b0;
            black_rest <= 1'b0;
            vld_d   <= 1'b0; span_d <= 1'b0;
        end else begin
            consume <= 1'b0;    // default: no row drain this cycle
            case (state)
                // ---------------- latch geometry, start divisions --------
                S_IDLE: begin
                    vld_d  <= 1'b0;
                    span_d <= 1'b0;
                    if (info_valid) begin
                        w          <= src_w;
                        h          <= src_h;
                        run_en     <= 1'b1;
                        black_rest <= 1'b0;
                        j          <= 11'd0;
                        y_phase    <= 27'd0;
                        fit_width  <= fit_width_now;
                        // stage 0: fit size. dividend = 640*H or 480*W
                        div_stage  <= 2'd0;
                        d_den      <= fit_width_now ? src_w : src_h;
                        dreg       <= {11'd0, fit_width_now ? fit_num_w : fit_num_h};
                        d_cnt      <= 5'd27;
                        state      <= S_DIV;
                    end
                end

                // ---------------- one-shot sequential divider ------------
                S_DIV: begin
                    if (d_cnt != 5'd0) begin
                        dreg <= dreg_nxt;
                        d_cnt <= d_cnt - 5'd1;
                    end else begin
                        // quotient ready in dreg[26:0]; chain next stage
                        d_cnt <= 5'd27;
                        case (div_stage)
                            2'd0: begin
                                if (fit_width) begin
                                    out_w <= 11'd640;
                                    out_h <= dreg[10:0];        // = 640*H/W <= 480
                                    div_stage <= 2'd1;
                                    d_den     <= 11'd640;       // x_step = (W<<16)/640
                                end else begin
                                    out_h <= 11'd480;
                                    out_w <= dreg[10:0];        // = 480*W/H <= 640
                                    div_stage <= 2'd1;
                                    d_den     <= dreg[10:0];    // x_step = (W<<16)/out_w
                                end
                                dreg <= {11'd0, w, 16'd0};      // W << 16
                            end
                            2'd1: begin
                                x_step    <= dreg[26:0];
                                div_stage <= 2'd2;
                                d_den     <= out_h;             // y_step = (H<<16)/out_h
                                dreg      <= {11'd0, h, 16'd0}; // H << 16
                            end
                            default: begin
                                y_step  <= dreg[26:0];
                                x0      <= (11'd640 - out_w) >> 1;
                                y0      <= (11'd480 - out_h) >> 1;
                                x_phase <= 27'd0;
                                y_phase <= 27'd0;
                                cur_row <= 11'd0;
                                buf_sel <= 1'b0;
                                col     <= 11'd0;
                                // y0==0 means output row 0 is already content
                                state   <= (((11'd480 - out_h) >> 1) == 11'd0) ? S_RUN : S_ROW;
                            end
                        endcase
                    end
                end

                // ---------------- wait for the needed source row ---------
                S_RUN: begin
                    consume <= 1'b0;
                    if (black_rest ||
                        (ready_f[buf_sel] && (ready_r[buf_sel] == cur_row))) begin
                        consume     <= 1'b1;
                        consume_sel <= buf_sel;
                        col     <= 11'd0;
                        x_phase <= 27'd0;
                        state   <= S_ROW;
                    end else if (ready_f[buf_sel] && ready_r[buf_sel] > cur_row) begin
                        // overwritten before consumption (outside the safe
                        // window): finish the frame in black, no deadlock
                        black_rest  <= 1'b1;
                        consume     <= 1'b1;
                        consume_sel <= buf_sel;
                        col     <= 11'd0;
                        x_phase <= 27'd0;
                        state   <= S_ROW;
                    end
                end

                // ---------------- issue one output row (OUT_W cycles) ----
                S_ROW: begin
                    // Write-FIFO backpressure: hold the pending pixel, do NOT
                    // advance col / x_phase / row state. Because the phase is
                    // frozen, rd_addr and the registered rd_data stay on the
                    // same pixel, so the resume cycle re-issues it exactly
                    // once (no duplicate, no skip, no row shift).
                    if (out_stall) begin
                        vld_d  <= 1'b0;
                        span_d <= 1'b0;
                    end else begin
                        vld_d   <= 1'b1;
                        span_d  <= in_content && row_in && !black_rest;
                        col     <= col + 11'd1;
                        if (in_content)
                            x_phase <= x_phase + x_step;
                        else if (col < x0)
                            x_phase <= 27'd0;       // hold phase until content starts
                        if (col == OUT_W[10:0] - 11'd1)
                            state <= S_FLUSH;
                    end
                end

                S_FLUSH: begin
                    vld_d  <= 1'b0;
                    span_d <= 1'b0;
                    state  <= S_NEXT;
                end

                // ---------------- advance to the next output row ---------
                S_NEXT: begin
                    if (j == OUT_H[10:0] - 11'd1) begin
                        state <= S_DONE;
                    end else begin
                        j <= j + 11'd1;
                        if ((j + 11'd1) >= y0 + out_h) begin
                            // trailing letterbox (or black_rest): no wait
                            col     <= 11'd0;
                            x_phase <= 27'd0;
                            state   <= S_ROW;
                        end else if ((j + 11'd1) == y0) begin
                            // first content row: phases restart at zero
                            y_phase <= 27'd0;
                            cur_row <= 11'd0;
                            buf_sel <= 1'b0;
                            state   <= S_RUN;
                        end else if (j < y0) begin
                            // leading letterbox: no wait
                            col     <= 11'd0;
                            x_phase <= 27'd0;
                            state   <= S_ROW;
                        end else begin
                            // content -> content row transition
                            y_phase <= y_nxt;
                            if (srow_nxt != cur_row) begin
                                cur_row <= srow_nxt;
                                buf_sel <= srow_nxt[0];
                                state   <= S_RUN;
                            end else begin
                                col     <= 11'd0;
                                x_phase <= 27'd0;
                                state   <= S_ROW;   // duplicate of the same row
                            end
                        end
                    end
                end

                S_DONE: begin
                    vld_d <= 1'b0;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
