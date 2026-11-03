# quartus_sta -t native.tcl /absolute/config.tcl
# Only opens the copied completed fitted database. No compile/fit/program flow.
load_package report
namespace eval ::c126 {}
if {[llength $::quartus(args)] != 1} { error "Expected one generated config.tcl" }
source [lindex $::quartus(args) 0]
source [file join $::c126::package diag.tcl]

proc ::c126::j {value} {
    return "\"[string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]\""
}
proc ::c126::ja {values} {
    set result {}
    foreach value $values { lappend result [j $value] }
    return "\[[join $result ,]\]"
}
proc ::c126::write_file {path text} {
    set fd [open $path {WRONLY CREAT EXCL}]
    fconfigure $fd -encoding utf-8 -translation lf
    puts $fd $text
    close $fd
}
proc ::c126::panels {tag path} {
    set fd [open $path {WRONLY CREAT EXCL}]
    fconfigure $fd -encoding utf-8 -translation lf
    set tables 0
    foreach panel [get_report_panel_names] {
        set at [string first $tag $panel]
        if {$at < 0} { continue }
        set id [get_report_panel_id $panel]
        if {[catch {get_number_of_rows -id $id} n]} {
            # A folder is not a table. Never hide other report API failures.
            if {[string first "Can't access report panel" $n] < 0} { error $n }
            continue
        }
        incr tables
        set suffix [string range $panel [expr {$at + [string length $tag]}] end]
        for {set row 0} {$row < $n} {incr row} {
            set cells [get_report_panel_row -id $id -row $row]
            puts $fd "{\"panel\":[j $suffix],\"row\":$row,\"cells\":[ja $cells]}"
        }
    }
    close $fd
    if {!$tables} { error "No native report tables generated for $tag" }
}
proc ::c126::table_registry {} {
    set result [dict create]
    foreach panel [get_report_panel_names] {
        set id [get_report_panel_id $panel]
        if {[catch {get_number_of_rows -id $id} count]} {
            if {[string first "Can't access report panel" $count] < 0} { error $count }
            continue
        }
        set rows {}
        for {set r 0} {$r < $count} {incr r} {
            lappend rows [get_report_panel_row -id $id -row $r]
        }
        dict set result $panel $rows
    }
    return $result
}
proc ::c126::exact_register {name} {
    set collection [get_registers [list $name]]
    if {[get_collection_size $collection] != 1} {
        error "C126 soft synchronizer stage cardinality changed: $name"
    }
    foreach_in_collection reg $collection {
        if {[get_node_info -name $reg] ne $name} {
            error "C126 soft synchronizer stage identity changed: $name"
        }
    }
    return $collection
}
proc ::c126::clock_name {path which} {
    set id [get_path_info -${which}_clock $path]
    if {$id eq ""} { return "" }
    return [get_clock_info -name $id]
}
proc ::c126::paths {file kind from to all_pairs} {
    set fd [open $file {WRONLY CREAT EXCL}]
    fconfigure $fd -encoding utf-8 -translation lf
    set opts [list -$kind -from $from -to $to -npaths 0 -pairs_only]
    # Setup/hold: every reachable endpoint's worst internal path.
    # Recovery/removal and the soft chain: every unique start/end pair.
    if {!$all_pairs} { lappend opts -nworst 1 }
    set count 0
    foreach_in_collection p [get_timing_paths {*}$opts] {
        set values [list $kind [get_node_info -name [get_path_info -from $p]] \
            [get_node_info -name [get_path_info -to $p]] \
            [clock_name $p from] [clock_name $p to] \
            [get_path_info -slack $p] [get_path_info -clock_relationship $p]]
        puts $fd [ja $values]
        incr count
    }
    close $fd
    return $count
}
proc ::c126::snapshot {phase index hold_only} {
    variable out
    variable soft
    set dir [file join $out $phase corner_$index]
    file mkdir $dir
    set active {}
    foreach_in_collection c [get_active_clocks] { lappend active [get_clock_info -name $c] }
    set clocks {}
    foreach_in_collection c [get_clocks *] {
        lappend clocks [list [get_clock_info -name $c] [get_clock_info -period $c]]
    }
    write_file [file join $dir clocks.json] \
        "{\"active\":[ja [lsort $active]],\"clocks\":[ja [lsort $clocks]]}"
    set tag C126_${phase}_${index}_UCP
    report_ucp -panel_name $tag -file [file join $dir unconstrained.rpt]
    panels $tag [file join $dir ucp.jsonl]
    set kinds {hold removal}
    if {!$hold_only} { set kinds {setup hold recovery removal} }
    set regs [get_registers *]
    foreach kind $kinds {
        paths [file join $dir internal_$kind.jsonl] $kind $regs $regs \
            [expr {$kind in {recovery removal}}]
    }
    set chain [string range $soft 0 end-6]
    set prev [exact_register $soft]
    foreach suffix {{dreg[0]} {dreg[1]}} {
        set name ${chain}${suffix}
        set next [exact_register $name]
        set types {hold}
        if {!$hold_only} { set types {setup hold} }
        foreach kind $types {
            if {![paths [file join $dir chain_${suffix}_$kind.jsonl] \
                    $kind $prev $next 1]} {
                error "C126 later synchronizer stage is not timed: $name ($kind)"
            }
        }
        set prev $next
    }
    set tag C126_${phase}_${index}_DDR
    set previous_tables [table_registry]
    report_ddr -panel_name $tag -file [file join $dir ddr.rpt]
    panels $tag [file join $dir ddr.jsonl]
    set current_tables [table_registry]
    set unexpected {}
    foreach name [lsort -unique [concat [dict keys $previous_tables] [dict keys $current_tables]]] {
        if {[string first $tag $name] >= 0} { continue }
        if {![dict exists $previous_tables $name] || ![dict exists $current_tables $name] ||
            [dict get $previous_tables $name] ne [dict get $current_tables $name]} {
            lappend unexpected $name
        }
    }
    write_file [file join $dir ddr_outside_prefix.json] [ja $unexpected]
    if {[llength $unexpected]} {
        error "Custom DDR reporting changed tables outside -panel_name; inspect ddr_outside_prefix.json before interpreting coverage"
    }
    set restored {}
    foreach_in_collection c [get_active_clocks] { lappend restored [get_clock_info -name $c] }
    if {[lsort $active] ne [lsort $restored]} {
        error "Vendor report_ddr did not restore the active-clock set"
    }
}

