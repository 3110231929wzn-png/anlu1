`timescale 1ns/1ps
module EG_LOGIC_BRAM #(parameter DATA_WIDTH_A=24,DATA_WIDTH_B=24,ADDR_WIDTH_A=11,ADDR_WIDTH_B=11,DATA_DEPTH_A=2048,DATA_DEPTH_B=2048,BYTE_ENABLE=0,MODE="DP",REGMODE_A="NOREG",REGMODE_B="OUTREG",WRITEMODE_A="NORMAL",WRITEMODE_B="NORMAL",RESETMODE="SYNC",IMPLEMENT="9K") (input [23:0] dia,dib,input [10:0] addra,addrb,input cea,ocea,clka,wea,rsta,bea,ceb,oceb,clkb,web,rstb,beb,output [23:0] doa,output reg [23:0] dob);
reg [23:0] mem[0:2047]; assign doa=0;
always @(posedge clka) if(cea&&wea)mem[addra]<=dia;
always @(posedge clkb)if(ceb)dob<=mem[addrb];
endmodule
module tb;
reg clk=0;always #5 clk=~clk;
reg rst=1,load_start=0,info_valid=0,px_valid=0;
reg [10:0] src_w,src_h,px_x,px_y;reg [23:0] px_data;wire out_valid;wire [23:0] out_data;
bmp_scaler dut(.*);
integer n=0,errors=0,ow,oh,x0,y0,sw,sh,xx,yy,sx,sy,xstep,ystep;reg checking=0;reg [23:0] expected;
function [23:0] color(input integer x,y); color={8'(x),8'(y),8'(x^y)};endfunction
always @(negedge clk)if(checking&&out_valid)begin
xx=n%640; yy=n/640;
if(xx>=x0&&xx<x0+ow&&yy>=y0&&yy<y0+oh)begin sx=((xx-x0)*xstep)>>16;sy=((yy-y0)*ystep)>>16;expected=color(sx,sy);end else expected=0;
if(out_data!==expected)begin if(errors<8)$display("MISMATCH %0dx%0d n=%0d got=%h exp=%h",sw,sh,n,out_data,expected);errors=errors+1;end
n=n+1;
end
task run_image(input integer w,h);integer x,y,t;begin
sw=w;sh=h; n=0;checking=0;
if(640*h<=480*w)begin ow=640;oh=640*h/w;end else begin oh=480;ow=480*w/h;end
x0=(640-ow)/2;y0=(480-oh)/2;xstep=(w<<16)/ow;ystep=(h<<16)/oh;
@(negedge clk);load_start=1;@(negedge clk);load_start=0;src_w=w;src_h=h;info_valid=1;checking=1;
@(negedge clk);info_valid=0;repeat(100)@(negedge clk);
for(y=0;y<h;y=y+1)for(x=0;x<w;x=x+1)begin px_valid=1;px_x=x;px_y=y;px_data=color(x,y);@(negedge clk);px_valid=0;repeat(7)@(negedge clk);end
for(t=0;t<400000&&n<307200;t=t+1)@(negedge clk);
if(n!=307200)begin $display("COUNT FAIL %0dx%0d n=%0d",w,h,n);errors=errors+1;end
repeat(20)@(negedge clk);
if(n!=307200)errors=errors+1;
$display("CASE %0dx%0d pixels=%0d cumulative_errors=%0d black_rest=%0d",w,h,n,errors,dut.black_rest);checking=0;
end endtask
initial begin repeat(4)@(negedge clk);rst=0;run_image(640,480);run_image(800,600);run_image(1280,720);run_image(1024,768);run_image(240,320);if(errors)$fatal(1,"FAIL errors=%0d",errors);$display("PASS scaler 5 dimensions full RGB boundary/pixel checks");$finish;end
initial begin #500000000;$fatal(1,"WATCHDOG");end
endmodule
