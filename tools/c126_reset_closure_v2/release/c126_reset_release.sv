// Conditional external waveform conditioner; NOT hard-IP reset closure.
// Hardware premises (not established by simulation or the Lean model):
//  * ref_clk is independent of EMIF reset, free-running and bounded in period.
//  * external_reset_n and ref_clock_good are qualified, glitch-free controls;
//    their low pulses meet the implementation's asynchronous-clear minimum.
//  * a real external monitor drops ref_clock_good on clock loss. Stopping the
//    clock alone cannot be detected here, especially after reset was released.
//  * the fitted chain meets its metastability/recovery/removal requirements;
//    the global_reset_n consumer contract covers every PHY/HMC/AUX/JTAG domain.
// HOLD_REF_CYCLES is an externally justified duration, not a device default.
// No EMIF clock is gated and no calibration/user-clock feedback is required.
module c126_reset_release #(
    parameter bit ALLOW_RELEASE = 1'b0,
    parameter int unsigned HOLD_REF_CYCLES = 0
) (
    input  logic ref_clk,
    input  logic external_reset_n,
    input  logic ref_clock_good,
    output logic global_reset_n
);
    // synthesis translate_off
    initial begin
        if (HOLD_REF_CYCLES < 1)
            $fatal(1, "C126_RELEASE_HOLD_REF_CYCLES_REQUIRED");
    end
    // synthesis translate_on

    generate
        if (ALLOW_RELEASE && HOLD_REF_CYCLES > 0) begin : g_release
            localparam int COUNT_W = HOLD_REF_CYCLES <= 1 ? 1 :
                                     $clog2(HOLD_REF_CYCLES);
            wire qualified_n = external_reset_n & ref_clock_good;
            // Raw asynchronous control reaches ONLY these three stages.
            // Preserve does not by itself establish placement or MTBF.
            (* preserve *) logic [2:0] release_sync;
            logic [COUNT_W-1:0] held;

            always_ff @(posedge ref_clk or negedge qualified_n) begin
                if (!qualified_n)
                    release_sync <= '0;
                else
                    release_sync <= {release_sync[1:0], 1'b1};
            end

            // Keep real recovery/removal checks from release_sync[2] to
            // this counter and output. Its deassertion is reference-clocked.
            // Assertion propagates through the chain even with no clock.
            always_ff @(posedge ref_clk or negedge release_sync[2]) begin
                if (!release_sync[2]) begin
                    held <= '0;
                    global_reset_n <= 1'b0;
                end else if (!global_reset_n) begin
                    if (held == HOLD_REF_CYCLES - 1)
                        global_reset_n <= 1'b1;
                    else
                        held <= held + 1'b1;
                end
            end
            // With ideal RTL events: release on qualifying edge N+3, where
            // N=HOLD_REF_CYCLES, after N complete periods following stage 2.
        end else begin : g_disabled
            // Invalid parameters and unselected integration both hold reset.
            assign global_reset_n = 1'b0;
        end
    endgenerate
endmodule
