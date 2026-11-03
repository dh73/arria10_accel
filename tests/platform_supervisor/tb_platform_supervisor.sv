`timescale 1ns/1ps
// Contract-level source stubs, real unchanged adapter and DDR initializer.
// This does NOT implement generated-kernel CSR idle tracking or PCIe DMA.
module tb_platform_supervisor;
  logic clk = 0;
  always #5 clk = ~clk;
  logic cold_reset_n;
  logic cal_success, cal_fail, memory_ready, backend_init_failed;
  logic backend_ecc_interrupt, amm_ready;
  logic kernel_status_valid, kernel_stop_ack, kernel_idle, kernel_fault;
  logic host_status_valid, host_stop_ack, host_dma_drained;
  logic host_desc_drained, host_writeback_drained, host_fault, external_stop;
  logic cmd_valid, clear_valid;
  logic [2:0] cmd_op;
  logic [15:0] clear_mask;
  logic launch_permit, host_submit_permit, kernel_stop_req, host_stop_req;
  logic adapter_quiesce_req, release_ready, fault_latched;
  logic [2:0] state_status, phase_status;
  logic [15:0] fault_history, fault_pending, first_fault_code;
  logic [7:0] first_adapter_code;
  logic [34:0] first_adapter_address;
  logic first_adapter_address_valid, cmd_ready, cmd_done, cmd_accepted;
  logic [3:0] cmd_reason;
  logic clear_done, reset_request, epoch_advance;
  logic [15:0] clear_blocked;
  logic adapter_fault, adapter_fault_address_valid;
  logic adapter_quiescing, adapter_drained;
  logic [7:0] adapter_fault_code;
  logic [34:0] adapter_fault_address;
  logic k_read, k_write, k_burstcount, k_waitrequest;
  logic [34:0] k_address;
  logic [63:0] k_writedata, k_readdata;
  logic [7:0] k_byteenable;
  logic k_readdatavalid, k_writeack;
  logic [24:0] d_address, amm_address;
  logic d_read, d_write, d_burstcount, d_waitrequest;
  logic [511:0] d_writedata, d_readdata, amm_writedata;
  logic [63:0] d_byteenable, amm_byteenable;
  logic d_readdatavalid, d_readdataerror, amm_read, amm_write;
  logic [6:0] amm_burstcount;
  int scrub_writes, client_writes, client_reads, returned_reads;
  logic [15:0] saved_first;
  logic [603:0] saved_offer;

  platform_supervised_ddr_adapter #(.CMD_DEPTH(2), .READ_DEPTH(2)) dut (.*);
  arria10_ddr_init #(.LAST_ADDRESS(25'd2)) initializer (
    .clk, .reset_n(cold_reset_n), .cal_success, .cal_fail,
    .initialized(memory_ready), .init_failed(backend_init_failed),
    .client_address(d_address), .client_read(d_read), .client_write(d_write),
    .client_writedata(d_writedata), .client_byteenable(d_byteenable),
    .client_burstcount(d_burstcount), .client_waitrequest(d_waitrequest),
    .amm_ready, .amm_address, .amm_read, .amm_write, .amm_writedata,
    .amm_byteenable, .amm_burstcount
  );

  always @(posedge clk or negedge cold_reset_n) begin
    if (!cold_reset_n) begin
      scrub_writes <= 0; client_writes <= 0;
      client_reads <= 0; returned_reads <= 0;
    end else begin
      if (amm_write && amm_ready) begin
        if (!memory_ready && !backend_init_failed) begin
          assert (amm_writedata === 512'b0 && amm_byteenable === '1)
            else $fatal(1, "scrub was not a full zero write");
          scrub_writes <= scrub_writes + 1;
        end else client_writes <= client_writes + 1;
      end
      if (amm_read && amm_ready) client_reads <= client_reads + 1;
      if (k_readdatavalid) returned_reads <= returned_reads + 1;
      assert (!reset_request && !epoch_advance)
        else $fatal(1, "supervisor fabricated reset/epoch advance");
      if (launch_permit)
        assert (state_status == 1 && !fault_latched && !external_stop &&
                !kernel_stop_req && !host_stop_req)
          else $fatal(1, "unsafe launch permission");
      if (release_ready)
        assert (kernel_stop_req && host_stop_req && adapter_quiesce_req &&
                kernel_status_valid && kernel_stop_ack && kernel_idle &&
                host_status_valid && host_stop_ack && host_dma_drained &&
                host_desc_drained && host_writeback_drained &&
                adapter_quiescing && adapter_drained)
          else $fatal(1, "release without independent drain evidence");
    end
  end

  task automatic check(input bit ok, input string message);
    if (!ok) $fatal(1, "%s (phase=%0d state=%0d history=%h)",
                    message, phase_status, state_status, fault_history);
  endtask
  task automatic tick;
    @(posedge clk); #1;
  endtask
  task automatic command(input logic [2:0] op,
                         input bit accepted, input logic [3:0] reason);
    while (cmd_ready !== 1'b1) tick();
    cmd_valid = 1; cmd_op = op; tick();
    cmd_valid = 0;
    if (!cmd_done) begin
      check(!cmd_ready && phase_status == 5 && !launch_permit &&
            kernel_stop_req && host_stop_req,
            "provisional opening did not retain producer stop");
      tick();
    end
    check(cmd_done === 1'b1 && cmd_accepted === accepted &&
          cmd_reason === reason, "wrong command completion");
  endtask
  task automatic common_reset;
    // External epoch boundary: all old traffic has been isolated by the test
    // environment. No old response survives this reset. No software command
    // calls this task, and a core-only reset is never modeled as safe recovery.
    cold_reset_n = 0;
    cal_success = 0; cal_fail = 0; amm_ready = 1;
    backend_ecc_interrupt = 0;
    kernel_status_valid = 1; kernel_stop_ack = 1;
    kernel_idle = 1; kernel_fault = 0;
    host_status_valid = 1; host_stop_ack = 1;
    host_dma_drained = 1; host_desc_drained = 1;
    host_writeback_drained = 1; host_fault = 0; external_stop = 0;
    cmd_valid = 0; cmd_op = 0; clear_valid = 0; clear_mask = 0;
    k_read = 0; k_write = 0; k_address = 0; k_writedata = 0;
    k_byteenable = '1; k_burstcount = 1;
    d_readdata = 0; d_readdatavalid = 0; d_readdataerror = 0;
    repeat (2) tick();
    check(!launch_permit && !release_ready && !fault_latched,
          "bad common-reset base");
    @(negedge clk); cold_reset_n = 1; tick();
  endtask
  task automatic calibrate;
    cal_success = 1; tick();
    check(!memory_ready && !launch_permit, "calibration bypassed scrub");
    repeat (3) tick();
    check(memory_ready && scrub_writes == 3 && !launch_permit,
          "startup requires complete scrub and explicit START");
  endtask
  task automatic boot_ready;
    common_reset();
    command(0, 0, 6); // START before calibration/scrub.
    calibrate();
    command(0, 1, 0);
    check(!launch_permit && !kernel_stop_req && !host_stop_req,
          "START bypassed the stop-ack return handshake");
    kernel_stop_ack = 0; host_stop_ack = 0; #1;
    check(launch_permit && host_submit_permit && !adapter_quiesce_req,
          "START did not open healthy admission");
  endtask

  initial begin
    $display("CASE startup QUIESCE preserves an already closed barrier");
    common_reset();
    check(release_ready && adapter_quiesce_req,
          "empty reset epoch did not establish the startup barrier");
    cmd_valid = 1; cmd_op = 2; #1;
    check(adapter_quiesce_req, "startup QUIESCE opened the adapter");
    tick(); cmd_valid = 0;
    check(cmd_done && cmd_accepted && adapter_quiesce_req &&
          !fault_history[7] && !fault_latched,
          "startup QUIESCE regressed an already closed barrier");
    tick();
    check(state_status == 4 && release_ready && adapter_quiesce_req,
          "startup QUIESCE did not park with admission closed");
    calibrate(); command(1, 1, 0);
    kernel_stop_ack = 0; host_stop_ack = 0; #1;
    check(launch_permit && !fault_latched,
          "explicit RESUME after startup QUIESCE failed");

    $display("CASE calibration failure before START");
    common_reset(); cal_fail = 1; #1;
    check(!launch_permit && !memory_ready, "failed calibration allowed launch");
    tick(); command(0, 0, 2);
    check(fault_history[0] && fault_latched && !reset_request,
          "startup calibration failure was not retained");
    cal_fail = 0; repeat (2) tick();
    check(fault_latched && !launch_permit && !memory_ready,
          "calibration failure auto-recovered");
    command(3, 0, 7);

    $display("CASE malformed request concurrent with provisional RESUME");
    boot_ready(); command(2, 1, 0);
    kernel_stop_ack = 1; host_stop_ack = 1; repeat (3) tick();
    check(release_ready && cmd_ready, "missing parked barrier for RESUME test");
    cmd_valid = 1; cmd_op = 1; k_read = 1; k_address = 35'h3; tick();
    cmd_valid = 0; k_read = 0;
    check(!cmd_done && !cmd_ready && phase_status == 5 &&
          !launch_permit && kernel_stop_req && host_stop_req,
          "RESUME acknowledged before the adapter was exposed");
    tick();
    check(cmd_done && !cmd_accepted && cmd_reason == 2 &&
          fault_latched && !launch_permit,
          "opening adapter fault did not reject provisional RESUME");

    $display("CASE external stop arrives during provisional RESUME");
    boot_ready(); command(2, 1, 0);
    kernel_stop_ack = 1; host_stop_ack = 1; repeat (3) tick();
    cmd_valid = 1; cmd_op = 1; tick(); cmd_valid = 0;
    check(!cmd_done && !cmd_ready && !launch_permit,
          "RESUME completed before opening qualification");
    external_stop = 1; tick();
    check(cmd_done && !cmd_accepted && cmd_reason == 3 &&
          !launch_permit && !fault_latched,
          "external stop failed to cancel provisional RESUME");

    boot_ready();
    $display("CASE active kernel and independent DMA/read debts");
    kernel_idle = 0;
    host_dma_drained = 0; host_desc_drained = 0; host_writeback_drained = 0;
    k_read = 1; k_address = 35'h48; tick();
    check(!k_waitrequest, "healthy kernel read blocked");
    k_read = 0; tick();
    check(client_reads == 1 && !adapter_drained, "read ownership missing");
    cmd_valid = 1; cmd_op = 2; #1;
    check(!launch_permit && kernel_stop_req && host_stop_req &&
          !adapter_quiesce_req, "QUIESCE must close launches first");
    tick(); check(cmd_done && cmd_accepted, "QUIESCE rejected");
    cmd_valid = 0;
    // Already running kernel can still admit memory after launch admission stops.
    k_write = 1; k_address = 35'h50; k_writedata = 64'h1234abcd;
    #1; check(!k_waitrequest, "graceful stop cut active kernel memory");
    tick(); k_write = 0; tick();
    check(client_writes == 1, "active kernel write not delivered");
    kernel_stop_ack = 1; host_stop_ack = 1;
    repeat (8) begin
      tick(); check(phase_status == 2 && !adapter_quiesce_req &&
                    !release_ready, "busy kernel was timed out");
    end
    kernel_idle = 1; tick();
    check(!adapter_quiesce_req, "DMA payload debt ignored");
    host_dma_drained = 1; tick();
    check(!adapter_quiesce_req, "descriptor debt ignored");
    host_desc_drained = 1; tick();
    check(!adapter_quiesce_req, "writeback debt ignored");
    host_writeback_drained = 1; tick();
    check(adapter_quiesce_req && !release_ready && !adapter_drained,
          "owned read was mistaken for complete drain");
    d_readdata = 0; d_readdata[127:64] = 64'hdeadbeef12345678;
    d_readdatavalid = 1; #1;
    check(k_readdatavalid && k_readdata === 64'hdeadbeef12345678,
          "owned response lost or wrong lane during quiesce");
    tick(); d_readdatavalid = 0; tick();
    check(returned_reads == 1 && release_ready && state_status == 4,
          "genuine accepted-work drain not recognized");
    external_stop = 1; command(1, 0, 3);
    check(!launch_permit, "resume overrode external stop");
    external_stop = 0;
    command(1, 1, 0);
    kernel_stop_ack = 0; host_stop_ack = 0; #1;
    check(launch_permit && !epoch_advance, "healthy explicit RESUME failed");
    command(0, 0, 4); command(7, 0, 1);
    command(2, 1, 0);
    kernel_stop_ack = 1; host_stop_ack = 1; repeat (3) tick();
    check(state_status == 4, "second graceful stop failed");

    $display("CASE live fault wins same-edge RESUME and W1C");
    backend_ecc_interrupt = 1; clear_valid = 1; clear_mask = '1;
    cmd_valid = 1; cmd_op = 1; #1;
    check(!launch_permit, "live ECC allowed same-cycle launch");
    tick();
    check(cmd_done && !cmd_accepted && cmd_reason == 2 &&
          clear_done && clear_blocked[2] && fault_pending[2] &&
          fault_history[2] && fault_latched, "fault/clear/resume priority");
    saved_first = first_fault_code;
    cmd_valid = 0; clear_valid = 0; backend_ecc_interrupt = 0; tick();
    clear_valid = 1; clear_mask = 16'h0004; tick(); clear_valid = 0;
    check(!fault_pending[2] && fault_history[2] && fault_latched,
          "W1C erased history or did not acknowledge quiet cause");
    host_fault = 1; tick(); host_fault = 0; tick();
    check(fault_history[5] && first_fault_code == saved_first &&
          state_status == 6 && !launch_permit, "first fault changed or resumed");
    command(1, 0, 2); command(3, 0, 7);
    check(!reset_request && !epoch_advance, "recovery command acted");
    host_desc_drained = 0; #1;
    check(!release_ready, "regressed drain certificate still authorized release");
    tick(); host_desc_drained = 1; repeat (3) tick();
    check(fault_history[7] && !release_ready,
          "broken barrier trust recovered without common reset");

    $display("CASE calibration loss and ECC while DDR command stalled");
    boot_ready(); kernel_idle = 0; amm_ready = 0;
    k_write = 1; k_address = 35'h58; k_writedata = 64'hfeed1234abcd5678;
    tick(); k_write = 0; tick();
    check(d_write && d_waitrequest, "no stalled command to test");
    saved_offer = {d_read,d_write,d_address,d_writedata,d_byteenable,d_burstcount};
    cal_success = 0; backend_ecc_interrupt = 1; #1;
    check(!launch_permit, "memory loss did not close launch immediately");
    repeat (4) begin
      tick();
      check({d_read,d_write,d_address,d_writedata,d_byteenable,d_burstcount}
            === saved_offer, "fault withdrew or changed stalled command");
      check(!release_ready && state_status == 5 && !adapter_quiesce_req,
            "fault fabricated drain or cut busy kernel");
    end
    backend_ecc_interrupt = 0; amm_ready = 1; tick();
    check(adapter_drained, "accepted stalled write did not retire");
    kernel_stop_ack = 1; host_stop_ack = 1;
    repeat (16) begin
      tick(); check(!release_ready && state_status == 5 &&
                    !reset_request, "non-idle faulted kernel escaped Hold");
    end
    kernel_idle = 1; repeat (3) tick();
    check(release_ready && state_status == 6 && !memory_ready &&
          fault_latched, "later real drain should preserve Offline fault");
    command(3, 0, 7);

    $display("CASE first adapter address and sticky fault preservation");
    boot_ready();
    k_read = 1; k_address = 35'h3; #1;
    check(!launch_permit, "live adapter protocol fault allowed launch");
    tick(); k_read = 0; tick();
    // quiescing reports the fault before the adapter's registered context.
    // The supervisor preserves an honestly unavailable first address; the
    // adapter independently retains its actual first address for host access.
    check(fault_latched && first_fault_code[3] &&
          !first_adapter_address_valid && adapter_fault_address_valid &&
          adapter_fault_address == 35'h3 && adapter_fault_code[2],
          "first event/context timing was misreported");
    saved_first = first_fault_code;
    k_read = 1; k_address = 35'h080000000; tick(); k_read = 0; tick();
    clear_valid = 1; clear_mask = '1; tick(); clear_valid = 0;
    check(first_fault_code == saved_first && !first_adapter_address_valid &&
          adapter_fault_address == 35'h3 &&
          fault_history[11] && fault_pending[10] && clear_blocked[10],
          "later fault/W1C changed first context or cleared ongoing adapter cause");

    $display("CASE unqualified/unknown status and coordinated reset epoch");
    common_reset();
    // Break the initial potential barrier before its first post-reset sample.
    // common_reset has already witnessed a healthy empty barrier, so reset once
    // more with unavailable certificates, as a real bridge may start invalid.
    cold_reset_n = 0; kernel_status_valid = 0; kernel_idle = 1'bx;
    repeat (2) tick(); @(negedge clk); cold_reset_n = 1;
    calibrate(); command(0, 0, 5);
    check(!launch_permit && !release_ready && !fault_latched,
          "unknown/invalid startup certificate trusted");
    command(2, 1, 0); repeat (3) tick();
    check(phase_status == 2 && !fault_latched && !release_ready,
          "startup QUIESCE invented status or drain");
    kernel_status_valid = 1; kernel_idle = 1; repeat (3) tick();
    command(0, 0, 4); command(1, 1, 0);
    kernel_stop_ack = 0; host_stop_ack = 0;
    kernel_status_valid = 1'bx; #1;
    check(!launch_permit, "unknown live certificate allowed admission");
    tick(); check(fault_history[6] && fault_latched, "qualification loss lost");
    common_reset();
    check(!fault_latched && fault_history == 0 && first_fault_code == 0,
          "common reset did not establish fresh epoch base");
    // A stale response would violate the reset-domain assumption. The real
    // adapter detects this test violation; reset is not proof of old isolation.
    d_readdatavalid = 1; tick(); d_readdatavalid = 0; tick();
    check(adapter_fault_code[6] && fault_latched && !launch_permit,
          "post-reset unowned response was silently accepted");
    $display("PASS platform_supervisor contract and real adapter/init tests");
    $finish;
  end
endmodule
