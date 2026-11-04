`timescale 1ns/1ps
// Real frame FSMs/FIFOs and provided SDRAM controller; command coverage only.
// The vendor SDRAM primitive has no memory behavior, so no data/retention pass.
module tb_v3_real_sdram_pipeline;
 wire shifted_clk;

 reg mc=0,wc=0,vc=0,rst=1;
 assign #9 shifted_clk=mc;
 always #10 mc=~mc;
 always #5 wc=~wc;
 always #20 vc=~vc;
 reg wreq=0,wen=0,rreq=0,ren=0;
 reg [31:0] wdata=0;
 reg [20:0] base=0;
 wire init,refresh,busy,rdvalid,wack,wfinish,rack,rfinish;
 wire [31:0] dout,wrdata,pixel;
 wire [20:0] wa,ra;
 wire we,re;
 wire [3:0] dm;
 integer writes=0,reads=0,acts=0,unknown_ba=0,i,bank;
 reg [3:0] write_banks=0,read_banks=0;
 sdram sd(.Clk(mc),.Clk_sft(shifted_clk),.Rst(rst),.Sdr_init_done(init),
   .Sdr_init_ref_vld(refresh),.Sdr_busy(busy),.App_wr_en(we),.App_wr_addr(wa),
   .App_wr_dm(dm),.App_wr_din(wrdata),.App_rd_en(re),.App_rd_addr(ra),
   .Sdr_rd_en(rdvalid),.Sdr_rd_dout(dout));
 frame_read_write #(.BURST_SIZE(8),.FRAME_WIDTH(8),.FRAME_HEIGHT(4)) fr(
   .rst(rst),.mem_clk(mc),.Sdr_init_done(init),.Sdr_init_ref_vld(refresh),.Sdr_busy(busy),
   .App_rd_en(re),.App_rd_addr(ra),.Sdr_rd_en(rdvalid),.Sdr_rd_dout(dout),
   .read_clk(vc),.read_req(rreq),.read_req_ack(rack),.read_finish(rfinish),
   .read_commit_toggle(),.read_active_index(),.read_addr_0(base),.read_addr_1(21'd32),
   .read_addr_2(21'd0),.read_addr_3(21'd0),.read_addr_index(2'd0),.read_len(21'd32),
   .read_en(ren),.read_data(pixel),.App_wr_en(we),.App_wr_addr(wa),.App_wr_din(wrdata),.App_wr_dm(dm),
   .write_clk(wc),.write_req(wreq),.write_req_ack(wack),.write_finish(wfinish),
   .write_addr_0(base),.write_addr_1(21'd32),.write_addr_2(21'd0),.write_addr_3(21'd0),
   .write_addr_index(2'd0),.write_len(21'd32),.write_en(wen),.write_data(wdata));
 always @(negedge mc) begin
   #1;
   if(init)case({sd.SDR_RAS,sd.SDR_CAS,sd.SDR_WE})
     3'b011:acts=acts+1;
     3'b100:begin writes=writes+1;if((^sd.sdram.ba)===1'bx)unknown_ba=unknown_ba+1;else write_banks[sd.sdram.ba]=1;end
     3'b101:begin reads=reads+1;if((^sd.sdram.ba)===1'bx)unknown_ba=unknown_ba+1;else read_banks[sd.sdram.ba]=1;end
   endcase
 end
 initial begin
   repeat(20)@(negedge mc);rst=0;wait(init);
   for(bank=0;bank<4;bank=bank+1)begin
   base=bank*256;
   @(negedge wc);wreq=1;wait(wack);repeat(2)@(negedge wc);wreq=0;
   wait(!wack);repeat(8)@(negedge wc);
   for(i=0;i<32;i=i+1)begin @(negedge wc);wen=1;wdata=32'h12340000+i;end
   @(negedge wc);wen=0;wait(wfinish);repeat(100)@(negedge mc);
   @(negedge vc);rreq=1;wait(rack);@(negedge vc);rreq=0;
   wait(!rack);repeat(100)@(negedge vc);ren=1;repeat(32)@(negedge vc);ren=0;
   repeat(1000)@(negedge mc);
   end
   $display("SUMMARY real frame/FIFO + SDRAM command coverage ACT=%0d WRITE=%0d READ=%0d unknown_bank=%0d write_banks=%b read_banks=%b",acts,writes,reads,unknown_ba,write_banks,read_banks);
   if(writes<1 || reads<1)$fatal(1,"Actual frame/FIFO traffic did not produce observed SDRAM READ/WRITE commands");
   if(unknown_ba)$fatal(1,"Observed unknown SDRAM traffic bank");
   if(write_banks!==4'b1111 || read_banks!==4'b1111)$fatal(1,"Four-bank read/write command coverage incomplete");
   $display("PASS tb_v3_real_sdram_pipeline: real frame/FIFO and controller produce read/write commands (data model absent)");$finish;
 end
 initial begin #10000000;$fatal(1,"real-controller pipeline watchdog init=%b busy=%b wack=%b wfin=%b rack=%b ACT=%0d WRITE=%0d READ=%0d",init,busy,wack,wfinish,rack,acts,writes,reads);end
endmodule
