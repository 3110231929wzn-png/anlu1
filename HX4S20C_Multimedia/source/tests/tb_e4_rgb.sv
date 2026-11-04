`timescale 1ns/1ps
module tb_e4_rgb;
 reg clk=0,rst=1,de=0,hs=0,vs=0,vld=1;
 always #5 clk=~clk;
 reg [23:0] rgb=0;reg signed [7:0] bri=0;reg signed [5:0] con=0;
 wire od,oh,ov;wire [23:0] out;
 rgb_adjust dut(clk,rst,de,hs,vs,rgb,bri,con,vld,od,oh,ov,out);
 integer b,q,v,n=0;reg [23:0] expected;
 function automatic [7:0] refch(input integer x,input integer b0,input integer q0);
   integer numerator,z;
   begin
     // Independent mathematical model: floor of combined gain numerator.
     numerator=(x-128)*(32+q0);
     z=128+b0+(numerator>=0?numerator/32:-((-numerator+31)/32));
     refch=z<0?0:z>255?255:z;
   end
 endfunction
 task step;
   begin @(posedge clk);#1;
     if({od,oh,ov}!=={de,hs,vs}||out!==expected)
       $fatal(1,"RGB/sync mismatch b=%0d q=%0d rgb=%h actual=%h expected=%h",bri,con,rgb,out,expected);
     @(negedge clk);n++;
   end
 endtask
 initial begin
   repeat(3)@(negedge clk);rst=0;
   for(b=-64;b<=64;b++)for(q=-16;q<=16;q++)for(v=0;v<256;v++)begin
     bri=b;con=q;rgb={8'(v),8'(255-v),8'((v+73)%256)};
     de=v[0];hs=v[1];vs=v[2];
     expected={refch(v,b,q),refch(255-v,b,q),refch((v+73)%256,b,q)};step();
   end
   vld=0;bri=64;con=-16;rgb=24'hffffff;expected=0;step();
   rst=1;#1;if(out!==0||od!==0||oh!==0||ov!==0)$fatal(1,"reset");
   $display("PASS tb_e4_rgb: vectors=%0d three_channels signed_floor saturation identity sync valid reset",n);$finish;
 end
 initial begin #20000000;$fatal(1,"RGB watchdog");end
endmodule
