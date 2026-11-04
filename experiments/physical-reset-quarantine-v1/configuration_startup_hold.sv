// AN784 tCD2UM upper bound 830us; retained board BOM X4 ECS-3518-500-B-xx
// is 50MHz +/-50ppm: ceil(830us * 50,002,500Hz) = 41503 cycles.
// Configuration-only FPGA power-up initialization. No NPOR/PERST/software reset.
// Premises: exact internal-initialization-clock mode, configured register
// power-up implementation, and actual clock upper bound must be qualified.
// This timing output is NOT startup_epoch_valid: external traffic containment
// and coordinated cold-initialization premises remain separate certificates.
module configuration_startup_hold #(
 parameter int unsigned HOLD_CYCLES=41503
)(input logic clk, output logic hold_complete=1'b0);
 localparam int W=HOLD_CYCLES>1?$clog2(HOLD_CYCLES):1;
 logic [W-1:0] elapsed='0;
 // Plain clocked process permits explicit FPGA power-up initialization.
 always @(posedge clk)begin
  if(!hold_complete)begin
   if(elapsed==HOLD_CYCLES-1)hold_complete<=1'b1;
   else elapsed<=elapsed+1'b1;
  end
 end
 // synthesis translate_off
 initial if(HOLD_CYCLES<41503)$fatal(1,"CONFIGURATION_STARTUP_HOLD_BELOW_BOM_BOUND");
 // synthesis translate_on
endmodule
