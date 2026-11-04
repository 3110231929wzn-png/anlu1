`timescale 1ns/1ps
module tb_v3_sdram_busy_guard;
 reg clk=0,rst=1,req=0,busy=1,refresh=0;
 always #5 clk=~clk;
 wire wa,ra,we,re,wfin,rfin;
 reg [7:0] rdpipe=0;
 integer i,blocked_w=0,blocked_r=0,issued_w=0,issued_r=0;
 always @(posedge clk)begin rdpipe<={rdpipe[6:0],re};if(we)issued_w=issued_w+1;if(re)issued_r=issued_r+1;end
 frame_fifo_write #(.ADDR_BITS(21),.BURST_BITS(10),.BURST_SIZE(8),.FRAME_WIDTH(8),.FRAME_HEIGHT(1)) writer(
   .rst(rst),.mem_clk(clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),
   .App_rd_busy(1'b0),.O_wr_busy(),.App_wr_en(we),.App_wr_addr(),.write_req(req),.write_req_ack(wa),
   .write_finish(wfin),.write_addr_0(21'd0),.write_addr_1(21'd0),.write_addr_2(21'd0),.write_addr_3(21'd0),
   .write_addr_index(2'd0),.write_len(21'd8),.fifo_aclr(),.rdusedw(10'd32));
 frame_fifo_read #(.ADDR_BITS(21),.BURST_BITS(10),.BURST_SIZE(8)) reader(
   .rst(rst),.mem_clk(clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),
   .Sdr_rd_en(rdpipe[7]),.App_wr_busy(1'b0),.O_rd_busy(),.App_rd_en(re),.App_rd_addr(),
   .read_req(req),.read_req_ack(ra),.read_finish(rfin),.read_commit_toggle(),.read_active_index(),
   .read_addr_0(21'd0),.read_addr_1(21'd0),.read_addr_2(21'd0),.read_addr_3(21'd0),
   .read_addr_index(2'd0),.read_len(21'd8),.fifo_aclr(),.wrusedw(10'd0));
 task begin_frame;
   begin
     rst=1;req=0;repeat(3)@(negedge clk);rst=0;
     req=1;wait(wa && ra);@(negedge clk);req=0;
   end
 endtask
 initial begin
   begin_frame();
   for(i=0;i<40;i=i+1)begin @(negedge clk);if(we)blocked_w=blocked_w+1;if(re)blocked_r=blocked_r+1;end
   $display("TRACE blocked busy write_pulses=%0d read_pulses=%0d",blocked_w,blocked_r);
   if(blocked_w || blocked_r)$fatal(1,"Frame controllers start new bursts while SDRAM busy");
   busy=0;repeat(50)@(negedge clk);
   if(issued_w!=8 || issued_r!=8)$fatal(1,"Release of busy did not resume complete bursts");
   refresh=1;issued_w=0;issued_r=0;begin_frame();
   repeat(40)@(negedge clk);
   if(issued_w || issued_r)$fatal(1,"Frame controllers start new bursts during refresh");
   refresh=0;repeat(50)@(negedge clk);
   if(issued_w!=8 || issued_r!=8)$fatal(1,"Release of refresh did not resume complete bursts");
   $display("PASS tb_v3_sdram_busy_guard: no new burst while busy/refresh, release resumes exactly eight requests");$finish;
 end
 initial begin #10000;$fatal(1,"busy guard watchdog");end
endmodule
