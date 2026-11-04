`timescale 1ns/1ps
// Independent coordinate/text reference; font fixtures are the delivered ROM data.
// A + one full frame, scroll carry/wrap and explicit blend extremes.
module tb_osd_overlay;
  reg clk=0,rst=1,de=0,hs=0,vs=0;
  always #20 clk=~clk;
  reg [23:0] rgb=0;
  wire od,oh,ov; wire [23:0] out;
  reg [1:0] page=0;
  reg [2:0] total=4;
  reg autoplay=0;
  osd_overlay dut(.I_clk(clk),.I_rst(rst),.I_de(de),.I_hs(hs),.I_vs(vs),.I_rgb(rgb),
    .O_de(od),.O_hs(oh),.O_vs(ov),.O_rgb(out),.I_page(page),.I_total(total),.I_auto(autoplay),.I_mode(2'd0));
  reg [23:0] cn[0:255]; reg [9:0] font[0:1023];
  integer x,y,k,c,expected_phase,checks=0,errors=0,title_hits=0,scroll_hits=0;
  string message="WELCOME TO ANLOGIC FPGA HDMI MULTIMEDIA DISPLAY   TF CARD BMP PLAYER WITH REAL-TIME OSD OVERLAY   PAGE 1-4 AUTOMATIC SLIDESHOW  ";
  string info="        PIC 1/4  MODE:MANUAL  T=00:00  FX:HWIPE";
  function automatic [23:0] mix(input [23:0] a,b,input integer weight);
    integer q; reg [23:0] value;
    begin
      for(q=0;q<3;q=q+1) value[q*8+:8]=(integer'(a[q*8+:8])*(4-weight)+integer'(b[q*8+:8])*weight)/4;
      mix=value;
    end
  endfunction
  function automatic [23:0] ref_rgb(input integer xx,yy,phase,input [23:0] bg);
    integer ci,sub,row,code,bi; reg [23:0] v;
    begin
      v=bg;
      if((yy>=2&&yy<30)||yy>=420) v=mix(v,24'h0a101e,2);
      bi=(xx-560)/16;
      if(xx>=560&&xx<624&&((xx-560)%16)<12&&yy<24&&yy>=24-(8+bi*4))
        v=mix(v,24'hffa838,bi<=page?2:1);
      if(xx>=243&&xx<397&&yy>=4&&yy<28) begin
        ci=(xx-243)/26;sub=(xx-243)%26;
        if(sub<24&&cn[ci*32+yy-4][23-sub]) v=24'hffffff;
      end
      if((yy>=424&&yy<440)||(yy>=452&&yy<468)) begin
        if(yy<440)begin ci=((xx+phase)/12)%128;sub=(xx+phase)%12;row=yy-424;code=message.getc(ci);end
        else begin ci=xx/12;sub=xx%12;row=yy-452;code=ci<info.len()?info.getc(ci):32;end
        if(sub<10&&font[(code-32)*16+row][9-sub])v=yy<440?24'ha0e4ff:24'hffffff;
      end
      ref_rgb=v;
    end
  endfunction
  task tick; begin @(posedge clk);#1;@(negedge clk);end endtask
  task sync_frame;
    begin de=0;vs=0;tick();vs=1;tick();vs=0;tick();end
  endtask
  reg [23:0] expected;
  initial begin
    $readmemh("osd_font_cn.hex",cn);$readmemh("osd_font_5x7.hex",font);
    repeat(3)tick();rst=0;tick();
    // Known bug discriminator: equal white inputs must remain white at 25%.
    if(dut.bl25(8'hff,8'hff)!==8'hff)$fatal(1,"25%% blend white expected=ff actual=%h",dut.bl25(8'hff,8'hff));
    for(k=0;k<256;k=k+1)begin
      if(dut.bl50(k[7:0],(255-k))!==8'd127)$fatal(1,"50%% extreme failed");
      if(dut.bl25(k[7:0],k[7:0])!==k[7:0])$fatal(1,"25%% equal-input rounding failed k=%0d",k);
    end
    sync_frame();expected_phase=1;
    for(y=0;y<480;y=y+1)begin
      de=0;hs=1;tick();hs=0;tick();
      for(x=0;x<640;x=x+1)begin
        de=1;rgb={x[7:0],y[7:0],(x[7:0]^y[7:0])};#1;
        expected=ref_rgb(x,y,expected_phase,rgb);checks++;
        if(out!==expected)begin errors++;if(errors<8)$display("DIFF x=%0d y=%0d expected=%h actual=%h",x,y,expected,out);end
        if(od!==de||oh!==hs||ov!==vs)$fatal(1,"sync alignment");
        if(y>=4&&y<28&&out==24'hffffff)title_hits++;
        if(y>=424&&y<440&&out==24'ha0e4ff)scroll_hits++;
        tick();
      end
      de=0;rgb=24'h123456;#1;if(out!==rgb)$fatal(1,"blanking modified");tick();
    end
    if(errors||title_hits<100||scroll_hits<100)$fatal(1,"full frame errors=%0d title=%0d scroll=%0d",errors,title_hits,scroll_hits);
    // No pixel rows needed to exercise VS-driven scroll carry and 128-ci wrap.
    for(k=2;k<=1536;k=k+1)begin
      sync_frame();
      if(dut.scroll_px!==4'(k%12)||dut.scroll_cell!==7'((k/12)%128))$fatal(1,"scroll phase k=%0d",k);
    end
    rst=1;#1;
    if(dut.x_cnt!==0||dut.y_cnt!==0||dut.scroll_px!==0||dut.scroll_cell!==0||dut.tick_cnt!==0)$fatal(1,"reset state");
    $display("PASS tb_osd_overlay: pixels=%0d errors=%0d title_hits=%0d scroll_hits=%0d scroll_wrap=1536 blend_extremes=512 reset=1",checks,errors,title_hits,scroll_hits);
    $finish;
  end
  initial begin #30000000;$fatal(1,"watchdog");end
endmodule