proc ::c126::main {} {
    variable root
    variable project
    variable revision
    variable out
    variable mode
    variable package
    cd $root
    project_open -revision $revision $project
    if {[get_global_assignment -name DEVICE] ne "10AX115S3F45E2SGE3" ||
        [get_global_assignment -name TOP_LEVEL_ENTITY] ne "ed_synth_top"} {
        error "C126 fitted target identity mismatch"
    }
    if {[catch {get_global_assignment -name PROJECT_OUTPUT_DIRECTORY} output_dir]} {
        set output_dir .
    }
    if {$output_dir eq ""} { set output_dir . }
    set parts [file split [file normalize $output_dir]]
    set rootparts [file split [file normalize $root]]
    if {[lrange $parts 0 [expr {[llength $rootparts]-1}]] ne $rootparts} {
        error "PROJECT_OUTPUT_DIRECTORY escapes the isolated copied project"
    }
    load_report
    create_timing_netlist
    # Validate top-level SDC path containment. Nested includes are a caller
    # prerequisite of the copied project; this is not a general Tcl sandbox.
    foreach filename [get_default_sdc_file_names] {
        set parts [file split [file normalize $filename]]
        if {[lrange $parts 0 [expr {[llength $rootparts]-1}]] ne $rootparts} {
            error "Top-level SDC path escapes the isolated copied project: $filename"
        }
    }
    read_sdc
    update_timing_netlist
    c126_diagnose [file join $out diagnostic]
    set conditions {}
    set meta {}
    foreach_in_collection op [get_available_operating_conditions] {
        lappend conditions $op
        lappend meta "{\"name\":[j [get_operating_conditions_info -name $op]],\"hold_only\":[get_operating_conditions_info -is_hold_only $op]}"
    }
    if {![llength $conditions]} { error "No operating conditions" }
    write_file [file join $out corners.json] "\[[join $meta ,]\]"
    foreach phase {before after} {
        if {$phase eq "after"} {
            if {$mode eq "diagnose"} { break }
            source [file join $package candidate.sdc]
            update_timing_netlist
        }
        set i 0
        foreach op $conditions {
            set_operating_conditions $op
            update_timing_netlist
            snapshot $phase $i [get_operating_conditions_info -is_hold_only $op]
            incr i
        }
    }
    delete_timing_netlist
    project_close
    write_file [file join $out native.complete] $mode
}
if {[catch {::c126::main} message options]} {
    puts stderr [dict get $options -errorinfo]
    catch {delete_timing_netlist}
    catch {project_close}
    exit 1
}
