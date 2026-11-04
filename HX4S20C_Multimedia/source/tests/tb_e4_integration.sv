`timescale 1ns/1ps
module tb_e4_integration;
 reg vc=0,sc=0,mc=0,rst=1,de=0,hs=0,vs=0,ready=0,req=0,key=1,sw=0;
 always #20 vc=~vc;always #5 sc=~sc;always #10 mc=~mc;
 reg [23:0] data=24'h305070;reg [2:0] page=0;reg [1:0] mode=0;reg autoplay=0;
 wire enable,re,dd,hd,vd;wire [23:0] aligned;
 wire od,oh,ov;wire [23:0] rgb;
 video_frame_enable guard(vc,rst,ready,req,enable);
 video_delay delay_dut(.video_clk(vc),.rst(rst),.read_en(re),.read_data(data),
   .hs(hs),.vs(vs),.de(de),.hs_r(hd),.vs_r(vd),.de_r(dd),.vout_data(aligned));
 video_e4 #(.CTRL_CLK_FREQ(1000)) dut(
   .sd_clk(sc),.sd_rst(rst),.mem_clk(mc),.mem_rst(rst),.video_clk(vc),.video_rst(rst),
   .display_page(page),.image_total(4'd8),.e3_on(1'b1),.transition_mode(mode),.autoplay(autoplay),
   .display_enable(enable),.I_de(dd),.I_hs(hd),.I_vs(vd),.I_rgb(enable?aligned:24'd0),
   .adjust_select(sw),.adjust_key_n(key),.O_de(od),.O_hs(oh),.O_vs(ov),.O_rgb(rgb));
 // Independent arithmetic pipeline feeding an unchanged E1 reference instance.
 reg rd=0,rh=0,rv=0,ren=0;reg [23:0] rr=0;
 integer expected_b=0,expected_q=0;
 function automatic [7:0] adj(input integer x);
   integer num,z;
   begin num=(x-128)*(32+expected_q);
     z=128+expected_b+(num>=0?num/32:-((-num+31)/32));adj=z<0?0:z>255?255:z;end
 endfunction
 always @(posedge vc or posedge rst)begin
   if(rst)begin rd<=0;rh<=0;rv<=0;ren<=0;rr<=0;end
   else begin rd<=dd;rh<=hd;rv<=vd;ren<=enable;
     rr<=enable?{adj(aligned[23:16]),adj(aligned[15:8]),adj(aligned[7:0])}:24'd0;end
 end
 wire gd,gh,gv;wire [23:0] golden;
 osd_video reference_e1(
   .sd_clk(sc),.sd_rst(rst),.mem_clk(mc),.mem_rst(rst),.video_clk(vc),.video_rst(rst),
   .display_page(page),.image_total(4'd8),.e3_on(1'b1),.transition_mode(mode),.autoplay(autoplay),
   .display_enable(ren),.I_de(rd),.I_hs(rh),.I_vs(rv),.I_rgb(rr),
   .O_de(gd),.O_hs(gh),.O_vs(gv),.O_rgb(golden));
 wire valid,sof,eol;wire [23:0] axis;
 video_rgb_to_axis_640x480 axis_dut(vc,rst,ov,od,rgb,sof,valid,eol,axis);
 integer ax=0,ay=0,pixels=0,lines=0,sofs=0,compared=0,black=0,panels=0;
 reg pde=0,pvs=0;reg [23:0] sample_rgb;reg sample_de;
 always @(posedge vc)begin
   sample_rgb=rgb;sample_de=od;
   #1;
   if(!rst)begin
     if({od,oh,ov}!=={rd,rh,rv})$fatal(1,"one-cycle RGB/DE/HS/VS alignment");
     if(dut.adjusted_de&&dut.adjusted_rgb!==rr)$fatal(1,"adjusted RGB mismatch");
     if(rv&&!pvs)begin ax=0;ay=0;end
     else if(pde&&!rd)begin ax=0;ay++;end
     if(!ren&&rgb!==0)$fatal(1,"first-frame panel/OSD leaked");
     if(rd)begin
       if(!ren)black++;
       if(ren&&ay>=32&&ay<48&&ax>=456&&ax<624)begin
         if(rgb===golden)$fatal(1,"panel absent");panels++;
       end else begin if(rgb!==golden)$fatal(1,"E1 changed outside panel x=%0d y=%0d",ax,ay);compared++;end
       ax++;
     end
     pde=rd;pvs=rv;
     if(valid!==sample_de||axis!==sample_rgb)$fatal(1,"AXIS alignment");
     if(valid)pixels++;if(eol)lines++;if(sof)sofs++;
   end else begin ax=0;ay=0;pde=0;pvs=0;end
 end
 task tick;begin @(posedge vc);#2;@(negedge vc);end endtask
 task ticks(input integer n);repeat(n)tick();endtask
 task tap;begin key=0;ticks(40);key=1;ticks(40);end endtask
 task new_frame;begin de=0;vs=0;ticks(100);req=1;vs=1;ticks(100);req=0;end endtask
 integer f,x,y;
 initial begin
   ticks(5);rst=0;
   for(f=0;f<5;f++)begin
     if(f==2)begin tap();expected_b=1;end
     if(f==3)begin sw=1;ticks(30);tap();expected_q=1;end
     if(f>0)begin mode=f-1;page=f-1;autoplay=f%2;end
     new_frame();
     if(dut.brightness!==8'(expected_b)||dut.contrast!==6'(expected_q))$fatal(1,"frame parameter latch");
     if(f>0&&(dut.u_osd_video.status.video_mode!==2'(f-1)||dut.u_osd_video.status.video_page!==3'(f-1)))$fatal(1,"metadata");
     for(y=0;y<480;y++)begin
       de=1;
       for(x=0;x<640;x++)begin data={8'(48+x%32),8'(80+y%32),8'(112+(x+y)%32)};tick();end
       de=0;ticks(160);
       if(f==0&&y==100)ready=1; // must wait until following frame request
       if(f>0&&y==200)mode=f%4;
       if(f>0&&dut.u_osd_video.status.video_mode!==2'(f-1))$fatal(1,"FX changed mid-frame");
     end
   end
   de=0;ticks(100);
   if(pixels!=5*307200||lines!=5*480||sofs!=5||black!=307200||panels!=4*2688)
     $fatal(1,"coverage pixels=%0d lines=%0d sof=%0d black=%0d panel=%0d",pixels,lines,sofs,black,panels);
   rst=1;#2;if(rgb!==0||od!==0||dut.brightness!==0)$fatal(1,"reset");
   $display("PASS tb_e4_integration: pixels=%0d lines=%0d SOF=%0d black=%0d E1_compared=%0d panel=%0d metadata_modes=4 RGB_sync_AXIS=1",pixels,lines,sofs,black,compared,panels);$finish;
 end
 initial begin #100000000;$fatal(1,"integration watchdog");end
endmodule
