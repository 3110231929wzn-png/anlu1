`timescale 1ns/1ps
module tb_v3_bmp_scan_pipeline;
 reg clk=0,rst=1,start=0,valid=0,done=0;
 always #5 clk=~clk;
 reg [7:0] b=0;
 wire req,scan_done,found;
 wire [2:0] total;
 wire [31:0] address,found_sector;
 reg [31:0] flen,offset,w,h,compression;
 reg [15:0] planes,bits;
 integer n,i,latency;
 reg expected;
 bmp_read dut(.clk(clk),.rst(rst),.ready(),.scan_start(start),
   .scan_start_sector(32'd7),.scan_max_sector(32'd7),.scan_target_count(3'd1),
   .scan_done(scan_done),.scan_found_valid(found),.scan_found_sector(found_sector),.scan_found_total(total),
   .load_start(1'b0),.load_abort(1'b0),.load_sector(32'd0),.sd_init_done(1'b1),.state_code(),
   .bmp_width(16'd640),.bmp_height(16'd480),.write_req(),.write_req_ack(1'b0),
   .sd_sec_read(req),.sd_sec_read_addr(address),.sd_sec_read_data(b),.sd_sec_read_data_valid(valid),
   .sd_sec_read_end(done),.bmp_data_wr_en(),.bmp_data());
 function [7:0] fixture(input integer k);
   begin
     fixture=0;
     case(k)
       0:fixture=8'h42;1:fixture=8'h4d;
       2,3,4,5:fixture=flen >> ((k-2)*8);
       10,11,12,13:fixture=offset >> ((k-10)*8);
       18,19,20,21:fixture=w >> ((k-18)*8);
       22,23,24,25:fixture=h >> ((k-22)*8);
       26,27:fixture=planes >> ((k-26)*8);
       28,29:fixture=bits >> ((k-28)*8);
       30,31,32,33:fixture=compression >> ((k-30)*8);
     endcase
   end
 endfunction
 initial begin
   for(n=0;n<32;n=n+1) begin
     rst=1;start=0;valid=0;done=0;
     repeat(3) @(negedge clk);rst=0;
     offset=54;flen=921654;w=640;h=480;planes=1;bits=24;compression=0;
     case(n%8)
       1:begin offset=54+n*17;flen=offset+921600;end
       2:w=32'h10000280;
       3:flen=921653;
       4:offset=32'hfffffff0;
       5:planes=0;
       6:begin offset=32'hfff00000;flen=32'hfffe1000;end
       7:compression=1;
     endcase
     expected=(w==640)&&(h==480)&&(planes==1)&&(bits==24)&&(compression==0)
       &&(offset>=54)&&(flen>=offset)&&((flen-offset)==921600);
     start=1;@(negedge clk);start=0;wait(req);@(negedge clk);
     for(i=0;i<512;i=i+1) begin valid=1;b=fixture(i);@(negedge clk);end
     valid=0;done=1;@(negedge clk);done=0;latency=0;
     while(!scan_done && latency<4)begin @(negedge clk);latency=latency+1;end
     if(!scan_done || total !== (expected?3'd1:3'd0))
       $fatal(1,"header decision mismatch case=%0d expected=%b total=%d latency=%d",n,expected,total,latency);
     if(expected && (found_sector!==7 || address!==(32'd7+((flen+32'd511)>>9))))
       $fatal(1,"scan commit address mismatch case=%0d address=%h",n,address);
   end
   $display("PASS tb_v3_bmp_scan_pipeline: 32 valid/malformed/high-offset header decisions and committed addresses");$finish;
 end
 initial begin #300000;$fatal(1,"scan pipeline watchdog");end
endmodule
