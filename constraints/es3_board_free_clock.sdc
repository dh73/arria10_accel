# ES3 E3.1 schematic sheets 8-9: X4 (50 MHz) -> U53 CLKOUT2 -> CLK_50 -> AU33.
# Nominal board-source constraint, not a live frequency measurement.
# No reset, synchronizer, or bundled-data timing paths are exempted here.
set a10_board_free_port [get_ports {board_pins_free_clk}]
if {[get_collection_size $a10_board_free_port] != 1} {
    error "Expected exactly one board_pins_free_clk port"
}
create_clock -name board_free_50 -period 20.000 $a10_board_free_port
unset a10_board_free_port
