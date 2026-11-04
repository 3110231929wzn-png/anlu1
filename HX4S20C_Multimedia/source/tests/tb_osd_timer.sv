`timescale 1ns/1ps
module tb_osd_timer;
 reg clk=0,rst=1,vs=0;always #20 clk=~clk;
 wire [23:0] rgb;wire de,hs,ov;
 osd_overlay #(.CLK_FREQ(8)) dut(.I_clk(clk),.I_rst(rst),.I_de(1'b0),.I_hs(1'b0),.I_vs(vs),.I_rgb(24'd0),
 .O_rgb(rgb),.O_de(de),.O_hs(hs),.O_vs(ov),.I_page(2'd0),.I_total(3'd4),.I_auto(1'b0),.I_mode(2'd0));
 integer k,seconds=0,ticks=0,checks=0,i,m;reg [15:0] view=0,expected_time;
 string label_text;
 reg [7:0] code;
 always @(posedge clk)begin
   if(rst)begin ticks=0;seconds=0;end
   else begin
     if(vs&&!dut.vs_d)view={4'((seconds/600)%6),4'((seconds/60)%10),4'((seconds/10)%6),4'(seconds%10)};
     ticks++;if(ticks==8)begin ticks=0;seconds=(seconds+1)%3600;end
     expected_time={4'((seconds/600)%6),4'((seconds/60)%10),4'((seconds/10)%6),4'(seconds%10)};
     #1;checks++;
     if({dut.min_hi,dut.min_lo,dut.sec_hi,dut.sec_lo}!==expected_time)$fatal(1,"BCD counter k=%0d expected=%h",k,expected_time);
     if({dut.view_min_hi,dut.view_min_lo,dut.view_sec_hi,dut.view_sec_lo}!==view)$fatal(1,"time text changed mid-frame");
   end
 end
 initial begin
   repeat(3)@(negedge clk);rst=0;
   // An accelerated physical-clock parameter tests 59:59 -> 00:00, plus
   // periodic frame publication independently from the raw counter edge.
   for(k=0;k<8*3602;k++)begin vs=(k%31)==0;@(negedge clk);end
   for(m=0;m<4;m++)begin
     case(m)0:label_text="FX:HWIPE";1:label_text="FX:VWIPE";2:label_text="FX:SLIDE";3:label_text="FX:FADE ";endcase
     for(i=0;i<8;i++)begin
       code=dut.osd_info_char(6'(39+i),2'd0,3'd4,1'b0,2'(m),4'd0,4'd0,4'd0,4'd0);
       if(code!==label_text.getc(i))$fatal(1,"FX label mode=%0d char=%0d expected=%h actual=%h",m,i,label_text.getc(i),code);
     end
   end
   rst=1;view=0;#1;if(dut.tick_cnt!==0||dut.view_sec_lo!==0)$fatal(1,"timer reset");
   $display("PASS tb_osd_timer: clock_checks=%0d rollover_59_59=1 frame_stable=1 FX_labels=4 reset=1",checks);$finish;
 end
endmodule
