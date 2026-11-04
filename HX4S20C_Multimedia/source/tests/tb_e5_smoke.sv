`timescale 1ns/1ps
module tb_e5_smoke;
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

// The only stimulus source is one complete synchronous 512-sample PCM window.
reg av=0;
reg [23:0] left=0;
wire od,oh,ov;
wire [23:0] rgb;
video_e5 dut(clk,rst,av,left,ed,eh,ev,ergb,od,oh,ov,rgb);
wire sof,aval,eol;
wire [23:0] axis;
video_rgb_to_axis_640x480 axis_dut(clk,rst,ov,od,rgb,sof,aval,eol,axis);
// This is the real transmitter's existing AXIS boundary, not a TMDS model.
wire I_axis_s_user=sof,I_axis_s_valid=aval,I_axis_s_last=eol;
wire [23:0] I_axis_s_data=axis;
integer stage=0,video_frame=-1,samples=0,fft_starts=0,fft_dones=0,band_updates=0,display_commits=0;
integer pixels=0,lines=0,sofs=0,outside=0,region=0,changed=0,bar_pixels=0,axis_marker_pixels=0;
integer rr[0:511],ii[0:511],stimulus_r[0:511],stimulus_i[0:511];
integer k,j,n,h,base,wr,wi,ar,ai,br,bi,tr,ti,cycles,checked_bins=0;
longint signed pr,pi;
real theta;
reg [255:0] expected_cur=0,expected_peak=0;
time start_time,done_time,bands_time,pending_time,display_time,marker_time;
e5_progress #(.LABEL("smoke"),.MAX_CYCLES(800000)) monitor(
 .clk(clk),.stage(stage),.samples(samples),.fft_starts(fft_starts),.fft_dones(fft_dones),.frame(video_frame),
 .state_bits({24'd0,rst,av,dut.analyzer.fft_busy,dut.analyzer.bd_busy,dut.pending_ok,dut.display_ok,de,vs}));
always @(posedge clk) if(!rst) begin
 if(av)samples++;
 if(dut.analyzer.fft_start)begin fft_starts++;start_time=$time;$display("EVIDENCE fft_start time=%0t samples=%0d",$time,samples);end
 if(dut.analyzer.fft_done)begin fft_dones++;done_time=$time;$display("EVIDENCE fft_done time=%0t",$time);end
 if(dut.update)begin band_updates++;bands_time=$time;$display("EVIDENCE bands_done time=%0t cur=%h peak=%h",$time,dut.cur,dut.peak);end
 if(dut.overrun)$fatal(1,"PCM overrun");
end
function automatic integer rev(input integer a);
 integer t,z;begin z=0;for(t=0;t<9;t++)z=(z<<1)|((a>>t)&1);return z;end
endfunction
function automatic integer sat(input longint signed a);
 begin if(a>32767)return 32767;if(a< -32768)return -32768;return int'(a);end
endfunction

task golden_fft;
 begin
   for(k=0;k<512;k++)begin rr[rev(k)]=stimulus_r[k];ii[rev(k)]=stimulus_i[k];end
   for(h=1;h<512;h=h*2)begin
     for(base=0;base<512;base=base+2*h)begin
       for(j=0;j<h;j++)begin
         theta=6.283185307179586*j/(2*h);
         wr=$rtoi($cos(theta)*32767.0+($cos(theta)>=0?0.5:-0.5));
         wi=$rtoi(-$sin(theta)*32767.0-0.5);
         ar=rr[base+j];ai=ii[base+j];br=rr[base+j+h];bi=ii[base+j+h];
         pr=longint'(br)*wr-longint'(bi)*wi;
         pi=longint'(br)*wi+longint'(bi)*wr;
         tr=int'((pr+16384)>>>15);ti=int'((pi+16384)>>>15);
         rr[base+j]=sat((longint'(ar)+tr)>>>1);
         ii[base+j]=sat((longint'(ai)+ti)>>>1);
         rr[base+j+h]=sat((longint'(ar)-tr)>>>1);
         ii[base+j+h]=sat((longint'(ai)-ti)>>>1);
       end
     end
   end
 end
endtask

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

// Independent E4-output -> two E5 registers -> AXIS scoreboard.
integer rx=0,ry=0,ex=0,ey=0;
reg prev_vs=0,exp_de=0,exp_hs=0,exp_vs=0;
reg [23:0] exp_rgb=0,exp_base=0;
reg sd,sh,sv,edge_commit,axis_valid;
reg [23:0] sr,now_rgb,axis_input;
reg [511:0] before_display;
integer sx,syy;
always @(posedge clk)begin
 sd=ed;sh=eh;sv=ev;sr=ergb;
 edge_commit=ev&&!dut.vs_d&&dut.pending_ok;
 before_display={dut.display_cur,dut.display_peak};
 axis_input=rgb;axis_valid=od;
 if(rst)begin rx=0;ry=0;prev_vs=0;exp_de=0;exp_hs=0;exp_vs=0;exp_rgb=0;exp_base=0;end
 else begin
  if(sv!=prev_vs)begin rx=0;ry=0;end
  sx=rx;syy=ry;
  now_rgb=compose(sr,rx,ry,expected_cur,expected_peak,dut.display_ok);
  if(!sd)now_rgb=sr;
  if(sd)begin
   if(!dut.display_ok||dut.renderer.I_cur!==expected_cur||dut.renderer.I_peak!==expected_peak)
    $fatal(1,"computed spectrum did not reach renderer");
   if(rx==639)begin rx=0;ry++;end else rx++;
  end
  prev_vs=sv;
  #1;
  if({od,oh,ov,rgb}!=={exp_de,exp_hs,exp_vs,exp_rgb})$fatal(1,"RGB/DE/HS/VS compositing or two-cycle alignment");
  if({dut.display_cur,dut.display_peak}!==before_display&&!edge_commit)$fatal(1,"snapshot changed outside frame commit");
  if(edge_commit)begin
   display_commits++;display_time=$time;
   if(dut.display_cur!==expected_cur||dut.display_peak!==expected_peak)$fatal(1,"snapshot not from computed band set");
   $display("EVIDENCE display_commit time=%0t cur=%h peak=%h",$time,dut.display_cur,dut.display_peak);
  end
  if(exp_de)begin
   if(ey<304||ey>419)begin
    outside++;if(rgb!==exp_base)$fatal(1,"outside spectrum region changed");
   end else begin
    region++;if(rgb!==exp_base)changed++;
    if(ex>=580&&ex<596)bar_pixels++;
   end
   if(ex==580&&ey==419)begin
    if(rgb!==24'h4087ca)$fatal(1,"known nonzero band pixel mismatch");
    marker_time=$time;$display("EVIDENCE renderer_marker time=%0t x=%0d y=%0d input=%h output=%h",$time,ex,ey,exp_base,rgb);
   end
  end
  if(I_axis_s_valid!==axis_valid||I_axis_s_data!==axis_input)$fatal(1,"HDMI AXIS pixel alignment");
  if(I_axis_s_valid)begin
   pixels++;
   if(I_axis_s_data==24'h4087ca)axis_marker_pixels++;
  end
  if(I_axis_s_last)lines++;
  if(I_axis_s_user)sofs++;
  exp_de=sd;exp_hs=sh;exp_vs=sv;exp_rgb=now_rgb;exp_base=sr;ex=sx;ey=syy;
 end
end

task tick;begin @(posedge clk);#2;@(negedge clk);end endtask
task ticks(input integer count);repeat(count)tick();endtask
integer x,y;
initial begin
 // Pure bin128 tone: [0,+4194304,0,-4194304], quantized [0,+8192,0,-8192].
 // band_map_rom explicitly maps bin128 to band29; the first AGC target is 116.
 if(dut.analyzer.u_fft.N!=512||dut.analyzer.u_fft.STAGES!=9)$fatal(1,"unexpected FFT configuration");
 expected_cur[29*8+:8]=116;expected_peak[29*8+:8]=116;
 ticks(5);rst=0;vs=1;mode=3;stage=1;
 for(n=0;n<512;n++)begin
  case(n%4)
   0,2:stimulus_r[n]=0;
   1:stimulus_r[n]=8192;
   3:stimulus_r[n]=-8192;
  endcase
  stimulus_i[n]=0;
  left=24'(stimulus_r[n]*512);av=1;tick();av=0;ticks(520);
 end
 stage=2;golden_fft();
 for(cycles=0;cycles<17000&&!dut.analyzer.fft_done;cycles++)tick();
 if(!dut.analyzer.fft_done)$fatal(1,"FFT deadline");
 tick(); // Commit the last registered RAM write.
 for(k=0;k<512;k++)begin
  if(dut.analyzer.u_bank0.mem[k]!=={16'(ii[k]),16'(rr[k])})$fatal(1,"one-window FFT mismatch bin=%0d",k);
  checked_bins++;
 end
 $display("EVIDENCE FFT bins_checked=%0d bin128=%h bin384=%h",checked_bins,dut.analyzer.u_bank0.mem[128],dut.analyzer.u_bank0.mem[384]);
 stage=3;
 for(cycles=0;cycles<1000&&!dut.update;cycles++)tick();
 if(!dut.update||!dut.data_ok||dut.cur!==expected_cur||dut.peak!==expected_peak)$fatal(1,"expected band29 height116 absent");
 tick();
 if(!dut.pending_ok||dut.pending_cur!==expected_cur||dut.pending_peak!==expected_peak)$fatal(1,"pending snapshot mismatch");
 if(dut.display_ok)$fatal(1,"computed data displayed before frame boundary");
 pending_time=$time;$display("EVIDENCE pending_snapshot time=%0t cur=%h peak=%h",$time,dut.pending_cur,dut.pending_peak);
 stage=4;video_frame=0;
 // Exactly one complete low-active 800x525 raster; no further PCM windows.
 for(y=0;y<525;y++)for(x=0;x<800;x++)begin
  vs=!(y>=10&&y<12);hs=!(x>=16&&x<112);
  de=(y>=45&&x>=160);ix=de?10'(x-160):0;iy=de?9'(y-45):0;
  stage=5;tick();
 end
 stage=6;de=0;ticks(10);
 if(samples!=512||fft_starts!=1||fft_dones!=1||checked_bins!=512||band_updates!=1||display_commits!=1)
  $fatal(1,"one-window chain count");
 if(pixels!=307200||lines!=480||sofs!=1||outside!=232960||region!=74240||changed!=74240||bar_pixels!=1856||axis_marker_pixels!=1840)
  $fatal(1,"one-frame coverage pixels=%0d outside=%0d region=%0d changed=%0d bar=%0d axis_marker=%0d",pixels,outside,region,changed,bar_pixels,axis_marker_pixels);
 if(!(start_time<done_time&&done_time<bands_time&&bands_time<=pending_time&&pending_time<display_time&&display_time<marker_time))
  $fatal(1,"chain event order");
 stage=7;monitor.dump("final_checks");
 $display("PASS tb_e5_smoke: samples=%0d FFT=%0d bins=%0d bands=%0d display_commits=%0d pixels=%0d lines=%0d SOF=%0d outside_unchanged=%0d region_changed=%0d bar_pixels=%0d HDMI_AXIS_marker_pixels=%0d endpoint=HDMI_transmitter_AXIS_input",samples,fft_dones,checked_bins,band_updates,display_commits,pixels,lines,sofs,outside,changed,bar_pixels,axis_marker_pixels);$finish;
end
endmodule
