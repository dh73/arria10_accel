# Preserve default constraint import order and entity scopes. A retained fitted
# database can name its original generated SDC path after the database is copied.
namespace eval ::c126 {}
proc ::c126::below {path base} {
    set p [file split [file normalize $path]]
    set b [file split [file normalize $base]]
    return [expr {[lrange $p 0 [expr {[llength $b]-1}]] eq $b}]
}
proc ::c126::bytes {path} {
    set fd [open $path rb]
    try { return [read $fd] } finally { close $fd }
}
proc ::c126::check_default_sdc {filename root baseline} {
    set path [file normalize $filename]
    if {[below $path $root]} { return $path }
    # Only compiler-generated constraints retained in the exact original QDB.
    if {![below $path [file join $baseline qdb]] || [file extension $path] ne ".sdc"} {
        error "SDC outside copied project and recorded generated baseline: $filename"
    }
    set baseparts [file split [file normalize $baseline]]
    set rel [lrange [file split $path] [llength $baseparts] end]
    set copy [file join $root {*}$rel]
    if {![below $copy $root] || ![file isfile $path] || ![file isfile $copy]} {
        error "Retained SDC lacks its isolated counterpart: $filename"
    }
    if {[bytes $path] ne [bytes $copy]} {
        error "Retained/copy SDC content differs: $filename"
    }
    # Read-only original is intentional: do not replace default read_sdc with
    # a flat file loop, which would change imported HDL/entity-bound semantics.
    return $copy
}
