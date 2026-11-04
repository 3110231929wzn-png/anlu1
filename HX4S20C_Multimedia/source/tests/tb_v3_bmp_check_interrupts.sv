`timescale 1ns/1ps
module tb_v3_bmp_check_interrupts;
 reg clk=0,rst=1,scan=0,load=0,abort_load=0,init_done=1,valid=0,secend=0;
 always #5 clk=~clk;
 reg [7:0] data=0;
 wire ready,req,wreq,found;
 integer kind,action,i,found_count=0,write_count=0;
 bmp_read dut(.clk(clk),.rst(rst),.ready(ready),.scan_start(scan),.scan_start_sector(32'd0),
   .scan_max_sector(32'd0),.scan_target_count(3'd1),.scan_done(),.scan_found_valid(found),
   .scan_found_sector(),.scan_found_total(),.load_start(load),.load_abort(abort_load),
   .load_sector(32'd0),.sd_init_done(init_done),.state_code(),.bmp_width(16'd640),.bmp_height(16'd480),
   .write_req(wreq),.write_req_ack(1'b0),.sd_sec_read(req),.sd_sec_read_addr(),
   .sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(secend),.bmp_data_wr_en(),.bmp_data());
 always @(posedge clk) begin
   if(rst)begin found_count<=0;write_count<=0;end
   else begin if(found)found_count<=found_count+1;if(wreq)write_count<=write_count+1;end
 end
 function [7:0] fixture(input integer n);
   case(n)
     0:fixture=8'h42;1:fixture=8'h4d;2:fixture=8'h36;3:fixture=8'h10;4:fixture=8'h0e;
     10:fixture=54;18:fixture=8'h80;19:fixture=2;22:fixture=8'he0;23:fixture=1;26:fixture=1;28:fixture=24;
     default:fixture=0;
   endcase
 endfunction
 initial begin
   for(kind=0;kind<2;kind=kind+1)for(action=0;action<3;action=action+1)begin
     rst=1;init_done=1;abort_load=0;scan=0;load=0;valid=0;secend=0;
     repeat(3)@(negedge clk);rst=0;
     scan=(kind==0);load=(kind==1);@(negedge clk);scan=0;load=0;
     wait(req);@(negedge clk);
     for(i=0;i<512;i=i+1)begin valid=1;data=fixture(i);@(negedge clk);end
     valid=0;secend=1;@(negedge clk);secend=0;
     // The newly introduced pending decision has not committed yet.
     if(found || wreq || ready)$fatal(1,"Decision committed before interrupt window");
     case(action)0:abort_load=1;1:rst=1;2:init_done=0;endcase
     @(negedge clk);abort_load=0;rst=0;
     repeat(3)@(negedge clk);
     if(!ready || req || wreq || found_count || write_count)
       $fatal(1,"Interrupted decision committed: kind=%0d action=%0d found=%0d writes=%0d",kind,action,found_count,write_count);
   end
   $display("PASS tb_v3_bmp_check_interrupts: abort/reset/media loss preempt both pending header decisions");$finish;
 end
 initial begin #100000;$fatal(1,"decision interrupt watchdog");end
endmodule
