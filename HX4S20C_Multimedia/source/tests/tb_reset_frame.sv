`timescale 1ns/1ps
module tb_reset_frame;
    reg clk=0,raw_rst=1,source_valid=0,frame_req=0;
    wire rst,enabled;
    integer trial;
    always #5 clk=~clk;
    reset_release_sync reset_dut(.I_clk(clk),.I_async_rst(raw_rst),.O_rst(rst));
    video_frame_enable gate_dut(.clk(clk),.rst(rst),.async_display_valid(source_valid),
        .frame_req(frame_req),.display_enable(enabled));
    initial begin
        for(trial=0;trial<3;trial=trial+1) begin
            raw_rst=1;source_valid=0;frame_req=0;#2;
            if(rst!==1) $fatal(1,"reset assertion did not propagate asynchronously");
            @(negedge clk);#2;raw_rst=0;
            @(posedge clk);#1;if(rst!==1) $fatal(1,"reset released too early");
            @(posedge clk);#1;if(rst!==0) $fatal(1,"reset did not release after two local edges");
            repeat(3) @(negedge clk);source_valid=1;
            repeat(5) @(negedge clk);
            if(enabled!==0) $fatal(1,"first image enabled in the middle of a frame");
            frame_req=1;repeat(3) @(negedge clk);frame_req=0;
            if(enabled!==1) $fatal(1,"complete first frame was not enabled");
            #2;
        end
        $display("PASS tb_reset_frame: async assertion, local release and frame-boundary black gate");$finish;
    end
    initial begin #20000;$fatal(1,"reset/frame watchdog");end
endmodule
