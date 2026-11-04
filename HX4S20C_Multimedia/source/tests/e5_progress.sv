`timescale 1ns/1ps
// Test-only monitor. A time watchdog also fires if the observed clock stops.
module e5_progress #(
    parameter LABEL="e5", parameter integer MAX_CYCLES=2500000,
    parameter integer PERIOD=25000
)(input wire clk, input integer stage, samples, fft_starts, fft_dones, frame,
  input wire [31:0] state_bits);
    integer cycles=0;
    task dump(input string reason);
      begin
        $display("PROGRESS target=%s reason=%s time=%0t stage=%0d samples=%0d fft_start=%0d fft_done=%0d frame=%0d cycles=%0d state=%h",
          LABEL,reason,$time,stage,samples,fft_starts,fft_dones,frame,cycles,state_bits);
        $fflush();
      end
    endtask
    initial dump("start");
    always @(stage) dump("stage_change");
    always @(posedge clk) begin
      cycles=cycles+1;
      if(cycles%PERIOD==0) dump("heartbeat");
      if(cycles>=MAX_CYCLES) begin
        dump("cycle_timeout");$fatal(1,"test cycle limit");
      end
    end
    initial begin
      #(MAX_CYCLES*40+100);
      dump("time_timeout");$fatal(1,"test simulated-time limit");
    end
endmodule
