`timescale 1ns/1ps
module tb_e3_live_display;
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
reg key_next=1,wfin_tgl=0,mode_switch=0;
wire rreq,ren,hs0,vs0,de0,hs,vs,de,enabled;
wire [23:0]rgb;
video_timing_data timing(.video_clk(vc),.rst(rst),.read_req(rreq),.read_req_ack(rreq_ack),.hs(hs0),.vs(vs0),.de(de0));
video_delay vd(.video_clk(vc),.rst(rst),.read_en(ren),.read_data(pixel[31:8]),.hs(hs0),.vs(vs0),.de(de0),.hs_r(hs),.vs_r(vs),.de_r(de),.vout_data(rgb));
video_frame_enable gate(.clk(vc),.rst(rst),.async_display_valid(display_valid),.frame_req(rreq),.display_enable(enabled));
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
  .SCAN_MAX_SECTOR(32'd4000),.SCAN_TARGET_COUNT(4'd2)) u_bmp(
  .clk(wc),.rst(rst),.key_next(key_next),.key_auto(1'b0),.enable_e3(mode_switch),
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


integer read_requests=0,read_returns=0,fifo_pushes=0,read_pops=0,urgent_clks=0;
always @(posedge mc) if(!rst)begin
 if(re)read_requests=read_requests+1;
 if(rdvalid)read_returns=read_returns+1;
 if(fr.read_fifo_we)fifo_pushes=fifo_pushes+1;
 if(fr.O_rd_urgent)urgent_clks=urgent_clks+1;
 if(fr.read_fifo_we && fr.read_buf.full_flag)$fatal(1,"READ FIFO OVERFLOW");
end
always @(posedge wc)if(!rst && wen && fr.write_buf.full_flag)$fatal(1,"WRITE FIFO OVERFLOW");
integer buffer_image[0:1];
integer wc_count=0,completed=0,visible_frames=0,total_pixels=0,conflicts=0;
integer frame_old=0,frame_new=0,frame_cut=0;
reg commit_d=0;
integer write_image=0,wr_epoch=0;
function [31:0] expected_word(input integer image,x,y);
 begin
 if(image==0)expected_word={8'(x),8'(y),8'(x^y),8'd0};
 else expected_word={8'(y),8'(x),8'(x+y),8'd0};
 end
endfunction
always @(negedge mc)begin
 if(rst)begin commit_d=0;frame_old=0;frame_new=0;frame_cut=0;end
 else if(commit!=commit_d)begin
 commit_d=commit;
 frame_old=fr.g_wipe.reader.old_base/307200;
 frame_new=fr.g_wipe.reader.new_base/307200;
 frame_cut=fr.g_wipe.reader.progress*10;
 end
end
always @(posedge mc)begin
 if(rst)begin wc_count=0;completed=0;wfin_tgl=0;end
 else begin
 if(app_we)begin
  if(wa>=614400)$fatal(1,"WRITE ADDRESS");
  if(display_valid && ((wa/307200)==disp_active ||
    (fr.g_wipe.reader.wipe_active && ((wa/307200)==fr.g_wipe.reader.old_base/307200 || (wa/307200)==fr.g_wipe.reader.new_base/307200))))begin
   conflicts=conflicts+1;$fatal(1,"READ WRITE CONFLICT addr=%0d",wa);
  end
  if(wrdata!==expected_word(u_bmp.load_idx,wa%640,(wa%307200)/640))$fatal(1,"WRITE CONTENT addr=%0d",wa);
  wc_count=wc_count+1;
 end
 if(wfinish)begin
  if(wc_count!=307200)$fatal(1,"WRITE COUNT %0d",wc_count);
  buffer_image[wr_idx]=u_bmp.load_idx;
  completed=completed+1;wc_count=0;wfin_tgl<=~wfin_tgl;
  $display("WRITE COMPLETE count=%0d buffer=%0d image=%0d t=%0t",completed,wr_idx,u_bmp.load_idx,$time);
 end
 end
end
reg [20:0]hd=0,vdly=0,dd=0;
reg prevvs=0,prevde=0;
integer p=0,line_count=0,errors=0,underflows=0,epoch=0;
reg was_valid=0;
reg[31:0]exp;
integer chosen;
always @(posedge vc)begin
 if(rst)begin hd<=0;vdly<=0;dd<=0;end
 else begin hd<={hd[19:0],hs0};vdly<={vdly[19:0],vs0};dd<={dd[19:0],de0};end
 if(!rst && ren && display_valid)begin
 read_pops=read_pops+1;
 if(fr.read_buf.empty_flag!==0)begin
 underflows=underflows+1;
 $fatal(1,"READ UNDERFLOW p=%0d rstate=%0d wstate=%0d used=%0d req=%0d ret=%0d push=%0d pop=%0d urgent=%0d",p,fr.g_wipe.reader.state,fr.frame_fifo_write_m0.state,fr.wrusedw,read_requests,read_returns,fifo_pushes,read_pops,urgent_clks);
 end end
end
always @(negedge vc)begin
 if(rst)begin p=0;line_count=0;prevvs=0;prevde=0;was_valid=0;end
 else begin
 if({hs,vs,de}!=={hd[20],vdly[20],dd[20]})$fatal(1,"SYNC ALIGN");
 if(was_valid && !display_valid)$fatal(1,"LIVE DISPLAY DROPPED DURING RESCAN");
 if(display_valid)was_valid=1;
 if(prevvs && !vs)begin
  if(p!=0 && p!=307200)$fatal(1,"FRAME COUNT %0d",p);
  if(p==307200)visible_frames=visible_frames+1;
  p=0;
 end
 if(enabled && de)begin
  chosen=((p%640)<frame_cut)?frame_new:frame_old;
  exp=expected_word(buffer_image[chosen],p%640,p/640);
  if(rgb!==exp[31:8])begin
   errors=errors+1;
   $fatal(1,"RGB MISMATCH p=%0d got=%h expected=%h old=%0d new=%0d cut=%0d",p,rgb,exp[31:8],frame_old,frame_new,frame_cut);
  end
  p=p+1;total_pixels=total_pixels+1;line_count=line_count+1;
 end
 if(prevde && !de && enabled)begin if(line_count!=640)$fatal(1,"LINE COUNT %0d",line_count);line_count=0;end
 prevvs=vs;prevde=de;
 end
end
task next_image;
 begin key_next=0;repeat(6000000)@(negedge wc);key_next=1;end
endtask
initial begin
 buffer_image[0]=0;buffer_image[1]=0;
 repeat(20)@(negedge wc);rst=0;
 wait(completed==1 && display_valid && visible_frames>=2);
 next_image();wait(u_bmp.load_busy);mode_switch=1;
 wait(completed>=3 && u_bmp.e3_active==1 && !u_bmp.display_commit_pending);
 next_image();wait(u_bmp.load_busy);mode_switch=0;
 wait(completed>=5 && u_bmp.e3_active==0 && !u_bmp.display_commit_pending);
 wait(visible_frames>=200);
 rst=1;repeat(20)@(negedge wc);rst=0;
 wait(completed==1 && display_valid);repeat(1000000)@(negedge vc);
 if(errors || conflicts || underflows)$fatal(1,"COUNTERS");
 $display("PASS LIVE DISPLAY pixels=%0d frames=%0d RGB_errors=%0d conflicts=%0d underflows=%0d",total_pixels,visible_frames,errors,conflicts,underflows);$finish;
end
initial begin #12000000000.0;$fatal(1,"WATCHDOG completed=%0d frames=%0d",completed,visible_frames);end
endmodule
