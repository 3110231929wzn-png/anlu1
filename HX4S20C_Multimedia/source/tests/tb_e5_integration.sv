`timescale 1ns/1ps
module tb_e5_integration;
reg clk=0,sc=0,mc=0,refclk=0,rst=1,arst=1;
always #20 clk=~clk;
always #5 sc=~sc;
always #10 mc=~mc;
always #10 refclk=~refclk;
reg de=0,hs=0,vs=0,key=1,sel=0;
reg [1:0] mode=0,page=0;
reg [9:0] ix=0;
reg [8:0] iy=0;
reg [6:0] progress=32;
wire [23:0] trans_rgb;
wire [9:0] ox,nx;
wire [8:0] sy;
wire on,nn,tvalid;
transition_pixels transition_dut(mode,progress,ix,iy,24'h204060,24'hb08040,
    trans_rgb,ox,nx,sy,on,nn,tvalid);
wire ed,eh,ev;
wire [23:0] ergb;
video_e4 #(.CTRL_CLK_FREQ(1000)) e4(
    .sd_clk(sc),.sd_rst(rst),.mem_clk(mc),.mem_rst(rst),.video_clk(clk),.video_rst(rst),
    .display_page(page),.transition_mode(mode),.image_total(3'd4),.autoplay(1'b1),
    .display_enable(1'b1),.I_de(de),.I_hs(hs),.I_vs(vs),.I_rgb(trans_rgb),
    .adjust_select(sel),.adjust_key_n(key),.O_de(ed),.O_hs(eh),.O_vs(ev),.O_rgb(ergb));
wire av,acr,rav,racr;
wire [23:0] left,right,rleft,rright;
wire [19:0] cts,an,rcts,rn;
hdmi_basic_audio audio(refclk,clk,arst,av,left,right,acr,cts,an);
hdmi_basic_audio reference_audio(refclk,clk,arst,rav,rleft,rright,racr,rcts,rn);
wire od,oh,ov;
wire [23:0] rgb;
video_e5 dut(clk,rst,av,left,ed,eh,ev,ergb,od,oh,ov,rgb);
wire sof,aval,eol;
wire [23:0] axis;
video_rgb_to_axis_640x480 axis_dut(clk,rst,ov,od,rgb,sof,aval,eol,axis);

// A separate intentionally overspeed source exercises backpressure ownership.
reg fast_rst=1,fast_valid=0;
wire [255:0] fc,fp;
wire [7:0] fr;
wire fok,fa,fu,fo;
spectrum_top fast(clk,fast_rst,fast_valid,24'h800000,fu,fo,fc,fp,fr,fok,fa);
integer bank_checks=0,fast_updates=0;
always @(posedge clk)if(!fast_rst)begin
    if(fast.processing && fast.cap_we && fast.cap_wbank==fast.fft_bank)
        $fatal(1,"capture overwrote processing bank");
    if(fast.processing)bank_checks++;
    if(fu)fast_updates++;
end
initial begin
 repeat(6)@(negedge clk);fast_rst=0;fast_valid=1;
 repeat(40000)@(negedge clk);
 if(!fo||fast_updates==0||bank_checks<10000)$fatal(1,"overspeed coverage missing");
 fast_valid=0;fast_rst=1;
end

integer cycle=0,samples=0,pos_samples=0,neg_samples=0,acrs=0,last_sample=0;
integer band_updates=0,silent_updates=0,last_silence=0,display_updates=0;
integer stage=0,video_frame=-1,fft_starts=0,fft_dones=0;
reg interframe=1;
e5_progress #(.LABEL("integration"),.MAX_CYCLES(3600000)) monitor(
 .clk(clk),.stage(stage),.samples(samples),.fft_starts(fft_starts),.fft_dones(fft_dones),.frame(video_frame),
 .state_bits({24'd0,arst,rst,dut.analyzer.fft_busy,dut.analyzer.bd_busy,dut.overrun,fast_valid,de,vs}));
always @(posedge clk) if(!rst) begin
 if(dut.analyzer.fft_start)fft_starts++;
 if(dut.analyzer.fft_done)fft_dones++;
 if(interframe && de)$fatal(1,"DE must be low during interframe controls");
end
reg last_av=0;
always @(posedge clk)begin
 if(rst)begin cycle=0;last_sample=0;last_av=0;end
 else begin
   cycle++;
   if({av,left,right,acr,cts,an}!=={rav,rleft,rright,racr,rcts,rn})
     $fatal(1,"audio differs from unchanged baseline wrapper");
   if(arst)begin last_sample=0;last_av=0;end
   else if(av)begin
     if(last_av)$fatal(1,"audio valid wider than one pixel clock");
     if(last_sample && (cycle-last_sample<520||cycle-last_sample>521))$fatal(1,"audio cadence");
     last_sample=cycle;samples++;
     if($signed(left)>0)pos_samples++;
     if($signed(left)<0)neg_samples++;
     if(left!==right)$fatal(1,"stereo test tone mismatch");
   end
   last_av=av;
   if(acr)begin if(an!==6144)$fatal(1,"ACR N changed");acrs++;end
   if(dut.update && dut.data_ok)begin
     band_updates++;
     if((^dut.cur===1'bx)||(^dut.peak===1'bx))$fatal(1,"band output unknown");
   end
   if(dut.analyzer.silence_tick)begin
     if(last_silence && cycle-last_silence<500000)$fatal(1,"silence tick runs too fast");
     last_silence=cycle;silent_updates++;
   end
   if(dut.overrun)$fatal(1,"normal sample rate overrun");
 end
end

// Independent raster and compositing reference, indexed at E4 output.
integer rx=0,ry=0,pixels=0,lines=0,sofs=0,outside=0,spectrum_pixels=0,changed=0;
integer panel=0,snap_checks=0;
reg prev_vs=0,exp_de=0,exp_hs=0,exp_vs=0;
reg [23:0] exp_rgb=0;
reg [511:0] last_display=0;
reg last_display_ok=0;
function automatic [23:0] compose(input [23:0] a,input integer x,y,
    input [255:0] c,p,input bit en);
 integer bi,bx,yf,h,pk,r,g,b,cr,cg,cb;
 begin
   r=a[23:16];g=a[15:8];b=a[7:0];
   if(en&&y>=304&&y<=419)begin
     bi=x/20;bx=x%20;yf=419-y;h=c[bi*8+:8];pk=p[bi*8+:8];
     r=(r>>1)+(r>>3);g=(g>>1)+(g>>3);b=(b>>1)+(b>>3);
     case(bi/8)
       0:begin cr=255;cg=64;cb=64;end
       1:begin cr=255;cg=176;cb=48;end
       2:begin cr=64;cg=224;cb=96;end
       3:begin cr=64;cg=160;cb=255;end
     endcase
     if(bx<16)begin
       if(pk!=0&&(yf==pk||yf+1==pk))begin r=232;g=240;b=255;end
       else if(yf<h)begin r=(r>>2)+(cr>>1)+(cr>>2);g=(g>>2)+(cg>>1)+(cg>>2);b=(b>>2)+(cb>>1)+(cb>>2);end
     end
   end
   return {8'(r),8'(g),8'(b)};
 end
endfunction
reg sd,sh,sv,sen,frame_edge;
reg [23:0] sr,now_rgb,axis_input;
reg axis_valid;
reg [511:0] before_display;
integer sx,syy;
always @(posedge clk)begin
 sd=ed;sh=eh;sv=ev;sr=ergb;sen=dut.display_ok;
 frame_edge=ev&&!dut.vs_d;
 before_display={dut.display_cur,dut.display_peak};
 axis_input=rgb;axis_valid=od;
 if(rst)begin rx=0;ry=0;prev_vs=0;exp_de=0;exp_hs=0;exp_vs=0;exp_rgb=0;end
 else begin
   if(sv!=prev_vs)begin rx=0;ry=0;end
   sx=rx;syy=ry;
   now_rgb=compose(sr,rx,ry,dut.display_cur,dut.display_peak,sen);
   if(!sd)now_rgb=sr;
   if(sd)begin
     if(ry<304||ry>419)outside++;else if(sen)spectrum_pixels++;
     if(ry>=32&&ry<48&&rx>=456&&rx<624)panel++;
     if(rx==639)begin rx=0;ry++;end else rx++;
   end
   prev_vs=sv;
   #1;
   if({od,oh,ov,rgb}!=={exp_de,exp_hs,exp_vs,exp_rgb})
     $fatal(1,"pixel reference / 2-clock alignment mismatch x=%d y=%d got=%h expected=%h",sx,syy,rgb,exp_rgb);
   if({dut.display_cur,dut.display_peak}!==before_display&&!frame_edge)$fatal(1,"snapshot changed midframe");
   if(frame_edge&&dut.display_ok)display_updates++;
   if(sd)snap_checks++;
   if(aval!==axis_valid||axis!==axis_input)$fatal(1,"AXIS RGB alignment");
   if(aval) pixels++;
   if(eol)lines++;
   if(sof)sofs++;
   if(exp_de&&rgb!==sr)changed++; // supplemental activity only; exact reference above is the oracle.
   exp_de=sd;exp_hs=sh;exp_vs=sv;exp_rgb=now_rgb;
 end
end
task tick;begin @(posedge clk);#2;@(negedge clk);end endtask
task ticks(input integer n);repeat(n)tick();endtask
integer f,x,y;
initial begin
 ticks(5);rst=0;arst=0;
 for(f=0;f<8;f++)begin
   de=0;interframe=1;video_frame=f;stage=1;
   mode=f%4;page=f%4;
   if(f==2)begin key=0;ticks(40);key=1;ticks(40);end
   if(f==3)begin sel=1;ticks(40);end
   if(f==4)begin key=0;ticks(40);key=1;ticks(40);arst=1;end
   if(f==5)key=1;
   if(f==6)arst=0;
   stage=2;interframe=0;
   // Full 800x525 raster, low-active HS/VS as in the successful baseline.
   for(y=0;y<525;y++)for(x=0;x<800;x++)begin
     vs=!(y>=10&&y<12);hs=!(x>=16&&x<112);
     de=(y>=45&&x>=160);
     ix=de?10'(x-160):0;iy=de?9'(y-45):0;
     tick();
   end
 end
 stage=3;de=0;interframe=1;ticks(10);
 if(pixels!=8*307200||lines!=8*480||sofs!=8||spectrum_pixels==0||display_updates<6||band_updates<8||silent_updates<1||pos_samples==0||neg_samples==0||acrs<4||panel!=8*2688)
   $fatal(1,"coverage pixels=%d lines=%d SOFs=%d bands=%d silent=%d panel=%d",pixels,lines,sofs,band_updates,silent_updates,panel);
 if(e4.brightness!==1||e4.contrast!==1)$fatal(1,"E4 parameter key/frame latch regression");
 stage=4;monitor.dump("final_checks");
 rst=1;#2;if(rgb!==0||od!==0)$fatal(1,"video reset");
 $display("PASS tb_e5_integration: pixels=%0d lines=%0d SOF=%0d outside=%0d spectrum_pixels=%0d panel=%0d snapshot_checks=%0d display_updates=%0d bands=%0d silence_ticks=%0d PCM=%0d positive=%0d negative=%0d ACR=%0d bank_checks=%0d fast_updates=%0d modes=4 RGB_DE_HS_VS_AXIS=aligned",pixels,lines,sofs,outside,spectrum_pixels,panel,snap_checks,display_updates,band_updates,silent_updates,samples,pos_samples,neg_samples,acrs,bank_checks,fast_updates);$finish;
end
initial begin #150000000;monitor.dump("legacy_watchdog");$fatal(1,"joint simulation watchdog");end
endmodule
