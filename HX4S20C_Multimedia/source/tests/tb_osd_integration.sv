`timescale 1ns/1ps
// Same video_delay -> gated RGB -> osd_video -> original AXIS used by V3 top.
// SDRAM/HDMI encrypted cores are outside this focused video insertion test.
module tb_osd_integration;
 reg vc=0,sc=0,mc=0,rst=1,de=0,hs=0,vs=0,enable=0;
 always #20 vc=~vc;always #5 sc=~sc;always #10 mc=~mc;
 reg [23:0] data=24'h305070;
 wire hd,vd,dd,re;wire [23:0] aligned,overlaid;
 wire oh,ov,od,valid,user_flag,last_flag;wire [23:0] axis;
 reg [1:0] page=0,mode=0;reg autoplay=0;
 video_delay delay_dut(.video_clk(vc),.rst(rst),.read_en(re),.read_data(data),
   .hs(hs),.vs(vs),.de(de),.hs_r(hd),.vs_r(vd),.de_r(dd),.vout_data(aligned));
 osd_video dut(.sd_clk(sc),.sd_rst(rst),.mem_clk(mc),.mem_rst(rst),
   .video_clk(vc),.video_rst(rst),.display_page(page),.image_total(3'd4),.autoplay(autoplay),
   .transition_mode(mode),.display_enable(enable),.I_de(dd),.I_hs(hd),.I_vs(vd),
   .I_rgb(enable?aligned:24'd0),.O_de(od),.O_hs(oh),.O_vs(ov),.O_rgb(overlaid));
 video_rgb_to_axis_640x480 axis_dut(.I_clk(vc),.I_rst(rst),.I_vs(ov),.I_de(od),.I_rgb(overlaid),
   .O_video_user(user_flag),.O_video_valid(valid),.O_video_last(last_flag),.O_video_data(axis));
 integer x,y,f,k,checks=0,lines=0,sofs=0,bands=0,opaque=0;
 reg [23:0] sampled;reg sampled_de;
 integer ax=0,ay=0;reg prev_de=0,prev_vs=0;
 always @(posedge vc)begin
   sampled=overlaid;sampled_de=dd;
   if(!rst)begin
     if(od!==dd||oh!==hd||ov!==vd)$fatal(1,"OSD moved sync");
     if(!enable&&overlaid!==0)$fatal(1,"startup black broken");
     if(enable&&dd)begin
       if(ay==100&&overlaid!==aligned)$fatal(1,"uncovered background changed");
       if(ay==2&&ax==0)begin
         if(overlaid!==24'h1d3047)$fatal(1,"50%% band expected=1d3047 actual=%h",overlaid);
         bands++;
       end
       if(ay==8&&ax==254)begin
         if(overlaid!==24'hffffff)$fatal(1,"Chinese opaque glyph alignment");opaque++;
       end
     end
     if(vd&&!prev_vs)begin ax=0;ay=0;end
     else if(prev_de&&!dd)begin ax=0;ay=ay+1;end
     if(dd)ax=ax+1;
     prev_de=dd;prev_vs=vd;
   end else begin ax=0;ay=0;prev_de=0;prev_vs=0;end
   #1;
   if(!rst)begin
     if(valid!==sampled_de||axis!==sampled)$fatal(1,"AXIS pixel/DE mismatch");
     if(valid)checks++;
     if(last_flag)lines++;
     if(user_flag)sofs++;
   end
 end
 task tick;begin @(posedge vc);#2;@(negedge vc);end endtask
 task new_frame;
   begin de=0;vs=0;repeat(100)tick();vs=1;repeat(100)tick();end
 endtask
 initial begin
   repeat(5)tick();rst=0;
   // First-image gate is preserved even where the OSD would draw title/bands.
   new_frame();for(y=0;y<30;y++)begin de=1;repeat(640)tick();de=0;repeat(160)tick();end
   de=0;repeat(60)tick();enable=1;
   for(f=0;f<4;f++)begin
     mode=f;page=f;autoplay=f%2;new_frame();
     if(dut.status.video_mode!==2'(f)||dut.status.video_page!==2'(f)||dut.status.video_auto!==1'(f%2))$fatal(1,"real metadata not latched");
     for(y=0;y<480;y++)begin
       de=1;repeat(640)tick();de=0;repeat(160)tick();
       if(y==200)mode=(f+1)%4; // actual source changes must not tear current frame
       if(dut.status.video_mode!==2'(f))$fatal(1,"mode changed in frame");
     end
   end
   de=0;repeat(100)tick();rst=1;#1;
   if(dut.status.video_total!==0)$fatal(1,"reset metadata");
   if(checks!=4*307200+30*640||lines!=4*480+30||sofs!=5||bands!=4||opaque!=4)
      $fatal(1,"coverage pixels=%0d lines=%0d SOF=%0d bands=%0d opaque=%0d",checks,lines,sofs,bands,opaque);
   $display("PASS tb_osd_integration: pixels=%0d lines=%0d SOF=%0d modes=4 startup_black=1 frame_stable=1 sync_axis=1 reset=1",checks,lines,sofs);$finish;
 end
 initial begin #100000000;$fatal(1,"integration watchdog");end
endmodule
