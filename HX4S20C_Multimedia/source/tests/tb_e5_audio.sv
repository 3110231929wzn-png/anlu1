`timescale 1ns/1ps
module tb_e5_audio;
reg clk=0,rst=1,valid=0;
always #20 clk=~clk;
reg [23:0] pcm=0;
wire [255:0] cur,peak;
wire [7:0] level;
wire update,overrun,ok,active;
spectrum_top dut(.clk(clk),.rst(rst),.I_audio_valid(valid),.I_audio_pcm(pcm),
 .O_cur(cur),.O_peak(peak),.O_ref(level),.O_update(update),.O_overrun(overrun),.O_data_ok(ok),.O_active(active));
integer stage=0,caseid=-1,cap_count=0,fft_starts=0,fft_dones=0,band_updates=0,silence_ticks=0;
integer rr[0:511],ii[0:511],stimulus_r[0:511],stimulus_i[0:511];
integer k,j,n,h,base,wr,wi,ar,ai,br,bi,tr,ti,cycles,checked_bins=0,value;
longint signed pr,pi;
real theta;
e5_progress #(.LABEL("audio"),.MAX_CYCLES(2500000)) monitor(
 .clk(clk),.stage(stage),.samples(cap_count),.fft_starts(fft_starts),.fft_dones(fft_dones),.frame(caseid),
 .state_bits({26'd0,rst,valid,dut.fft_busy,dut.bd_busy,overrun,active}));
always @(posedge clk) if(!rst) begin
 if(dut.fft_start)fft_starts++;
 if(dut.fft_done)fft_dones++;
 if(update)band_updates++;
 if(dut.silence_tick)silence_ticks++;
 if(overrun)$fatal(1,"normal PCM rate overrun");
end
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

function automatic integer rev(input integer a);
 integer t,z;begin z=0;for(t=0;t<9;t++)z=(z<<1)|((a>>t)&1);return z;end
endfunction
function automatic integer sat(input longint signed a);
 begin if(a>32767)return 32767;if(a< -32768)return -32768;return int'(a);end
endfunction

task tick;begin @(posedge clk);#2;@(negedge clk);end endtask
task ticks(input integer count);repeat(count)tick();endtask
task sample(input integer v);
 integer expected;
 begin
  valid=1;pcm=24'(v);expected=v>>>9;
  stimulus_r[cap_count%512]=expected;stimulus_i[cap_count%512]=0;
  tick();
  if(!dut.cap_we||dut.cap_wdata!=={16'd0,16'(expected)}||dut.cap_waddr!==9'(rev(cap_count%512))||dut.cap_wbank!==1'((cap_count/512)%2))
   $fatal(1,"PCM capture/address/bank mismatch sample=%0d value=%0d",cap_count,v);
  if(dut.frame_ready!==(cap_count%512==511))$fatal(1,"frame-ready cadence");
  cap_count++;valid=0;ticks(520);
 end
endtask
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

initial begin
 ticks(5);rst=0;
 for(caseid=0;caseid<6;caseid++)begin
  stage=1;monitor.dump("window_start");
  for(n=0;n<512;n++)begin
   case(caseid)
    0:value=0;
    1:value=8388607;
    2:value=-8388608;
    3:value=n%2?8388607:-8388608;
    4:value=$rtoi(7000000.0*$sin(6.283185307179586*11*n/512));
    5:value=n%2?512:-512;
   endcase
   sample(value);
  end
  stage=2;golden_fft();
  for(cycles=0;cycles<17000&&!dut.fft_done;cycles++)tick();
  if(!dut.fft_done)$fatal(1,"FFT completion bound");
  tick();
  for(k=0;k<512;k++)begin
   if(caseid%2==0)begin
    if(dut.u_bank0.mem[k]!=={16'(ii[k]),16'(rr[k])})$fatal(1,"FFT bank0 case=%0d bin=%0d",caseid,k);
   end else begin
    if(dut.u_bank1.mem[k]!=={16'(ii[k]),16'(rr[k])})$fatal(1,"FFT bank1 case=%0d bin=%0d",caseid,k);
   end
   checked_bins++;
  end
  for(cycles=0;cycles<1000&&!update;cycles++)tick();
  if(!update||!ok||(^cur===1'bx)||(^peak===1'bx))$fatal(1,"bands completion/known-data bound");
  for(k=0;k<32;k++)if(cur[k*8+:8]>116||peak[k*8+:8]>116)$fatal(1,"height overflow");
  tick();
 end
 stage=3;ticks(500100);
 if(silence_ticks<1||active)$fatal(1,"silence timeout handling");
 if(cap_count!=3072||fft_starts!=6||fft_dones!=6||checked_bins!=3072||band_updates<7)
  $fatal(1,"audio pipeline coverage");
 stage=4;monitor.dump("final_checks");
 $display("PASS tb_e5_audio: samples=%0d starts=%0d dones=%0d bins=%0d updates=%0d silence=%0d",cap_count,fft_starts,fft_dones,checked_bins,band_updates,silence_ticks);$finish;
end
endmodule
