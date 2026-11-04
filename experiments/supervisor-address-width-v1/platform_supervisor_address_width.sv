// Proposed new shell control. All inputs belong to the common EMIF clock.
// See docs/platform_supervisor.md for the NEW status/CDC/reset contracts.
module platform_supervisor_address_width #(parameter int ADDR_W = 35) (
  input  logic clk, cold_reset_n,
  input  logic memory_ready, backend_init_failed, backend_ecc_interrupt,
  input  logic adapter_fault,
  input  logic [7:0] adapter_fault_code,
  input  logic [ADDR_W-1:0] adapter_fault_address,
  input  logic adapter_fault_address_valid, adapter_quiescing, adapter_drained,
  input  logic kernel_status_valid, kernel_stop_ack, kernel_idle, kernel_fault,
  input  logic host_status_valid, host_stop_ack,
  input  logic host_dma_drained, host_desc_drained, host_writeback_drained,
  input  logic host_fault, external_stop,
  input  logic cmd_valid,
  input  logic [2:0] cmd_op,
  input  logic clear_valid,
  input  logic [15:0] clear_mask,
  output logic launch_permit, host_submit_permit,
  output logic kernel_stop_req, host_stop_req, adapter_quiesce_req,
  output logic [2:0] state_status, phase_status,
  output logic release_ready, fault_latched,
  output logic [15:0] fault_history, fault_pending, first_fault_code,
  output logic [7:0] first_adapter_code,
  output logic [ADDR_W-1:0] first_adapter_address,
  output logic first_adapter_address_valid,
  output logic cmd_ready, cmd_done, cmd_accepted,
  output logic [3:0] cmd_reason,
  output logic clear_done,
  output logic [15:0] clear_blocked,
  output logic reset_request, epoch_advance
);
  localparam logic [2:0] HOLD=0, READY=1, STOP_WORK=2,
                         STOP_ADAPTER=3, PARKED=4, OPENING=5;
  localparam logic [2:0] START=0, RESUME=1, QUIESCE=2, RECOVER=3;
  localparam logic [3:0] OK=0, BADOP=1, FAULT=2, STOP=3, PHASE=4,
                         DEBT=5, MEMORY=6, UNSUPPORTED=7;
  logic [2:0] phase_q, phase_d;
  logic seen_ready_q, started_q, barrier_seen_q;
  logic [15:0] live_fault, clear_bits;
  logic [7:0] adapter_bits;
  logic reset_ok, sources_drained, raw_barrier, effective_fault;
  logic stop_now, admission_closed, accept_cmd, begin_open, finish_open;
  logic [3:0] reason;

  // Binary comparisons implement ordinary gates in hardware. The explicit
  // default also keeps X/Z from granting permission in four-state simulation.
  // This does NOT detect metastability or replace coherent CDC/validity logic.
  function automatic logic one(input logic v);
    case (v) 1'b1: one=1'b1; default: one=1'b0; endcase
  endfunction
  function automatic logic zero(input logic v);
    case (v) 1'b0: zero=1'b1; default: zero=1'b0; endcase
  endfunction

  assign reset_ok = one(cold_reset_n);
  assign phase_status = phase_q;
  assign reset_request = 1'b0;
  assign epoch_advance = 1'b0;
  assign cmd_ready = reset_ok && (phase_q!=OPENING);
  assign sources_drained = one(kernel_status_valid) && one(kernel_stop_ack) &&
    one(kernel_idle) && one(host_status_valid) && one(host_stop_ack) &&
    one(host_dma_drained) && one(host_desc_drained) && one(host_writeback_drained);

  // Stop producer admissions first. Never close this gate merely because a
  // graceful stop/fault was requested while an accepted kernel can still run.
  assign adapter_quiesce_req = !reset_ok || (phase_q==HOLD) ||
                               (phase_q==STOP_ADAPTER) || (phase_q==PARKED);
  // adapter_quiesce_req structurally implies producer admission is closed.
  // Do not use effective_fault/admission_closed here: that creates a cycle
  // through the barrier-regression fault detector below.
  assign raw_barrier = reset_ok && adapter_quiesce_req && sources_drained &&
                       one(adapter_quiescing) && one(adapter_drained);

  always_comb begin
    adapter_bits='0;
    clear_bits='0;
    for (int b=0; b<8; b=b+1)
      adapter_bits[b] = !zero(adapter_fault_code[b]);
    for (int b=0; b<16; b=b+1)
      clear_bits[b] = one(clear_valid) && one(clear_mask[b]);
    live_fault='0;
    if (reset_ok) begin
      live_fault[0] = !zero(backend_init_failed);
      live_fault[1] = seen_ready_q && !one(memory_ready);
      live_fault[2] = !zero(backend_ecc_interrupt);
      // quiescing includes the adapter's LIVE faults before its sticky fault
      // register updates. Ignore our own requested adapter stop here.
      live_fault[3] = !zero(adapter_fault) ||
                      (!adapter_quiesce_req && !zero(adapter_quiescing));
      live_fault[4] = !zero(kernel_fault);
      live_fault[5] = !zero(host_fault);
      live_fault[6] = started_q &&
        (!one(kernel_status_valid) || !one(host_status_valid));
      live_fault[7] = (((phase_q==STOP_ADAPTER) || (phase_q==PARKED) ||
                        (phase_q==OPENING)) &&
                        !sources_drained) || (barrier_seen_q && !raw_barrier);
      case (phase_q)
        HOLD,READY,STOP_WORK,STOP_ADAPTER,PARKED,OPENING: begin end
        default: live_fault[7]=1'b1;
      endcase
      if (!zero(adapter_fault)) live_fault[15:8]=adapter_bits;
    end
  end

  assign effective_fault = fault_latched || (|live_fault);
  assign stop_now = !zero(external_stop) ||
                    (cmd_ready && one(cmd_valid) && (cmd_op === QUIESCE));
  assign admission_closed = !reset_ok || (phase_q!=READY) ||
                            effective_fault || stop_now;
  assign kernel_stop_req = admission_closed;
  assign host_stop_req = admission_closed;
  assign launch_permit = reset_ok && !admission_closed && one(memory_ready) &&
                          one(kernel_status_valid) && one(host_status_valid) &&
                          zero(kernel_stop_ack) && zero(host_stop_ack);
  assign host_submit_permit = launch_permit;
  // Contract regression destroys trust until cold reset. Other faults can
  // become physically drained without becoming healthy or runnable.
  assign release_ready = raw_barrier && !fault_history[7] && !live_fault[7];

  // Independent W1C affects notification bits only. This decoder reads the
  // pre-edge sticky latch and live causes, never the cleared pending mask.
  always_comb begin
    accept_cmd=1'b0;
    begin_open=1'b0;
    finish_open=1'b0;
    reason=OK;
    if (phase_q==OPENING) begin
      // Complete the PREVIOUS START/RESUME, not the current command inputs.
      // Opening exposes adapter live faults hidden by requested quiescing.
      // Producer gates remain stopped and no launch permission exists yet.
      if (effective_fault) reason=FAULT;
      else if (!zero(external_stop)) reason=STOP;
      else if (!one(memory_ready)) reason=MEMORY;
      else if (!sources_drained) reason=DEBT;
      else finish_open=1'b1;
    end else if (cmd_ready && one(cmd_valid)) begin
      case (cmd_op)
        QUIESCE: accept_cmd=1'b1;
        RECOVER: reason=UNSUPPORTED;
        START,RESUME: begin
          if (effective_fault) reason=FAULT;
          else if (!zero(external_stop)) reason=STOP;
          else if (((cmd_op==START) && (phase_q!=HOLD)) ||
                   ((cmd_op==RESUME) && (phase_q!=PARKED))) reason=PHASE;
          else if (!one(memory_ready)) reason=MEMORY;
          else if (!release_ready) reason=DEBT;
          else begin_open=1'b1;
        end
        default: reason=BADOP;
      endcase
    end
    phase_d=phase_q;
    case (phase_q)
      HOLD: if (begin_open) phase_d=OPENING;
            else if (stop_now) phase_d=sources_drained ? STOP_ADAPTER : STOP_WORK;
      READY: if (effective_fault || stop_now) phase_d=STOP_WORK;
      STOP_WORK: if (sources_drained) phase_d=STOP_ADAPTER;
      STOP_ADAPTER: if (release_ready) phase_d=PARKED;
      PARKED: if (begin_open) phase_d=OPENING;
      OPENING: phase_d=finish_open ? READY : STOP_WORK;
      default: phase_d=HOLD;
    endcase
  end

  always_comb begin
    state_status=3'd0;
    if (reset_ok) begin
      if (effective_fault) state_status=release_ready ? 3'd6 : 3'd5;
      else if (launch_permit) state_status=3'd1;
      else if ((phase_q==OPENING) || ((phase_q==READY) && !admission_closed))
        state_status=3'd3;
      else if ((phase_q==HOLD) && !stop_now) state_status=3'd0;
      else if (release_ready) state_status=3'd4;
      else state_status=3'd2;
    end
  end

  always_ff @(posedge clk or negedge cold_reset_n) begin
    if (!cold_reset_n) begin
      phase_q<=HOLD;
      seen_ready_q<=1'b0;
      started_q<=1'b0;
      barrier_seen_q<=1'b0;
      fault_latched<=1'b0;
      fault_history<='0;
      fault_pending<='0;
      first_fault_code<='0;
      first_adapter_code<='0;
      first_adapter_address<='0;
      first_adapter_address_valid<=1'b0;
      cmd_done<=1'b0;
      cmd_accepted<=1'b0;
      cmd_reason<=OK;
      clear_done<=1'b0;
      clear_blocked<='0;
    end else begin
      phase_q<=phase_d;
      if (one(memory_ready)) seen_ready_q<=1'b1;
      if (finish_open) started_q<=1'b1;
      if (begin_open) barrier_seen_q<=1'b0;
      else if (release_ready) barrier_seen_q<=1'b1;
      fault_latched<=fault_latched || (|live_fault);
      fault_history<=fault_history | live_fault;
      fault_pending<=(fault_pending & ~clear_bits) | live_fault;
      if (!fault_latched && (|live_fault)) begin
        first_fault_code<=live_fault;
        first_adapter_code<=!zero(adapter_fault) ? adapter_bits : 8'b0;
        first_adapter_address_valid<=!zero(adapter_fault) &&
                                      one(adapter_fault_address_valid);
        first_adapter_address<=(!zero(adapter_fault) &&
          one(adapter_fault_address_valid)) ? adapter_fault_address : '0;
      end
      cmd_done<=(phase_q==OPENING) ||
                 (cmd_ready && one(cmd_valid) && !begin_open);
      cmd_accepted<=finish_open || (cmd_ready && one(cmd_valid) && accept_cmd);
      cmd_reason<=((phase_q==OPENING) || (cmd_ready && one(cmd_valid))) ? reason : OK;
      clear_done<=one(clear_valid);
      clear_blocked<=clear_bits & live_fault;
    end
  end

