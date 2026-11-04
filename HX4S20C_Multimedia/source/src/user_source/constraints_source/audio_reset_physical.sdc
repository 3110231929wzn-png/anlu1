# Physical-only reset-boundary exception. Read AFTER route/physical packing.
# release_pipe[0] connects only first-stage Q and second-stage D. The build
# proves both FFs, common audio clock/raw async reset, D0=0, D1=Q0, and no
# unrelated FF sharing either SR before reading this command. Cell names can
# come from unrelated LUTs packed into the same slice; connectivity is stable.
# Only the two logical synchronizer stages' asynchronous SET pins are scoped.
# Setup/recovery only: D paths, downstream release and removal/hold stay timed.
set_false_path -setup -to [get_pins -of [get_cells -of [get_nets {u_hdmi_basic_audio/u_audio_mclk_reset/release_pipe[0]}]] {*.sr}]
