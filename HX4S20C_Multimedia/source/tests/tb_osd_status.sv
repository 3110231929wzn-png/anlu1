`timescale 1ns/1ps
module tb_osd_status;
  reg sc=0,mc=0,vc=0,srst=1,mrst=1,vrst=1,vs=0;
  always #5 sc=~sc;
  always #10 mc=~mc;
  always #20 vc=~vc;
  reg [1:0] page=0,mode=0;reg [2:0] total=0;reg autoplay=0;
  wire [1:0] vp,vm;wire [2:0] vt;wire va;
  osd_status dut(.sd_clk(sc),.sd_rst(srst),.mem_clk(mc),.mem_rst(mrst),
    .video_clk(vc),.video_rst(vrst),.video_vs(vs),
    .display_page(page),.image_total(total),.autoplay(autoplay),.transition_mode(mode),
    .video_page(vp),.video_total(vt),.video_auto(va),.video_mode(vm));
  integer checks=0,k,held_checks=0;
  reg [7:0] held;
  reg [5:0] previous_bundle;
  reg in_flight;
  always @(posedge sc)begin
    previous_bundle=dut.player_mailbox.held_data;
    in_flight=(dut.player_mailbox.req!=dut.player_mailbox.ack_sync[1]);
    #1;
    if(!srst&&in_flight)begin
      held_checks++;
      if(dut.player_mailbox.held_data!==previous_bundle)$fatal(1,"bundle changed before ACK");
    end
  end
  task settle;begin repeat(32)@(negedge vc);end endtask
  task frame;
    begin vs=1;repeat(3)@(negedge vc);vs=0;repeat(3)@(negedge vc);end
  endtask
  task expect_state(input [1:0] ep,em,input [2:0] et,input ea);
    begin checks++;if({vp,vm,vt,va}!=={ep,em,et,ea})$fatal(1,"snapshot expected p=%0d m=%0d n=%0d a=%b actual p=%0d m=%0d n=%0d a=%b",ep,em,et,ea,vp,vm,vt,va);end
  endtask
  initial begin
    settle();srst=0;repeat(2)@(negedge mc);mrst=0;repeat(2)@(negedge vc);vrst=0;
    page=3;total=4;autoplay=1;mode=2;settle();
    expect_state(0,0,0,0);frame();expect_state(3,2,4,1);
    held={vp,vm,vt,va};
    // Burst changes while a previous snapshot is in flight. Last coherent
    // source tuple must eventually arrive; no mid-frame public update.
    for(k=0;k<24;k=k+1)begin
      @(negedge sc);page=k%4;total=(k%4)+1;autoplay=k%2;mode=k%4;
      #1;if({vp,vm,vt,va}!==held)$fatal(1,"mid-frame change");
    end
    page=1;total=2;autoplay=0;mode=3;settle();expect_state(3,2,4,1);
    frame();expect_state(1,3,2,0);
    for(k=0;k<4;k=k+1)begin mode=k;settle();expect_state(1,k==0?3:k-1,2,0);frame();expect_state(1,k,2,0);end
    // Reassert reset while a new tuple is in flight, then stagger releases.
    page=2;total=3;autoplay=1;mode=2;repeat(2)@(negedge sc);
    srst=1;mrst=1;vrst=1;#1;expect_state(0,0,0,0);
    page=0;total=3;autoplay=1;mode=1;
    settle();srst=0;mrst=0;vrst=0;settle();frame();expect_state(0,1,3,1);
    if(held_checks==0)$fatal(1,"no outstanding handshake exercised");
    $display("CDC_HELD_UNTIL_ACK_CHECKS=%0d",held_checks);
    $display("PASS tb_osd_status: checks=%0d frame_atomic=1 burst_coherent=1 modes=4 reset=1",checks);$finish;
  end
  initial begin #100000;$fatal(1,"watchdog");end
endmodule
