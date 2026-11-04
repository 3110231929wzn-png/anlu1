# Generate from the routed database produced by the documented build flow.
# The historical routed.db is intentionally not published.
if {![info exists ::env(STAGE1_ROUTED_DB)] || ![file exists $::env(STAGE1_ROUTED_DB)]} {
    puts stderr "Set STAGE1_ROUTED_DB to your newly generated routed.db"
    exit 1
}
if {![info exists ::env(STAGE1_BIT_OUTPUT)]} {
    puts stderr "Set STAGE1_BIT_OUTPUT to a new output .bit file"
    exit 1
}
if {[file exists $::env(STAGE1_BIT_OUTPUT)]} {
    puts stderr "Refusing to overwrite an existing BIT file"
    exit 1
}
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    import_db $::env(STAGE1_ROUTED_DB)
    bitgen -bit $::env(STAGE1_BIT_OUTPUT)
} message]} {puts stderr "LOWWATER_BITGEN_FAILED: $message"; exit 1}
puts "LOWWATER_BITGEN_COMPLETE"
exit 0
