`timescale 1ns/1ps
module tb_rgb_shiftadd_equiv;
 reg clk=0,rst=1,de=0,hs=0,vs=0,vld=1;
 always #5 clk=~clk;
 reg [23:0] rgb=0;reg signed [7:0] bri=0;reg signed [5:0] con=0;
 wire ad,ah,av,bd,bh,bv;wire [23:0] a,b;
 rgb_adjust original(clk,rst,de,hs,vs,rgb,bri,con,vld,ad,ah,av,a);
 rgb_adjust_shiftadd candidate(clk,rst,de,hs,vs,rgb,bri,con,vld,bd,bh,bv,b);
 integer bi,qi,vi,n=0,invalid=0;reg [26:0] prior;
 task compare;
   begin
     if({ad,ah,av,a}!=={bd,bh,bv,b})
       $fatal(1,"equivalence b=%0d q=%0d rgb=%h valid=%b orig=%h alt=%h",bri,con,rgb,vld,a,b);
   end
 endtask
 task step;
   begin
     prior={bd,bh,bv,b};#1;
     if({bd,bh,bv,b}!==prior)$fatal(1,"output changed before clock edge");
     @(posedge clk);#1;compare();
     if({bd,bh,bv}!=={de,hs,vs})$fatal(1,"sync latency mismatch");
     if(!vld&&b!==0)$fatal(1,"invalid black");
     if(vld&&bri==0&&con==0&&b!==rgb)$fatal(1,"identity");
     @(negedge clk);n++;
   end
 endtask
 initial begin
   repeat(3)@(negedge clk);rst=0;
   // Each channel visits every value for every legal parameter pair.
   // Channels are independent in both modules; no 256^3 cross-product is needed.
   for(bi=-64;bi<=64;bi++)for(qi=-16;qi<=16;qi++)for(vi=0;vi<256;vi++)begin
     bri=bi;con=qi;rgb={8'(vi),8'(255-vi),8'((vi+73)%256)};
     de=vi[0];hs=vi[1];vs=vi[2];vld=1;step();
   end
   for(bi=-64;bi<=64;bi++)for(qi=-16;qi<=16;qi++)begin
     bri=bi;con=qi;rgb=24'hffffff;vld=0;step();invalid++;
   end
   // Assert asynchronously BETWEEN edges while output and sync are nonzero.
   vld=1;bri=0;con=0;rgb=24'h123456;de=1;hs=1;vs=1;step();
   #2;rst=1;#1;compare();if({bd,bh,bv,b}!==0)$fatal(1,"async reset");
   @(negedge clk);rst=0;rgb=24'h654321;step();
   $display("PASS tb_rgb_shiftadd_equiv: legal_vectors=1089792 channel_comparisons=3269376 invalid_pairs=%0d one_cycle_latency=1 async_reset=1 bit_exact=1",invalid);$finish;
 end
 initial begin #20000000;$fatal(1,"equivalence watchdog");end
endmodule