`ifndef SYNTHESIS
`ifdef PLATFORM_SUPERVISOR_ASSERTIONS
  assert property (@(posedge clk) disable iff (!cold_reset_n)
    launch_permit |-> phase_q==READY && !effective_fault && !stop_now &&
      !kernel_stop_req && !host_stop_req && !adapter_quiesce_req &&
      !kernel_stop_ack && !host_stop_ack)
      else $fatal(1,"unsafe launch permission");
  assert property (@(posedge clk) disable iff (!cold_reset_n)
    release_ready |-> kernel_stop_req && host_stop_req &&
      adapter_quiesce_req && sources_drained && adapter_quiescing && adapter_drained)
      else $fatal(1,"release without independent drain certificates");
  assert property (@(posedge clk) disable iff (!cold_reset_n)
    phase_q==STOP_WORK |-> !adapter_quiesce_req)
      else $fatal(1,"running-kernel memory gate closed during STOP_WORK");
  assert property (@(posedge clk) disable iff (!cold_reset_n)
    fault_latched |=> fault_latched && $stable({first_fault_code,
      first_adapter_code,first_adapter_address,first_adapter_address_valid}))
      else $fatal(1,"sticky first fault changed");
  assert property (@(posedge clk) disable iff (!cold_reset_n)
    1'b1 |=> (fault_history & $past(fault_history))==$past(fault_history))
      else $fatal(1,"fault history lost a bit");
  assert property (@(posedge clk) disable iff (!cold_reset_n)
    cmd_ready && one(cmd_valid) && cmd_op==RECOVER |=> cmd_done && !cmd_accepted &&
      cmd_reason==UNSUPPORTED) else $fatal(1,"software recovery accepted");
  assert property (@(posedge clk) !reset_request && !epoch_advance)
      else $fatal(1,"fabricated reset or generation advance");
  assert property (@(posedge clk) disable iff (!cold_reset_n)
    one(adapter_fault_address_valid) |-> !$isunknown(adapter_fault_address))
      else $fatal(1,"unknown qualified fault address");
`endif
`endif
endmodule
