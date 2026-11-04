`timescale 1ns/1ps
// Round 4 item C: sector-interface-level dynamic verification of the E3 chain.
//
// Reuses the previously-passing sector card model protocol (see
// sd_sector_model.sv header). The following modules are REAL product RTL with
// zero modifications: sd_card_bmp (scan/scheduler) -> bmp_read (header/sector
// streaming) -> bmp_scaler (REGMODE_B NOREG fix) -> frame_fifo_write ->
// frame_read_write -> sdram.v controller. The vendor EG_LOGIC_BRAM sim model
// and the diagnostic SDRAM device model provide memory behaviour.
//
// Dynamically verified this run (sector interface and above):
//   2-image scan, first-image auto-load into buffer 0, exact 307200-pixel
//   write, full-frame word compare (RGB + letterbox black + v-flip row map),
//   display readback through the real read path, key_next load of image B
//   into buffer 1 with buffer 0 proven untouched, second readback and commit,
//   write-FIFO pressure at the REAL RTL byte rate (56 wc clks/byte,
//   16.667 MHz SPI): full-state counted directly, silent full-drop alarm,
//   occupancy watermark, exact 307200 App writes per write_finish.
//
// NOT verified here (sector interface and below): SPI byte transport, SD
// command codec, card init FSM - baseline coverage, intentionally not re-run.
module tb_e3_sector_chain;
// ---------------------------------------------------------------- clocks ---
reg wc=0, mc=0, vc=0, rst=1;
always #5  wc = ~wc;   // 100 MHz: SD/write domain
always #10 mc = ~mc;   //  50 MHz: SDRAM controller
always #20 vc = ~vc;   //  25 MHz: video/read domain
wire physical_clock;
assign #9.0 physical_clock = mc;          // controller phase shift (data-loop pattern)

// ----------------------------------------------------------------- DUTs ----
wire init, refresh, busy, rdvalid, wreq, wack, wfinish, rreq_ack, rfinish, commit;
wire wen, re;      // wen: u_bmp.write_en -> fr.write_en (pixel push into FIFO)
wire app_we;       // app_we: fr.App_wr_en -> sd.App_wr_en (controller write strobe)
wire wr_afull;     // fr.wr_afull -> u_bmp.wr_afull (write-FIFO backpressure)
wire [31:0] wdata, dout, wrdata, pixel;
wire [20:0] wa, ra;
wire [3:0] dm;
wire [1:0] wr_idx, disp_idx, disp_active;
wire display_valid;
wire [3:0] state_code;
wire [3:0] osd_total;
reg key_next=1,wfin_tgl=0,timing_rst=1;
wire rreq,ren,timing_de;
video_timing_data timing(.video_clk(vc),.rst(rst|timing_rst),.read_req(rreq),.read_req_ack(rreq_ack),.hs(),.vs(),.de(timing_de));
assign ren=timing_de & ~timing_rst;
integer read_underflows=0;
always @(posedge vc) if(!rst && ren && fr.read_buf.empty_flag)begin
 read_underflows=read_underflows+1;$fatal(1,"READ FIFO UNDERFLOW progress=%0d",fr.g_wipe.reader.progress);
end

sdram sd(.Clk(mc),.Clk_sft(physical_clock),.Rst(rst),.Sdr_init_done(init),
  .Sdr_init_ref_vld(refresh),.Sdr_busy(busy),.App_wr_en(app_we),.App_wr_addr(wa),
  .App_wr_dm(dm),.App_wr_din(wrdata),.App_rd_en(re),.App_rd_addr(ra),
  .Sdr_rd_en(rdvalid),.Sdr_rd_dout(dout));
defparam sd.sdram.READ_DELAY_NS = 5.4;

frame_read_write #(.ENABLE_WIPE(1),.WRITE_V_FLIP(1),.FRAME_WIDTH(640),.FRAME_HEIGHT(480)) fr(
  .rst(rst),.mem_clk(mc),.Sdr_init_done(init),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),
  .App_rd_en(re),.App_rd_addr(ra),.Sdr_rd_en(rdvalid),.Sdr_rd_dout(dout),
  .read_clk(vc),.read_req(rreq),.read_req_ack(rreq_ack),.read_finish(rfinish),
  .read_commit_toggle(commit),.read_active_index(disp_active),
  .read_addr_0(21'd0),.read_addr_1(21'd307200),.read_addr_2(21'd0),.read_addr_3(21'd0),
  .read_addr_index(disp_idx),.read_len(21'd307200),.read_en(ren),.read_data(pixel),
  .transition_mode(2'd0),.osd_transition_mode(),
  .App_wr_en(app_we),.App_wr_addr(wa),.App_wr_din(wrdata),.App_wr_dm(dm),.wr_afull(wr_afull),
  .write_clk(wc),.write_req(wreq),.write_req_ack(wack),.write_finish(wfinish),
  .write_addr_0(21'd0),.write_addr_1(21'd307200),.write_addr_2(21'd0),.write_addr_3(21'd0),
  .write_addr_index(wr_idx),.write_len(21'd307200),.write_en(wen),.write_data(wdata));

sd_card_bmp #(.CLK_FREQ_HZ(100_000_000),.SCAN_START_SECTOR(32'd0),
  .SCAN_MAX_SECTOR(32'd20000),.SCAN_TARGET_COUNT(4'd2)) u_bmp(
  .clk(wc),.rst(rst),.key_next(key_next),.key_auto(1'b0),.enable_e3(1'b1),
  .display_valid(display_valid),.state_code(state_code),.osd_display_page(),
  .osd_image_total(osd_total),.osd_auto_play(),.osd_e3_on(),
  .write_finish_toggle(wfin_tgl),.read_commit_toggle(commit),.read_active_index(disp_active),
  .write_buf_idx(wr_idx),.disp_buf_idx(disp_idx),
  .write_req(wreq),.write_req_ack(wack),.wr_afull(wr_afull),.write_en(wen),.write_data(wdata),
  .SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(1'b1));
// NOTE: sd_card_top inside u_bmp binds to tests/e3_chain/sd_sector_model.sv
// (same-name drop-in, protocol copied from the passing support model). The
// product sd_card_top.v / spi_master.v / sd_card_cmd.v /
// sd_card_sec_read_write.v are deliberately NOT compiled.

// ------------------------------------------------------ SDRAM shadow -------
reg [31:0] shadow [0:614399];
integer frame_writes = 0, first_wr = -1, wfin_cnt = 0;
always @(posedge mc) begin
    if (rst) begin frame_writes<=0; first_wr<=-1; wfin_tgl<=0; end
    else begin
        if (app_we) begin
            if (wa >= 21'd614400) $fatal(1, "App write outside frame buffers addr=%0d", wa);
            shadow[wa] <= wrdata;
            if (first_wr < 0) first_wr <= wa;
            frame_writes <= frame_writes + 1;
        end
        if (wfinish) begin
            // exact-transport check: a write_finish with != 307200 App writes
            // means data was lost or duplicated on the way to SDRAM; content
            // compare alone cannot distinguish that from silent FIFO drops.
            if (frame_writes != 307200)
                $fatal(1, "write_finish #%0d with %0d App writes, expected exactly 307200",
                       wfin_cnt+1, frame_writes);
            wfin_tgl <= ~wfin_tgl;
            wfin_cnt <= wfin_cnt + 1;
            $display("DIAG write_finish #%0d writes=%0d first_addr=%0d t=%0t",
                     wfin_cnt+1, frame_writes, first_wr, $time);
            frame_writes <= 0; first_wr <= -1;
        end
    end
end

// ------------------------------------------------ FIFO pressure monitors ---
// wfifo_32_32_512 write side (wc domain), probed hierarchically. Inside the
// vendor model wr_en_s = !full_flag & we: a push while full is SILENTLY
// DROPPED with no DUT-visible error, so data loss can only be proven by
// counting we & full_flag directly. fill=1 word/wc-clk during scaler row
// emission (640-word bursts, 2 words per mem_clk) vs drain <= 1 word/mem-clk
// (bursts of 256 gated by Sdr_busy/refresh/App_rd_busy): peak occupancy per
// row is >= 320 words before any arbitration loss, so the 512-deep FIFO has
// only ~96 mem-clks of stall budget per row - measured, not assumed.
integer fifo_push_cnt = 0, fifo_drop_cnt = 0, fifo_full_cnt = 0, fifo_peak = 0;
integer f_push = 0, f_drop = 0, f_peak = 0;
always @(posedge wc) begin
    if (rst) begin
        fifo_push_cnt = 0; fifo_drop_cnt = 0; fifo_full_cnt = 0; fifo_peak = 0;
        f_push = 0; f_drop = 0; f_peak = 0;
    end else begin
        if (wen) begin fifo_push_cnt = fifo_push_cnt + 1; f_push = f_push + 1; end
        if (wen && fr.write_buf.full_flag) begin
            fifo_drop_cnt = fifo_drop_cnt + 1; f_drop = f_drop + 1;
            if (fifo_drop_cnt <= 20)
                $display("FIFO OVERFLOW drop #%0d t=%0t wrusedw=%0d wstate=%0d wcnt=%0d",
                         fifo_drop_cnt, $time, fr.write_buf.wrusedw,
                         fr.frame_fifo_write_m0.state, fr.frame_fifo_write_m0.write_cnt);
        end
        if (fr.write_buf.full_flag) fifo_full_cnt = fifo_full_cnt + 1;
        if (fr.write_buf.wrusedw > fifo_peak) fifo_peak = fr.write_buf.wrusedw;
        if (fr.write_buf.wrusedw > f_peak)     f_peak     = fr.write_buf.wrusedw;
        // per-frame reset when the write FSM latches a new frame (S_ACK)
        if (fr.frame_fifo_write_m0.state == 4'd1) begin
            f_push = 0; f_drop = 0; f_peak = 0;
        end
        if (fr.write_finish)
            $display("FIFO frame stats: push=%0d drop=%0d peak=%0d (full_clks total=%0d)",
                     f_push, f_drop, f_peak, fifo_full_cnt);
    end
end

// ------------------------------------------------- sparse diagnostics ------
reg [3:0] prev_state = 0;
integer sec_ends = 0, wen_cnt = 0, scl_cnt = 0, wack_cnt = 0, snap_i = 0;
integer stall_clks = 0, stall_evts = 0;
reg     afull_d = 0;
always @(posedge wc) begin
    if (!rst) begin
        // backpressure activity (write clock domain, same as afull itself)
        if (wr_afull) stall_clks = stall_clks + 1;
        if (wr_afull && !afull_d) stall_evts = stall_evts + 1;
        afull_d <= wr_afull;
        if (state_code !== prev_state) begin
            $display("DIAG state_code %0d -> %0d t=%0t", prev_state, state_code, $time);
            prev_state <= state_code;
        end
        if (u_bmp.sd_sec_read_end) sec_ends = sec_ends + 1;
        if (u_bmp.load_abort) $display("DIAG load_abort t=%0t", $time);
        if (wen) wen_cnt = wen_cnt + 1;   // pixel-push strobe from sd_card_bmp
        if (u_bmp.scl_out_valid) scl_cnt = scl_cnt + 1;
        if (wack && !u_bmp.write_req_d) wack_cnt = wack_cnt + 1;
        // periodic snapshot every 50 ms (5 event-level lines max)
        if (snap_i < 4 && $time >= (snap_i+1)*50_000_000) begin
            snap_i = snap_i + 1;
            $display("DIAG snap%0d t=%0t wen=%0d scl_out=%0d wack=%0d wstate=%0d wcnt=%0d init=%b busy=%b",
                     snap_i, $time, wen_cnt, scl_cnt, wack_cnt,
                     fr.frame_fifo_write_m0.state, fr.frame_fifo_write_m0.write_cnt, init, busy);
        end
    end
end

// ---------------------------------------------------- expectations ---------
// Source colours (match the sector model): A(x,y): R=x G=y B=x^y (1280x720);
// B(x,y): R=y G=x B=x+y (800x600). x,y are IMAGE coordinates: the card model
// stores file row r as image row H-1-r (BMP bottom-up).
//
// Row mapping through the chain (independently derived, not fitted):
//   card file row r  = image row H-1-r
//   bmp_read px_y    = file row index r (it counts delivered rows from 0)
//   scaler           : output stream row t takes source index s = floor((t-y0)*y_step)
//   frame_fifo_write : stream row t -> memory row 479-t   (WRITE_V_FLIP)
//   read path        : memory row m  -> display row m      (ascending read)
// so display row j shows source file row s(j), i.e. image row H-1-s(j).
// Round 7 run 1 failed here because this H-1- inversion was missing (the tb
// compared against image row s, which is the vertically mirrored position);
// the RTL, the letterbox bands and the x mapping were all consistent.
function [31:0] word_a(input integer c, j);
    integer x, y, s;
    begin
        if (j >= 60 && j < 420) begin
            x = 2*c; s = 2*(j-60); y = 719 - s;
            word_a = {8'(x), 8'(y), 8'(x^y), 8'h00};
        end else word_a = 32'h0;
    end
endfunction
function [31:0] word_b(input integer c, j);
    integer sx, sy, y;
    begin
        sx = (c * 81920) >> 16;   // xstep=(800<<16)/640
        sy = (j * 81920) >> 16;   // ystep=(600<<16)/480
        y  = 599 - sy;            // file row -> image row
        word_b = {8'(y), 8'(sx), 8'(sx+y), 8'h00};
    end
endfunction

integer errors = 0, k, r, c, j;
task verify_buffer(input integer base, input bit is_b);
    begin
        for (k = 0; k < 307200; k = k + 1) begin
            r = k / 640; c = k % 640; j = 479 - r;
            if (shadow[base + k] !== (is_b ? word_b(c,j) : word_a(c,j))) begin
                if (errors < 8)
                    $display("MISMATCH buf=%0d k=%0d (r=%0d c=%0d j=%0d) got=%h exp=%h",
                             base, k, r, c, j, shadow[base+k], is_b ? word_b(c,j) : word_a(c,j));
                errors = errors + 1;
            end
        end
    end
endtask

task read_pass(input [1:0] idx,input bit do_compare,input bit is_b);
 integer p,rr,cc,jj,n;reg[31:0]exp;
 begin
 @(negedge vc);timing_rst=0;p=0;n=0;
 while(p<307200 && n<900000)begin
 @(posedge vc);
 if(ren)begin
 #1;
 if(do_compare)begin
 rr=p/640;cc=p%640;jj=479-rr;exp=is_b?word_b(cc,jj):word_a(cc,jj);
 if(pixel!==exp)begin
 if(errors<8)$display("READBACK MISMATCH idx=%0d p=%0d got=%h exp=%h",idx,p,pixel,exp);
 errors=errors+1;end
 end
 p=p+1;end
 n=n+1;end
 if(p!=307200)$fatal(1,"READ COUNT %0d",p);
 @(negedge vc);timing_rst=1;repeat(2000)@(negedge vc);
 end
endtask

task readback(input [1:0] idx,input bit is_b);
 integer frames;
 begin
 frames=0;
 if(idx!=0)begin
 while((disp_active!=idx || fr.g_wipe.reader.wipe_active) && frames<66)begin
 read_pass(idx,0,is_b);frames=frames+1;end
 if(disp_active!=idx || fr.g_wipe.reader.wipe_active)$fatal(1,"TRANSITION TIMEOUT");
 end
 read_pass(idx,1,is_b);
 $display("DIAG clean readback idx=%0d compare=307200 transition_frames=%0d errors=%0d underflows=%0d",idx,frames,errors,read_underflows);
 end
endtask

// ------------------------------------------------------------- main --------
integer t;
initial begin
    repeat(20) @(negedge wc); rst = 0;
    // stage 1: card init (model delays sd_init_done 13 ms so E3 mode settles)
    t = 0; while (init !== 1'b1 && t < 3_000_000) begin @(negedge wc); t = t + 1; end
    if (init !== 1'b1) $fatal(1, "STAGE TIMEOUT SD_INIT");
    // stage 2: scan + first load + frame A ready (image A: 2.76 MB at the real
    // 56 clk/byte = 1.79 MB/s ≈ 1.55 s; scan itself reads only ~11 sectors)
    t = 0; while (display_valid !== 1'b1 && t < 400_000_000) begin @(negedge wc); t = t + 1; end
    if (display_valid !== 1'b1)
        $fatal(1, "STAGE TIMEOUT FRAME_A state=%0d sec_ends=%0d wfin=%0d wen=%0d scl_out=%0d wack=%0d wstate=%0d init=%b",
               state_code, sec_ends, wfin_cnt, wen_cnt, scl_cnt, wack_cnt,
               fr.frame_fifo_write_m0.state, init);
    if (osd_total !== 4'd2) $fatal(1, "scan found %0d images, expected 2", osd_total);
    if (disp_idx !== 2'd0) $fatal(1, "frame A displayed from buffer %0d, expected 0", disp_idx);
    repeat(1000) @(negedge mc);
    if (frame_writes != 0) $fatal(1, "stray writes after frame A: %0d", frame_writes);
    if (wfin_cnt != 1) $fatal(1, "expected exactly 1 write_finish, got %0d", wfin_cnt);
    verify_buffer(0, 1'b0);
    if (errors) $fatal(1, "FRAME A buffer verify failed errors=%0d", errors);
    $display("DIAG frame A buffer verified 307200 words (letterbox+RGB+vflip)");
    // stage 3: display readback of buffer 0 through the real read path
    readback(2'd0, 1'b0);
    if (errors) $fatal(1, "FRAME A readback failed errors=%0d", errors);
    repeat(2000) @(negedge wc);   // let the scheduler accept the commit
    // stage 4: key_next -> load image B into buffer 1
    @(negedge wc); key_next = 0;
    repeat(6_000_000) @(negedge wc);          // 60 ms > 50 ms debounce
    key_next = 1;
    t = 0; while (!(wfin_cnt == 2 && disp_idx == 2'd1) && t < 250_000_000) begin @(negedge wc); t = t + 1; end
    if (!(wfin_cnt == 2 && disp_idx == 2'd1))
        $fatal(1, "STAGE TIMEOUT FRAME_B state=%0d wfin=%0d disp=%0d sec_ends=%0d", state_code, wfin_cnt, disp_idx, sec_ends);
    repeat(1000) @(negedge mc);
    if (frame_writes != 0) $fatal(1, "stray writes after frame B: %0d", frame_writes);
    verify_buffer(307200, 1'b1);
    if (errors) $fatal(1, "FRAME B buffer verify failed errors=%0d", errors);
    verify_buffer(0, 1'b0);                    // buffer 0 must be untouched
    if (errors) $fatal(1, "BUFFER 0 corrupted during load B errors=%0d", errors);
    $display("DIAG frame B buffer verified, buffer 0 unchanged");
    // stage 5: display readback of buffer 1
    readback(disp_idx, 1'b1);
    if (errors) $fatal(1, "FRAME B readback failed errors=%0d", errors);
    if (fifo_drop_cnt != 0)
        $fatal(1, "FIFO full-drops observed at REAL byte rate: %0d words silently lost (product datapath issue)", fifo_drop_cnt);
    if (stall_clks == 0)
        $fatal(1, "backpressure never engaged: test did not exercise the stall path");
    if (fifo_peak > 510)
        $fatal(1, "FIFO peak %0d exceeds the 510-word backpressure headroom", fifo_peak);
    $display("PASS sector-chain: 2-image scan, loads A/B exact 307200 px each, full-frame RGB+black+vflip compares, readback A/B via real path, buffer isolation OK, zero FIFO drops at real byte rate (peak=%0d/512, stalls=%0d clks in %0d events) (sector ends=%0d)",
             fifo_peak, stall_clks, stall_evts, sec_ends);
    $finish;
end

initial begin #9_000_000_000.0;
    $fatal(1, "WATCHDOG state=%0d wfin=%0d sec_ends=%0d frame_writes=%0d", state_code, wfin_cnt, sec_ends, frame_writes);
end
endmodule
