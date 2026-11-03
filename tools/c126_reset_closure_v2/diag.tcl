# Quartus Prime Pro 26.1 retained-fitted-netlist diagnostic library.
# Caller must already have create_timing_netlist/read_sdc/update_timing_netlist.
# No assignments, timing cuts, netlist edits, or device actions are performed.
# Input: ::c126::reset_endpoints, the 22 exact keeper names from C126.
# Optional input: ::c126::expected_clock, a dict of keeper -> assessment clock.
# Output is Tcl-list DATA, one record per line. Do not source the output file.
namespace eval ::c126 {}

proc ::c126::diag_collection {node} {
    # IDs from foreach_in_collection are object IDs, not native collections.
    # Commands accepting filters could interpret a bare ID as a name pattern.
    # Natural bus naming is enabled by default in Quartus; exact numeric [n]
    # names are passed as one Tcl-list element without Tcl command expansion.
    set name [get_node_info -name $node]
    switch -- [get_node_info -type $node] {
        reg { set result [get_registers -no_duplicates [list $name]] }
        port { set result [get_ports [list $name]] }
        pin { set result [get_pins -no_duplicates [list $name]] }
        default { error "Cannot construct a clock/fanout collection for $name" }
    }
    if {[get_collection_size $result] != 1} {
        error "Native diagnostic collection does not resolve exactly once: $name"
    }
    foreach_in_collection found $result {
        if {$found ne $node || [get_node_info -name $found] ne $name} {
            error [list NATIVE_OBJECT_IDENTITY_MISMATCH \
                expected_id $node expected_name $name \
                expected_type [get_node_info -type $node] \
                actual_id $found actual_name [get_node_info -name $found] \
                actual_type [get_node_info -type $found]]
        }
    }
    return $result
}

proc ::c126::diag_names {collection} {
    set result {}
    foreach_in_collection object $collection {
        lappend result [get_node_info -name $object]
    }
    return [lsort -unique $result]
}

proc ::c126::diag_clocks {node} {
    set result {}
    foreach_in_collection clock [get_clocks -of_objects [diag_collection $node]] {
        lappend result [get_clock_info -name $clock]
    }
    return [lsort -unique $result]
}

proc ::c126::diag_edge {fd context edge} {
    set src [get_edge_info -src $edge]
    set dst [get_edge_info -dst $edge]
    puts $fd [list EDGE context $context id $edge \
        src [get_node_info -name $src] src_type [get_node_info -type $src] \
        dst [get_node_info -name $dst] dst_type [get_node_info -type $dst] \
        arc_type [get_edge_info -type $edge] \
        delay_type [get_edge_info -delay_type $edge] \
        disabled [get_edge_info -is_disabled $edge] \
        unateness [get_edge_info -unateness $edge]]
}

proc ::c126::diag_node {fd context node} {
    set type [get_node_info -type $node]
    puts $fd [list NODE context $context id $node \
        name [get_node_info -name $node] type $type \
        location [get_node_info -location $node]]
    if {$type eq "reg"} {
        puts $fd [list REGISTER context $context \
            name [get_node_info -name $node] clocks [diag_clocks $node] \
            recognized_sync_stage [get_register_info -is_synchronizer $node]]
    }
    # These four options return ordinary Tcl lists, not Quartus collections.
    foreach option {-clock_edges -synch_edges -asynch_edges -fanout_edges} {
        set edges [get_node_info $option $node]
        puts $fd [list EDGE_LIST context $context \
            name [get_node_info -name $node] query $option count [llength $edges]]
        foreach edge $edges { diag_edge $fd $context $edge }
    }
}

proc ::c126::diag_cell {fd cell} {
    set name [get_cell_info -name $cell]
    # -type would only return "cell"; -wysiwyg_type identifies the atom.
    puts $fd [list CELL name $name id $cell \
        primitive [get_cell_info -wysiwyg_type $cell] \
        location [get_cell_info -location $cell]]
    set pins [get_cell_info -pins $cell]
    puts $fd [list CELL_PINS cell $name count [get_collection_size $pins]]
    foreach_in_collection pin $pins {
        puts $fd [list PIN cell $name id $pin \
            name [get_pin_info -name $pin] suffix [get_pin_info -suffix $pin] \
            input [get_pin_info -is_in_pin $pin] \
            output [get_pin_info -is_out_pin $pin] \
            clock [get_pin_info -is_clock_pin $pin]]
        diag_node $fd [list cell_pin $name] $pin
    }
    # Cell pins and buried nodes are Quartus collections.
    foreach option {-buried_regs -buried_nodes} {
        set nodes [get_cell_info $option $cell]
        puts $fd [list CELL_NODES cell $name query $option \
            count [get_collection_size $nodes]]
        foreach_in_collection node $nodes {
            diag_node $fd [list cell_buried $name $option] $node
        }
    }
}

