`timescale 1ns/1ps
module tb_e3_header_timing;
reg clk=0,rst=1;always #5 clk=~clk;
integer w,h,len,off=54,i,j,checks=0;reg enable=1;
bmp_read dut(.clk(clk),.rst(rst),.enable_e3(enable),.sd_init_done(1'b0));
initial begin
 repeat(3)@(negedge clk);rst=0;
 force dut.width=w;force dut.height=h;force dut.file_len=len;force dut.pixel_offset=off;
 force dut.header_0=8'h42;force dut.header_1=8'h4d;
 force dut.color_planes=1;force dut.bit_count=24;force dut.compression=0;
 for(w=120;w<=1280;w=w+1)begin
 for(j=0;j<4;j=j+1)begin
 case(j)0:h=60;1:h=480;2:h=720;3:h=1024;endcase
 len=54+((w*3+3)/4*4)*h;
 repeat(4)@(negedge clk);
 if(dut.hdr_pixel_bytes!==((w*3+3)/4*4)*h || dut.header_match!==1)$fatal(1,"VALID w=%0d h=%0d",w,h);
 len=len-1;repeat(4)@(negedge clk);
 if(dut.header_match!==0)$fatal(1,"TRUNCATED w=%0d h=%0d",w,h);
 checks=checks+2;
 end end
 w=640;h=480;len=54+640*480*3;enable=0;repeat(4)@(negedge clk);
 if(dut.header_match!==1)$fatal(1,"LEGACY");
 $display("PASS header timing checks=%0d padding0..3 widths120..1280 heights60/480/720/1024 truncation + legacy",checks+1);$finish;
end
endmodule
