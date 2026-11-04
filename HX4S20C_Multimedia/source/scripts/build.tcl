# Offline synthesis/place/route only. Never programs a board or calls bitgen.
set script_dir [file dirname [info script]]
set project_root [file dirname $script_dir]
set project_dir [file join $project_root src td_project]
if {[info exists ::env(STAGE1_BUILD_DIR)]} {
    set out_dir $::env(STAGE1_BUILD_DIR)
} else {
    set out_dir [file join $project_root build final]
}
puts "STAGE1_PATHS: root=$project_root output=$out_dir project=$project_dir"
file mkdir $out_dir
cd $project_dir
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project lab_ex5_i2s_v1.0.al -single_run
    elaborate -top top
    read_adc ../user_source/constraints_source/pin.adc
    read_sdc ../user_source/constraints_source/timing.sdc
    read_sdc -ip wfifo_32_32_512 ../user_source/hdl_source/IP/afifo_16_32_256.tcl
    read_sdc -ip rfifo_32_32_512 ../user_source/hdl_source/IP/afifo_32_16_256.tcl
    export_db [file join $out_dir elaborate.db]
    if {[info exists ::env(STAGE1_ELABORATE_ONLY)] && $::env(STAGE1_ELABORATE_ONLY) eq "1"} {
        puts "STAGE1_ELABORATION_COMPLETE: $out_dir"
        exit 0
    }
    optimize_rtl
    optimize_gate -packarea [file join $out_dir gate.area]
    legalize_phy_inst
    export_db [file join $out_dir gate.db]
    place
    route
    # Packed register cells may inherit LUT names. Validate physical FF identity
    # after packing, before applying the original synchronizer-boundary scope.
    source [file join $script_dir audit_audio_reset_mapping.tcl]
    read_sdc ../user_source/constraints_source/audio_reset_physical.sdc
    audio_reset_boundary::audit
    # read_sdc stores the new boundary, but this session's route timer may
    # retain its old exception set. run_build.py performs final STA in a fresh
    # TD session importing this routed DB (SWUG105 section 4.9.7).
    report_area -io_info -file [file join $out_dir final.area]
    export_db [file join $out_dir routed.db]
} message]} {
    puts stderr "STAGE1_BUILD_FAILED: $message"
    puts stderr $::errorInfo
    exit 1
}
puts "STAGE1_BUILD_COMPLETE: $out_dir"
exit 0
