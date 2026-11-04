# Continue the accepted gate checkpoint exactly once; no synthesis or bitgen.
set script_dir [file dirname [info script]]
set project_root [file dirname $script_dir]
cd [file join $project_root src td_project]
set out_dir $::env(STAGE1_BUILD_DIR)
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    import_db [file join $out_dir gate.db]
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
    puts stderr "SHIFTADD_PHYSICAL_FAILED: $message"
    puts stderr $::errorInfo
    exit 1
}
puts "SHIFTADD_PHYSICAL_COMPLETE: $out_dir"
exit 0
