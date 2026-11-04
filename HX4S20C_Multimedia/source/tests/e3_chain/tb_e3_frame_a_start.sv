`timescale 1ns/1ps
module tb_e3_frame_a_start;
reg mc=0,vc=0,rst=1,trst=1,armed=0;
always #10 mc=~mc;always #20 vc=~vc;
wire physical_clock;assign #9 physical_clock=mc;
wire init,refresh,busy,rdvalid,wreq,wack,wfinish,rreq_ack,rfinish,commit;
wire app_we,re,wr_afull,rreq,de;
wire ren=armed & de;
wire [31:0]dout,wrdata,pixel;wire[20:0]wa,ra;wire[3:0]dm;
wire[1:0]disp_active;wire[1:0]disp_idx=0,wr_idx=0;
assign wreq=0;
video_timing_data timing(.video_clk(vc),.rst(rst|trst),.read_req(rreq),.read_req_ack(rreq_ack),.hs(),.vs(),.de(de));
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
  .write_addr_index(wr_idx),.write_len(21'd307200),.write_en(1'b0),.write_data(32'd0));

function [31:0] word_a(input integer c, j);
    integer x, y, s;
    begin
        if (j >= 60 && j < 420) begin
            x = 2*c; s = 2*(j-60); y = 719 - s;
            word_a = {8'(x), 8'(y), 8'(x^y), 8'h00};
        end else word_a = 32'h0;
    end
endfunction

integer i,p=0,errors=0,underflows=0,requests=0,acks=0,lines=0,linepixels=0;
reg reqd=0,ackd=0,ded=0;
reg[31:0]exp;
always @(posedge vc) if(!rst)begin
 if(rreq && !reqd)requests=requests+1;
 if(rreq_ack && !ackd)acks=acks+1;
 reqd<=rreq;ackd<=rreq_ack;
 if(ren)begin
  if(fr.read_buf.empty_flag!==1'b0)begin underflows=underflows+1;$fatal(1,"FIFO EMPTY/X p=%0d",p);end
  exp=word_a(p%640,479-p/640);
  #1;
  if(pixel!==exp)begin
   if(errors<8)$display("MISMATCH p=%0d got=%h exp=%h",p,pixel,exp);
   errors=errors+1;
  end
  p=p+1;linepixels=linepixels+1;
 end
 if(ded && !ren)begin
  if(linepixels!=640)$fatal(1,"LINE COUNT %0d",linepixels);
  lines=lines+1;linepixels=0;
 end
 ded<=ren;
end
initial begin
 repeat(20)@(negedge vc);rst=0;
 wait(init===1'b1);
 // Read-only test fixture: seed already-validated A image; no SD/scaler/write tests.
 for(i=0;i<307200;i=i+1)sd.sdram.memory[i]=word_a(i%640,479-i/640);
 @(negedge vc);trst=0;
 wait(rreq===1'b1);wait(rreq_ack===1'b1);
 wait(rreq===1'b0);wait(rreq_ack===1'b0);
 wait(commit===1'b1 && disp_active===0 && fr.read_fifo_aclr===0);
 wait(fr.read_buf.wrusedw>=384 && fr.read_buf.empty_flag===0);
 if(de!==0)$fatal(1,"Ready during active raster; cannot start mid-frame");
 @(negedge vc);armed=1;
 wait(p==307200);
 @(negedge vc);armed=0;
 if(errors || underflows || requests!=1 || acks!=1)$fatal(1,"FAIL p=%0d errors=%0d underflows=%0d req=%0d ack=%0d",p,errors,underflows,requests,acks);
 if(lines!=479 || linepixels!=640)$fatal(1,"ROW TOTAL lines=%0d tail=%0d",lines,linepixels);
 $display("PASS frameA read-only pixels=%0d errors=%0d underflows=%0d requests=%0d acks=%0d lines=480",p,errors,underflows,requests,acks);
 $finish;
end
initial begin #60000000;$fatal(1,"WATCHDOG p=%0d req=%0d ack=%0d",p,requests,acks);end
endmodule
