`timescale 1ns/1ps
// RTL SPI with scalar path delays extracted from Routed SDF. Not full gate/SDF or board signoff.
module tb_spi_pad_budget #(parameter integer SPI_DIV=-1);
reg clk=0,rst=1,ncs_ctrl=1,req=0;
always #5 clk=~clk;
reg [15:0] divider=0;
reg [7:0] tx=0,response=0;
wire ncs,sclk,mosi,ack,internal_sclk,internal_mosi,miso;
reg card_miso=1;
assign #4.620 sclk=internal_sclk;
assign #4.620 mosi=internal_mosi;
assign #3.533 miso=card_miso;
wire [7:0] rx;
// Read the production wrapper's default setting; do not duplicate its value.
sd_card_top configuration_dut(.clk(clk),.rst(rst),.abort_req(1'b0),.SD_MISO(1'b1),
 .sd_sec_read(1'b0),.sd_sec_read_addr(32'd0),.sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0));
integer effective_divider;
spi_master dut(.sys_clk(clk),.rst(rst),.nCS(ncs),.DCLK(internal_sclk),.MOSI(internal_mosi),.MISO(miso),
 .CPOL(1'b1),.CPHA(1'b1),.nCS_ctrl(ncs_ctrl),.clk_div(divider),.wr_req(req),.wr_ack(ack),.data_in(tx),.data_out(rx));
real delay_ns=14.0;
integer launched=0,captured=0,total=0;
reg [7:0] observed=0;
reg active=0;
always @(negedge sclk) if(!rst && !ncs)begin
 if(launched>=8)$fatal(1,"too many SPI launch edges");
 card_miso <= #(delay_ns) response[7-launched];
 launched=launched+1;active=1;
end
always @(posedge sclk) if(!rst && !ncs && active)begin
 observed={observed[6:0],mosi};captured=captured+1;
end
task transfer(input [15:0] div,input real tcard,input [7:0] outgoing,input [7:0] incoming);
 begin
  @(negedge clk);divider=div;delay_ns=tcard;tx=outgoing;response=incoming;
  launched=0;captured=0;observed=0;active=0;ncs_ctrl=0;req=1;
  wait(ack);#1;
  if(rx!==incoming || observed!==outgoing || captured!=8 || launched!=8)
   $fatal(1,"SPI compare: div=%0d delay=%0f rx=%h wanted=%h MOSI=%h wanted=%h edges=%0d/%0d",div,tcard,rx,incoming,observed,outgoing,launched,captured);
  total=total+1;
  @(negedge clk);req=0;ncs_ctrl=1;active=0;repeat(8)@(negedge clk);
 end
endtask
initial begin
 effective_divider=(SPI_DIV<0)?configuration_dut.SPI_HIGH_SPEED_DIV:SPI_DIV;
 $display("SPI pad budget effective divider=%0d",effective_divider);
 repeat(8)@(negedge clk);rst=0;repeat(4)@(negedge clk);
 transfer(effective_divider,0.0,8'h3c,8'ha5);
 transfer(effective_divider,14.0,8'ha5,8'h3c);
 transfer(effective_divider,14.0,8'h00,8'hff);
 transfer(effective_divider,14.0,8'hff,8'h00);
 transfer(248,50.0,8'h96,8'h69);
 $display("PASS tb_spi_pad_budget: %0d SPI mode3 bytes, high-speed tOD0/14ns and low-speed50ns",total);$finish;
end
initial begin #1000000;$fatal(1,"SPI test watchdog");end
endmodule
