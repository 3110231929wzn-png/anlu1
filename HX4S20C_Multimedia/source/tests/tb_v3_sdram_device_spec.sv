`timescale 1ns/1ps
// EM638325 Rev3.2: bank=0 during MRS; 4096 refreshes per 64ms.
module tb_v3_sdram_device_spec;
 wire shifted_clk;

 reg clk=0,rst=1;
 assign #9 shifted_clk=clk;
 always #10 clk=~clk;
 wire initialized,refresh,busy,valid;
 wire [31:0] data;
 integer modes=0,bad_modes=0,refreshes=0,bad_intervals=0;
 time last_ref=0;
 sdram dut(.Clk(clk),.Clk_sft(shifted_clk),.Rst(rst),.Sdr_init_done(initialized),
   .Sdr_init_ref_vld(refresh),.Sdr_busy(busy),.App_wr_en(1'b0),.App_wr_addr(21'd0),
   .App_wr_dm(4'd0),.App_wr_din(32'd0),.App_rd_en(1'b0),.App_rd_addr(21'd0),
   .Sdr_rd_en(valid),.Sdr_rd_dout(data));
 always @(negedge clk) begin
   #1;
   if(!rst && {dut.SDR_RAS,dut.SDR_CAS,dut.SDR_WE}===3'b000)begin
     modes=modes+1;
     $display("TRACE MRS raw_bank=%b physical_bank=%b address=%h",dut.SDR_BA,dut.sdram.ba,dut.sdram.addr);
     if(dut.sdram.ba!==2'b00 || dut.sdram.addr[10]!==1'b0)bad_modes=bad_modes+1;
   end
   if(initialized && {dut.SDR_RAS,dut.SDR_CAS,dut.SDR_WE}===3'b001)begin
     if(refreshes>0)begin
       $display("TRACE physical idle refresh interval=%0t",$time-last_ref);
       if(($time-last_ref)>15625 || ($time-last_ref)<15500)bad_intervals=bad_intervals+1;
     end
     last_ref=$time;refreshes=refreshes+1;
   end
 end
 initial begin
   repeat(20)@(negedge clk);rst=0;wait(initialized);repeat(20000)@(negedge clk);
   $display("SUMMARY MRS=%0d bad_mode=%0d refreshes=%0d bad_refresh_intervals=%0d",modes,bad_modes,refreshes,bad_intervals);
   if(modes<1 || refreshes<5 || bad_modes || bad_intervals)$fatal(1,"EM638325 initialization/idle-refresh specification check failed");
   $display("PASS tb_v3_sdram_device_spec: physical MRS bank zero and idle refresh within 15.625us");$finish;
 end
 initial begin #10000000;$fatal(1,"EM638325 spec watchdog");end
endmodule