proc ::c126::diag_reset_graph {fd root} {
    # Traverse the timing graph only to its first sequential/port boundaries.
    # A visited set terminates feedback loops; there is no path/time/count cap.
    set pending [list $root]
    set head 0
    set seen [dict create]
    set boundaries [dict create]
    while {$head < [llength $pending]} {
        set node [lindex $pending $head]
        incr head
        if {[dict exists $seen $node]} { continue }
        dict set seen $node 1
        set type [get_node_info -type $node]
        set name [get_node_info -name $node]
        puts $fd [list RESET_GRAPH_NODE id $node name $name type $type]
        if {$node ne $root && ($type eq "reg" || $type eq "port")} {
            dict set boundaries $name 1
            puts $fd [list RESET_GRAPH_BOUNDARY name $name type $type]
            continue
        }
        set edges [get_node_info -fanout_edges $node]
        puts $fd [list RESET_GRAPH_FANOUT name $name count [llength $edges]]
        foreach edge $edges {
            diag_edge $fd reset_graph $edge
            if {[get_edge_info -is_disabled $edge]} {
                puts $fd [list RESET_GRAPH_STOP edge $edge reason disabled]
                continue
            }
            lappend pending [get_edge_info -dst $edge]
        }
    }
    puts $fd [list RESET_GRAPH_COMPLETE nodes [dict size $seen] \
        boundaries [lsort [dict keys $boundaries]]]
}

proc ::c126::c126_diagnose {outdir} {
    variable reset_endpoints
    variable expected_clock
    if {[llength $reset_endpoints] != 22 || \
        [llength [lsort -unique $reset_endpoints]] != 22} {
        error "C126 diagnostic requires exactly 22 distinct assessment endpoint names"
    }
    set root_name {global_reset_reset_n[0]}
    set wanted [dict create $root_name 1]
    foreach name $reset_endpoints { dict set wanted $name 1 }
    # Exact string equality avoids wildcard interpretation of generated [n] names.
    set resolved [dict create]
    foreach_in_collection node [get_keepers *] {
        set name [get_node_info -name $node]
        if {[dict exists $wanted $name]} { dict lappend resolved $name $node }
    }
    foreach name [dict keys $wanted] {
        if {![dict exists $resolved $name] || \
            [llength [dict get $resolved $name]] != 1} {
            error "C126 diagnostic keeper does not resolve exactly once: $name"
        }
    }
    set root [lindex [dict get $resolved $root_name] 0]
    if {[get_node_info -type $root] ne "port"} {
        error "C126 reset source is not a port: $root_name"
    }
    file mkdir $outdir
    set output [file join $outdir reset-atom-arcs.tcllist]
    if {[file exists $output]} { error "Refusing to overwrite $output" }
    set fd [open $output {WRONLY CREAT EXCL}]
    fconfigure $fd -encoding utf-8 -translation lf
    set rc [catch {
        puts $fd [list FORMAT c126_reset_atom_arcs_v1]
        puts $fd [list LIMITATION \
            {Timing-model edges and recognized synchronizers do not prove hard-IP reset safety.}]
        set cells [dict create]
        set clock_mismatches {}
        foreach name $reset_endpoints {
            set node [lindex [dict get $resolved $name] 0]
            if {[get_node_info -type $node] ne "reg"} {
                error "Assessment endpoint is not a register keeper: $name"
            }
            set cell [get_node_info -cell $node]
            if {$cell eq ""} { error "No host atom/cell for assessment endpoint: $name" }
            dict set cells $cell 1
            set actual_clocks [diag_clocks $node]
            puts $fd [list ENDPOINT name $name cell [get_cell_info -name $cell] \
                clocks $actual_clocks]
            if {[info exists expected_clock] && [dict exists $expected_clock $name]} {
                set expected [dict get $expected_clock $name]
                set expected_list {}
                if {$expected ne ""} { set expected_list [list $expected] }
                set match [expr {$actual_clocks eq $expected_list}]
                puts $fd [list ASSESSMENT_CLOCK name $name expected $expected_list \
                    observed $actual_clocks same $match]
                if {!$match} { lappend clock_mismatches $name }
            }
            diag_node $fd assessment_endpoint $node
            foreach query {get_fanins get_fanouts} {
                set collection [$query [diag_collection $node]]
                puts $fd [list KEEPERS endpoint $name query $query \
                    count [get_collection_size $collection] names [diag_names $collection]]
            }
        }
        foreach cell [dict keys $cells] { diag_cell $fd $cell }
        foreach query {get_fanins get_fanouts} {
            set collection [$query [diag_collection $root]]
            puts $fd [list KEEPERS endpoint $root_name query $query \
                count [get_collection_size $collection] names [diag_names $collection]]
        }
        diag_reset_graph $fd $root
        puts $fd [list COMPLETE endpoints 22 cells [dict size $cells] \
            assessment_clock_mismatches $clock_mismatches \
            hard_ip_release_contract unproven]
        # A clock difference is evidence to review, not evidence of a safe reset.
        # Keep the full diagnosis even if the assessment's clock field differs.
    } message options]
    close $fd
    if {$rc} { return -options $options $message }
    return $output
}
