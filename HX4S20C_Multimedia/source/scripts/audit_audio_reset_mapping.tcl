# Restore the original two-flop reset-boundary exception by connectivity.
# Packed slices may inherit an unrelated LUT name, so register-name globbing
# cannot identify both FFs reliably. No data, downstream reset, or hold/removal
# path is excluded. Fail closed if the mapped topology differs from this proof.
namespace eval audio_reset_boundary {
    proc one {objects label} {
        if {[llength $objects] != 1} {error "AUDIO_RESET_SCOPE: expected one $label, got $objects"}
        return [lindex $objects 0]
    }
    proc qpins {object} {
        set result {}
        foreach pin [get_pins -of $object] {
            if {[regexp {\.q\[[01]\]$} [get_property NAME $pin]] &&
                [get_property DIRECTION $pin] == 1} {lappend result $pin}
        }
        return $result
    }
    proc resolve {} {
        variable verified_drivers
        variable verified_data
        set qnets [list \
            [one [get_nets {u_hdmi_basic_audio/u_audio_mclk_reset/release_pipe[0]}] stage0_net] \
            [one [get_nets {u_hdmi_basic_audio/u_tone/I_rst}] stage1_net]]
        set clock [one [get_nets {u_hdmi_basic_audio/u_tone/I_mclk}] local_clock]
        set async [one [get_nets {u_hdmi_basic_audio/u_audio_mclk_reset/I_async_rst}] async_input]
        set targets {}
        set drivers {}
        set data_pins {}
        set stage 0
        foreach net $qnets {
            # TD DIRECTION=1 means output; confirmed on the mapped EG4 pins.
            set q [one [qpins $net] stage${stage}_driver]
            set name [get_property NAME $q]
            if {![regexp {\.q\[([01])\]$} $name unused index]} {
                error "AUDIO_RESET_SCOPE: $name is not a physical FF output"
            }
            set cell [one [get_cells -of $q] stage${stage}_cell]
            set sr [one [get_pins ${cell}.sr] stage${stage}_sr]
            set clk [one [get_nets -of [get_pins ${cell}.clk]] stage${stage}_clock]
            set rst [one [get_nets -of $sr] stage${stage}_reset]
            if {$clk ne $clock || $rst ne $async} {
                error "AUDIO_RESET_SCOPE: unexpected clock/reset on $cell"
            }
            set d [one [get_pins [format {%s.mi[%s]} $cell $index]] stage${stage}_d]
            if {$stage == 0} {
                if {[get_property CONST_VALUE $d] ne "0"} {
                    error "AUDIO_RESET_SCOPE: first stage D is not constant zero"
                }
            } elseif {[one [get_nets -of $d] stage1_data] ne [lindex $qnets 0]} {
                error "AUDIO_RESET_SCOPE: second stage is not driven by first stage"
            }
            # A slice SR is shared. Do not mask another unrelated FF if packing
            # changes: every connected Q in these cells must be one of our two.
            foreach other [qpins $cell] {
                if {[regexp {\.q\[[01]\]$} [get_property NAME $other]] &&
                    [get_property IS_CONNECTED $other]} {
                    set other_net [one [get_nets -of $other] shared_ff_net]
                    if {[lsearch -exact $qnets $other_net] < 0} {
                        error "AUDIO_RESET_SCOPE: unrelated FF shares $cell SR"
                    }
                }
            }
            puts "AUDIO_RESET_MAPPING: stage=$stage q=$q d=$d clk=$clk async=$rst target=$sr"
            lappend data_pins $d
            lappend drivers $q
            lappend targets $sr
            incr stage
        }
        if {[llength [lsort -unique $drivers]] != 2} {
            error "AUDIO_RESET_SCOPE: two independent synchronizer stages required"
        }
        # Two FFs can occupy separate slices or share one SR; never more than 2.
        set targets [lsort -unique $targets]
        if {[llength $targets] < 1 || [llength $targets] > 2} {
            error "AUDIO_RESET_SCOPE: invalid physical async pin count"
        }
        set verified_drivers $drivers
        set verified_data $data_pins
        return $targets
    }
    proc audit {} {
        variable applied_targets
        set current [resolve]
        if {$current ne $applied_targets} {
            error "AUDIO_RESET_SCOPE: physical target identity changed after routing"
        }
        puts "AUDIO_RESET_SCOPE_VERIFIED: logical_stages=2 physical_pins=[llength $current] targets=$current"
    }
    set applied_targets [resolve]
    set selected [lsort -unique [get_pins -of [get_cells -of [get_nets {u_hdmi_basic_audio/u_audio_mclk_reset/release_pipe[0]}]] {*.sr}]]
    if {$selected ne $applied_targets} {
        error "AUDIO_RESET_SCOPE: SDC collection differs from proven synchronizer FFs"
    }
}
