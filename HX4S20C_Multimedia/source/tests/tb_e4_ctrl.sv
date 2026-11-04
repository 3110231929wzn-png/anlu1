`timescale 1ns/1ps
module tb_e4_ctrl;
 reg clk=0,rst=1,vs=0,sw=0,key=1;always #5 clk=~clk;
 wire signed [7:0] bri;wire signed [5:0] con;wire sel;
 param_ctrl #(.CLK_FREQ(1000)) dut(clk,rst,vs,sw,key,bri,con,sel);
 integer checks=0,i,oldb,oldc,slowsteps,faststeps,changes=0;
 reg signed [7:0] pb;reg signed [5:0] pc;reg ps,pvs;
 always @(posedge clk)begin
   pb=bri;pc=con;ps=sel;pvs=vs;#1;
   if(!rst&&!pvs&&({pb,pc,ps}!=={bri,con,sel}))$fatal(1,"parameter changed outside frame edge");
 end
 task ticks(input integer n);repeat(n)@(negedge clk);endtask
 task frame;begin vs=0;ticks(2);vs=1;ticks(2);vs=0;ticks(2);end endtask
 task check(input integer b,input integer c,input integer s);
   begin frame();if(bri!==8'(b)||con!==6'(c)||sel!==1'(s))
     $fatal(1,"ctrl expected b=%0d c=%0d sel=%0d got %0d %0d %0d",b,c,s,bri,con,sel);checks++;end
 endtask
 task tap;begin key=0;ticks(40);key=1;ticks(40);end endtask
 initial begin
   ticks(4);rst=0;ticks(4);check(0,0,0);
   // Raw pulses shorter than debounce cannot create steps.
   repeat(8)begin key=0;ticks(2);key=1;ticks(2);end
   ticks(30);check(0,0,0);
   tap();if(bri!==0)$fatal(1,"frame latch missing");check(1,0,0);
   for(i=2;i<=64;i++)begin tap();check(i,0,0);end
   tap();check(-64,0,0);tap();check(-63,0,0);
   sw=1;ticks(25);check(-63,0,1);
   for(i=1;i<=16;i++)begin tap();check(-63,i,1);end
   tap();check(-63,-16,1);tap();check(-63,-15,1);
   // Long hold target is latched; changing switch cannot change brightness.
   key=0;ticks(380);sw=0;ticks(40);frame();
   if(bri!==-63||con===-15||sel!==1)$fatal(1,"long hold / target latch");
   // Count repeated steps over equally sized slow/fast windows.
   frame();oldc=con;ticks(300);frame();slowsteps=($signed(con)-oldc+33)%33;
   ticks(850);frame();oldc=con;ticks(300);frame();faststeps=($signed(con)-oldc+33)%33;
   if(slowsteps<9||slowsteps>11||faststeps<19||faststeps>21)
     $fatal(1,"acceleration slow=%0d fast=%0d",slowsteps,faststeps);
   key=1;ticks(40);frame();oldb=bri;oldc=con;ticks(200);check(oldb,oldc,0);
   tap();check(oldb+1,oldc,0);
   rst=1;ticks(2);if(bri!==0||con!==0||sel!==0)$fatal(1,"reset");
   $display("PASS tb_e4_ctrl: checks=%0d debounce short_hold repeat acceleration release target_lock endpoints frame_latch reset",checks);$finish;
 end
 initial begin #2000000;$fatal(1,"ctrl watchdog");end
endmodule
