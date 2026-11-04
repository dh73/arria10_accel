// One common EMIF user-clock domain. See docs/kernel_ddr_adapter.md.
// Kernel ABI: 35-bit BYTE address, DATA_W bits, burstcount=1, allowance=0.
// mem0_rw_enable is intentionally not a port: generated DI leaves it floating.
// Cold reset MUST reset the kernel, this adapter, and the DDR response domain
// together. Clearing this state while an old DDR response can arrive is unsafe.
module kernel_ddr_width_adapter #(
  parameter int DATA_W = 64,
  parameter int CMD_DEPTH = 4,
  parameter int READ_DEPTH = 8
) (
  input  logic clk,
  input  logic cold_reset_n,
  input  logic memory_ready,
  input  logic backend_init_failed,
  input  logic backend_ecc_interrupt,
  input  logic quiesce_req,

  input  logic k_read, k_write,
  input  logic [34:0] k_address,
  input  logic [DATA_W-1:0] k_writedata,
  input  logic [DATA_W/8-1:0] k_byteenable,
  input  logic k_burstcount,
  output logic k_waitrequest,
  output logic [DATA_W-1:0] k_readdata,
  output logic k_readdatavalid,
  output logic k_writeack,

  output logic [24:0] d_address,
  output logic d_read, d_write,
  output logic [511:0] d_writedata,
  output logic [63:0] d_byteenable,
  output logic d_burstcount,
  input  logic d_waitrequest,
  input  logic [511:0] d_readdata,
  input  logic d_readdatavalid,
  input  logic d_readdataerror,

  output logic fault,
  output logic [7:0] fault_code,
  output logic [34:0] fault_address,
  output logic fault_address_valid,
  output logic quiescing,
  output logic drained
);
  localparam int CPW = (CMD_DEPTH > 1) ? $clog2(CMD_DEPTH) : 1;
  localparam int RPW = (READ_DEPTH > 1) ? $clog2(READ_DEPTH) : 1;
  localparam int CCW = (CMD_DEPTH > 1) ? $clog2(CMD_DEPTH + 1) : 1;
  localparam int RCW = (READ_DEPTH > 1) ? $clog2(READ_DEPTH + 1) : 1;

  // No data-array reset: only entries covered by the counts are observed.
  logic cmd_is_read [0:CMD_DEPTH-1];
  logic [34:0] cmd_address [0:CMD_DEPTH-1];
  logic [DATA_W-1:0] cmd_writedata [0:CMD_DEPTH-1];
  logic [DATA_W/8-1:0] cmd_byteenable [0:CMD_DEPTH-1];
  logic [CPW-1:0] cmd_rd_q, cmd_wr_q;
  logic [CCW-1:0] cmd_count_q;

  // Ownership begins at upstream acceptance, not at DDR dispatch. Keeping the
  // full address also makes ECC diagnostics refer to the original byte address.
  logic [34:0] read_address [0:READ_DEPTH-1];
  logic [RPW-1:0] read_rd_q, read_wr_q;
  logic [RCW-1:0] read_count_q, issued_count_q;
  logic offered_q, seen_ready_q;
  logic cmd_pop, cmd_push, read_push, read_pop, issue_read;
  logic response_owned, cmd_space, read_space, request_present;
  logic [7:0] live_fault;
  logic [34:0] live_fault_address;
  logic live_fault_address_valid;

  function automatic [CPW-1:0] next_cmd(input logic [CPW-1:0] p);
    if (p == CPW'(CMD_DEPTH-1)) next_cmd = '0;
    else next_cmd = p + 1'b1;
  endfunction
  function automatic [RPW-1:0] next_read(input logic [RPW-1:0] p);
    if (p == RPW'(READ_DEPTH-1)) next_read = '0;
    else next_read = p + 1'b1;
  endfunction

  // A registered FIFO head supplies the entire offered command. Readiness
  // controls NEW offers only. Once sampled stalled, offered_q preserves it.
  // Fault/quiesce never cancel accepted commands. There is no empty fallthrough.
  always_comb begin
    d_read = 1'b0;
    d_write = 1'b0;
    d_address = '0;
    d_writedata = '0;
    d_byteenable = '0;
    d_burstcount = 1'b1;
    if (cold_reset_n && cmd_count_q != 0 && (offered_q || memory_ready)) begin
      d_read = cmd_is_read[cmd_rd_q];
      d_write = !cmd_is_read[cmd_rd_q];
      // These bits are narrowed only from a previously validated command.
      d_address = cmd_address[cmd_rd_q][30:6];
      d_writedata[8 * (cmd_address[cmd_rd_q] & 35'd63) +: DATA_W] = cmd_writedata[cmd_rd_q];
      d_byteenable[(cmd_address[cmd_rd_q] & 35'd63) +: DATA_W/8] = cmd_byteenable[cmd_rd_q];
    end
  end
  assign cmd_pop = (d_read || d_write) && !d_waitrequest;
  assign issue_read = d_read && !d_waitrequest;

  // With no old issued read, a same-cycle accepted DDR read may respond. Its
  // tag is already present because command dispatch never bypasses the FIFO.
  // Old issued reads always take precedence over the newly accepted one.
  assign response_owned = (issued_count_q != 0) || issue_read;
  assign read_pop = cold_reset_n && d_readdatavalid && response_owned;
  always_comb begin
    k_readdatavalid = read_pop;
    k_readdata = '0;
    if (read_pop)
      k_readdata = d_readdata[8 * (read_address[read_rd_q] & 35'd63) +: DATA_W];
  end
  // ENABLE_BSP_AVMM_WRITE_ACK=0: the generated LSU acknowledges kernel-side
  // acceptance internally. This BSP input is unused and is tied deterministically.
  assign k_writeack = 1'b0;

  // Bitmask diagnostics. Code accumulates; address is the FIRST fault context.
  // No invented kernel error response: owned ECC responses still return exactly
  // once, and the host must use this sticky fault to invalidate success credit.
  always_comb begin
    request_present = k_read || k_write;
    live_fault = '0;
    live_fault_address = '0;
    live_fault_address_valid = 1'b0;
    if (cold_reset_n) begin
      live_fault[0] = k_read && k_write;
      live_fault[1] = request_present && !k_burstcount;
      live_fault[2] = request_present && ((k_address % (DATA_W/8)) != 0);
      live_fault[3] = request_present && (k_address[34:31] != 4'b0);
      live_fault[4] = backend_init_failed || (seen_ready_q && !memory_ready);
      live_fault[5] = backend_ecc_interrupt ||
                      (d_readdatavalid && d_readdataerror);
      live_fault[6] = d_readdatavalid && !response_owned;
      if (d_readdatavalid && d_readdataerror && response_owned) begin
        live_fault_address = read_address[read_rd_q];
        live_fault_address_valid = 1'b1;
      end else if (|live_fault[3:0]) begin
        live_fault_address = k_address;
        live_fault_address_valid = 1'b1;
      end
    end
  end
  assign cmd_space = (cmd_count_q < CCW'(CMD_DEPTH)) || cmd_pop;
  assign read_space = (read_count_q < RCW'(READ_DEPTH)) || read_pop;
  assign k_waitrequest = !cold_reset_n || !memory_ready || quiesce_req ||
                         fault || (|live_fault) || !cmd_space ||
                         (k_read && !read_space);
  assign cmd_push = cold_reset_n && request_present && !k_waitrequest;
  assign read_push = cmd_push && k_read;
  assign quiescing = quiesce_req || fault || (|live_fault);
  // This is an ownership/acceptance drain, NOT a DDR persistence indication.
  // A kernel request held while waitrequest=1 has not entered this contract.
  assign drained = cold_reset_n && (cmd_count_q == 0) &&
                   (read_count_q == 0) && (issued_count_q == 0);

  always_ff @(posedge clk or negedge cold_reset_n) begin
    if (!cold_reset_n) begin
      cmd_rd_q <= '0;
      cmd_wr_q <= '0;
      cmd_count_q <= '0;
      read_rd_q <= '0;
      read_wr_q <= '0;
      read_count_q <= '0;
      issued_count_q <= '0;
      offered_q <= 1'b0;
      seen_ready_q <= 1'b0;
      fault <= 1'b0;
      fault_code <= '0;
      fault_address <= '0;
      fault_address_valid <= 1'b0;
    end else begin
      if (memory_ready) seen_ready_q <= 1'b1;
      if (|live_fault) begin
        fault <= 1'b1;
        fault_code <= fault_code | live_fault;
        if (!fault) begin
          fault_address <= live_fault_address;
          fault_address_valid <= live_fault_address_valid;
        end
      end
      offered_q <= (d_read || d_write) && d_waitrequest;
      if (cmd_push) begin
        cmd_is_read[cmd_wr_q] <= k_read;
        cmd_address[cmd_wr_q] <= k_address;
        cmd_writedata[cmd_wr_q] <= k_writedata;
        cmd_byteenable[cmd_wr_q] <= k_byteenable;
        cmd_wr_q <= next_cmd(cmd_wr_q);
      end
      if (cmd_pop) cmd_rd_q <= next_cmd(cmd_rd_q);
      case ({cmd_push,cmd_pop})
        2'b10: cmd_count_q <= cmd_count_q + 1'b1;
        2'b01: cmd_count_q <= cmd_count_q - 1'b1;
        default: begin end
      endcase
      if (read_push) begin
        read_address[read_wr_q] <= k_address;
        read_wr_q <= next_read(read_wr_q);
      end
      if (read_pop) read_rd_q <= next_read(read_rd_q);
      case ({read_push,read_pop})
        2'b10: read_count_q <= read_count_q + 1'b1;
        2'b01: read_count_q <= read_count_q - 1'b1;
        default: begin end
      endcase
      case ({issue_read,read_pop})
        2'b10: issued_count_q <= issued_count_q + 1'b1;
        2'b01: issued_count_q <= issued_count_q - 1'b1;
        default: begin end
      endcase
    end
  end

  // Parameter checks and interface/state assertions are verification-only.
  // The external reset and ordered/exactly-once response assumptions are NOT
  // proved here; see the accompanying Lean refinement-gap list.
`ifndef SYNTHESIS
  initial begin
    if (!(DATA_W==64 || DATA_W==128 || DATA_W==256 || DATA_W==512))
      $fatal(1, "unsupported port width");
    if (CMD_DEPTH < 1 || READ_DEPTH < 1)
      $fatal(1, "kernel_ddr_adapter depths must be positive");
  end
`ifdef KERNEL_DDR_ASSERTIONS
  // Procedural checks also work with Verilator 4.028, whose SVA temporal
  // subset cannot parse the non-overlapping/stable property used here.
  localparam int OFFER_W = 1 + 1 + 25 + 512 + 64 + 1;
  logic previous_stalled;
  logic [OFFER_W-1:0] previous_offer;
  always_ff @(posedge clk or negedge cold_reset_n) begin
    if (!cold_reset_n) begin
      previous_stalled <= 1'b0;
      previous_offer <= '0;
    end else begin
      if (previous_stalled)
        // Generated kernels may leave disabled write-byte lanes unknown.
        // Compare all four-state values for stability; enabled data validity
        // is a separate interface obligation, checked by the testbench.
        assert ({d_read,d_write,d_address,d_writedata,d_byteenable,d_burstcount}
                === previous_offer) else $fatal(1, "stalled command changed");
      assert (cmd_count_q <= CCW'(CMD_DEPTH) && read_count_q <= RCW'(READ_DEPTH))
        else $fatal(1, "FIFO capacity exceeded");
      assert (issued_count_q <= read_count_q)
        else $fatal(1, "issued read has no reserved owner");
      assert (!read_pop || read_count_q != 0)
        else $fatal(1, "response without reserved owner");
      assert (!(d_read && d_write)) else $fatal(1, "invalid DDR command");
      assert (!cmd_push || ((k_read != k_write) && k_burstcount &&
                           (k_address[34:31] == 0) && ((k_address % (DATA_W/8)) == 0)))
        else $fatal(1, "invalid upstream admission");
      previous_stalled <= (d_read || d_write) && d_waitrequest;
      previous_offer <= {d_read,d_write,d_address,d_writedata,d_byteenable,d_burstcount};
    end
  end
`endif
`endif
endmodule
