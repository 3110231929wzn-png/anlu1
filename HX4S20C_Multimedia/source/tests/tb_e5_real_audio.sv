`timescale 1ns/1ps
// Reuse the original pin-level decoder, cadence, CTS/N and reset assertions.
// Its original PASS marker and $finish remain the sole success oracle.
module tb_e5_real_audio;
 tb_hdmi_basic_audio original_test();
 integer stage=0;
 wire [31:0] states={26'd0,original_test.reset_request,original_test.rst,
  original_test.dut.audio_pll_lock,original_test.audio_valid,original_test.bclk,original_test.lrck};
 e5_progress #(.LABEL("real_audio"),.MAX_CYCLES(480000)) monitor(
  .clk(original_test.pixel_clk),.stage(stage),.samples(original_test.total_good),
  .fft_starts(0),.fft_dones(0),.frame(-1),.state_bits(states));
 always @(original_test.reset_request) begin
  stage=stage+1;
 end
endmodule
