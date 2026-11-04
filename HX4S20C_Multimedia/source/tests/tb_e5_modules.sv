`timescale 1ns/1ps
module tb_e5_modules;
reg clk=0,rst=1,valid=0;
always #20 clk=~clk;
reg [23:0] pcm=0;
wire we,bank,wbank,ready,donebank;
wire [8:0] wa;
wire [31:0] wd;
audio_capture cap(clk,rst,valid,pcm,we,wa,wd,bank,wbank,ready,donebank);
reg start=0;
wire busy,done,fwe;
wire [8:0] ra,fwa;
wire [31:0] rd,fwd;
fft512_core fft(clk,rst,start,busy,done,ra,rd,fwe,fwa,fwd);
dpram_512x32 ram(clk,fwe,fwa,fwd,ra,rd);
wire [255:0] cur,peak;
wire [7:0] reflevel;
wire bb,bd,ok;
wire [8:0] bra;
reg bs=0,sil=0;
reg [31:0] brd=0;
spectrum_bands bands(clk,rst,bs,sil,bb,bd,bra,brd,cur,peak,reflevel,ok);
integer cap_count=0,frames=0,checks=0,magchecks=0;
integer rr[0:511],ii[0:511];
integer stimulus_r[0:511],stimulus_i[0:511];
integer caseid,k,j,n,h,base,idx,adr,wr,wi,ar,ai,br,bi,tr,ti,cycles;
longint signed pr,pi;
real theta;
function automatic integer rev(input integer a);
 integer t,z;begin z=0;for(t=0;t<9;t++)z=(z<<1)|((a>>t)&1);return z;end
endfunction
function automatic integer sat(input longint signed a);
 begin if(a>32767)return 32767;if(a< -32768)return -32768;return int'(a);end
endfunction
task tick;begin @(posedge clk);#2;@(negedge clk);end endtask
task sample(input integer v);
 integer expected;
 begin
   valid=1;pcm=24'(v);expected=v>>>9;tick();
   if(!we||wd!=={16'd0,16'(expected)}||wa!==9'(rev(cap_count%512))||wbank!==1'((cap_count/512)%2))
     $fatal(1,"capture sample=%0d got=%h expected=%h addr=%d count=%d",v,wd,16'(expected),wa,cap_count);
   if(ready!==(cap_count%512==511))$fatal(1,"capture ready cadence");
   if(ready&&donebank!==wbank)$fatal(1,"last sample bank");
   cap_count++;valid=0;tick();if(we||ready)$fatal(1,"capture invalid pulse");
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
task run_fft;
 begin
   for(n=0;n<512;n++)ram.mem[rev(n)]={16'(stimulus_i[n]),16'(stimulus_r[n])};
   golden_fft();start=1;tick();start=0;cycles=0;
   // Bounded wait, independent of whether done ever arrives.
   for(cycles=0;cycles<16200&&!done;cycles++)tick();
   if(!done||busy)$fatal(1,"FFT did not finish case=%0d cycles=%0d",caseid,cycles);
   tick(); // Commit final registered RAM write.
   for(n=0;n<512;n++)begin
     if(ram.mem[n]!=={16'(ii[n]),16'(rr[n])})
       $fatal(1,"FFT case=%0d bin=%0d got=%h expected=%h",caseid,n,ram.mem[n],{16'(ii[n]),16'(rr[n])});
     checks++;
   end
   frames++;
 end
endtask
integer v,expectabs,a,b;
initial begin
 repeat(4)tick();rst=0;
 sample(0);sample(1);sample(512);sample(-1);sample(-512);sample(-8388608);sample(8388607);
 // Every signed quantized value, plus varying discarded low bits.
 for(v=-16384;v<16384;v++)sample(v*512+((v+16384)%512));
 for(v=0;v<1024;v++)sample(v%2?-8388608:8388607);
 for(v=-32768;v<=32767;v++)begin
   expectabs=v<0?-v:v;if(expectabs>32767)expectabs=32767;
   if(bands.mag16(16'(v),16'd0)!==16'(expectabs))$fatal(1,"magnitude signed axis v=%d",v);
   if(bands.mag16(16'd0,16'(v))!==16'(expectabs))$fatal(1,"magnitude imag axis");
   magchecks+=2;
 end
 for(a=-32768;a<=32767;a+=4095)for(b=-32768;b<=32767;b+=4095)begin
   k=a<0?-a:a;j=b<0?-b:b;expectabs=k>j?k+(j>>1):j+(k>>1);
   if(expectabs>32767)expectabs=32767;
   if(bands.mag16(16'(a),16'(b))!==16'(expectabs))$fatal(1,"magnitude complex");magchecks++;
 end
 for(caseid=0;caseid<12;caseid++)begin
   for(n=0;n<512;n++)begin
     stimulus_i[n]=0;
     case(caseid)
       0:stimulus_r[n]=0;
       1:stimulus_r[n]=16383;
       2:stimulus_r[n]=-16384;
       3:stimulus_r[n]=n%2?16383:-16384;
       4:stimulus_r[n]=n==0?16383:0;
       5:stimulus_r[n]=n==0?-16384:0;
       6:stimulus_r[n]=$rtoi(15000*$sin(6.283185307179586*11*n/512));
       7:stimulus_r[n]=$rtoi(7000*$sin(6.283185307179586*7*n/512)+6000*$cos(6.283185307179586*87*n/512));
       8:begin stimulus_r[n]=n%2?32767:-32768;stimulus_i[n]=n%3?32767:-32768;end
       9:begin stimulus_r[n]=32767;stimulus_i[n]=32767;end
       10:begin stimulus_r[n]=-32768;stimulus_i[n]=-32768;end
       11:begin stimulus_r[n]=((n*7919+12345)%65536)-32768;stimulus_i[n]=((n*32719+9876)%65536)-32768;end
     endcase
   end
   run_fft();
 end
 // First real frame: nonzero positive bins must establish known cur/pk.
 brd={16'd0,16'd1000};bs=1;tick();bs=0;
 for(cycles=0;cycles<1000&&!bd;cycles++)tick();
 if(!bd||!ok||(^cur===1'bx)||(^peak===1'bx))$fatal(1,"first bands frame X or missing");
 for(k=0;k<32;k++)if(cur[k*8+:8]>116||peak[k*8+:8]>116)$fatal(1,"height overflow");
 sil=1;tick();sil=0;
 for(cycles=0;cycles<100&&!bd;cycles++)tick();
 if(!bd||(^cur===1'bx))$fatal(1,"silence bands");
 rst=1;tick();if(busy||bb||ok||we)$fatal(1,"reset did not clear control");
 $display("PASS tb_e5_modules: capture=%0d fft_frames=%0d fft_bins=%0d magnitude=%0d first_frame_known=1 silence=1 reset=1",cap_count,frames,checks,magchecks);$finish;
end
initial begin #30000000;$fatal(1,"module watchdog");end
endmodule
