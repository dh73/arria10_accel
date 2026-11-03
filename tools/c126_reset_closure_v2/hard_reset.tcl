# Read-only enforcement of the measured hard-IP boundary, not another reset cut.
# Endpoint identities are bound to the measured C126 fitted reset graph.
# Used after baseline read_sdc. Never creates clocks, changes MCPs, or edits atoms.
namespace eval ::c126::hard {}

proc ::c126::hard::spec {} {
    set arch {ed_synth_inst|emif|emif|arch|arch_inst}
    set tiles ${arch}|io_tiles_wrap_inst|io_tiles_inst
    set clock_prefix {ed_synth_inst|emif|emif_}
    set result [dict create]
    # These are the measured lane clocks; lane 3 does not follow a simple tile rule.
    foreach {tile clocks} {0 {1 1 1 1} 1 {0 0 0 2} 2 {2 2 2 0}} {
        for {set lane 0} {$lane < 4} {incr lane} {
            set cell [format {%s|tile_gen[%d].lane_gen[%d].lane_inst} $tiles $tile $lane]
            dict set result ${cell}~phy_reg1 [list ${cell}|reset_n \
                ${clock_prefix}phy_clk_l_[lindex $clocks $lane] twentynm_io_12_lane]
        }
    }
    foreach {suffix index} {{} 0 ~_Duplicate 2 ~_Duplicate_1 1} {
        set cell [format {%s|tile_gen[1].tile_ctrl_inst%s} $tiles $suffix]
        dict set result ${cell}~hmc_reg0 [list ${cell}|global_reset_n \
            ${clock_prefix}phy_clk_$index twentynm_tile_ctrl]
        dict set result ${cell}~hmc_reg1 [list ${cell}|global_reset_n \
            ${clock_prefix}phy_clk_l_$index twentynm_tile_ctrl]
    }
    set cell ${arch}|io_aux_inst|io_aux
    foreach {suffix clock} {soft_ram_reg core_cal_slave_clk aux_reg core_cal_master_clk jtag_reg {}} {
        if {$clock ne ""} {set clock ${clock_prefix}${clock}}
        dict set result ${cell}~${suffix} [list ${cell}|core_usr_reset_n $clock twentynm_io_aux]
    }
    return $result
}

proc ::c126::hard::one {collection name type} {
    if {[get_collection_size $collection] != 1} {
        error "C126 hard-reset boundary cardinality changed: $name"
    }
    foreach_in_collection id $collection {
        if {[get_node_info -name $id] ne $name || [get_node_info -type $id] ne $type} {
            error "C126 hard-reset boundary identity changed: $name"
        }
        return $id
    }
}

proc ::c126::hard::snapshot {directory hold_only} {
    set expected [spec]
    set all [concat [dict keys $expected] [list $::c126::soft]]
    if {[llength $::c126::reset_endpoints] != 22 ||
        [lsort $::c126::reset_endpoints] ne [lsort $all]} {
        error "C126 requires the exact measured 12 PHY, 6 HMC, 3 AUX and 1 soft endpoint set"
    }
    set source [get_ports [list {global_reset_reset_n[0]}]]
    one $source {global_reset_reset_n[0]} port
    set rows {}
    set kinds {removal}
    if {!$hold_only} {set kinds {recovery removal}}
    foreach endpoint [lsort [dict keys $expected]] {
        lassign [dict get $expected $endpoint] pin_name clock primitive
        set regs [get_registers [list $endpoint]]
        set reg [one $regs $endpoint reg]
        set pins [get_pins [list $pin_name]]
        one $pins $pin_name pin
        set cell [get_node_info -cell $reg]
        if {[get_cell_info -wysiwyg_type $cell] ne $primitive} {
            error "C126 hard-reset primitive changed: $endpoint"
        }
        set clocks [::c126::diag_clocks $reg]
        set wanted {}
        if {$clock ne ""} {set wanted [list $clock]}
        if {$clocks ne $wanted} {error "C126 hard-reset clock changed: $endpoint"}
        set live 0
        foreach edge [get_node_info -asynch_edges $reg] {
            # Opaque keeper/register/pin handles may have different type prefixes.
            if {[get_node_info -name [get_edge_info -src $edge]] eq $pin_name &&
                [get_node_info -name [get_edge_info -dst $edge]] eq $endpoint &&
                [get_edge_info -type $edge] eq "asynchronous" &&
                ![get_edge_info -is_disabled $edge]} {incr live}
        }
        if {!$live} {error "C126 live hard-reset check arc disappeared: $endpoint"}
        foreach kind $kinds {
            set paths {}
            # -pairs_only preserves the returned worst path per start/end pair;
            # equality of this matrix is not proof of every physical route.
            foreach_in_collection p [get_timing_paths -$kind -from $source -to $regs -npaths 0 -pairs_only] {
                lappend paths [::c126::ja [list $kind \
                    [get_node_info -name [get_path_info -from $p]] \
                    [get_node_info -name [get_path_info -to $p]] \
                    [::c126::clock_name $p from] [::c126::clock_name $p to] \
                    [get_path_info -slack $p] [get_path_info -clock_relationship $p]]]
            }
            # [] is retained as absence of an analyzable check, NEVER as success.
            # In particular jtag_reg has no observed clock; do not invent one.
            lappend rows "{\"endpoint\":[::c126::j $endpoint],\"entry_pin\":[::c126::j $pin_name],\"clock\":[::c126::j $clock],\"primitive\":[::c126::j $primitive],\"kind\":[::c126::j $kind],\"contract\":\"unresolved\",\"paths\":\[[join [lsort $paths] ,]\]}"
        }
    }
    ::c126::write_file [file join $directory hard_reset.jsonl] [join $rows \n]
}
