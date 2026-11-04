module tb_bmp_e3;
reg clk=0;always #5 clk=~clk;
reg rst=1,valid=0;reg[7:0]data=0;
wire wr;wire[23:0]rgb;wire[10:0]x,y;
bmp_read dut(.clk(clk),.rst(rst),.enable_e3(1'b1),.scan_start(1'b0),.load_start(1'b0),.load_abort(1'b0),.sd_init_done(1'b1),.write_req_ack(1'b0),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(1'b0),.bmp_data_wr_en(wr),.bmp_data(rgb),.px_x(x),.px_y(y));
integer W,H,got,xx,yy,k,stride;reg checking=0;
always @(negedge clk) if(checking&&wr)begin
if(x !== got%W || y !== got/W || rgb !== {8'(got/W),8'(got%W),8'h35})$fatal(1,"pixel mismatch %0d %0d %h",W,got,rgb);
got=got+1;end
task send(input[7:0]b);begin @(negedge clk);data=b;valid=1;@(negedge clk);valid=0;end endtask
task test(input integer w,input integer h);begin
W=w;H=h;got=0;rst=1;repeat(3)@(negedge clk);rst=0;repeat(2)@(negedge clk);stride=(3*W+3)&~3;
force dut.state=3'd4;force dut.pixel_offset=32'd0;force dut.width_m1=W-1;force dut.height_m1=H-1;force dut.width_x3=3*W;force dut.row_bytes=stride;force dut.file_len=stride*H;
checking=1;
for(yy=0;yy<H;yy=yy+1)begin
for(xx=0;xx<W;xx=xx+1)begin send(8'h35);send(xx);send(yy);end
for(k=3*W;k<stride;k=k+1)send(8'hee);end
repeat(3)@(negedge clk);if(got!=W*H)$fatal(1,"count %0d",got);
checking=0;release dut.state;release dut.pixel_offset;release dut.width_m1;release dut.height_m1;release dut.width_x3;release dut.row_bytes;release dut.file_len;
$display("PASS BMP parser %0dx%0d",W,H);end endtask
initial begin test(640,480);test(800,600);test(1280,720);test(1024,60);test(121,60);test(122,60);test(123,60);test(124,60);$display("PASS tb_bmp_e3");$finish;end
initial begin #200000000;$fatal(1,"timeout");end
endmodule
