// All time values below are digital stimulus, NOT board timing specifications.
module tb_c126_reset_release;
    timeunit 1ns;
    timeprecision 1ps;
    localparam int N = 5;
    logic ref_clk = 0;
    logic external_reset_n = 0;
    logic ref_clock_good = 0;
    wire reset_n, one_n, disabled_n;
    int qualified_edges = 0;
    int checks = 0;
    int total_edges = 0;

    c126_reset_release #(.ALLOW_RELEASE(1), .HOLD_REF_CYCLES(N)) dut
        (ref_clk, external_reset_n, ref_clock_good, reset_n);
    c126_reset_release #(.ALLOW_RELEASE(1), .HOLD_REF_CYCLES(1)) minimum
        (ref_clk, external_reset_n, ref_clock_good, one_n);
    // Deliberately leave ALLOW_RELEASE at its safe default.
    c126_reset_release #(.HOLD_REF_CYCLES(N)) disabled_dut
        (ref_clk, external_reset_n, ref_clock_good, disabled_n);

    always @(posedge ref_clk or negedge external_reset_n or negedge ref_clock_good) begin
        if (!external_reset_n || !ref_clock_good)
            qualified_edges = 0;
        else
            qualified_edges++;
        // Wait through both asynchronous clear NBA events.
        #1ps;
        if (reset_n !== (external_reset_n && ref_clock_good && qualified_edges >= N+3))
            $fatal(1, "C126 release latency mismatch: edges=%0d out=%b", qualified_edges, reset_n);
        if (one_n !== (external_reset_n && ref_clock_good && qualified_edges >= 4))
            $fatal(1, "C126 N=1 latency mismatch");
        if (disabled_n !== 1'b0)
            $fatal(1, "C126 disabled instance released");
        checks++;
    end

    task automatic tick;
        ref_clk = 0;
        #2ns;
        ref_clk = 1;
        total_edges++;
        #3ns;
        ref_clk = 0;
        #2ns;
    endtask

    task automatic expect_low;
        #2ps;
        if ({reset_n, one_n, disabled_n} !== 3'b000)
            $fatal(1, "C126 failed asynchronous assertion or restarted early");
    endtask

    task automatic restart;
        repeat (N+3) tick();
        if ({reset_n, one_n, disabled_n} !== 3'b110)
            $fatal(1, "C126 did not finish the qualified hold interval");
    endtask

    initial begin
        #1ns;
        tick();  // Establish the required initial asserted reset event.
        ref_clock_good = 1;
        tick();
        #1.25ns;
        external_reset_n = 1;
        restart();
        repeat (3) tick();

        // A between-edge pulse is digitally captured and stretched.
        // It is NOT evidence that a real 300 ps input pulse is qualified.
        #0.2ns;
        external_reset_n = 0;
        expect_low();
        #0.3ns;
        external_reset_n = 1;
        restart();

        // Restart while the chain has only seen two qualifying edges.
        external_reset_n = 0;
        expect_low();
        #0.1ns;
        external_reset_n = 1;
        repeat (2) tick();
        #50ns; // Ref clock is stopped: no synthetic progress is permitted.
        expect_low();
        repeat (N+1) tick();
        if (!reset_n) $fatal(1, "C126 resume lost elapsed qualifying edges");

        // Clock stopping alone is unobservable; this is a deliberate limit.
        #10ns;
        if (!reset_n) $fatal(1, "C126 changed state without an event");
        external_reset_n = 0;
        expect_low(); // Assertion must propagate while the clock is stopped.
        #0.4ns;
        external_reset_n = 1;
        #10ns;
        expect_low();
        restart();

        // A qualified clock-good loss reasserts asynchronously.
        ref_clock_good = 0;
        expect_low();
        #0.4ns;
        ref_clock_good = 1;
        repeat (3) tick();
        ref_clock_good = 0;
        expect_low();
        #0.5ns;
        ref_clock_good = 1;
        restart();

        // Retrigger one edge before N=5 would release.
        external_reset_n = 0;
        expect_low();
        #0.7ns;
        external_reset_n = 1;
        repeat (N+2) tick();
        if (reset_n) $fatal(1, "C126 released before final hold edge");
        external_reset_n = 0;
        expect_low();
        #0.8ns;
        external_reset_n = 1;
        restart();
        $display("C126_RESET_RELEASE_RTL_PASS edges=%0d checks=%0d", total_edges, checks);
        $finish;
    end
endmodule

// Separate top for the required invalid/default-duration negative control.
module tb_c126_reset_release_invalid;
    timeunit 1ns;
    timeprecision 1ps;
    wire reset_n;
    c126_reset_release dut(1'b0, 1'b0, 1'b0, reset_n);
    initial begin
        #1ns;
        $fatal(1, "C126_INVALID_PARAMETER_NOT_REJECTED");
    end
endmodule
