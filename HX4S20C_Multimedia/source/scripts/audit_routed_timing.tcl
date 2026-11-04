# Analysis only. A fresh TD process rebuilds the timer from persisted SDC.
# SWUG105 4.9.7 documents update_timing after import_db. No P&R or bitgen here.
set script_dir [file dirname [info script]]
set out_dir $::env(STAGE1_BUILD_DIR)
set db $::env(STAGE1_ROUTED_DB)
file mkdir $out_dir
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    import_db $db
    source [file join $script_dir audit_audio_reset_mapping.tcl]
    audio_reset_boundary::audit
    export_sdc -file [file join $out_dir effective_user.sdc]
    update_timing -mode final
    report_timing_status -file [file join $out_dir final.ts]
    report_timing_summary -file [file join $out_dir final_timing.rpt] -ep_num 1000
    report_timing_ignored -file [file join $out_dir audio_reset_ignored.rpt] -ep_num 100
    report_timing_exception -file [file join $out_dir exceptions.rpt]
    check_timing -verbose -file [file join $out_dir check_timing.rpt]
    write_verilog [file join $out_dir reset_mapping_implemented.v] -implement
    # Validate the effective exception, not just the physical object query.
    set fh [open [file join $out_dir audio_reset_ignored.rpt] r]
    set ignored [read $fh]
    close $fh
    set lo [string first {From flow sdc} $ignored]
    set hi [string first {From ip sdc} $ignored]
    if {$lo < 0 || $hi < $lo} {error "Reset boundary missing in actual ignored report"}
    set flow [string range $ignored $lo [expr {$hi - 1}]]
    set actual {}
    foreach {whole endpoint} [regexp -all -inline -line {^End Point[ ]*:[ ]*([^\n]+)\(triggered} $flow] {
        lappend actual [string trim $endpoint]
    }
    # Connectivity audit proves two logical FF stages and rejects any unrelated
    # FF sharing their SR. Both stages may legally pack into one physical slice
    # (one SR endpoint) or separate slices (two). Count the proven physical SRs,
    # without changing the SDC or excluding any additional timing path.
    set physical_count [llength $audio_reset_boundary::applied_targets]
    if {[lsort -unique $actual] ne $audio_reset_boundary::applied_targets ||
        [llength $actual] != $physical_count ||
        [regexp -all -line {^Check Type[ ]*:[ ]*recovery[ ]*$} $flow] != $physical_count} {
        error "Effective reset exception must match exactly the proven physical recovery entries"
    }
    if {[regexp -line {^Check Type[ ]*:[ ]*(hold|removal|setup)[ ]*$} $flow]} {
        error "Reset exception unexpectedly excludes data or min checks"
    }
    puts "AUDIO_RESET_STA_VERIFIED: two logical stages, $physical_count proven physical recovery entries only; no min/data exclusions"
} message]} {
    puts stderr "ROUTED_STA_FAILED: $message"
    puts stderr $::errorInfo
    exit 1
}
puts "ROUTED_STA_COMPLETE: $out_dir"
exit 0
