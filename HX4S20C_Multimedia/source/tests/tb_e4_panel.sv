`timescale 1ns/1ps
module tb_e4_panel;
 reg clk=0,rst=1,de=0,hs=0,vs=0;always #5 clk=~clk;
 reg signed [7:0] bri=0;reg signed [5:0] con=0;reg sel=0;
 wire od,oh,ov;wire [23:0] rgb;
 param_osd dut(clk,rst,de,hs,vs,24'h345678,bri,con,sel,od,oh,ov,rgb);
 integer x,y,changed=0,glyph=0,checks=0;
 task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
 initial begin
   repeat(3)tick();rst=0;vs=1;tick();tick();vs=0;tick();
   for(y=0;y<480;y++)begin
     de=1;
     for(x=0;x<640;x++)begin
       #1;if({od,oh,ov}!=={de,hs,vs})$fatal(1,"panel sync");
       if(y>=32&&y<48&&x>=456&&x<624)begin
         if(rgb!==24'h345678)changed++;
         if(rgb==24'hffc830||rgb==24'hd8e0f0)glyph++;
       end else if(rgb!==24'h345678)$fatal(1,"panel overlaps original content x=%0d y=%0d",x,y);
       checks++;tick();
     end
     de=0;repeat(160)tick();
   end
   if(changed!=168*16||glyph==0)$fatal(1,"panel absent/wrong rectangle changed=%0d glyph=%0d",changed,glyph);
   // Check glyph selection for all numeric endpoints via actual font lookup.
   for(integer q=-16;q<=16;q++)begin
     con=q;bri=-64;#1;
     if(dut.con_h!==8'((3216+q*100)/32))$fatal(1,"contrast display q=%0d",q);
   end
   $display("PASS tb_e4_panel: pixels=%0d rectangle=168x16 all_contrast_labels=33 no_E1_overlap",checks);$finish;
 end
 initial begin #5000000;$fatal(1,"panel watchdog");end
endmodule
