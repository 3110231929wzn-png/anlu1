`timescale 1ns/1ps
module tb_v3_sdram_data_loop #(parameter real MEM_HALF=10.0,parameter integer SDR_PHASE=162,parameter real TAC=5.4,
 parameter integer WIDTH=640,HEIGHT=4,BURST_SIZE=256,PIXEL_GAP=100,STRESS=1);
 localparam N=WIDTH*HEIGHT;
 reg mc=0,wc=0,vc=0,rst=1;
 always #(MEM_HALF)mc=~mc;
 always #5 wc=~wc;
 always #20 vc=~vc;
 reg wreq=0,wen=0,rreq=0,ren=0;
 reg [1:0] wi=0,ri=0;
 reg [31:0] wdata=0;
 wire init,refresh,busy,rdvalid,wack,wfinish,rack,commit;
 wire [31:0] dout,wrdata,pixel;
 wire [20:0] wa,ra;
 wire we,re;wire [3:0] dm;
 wire physical_clock;
 assign #(MEM_HALF * SDR_PHASE / 180.0) physical_clock=mc;
 integer i,expected_index,errors=0;
 integer valid_trace=0;
 always @(posedge mc)begin
   #1;
   if(we && $test$plusargs("TRACE_MEMORY"))$display("DIAG_MEMORY APP_WRITE t=%0t addr=%0d data=%h busy=%b",$time,wa,wrdata,busy);
   if(rdvalid && $test$plusargs("TRACE_MEMORY"))begin
     valid_trace=valid_trace+1;
     if(valid_trace<40)$display("DIAG_MEMORY CONTROLLER_VALID t=%0t data=%h",$time,dout);
   end
 end
 sdram sd(.Clk(mc),.Clk_sft(physical_clock),.Rst(rst),.Sdr_init_done(init),.Sdr_init_ref_vld(refresh),
   .Sdr_busy(busy),.App_wr_en(we),.App_wr_addr(wa),.App_wr_dm(dm),.App_wr_din(wrdata),
   .App_rd_en(re),.App_rd_addr(ra),.Sdr_rd_en(rdvalid),.Sdr_rd_dout(dout));
 defparam sd.sdram.READ_DELAY_NS=TAC;
 frame_read_write #(.BURST_SIZE(BURST_SIZE),.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT)) fr(
   .rst(rst),.mem_clk(mc),.Sdr_init_done(init),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),
   .App_rd_en(re),.App_rd_addr(ra),.Sdr_rd_en(rdvalid),.Sdr_rd_dout(dout),
   .read_clk(vc),.read_req(rreq),.read_req_ack(rack),.read_finish(),.read_commit_toggle(commit),.read_active_index(),
   .read_addr_0(21'd0),.read_addr_1(21'(N)),.read_addr_2(21'd0),.read_addr_3(21'd0),.read_addr_index(ri),
   .read_len(21'(N)),.read_en(ren),.read_data(pixel),.App_wr_en(we),.App_wr_addr(wa),.App_wr_din(wrdata),.App_wr_dm(dm),
   .write_clk(wc),.write_req(wreq),.write_req_ack(wack),.write_finish(wfinish),
   .write_addr_0(21'd0),.write_addr_1(21'(N)),.write_addr_2(21'd0),.write_addr_3(21'd0),.write_addr_index(wi),
   .write_len(21'(N)),.write_en(wen),.write_data(wdata));
 task produce_frame(input [1:0] index,input [23:0] tag);
 integer p;
 begin
   wi=index;
   @(negedge wc);wreq=1;wait(wack);repeat(2)@(negedge wc);wreq=0;wait(!wack);repeat(8)@(negedge wc);
   for(p=0;p<N;p=p+1)begin
     @(negedge wc);wen=1;wdata={tag,8'd0}|(p<<8);
     if(PIXEL_GAP>1)begin @(negedge wc);wen=0;repeat(PIXEL_GAP-2)@(negedge wc);end
   end
   @(negedge wc);wen=0;wait(wfinish);repeat(100)@(negedge mc);
   $display("TRACE produced frame index=%0d pixels=%0d",index,N);
 end endtask
 task consume_frame(input [1:0] index,input [23:0] tag);
 integer p,expected;
 begin
   ri=index;
   @(negedge vc);rreq=1;wait(rack);@(negedge vc);rreq=0;
   repeat(100)@(negedge vc);
   for(p=0;p<N;p=p+1)begin
     @(negedge vc);ren=1;@(posedge vc);#1;expected=(HEIGHT-1-p/WIDTH)*WIDTH+p%WIDTH;
     if(pixel[31:8] !== (tag|expected))begin
       errors=errors+1;if(errors<9)$display("MISMATCH frame=%0d i=%0d got=%h want=%h",index,p,pixel[31:8],tag|expected);
     end
   end
   @(negedge vc);ren=0;
   $display("TRACE consumed frame index=%0d pixels=%0d cumulative_errors=%0d",index,N,errors);
 end endtask
 initial begin
   repeat(20)@(negedge mc);rst=0;wait(init);
   produce_frame(0,24'h500000);
   if(STRESS)begin
     fork produce_frame(1,24'ha00000);consume_frame(0,24'h500000);join
     consume_frame(1,24'ha00000);
   end else consume_frame(0,24'h500000);
   $display("SUMMARY data-loop mismatches=%0d pixels=%0d mem_half=%0f phase=%0d",errors,N,MEM_HALF,SDR_PHASE);
   if(errors)$fatal(1,"Diagnostic SDRAM data-loop mismatch");
   $display("PASS tb_v3_sdram_data_loop: %0d visible RGB words through actual controller and diagnostic memory",N);$finish;
 end
 initial begin #1000000000;$fatal(1,"data loop watchdog");end
endmodule
