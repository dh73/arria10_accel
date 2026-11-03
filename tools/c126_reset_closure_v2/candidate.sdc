# Additive C126 candidate. Read AFTER all original generated SDC.
# Used on a copied retained fitted DB by native.tcl; never edits vendor files.
# No hard-IP reset exception is justified or installed here.
namespace eval ::c126 {}

proc ::c126::one {collection expected type} {
    if {[get_collection_size $collection] != 1} {
        error "C126 expected exactly one $type: $expected"
    }
    foreach_in_collection object $collection {
        if {[get_node_info -name $object] ne $expected ||
            [get_node_info -type $object] ne $type} {
            error "C126 unexpected object for $expected"
        }
        set result $object
    }
    return $result
}

proc ::c126::apply_candidate {} {
    variable packet_verified
    variable status_observation_only
    variable soft
    variable status_ports
    if {![info exists packet_verified] || !$packet_verified} {
        error "Use run.py: source packet and staged sources must be verified first"
    }
    if {![info exists status_observation_only] ||
        $status_observation_only ni {0 1}} {
        error "C126 status_observation_only must be explicitly 0 or 1"
    }
    set external {global_reset_reset_n[0]}
    set source [get_ports [list $external]]
    set source_id [one $source $external port]
    if {![get_port_info -is_input_port $source_id]} {
        error "C126 external reset is not an input"
    }
    # Do not suppress automatic duplicates to make this cardinality pass.
    set first [get_registers [list $soft]]
    set first_id [one $first $soft reg]
    # These are exactly the aliases used by the supplied generated vendor SDC.
    set data [get_pins [list "${soft}|d" "${soft}|*data"]]
    if {[get_collection_size $data] != 1} {
        error "C126 needs one actual first-stage data pin; inspect reset-atom-arcs.tcllist"
    }
    foreach_in_collection pin $data { set data_id $pin }
    set data_name [get_pin_info -name $data_id]
    if {![string match "${soft}|*" $data_name] ||
        ![get_pin_info -is_in_pin $data_id] ||
        [get_pin_info -is_clock_pin $data_id]} {
        error "C126 candidate pin is not the first-stage non-clock input"
    }
    set data_arc 0
    foreach edge [get_node_info -synch_edges $first_id] {
        if {[get_edge_info -src $edge] eq $data_id &&
            [get_edge_info -dst $edge] eq $first_id &&
            [get_edge_info -type $edge] eq "synchronous" &&
            ![get_edge_info -is_disabled $edge]} { set data_arc 1 }
    }
    if {!$data_arc} { error "C126 pin lacks a live synchronous data arc to din_s1" }
    foreach edge [get_node_info -asynch_edges $first_id] {
        if {[get_edge_info -src $edge] eq $data_id} {
            error "C126 refuses a pin that also has an asynchronous check arc"
        }
    }
    set reaches 0
    foreach_in_collection node [get_fanins -through $data $first] {
        if {[get_node_info -name $node] eq $external} { set reaches 1 }
    }
    if {!$reaches} { error "C126 external reset does not reach this data pin" }
    # Pre-resolve all selected status ports before installing any exception.
    set led_collections {}
    if {$status_observation_only} {
        if {[llength $status_ports] != 5 ||
            [llength [lsort -unique $status_ports]] != 5} {
            error "C126 requires exactly five named status outputs"
        }
        foreach name $status_ports {
            set port [get_ports [list $name]]
            set id [one $port $name port]
            if {![get_port_info -is_output_port $id]} {
                error "C126 status endpoint is not an output: $name"
            }
            lappend led_collections $port
        }
    }
    # reset_n=1 on this instance: this is asynchronous INPUT DATA sampling.
    # The other ISSP producer and every later register-to-register arc remain timed.
    set_false_path -from $source -through $data -to $first
    foreach port $led_collections { set_false_path -to $port }
    post_message -type info "C126 partial candidate: one external data-stage exception; status-observation-only=$status_observation_only; 21 hard-IP reset endpoints remain unresolved"
}
::c126::apply_candidate
