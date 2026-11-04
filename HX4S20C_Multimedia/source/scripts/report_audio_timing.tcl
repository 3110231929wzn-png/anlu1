# Read an existing routed checkpoint; no synthesis, P&R or bit generation.
set out $::env(AUDIO_BUILD_DIR)
cd $out
import_device eagle_s20.db -package EG4S20BG256
import_db [file join $out routed.db]
update_timing -mode final
report_timing_ignored -file [file join $out audio_ignored.rpt] -ep_num 100
report_clock_intersection -file [file join $out audio_clock_intersection.rpt]
puts "AUDIO_RESET_ASYNC_PIN_TARGETS: [get_pins -verbose {u_hdmi_basic_audio/u_audio_mclk_reset/release_pipe_reg*.sr}]"
puts "AUDIO_RESET_SYNC_DATA_TARGETS: [get_pins -verbose {u_hdmi_basic_audio/u_audio_mclk_reset/release_pipe_reg*.d*}]"
puts AUDIO_TIMING_AUDIT_COMPLETE
exit 0
