`timescale 1ns/1ps
// Interface regression for the two actual generated CRA modules. No force,
// hierarchy writes, invented DUT handshakes, or kernel reachability claim.
module cra_read_clear_safe_tb;
  logic clock=0, resetn=0, wr=0, done=0;
  logic request_read=0, upstream_blocked=0;
  // This is a TESTBENCH adapter, not a generated CRA port. A stalled upstream
  // request is not forwarded. Every forwarded read-high edge is a transaction.
  wire rd = request_read && !upstream_blocked;
  logic enable=1, valid_in=1, printf_full=0, lsu_active=0, write_pending=0;
  logic [4:0] address=0;
  logic [7:0] byteenable=8'hff;
  logic [63:0] wd=0;
  logic [31:0] printf_size=32'h12345678;
  wire [63:0] data[2];
  wire [31:0] status[2];
  wire [831:0] arguments[2];
  wire [1:0] valid, start, irq, counter_reset;
  // visible is the unreported count; pending is the count returned last edge
  // whose retirement is deliberately delayed one edge to retain IRQ timing.
  int unsigned visible[2], pending[2];
  longint unsigned produced[2], delivered[2];
  bit previous_done=0, modulo_only=0;
  int scenarios=0;
  int same_edge=0, consecutive_reads=0, blocked_edges=0;
  bit previous_count_read=0;
  always #5 clock=~clock;
`define PORTS(N) \
    .clock(clock), .resetn(resetn), .acl_counter_full(printf_full), \
    .acl_counter_size(printf_size), .avs_cra_address(address), \
    .avs_cra_byteenable(byteenable), .avs_cra_enable(enable), \
    .avs_cra_read(rd), .avs_cra_write(wr), .avs_cra_writedata(wd), \
    .has_a_lsu_active(lsu_active), .has_a_write_pending(write_pending), \
    .kernel_done(done), .valid_in(valid_in), .acl_counter_reset(counter_reset[N]), \
    .avs_cra_readdata(data[N]), .avs_cra_readdatavalid(valid[N]), \
    .cra_irq(irq[N]), .kernel_arguments(arguments[N]), \
    .kernel_start(start[N]), .status(status[N])
  Pass1Kernel_function_cra_agent p1 (`PORTS(0));
  Pass2Kernel_function_cra_agent p2 (`PORTS(1));
`undef PORTS

  // Sample inputs/pre-edge public state, then check registered outputs after NBA.
  // There is no dependence on transformed internal signal names.
  always @(posedge clock or negedge resetn) begin : scoreboard
    bit sampled_read, count_read, finish_event;
    logic [63:0] expected_response[2];
    logic [1:0] expected_done, expected_printf;
    int unsigned retired, physical_count;
    if (!resetn) begin
      previous_done=0;
      previous_count_read=0;
      for (int k=0;k<2;k++) begin
        visible[k]=0; pending[k]=0; produced[k]=0; delivered[k]=0;
      end
    end else begin
      sampled_read=rd;
      count_read=rd && address==5'd6;
      if (count_read && previous_count_read) consecutive_reads++;
      if (request_read && upstream_blocked) blocked_edges++;
      for (int k=0;k<2;k++) begin
        if ($isunknown({status[k],done,rd,wr,address,byteenable}))
          $fatal(1,"unknown public input/state kernel=%0d",k+1);
        finish_event=done && !previous_done && status[k][15];
        if (count_read && finish_event) same_edge++;
        physical_count=(visible[k]+pending[k])%4;
        expected_done[k]=(physical_count!=0) || (done && status[k][15]);
        expected_printf[k]=printf_full || status[k][3];
        if (wr && address==5'd0) begin
          expected_done[k]=byteenable[0] ? wd[1] : status[k][1];
          expected_printf[k]=byteenable[0] ? wd[3] : status[k][3];
        end
        if (address==5'd6) expected_response[k]=visible[k];
        else if (address==5'd1) expected_response[k]={printf_size,status[k]};
        else expected_response[k]={32'b0,status[k]};
        retired=count_read ? visible[k] : 0;
        delivered[k]+=retired;
        produced[k]+=int'(finish_event);
        pending[k]=retired;
        visible[k]=(visible[k]-retired+int'(finish_event))%4;
        if (modulo_only) begin
          if ((delivered[k]+visible[k])%4 != produced[k]%4)
            $fatal(1,"modulo conservation kernel=%0d",k+1);
        end else begin
          if (delivered[k]+visible[k] != produced[k])
            $fatal(1,"integer conservation kernel=%0d",k+1);
          if (visible[k]+pending[k]>1 || produced[k]-delivered[k]>1)
            $fatal(1,"serialized one-start contract violated kernel=%0d",k+1);
        end
      end
      previous_done=done;
      previous_count_read=count_read;
      #1;
      for (int k=0;k<2;k++) begin
        if (valid[k] !== sampled_read)
          $fatal(1,"read valid timing kernel=%0d",k+1);
        if (sampled_read && data[k] !== expected_response[k])
          $fatal(1,"read data kernel=%0d got=%h expected=%h time=%0t",
                 k+1,data[k],expected_response[k],$time);
        if (status[k][1] !== expected_done[k] || status[k][3] !== expected_printf[k])
          $fatal(1,"done/printf status pipeline kernel=%0d time=%0t",k+1,$time);
        // The generated profile bit is a one-cycle pulse, checked below.
        if (!status[k][5] && irq[k] !== (status[k][1] || status[k][3]))
          $fatal(1,"IRQ equation kernel=%0d time=%0t",k+1,$time);
      end
    end
  end

  task automatic cycle(input bit read_request, input bit kernel_finish,
                       input bit blocked=0);
    @(negedge clock);
    address=5'd6; request_read=read_request; upstream_blocked=blocked;
    wr=0; done=kernel_finish; byteenable=8'hff;
    @(posedge clock); #2;
  endtask

  task automatic idle(input int n=1);
    repeat(n) cycle(0,0);
  endtask

  task automatic write_reg(input logic [4:0] a, input logic [63:0] value,
                           input logic [7:0] be=8'hff);
    @(negedge clock);
    address=a; wd=value; byteenable=be; wr=1;
    request_read=0; upstream_blocked=0; done=0;
    @(posedge clock); #2;
  endtask

  task automatic read_reg(input logic [4:0] a);
    @(negedge clock);
    address=a; byteenable=8'hff; wr=0; request_read=1;
    upstream_blocked=0; done=0;
    @(posedge clock); #2;
  endtask

  task automatic reset_dut;
    @(negedge clock);
    resetn=0; request_read=0; upstream_blocked=0; wr=0; done=0;
    enable=1; valid_in=1; printf_full=0; lsu_active=0; write_pending=0;
    address=0; wd=0; byteenable=8'hff; modulo_only=0;
    #1;
    for (int k=0;k<2;k++)
      if (data[k] !== 64'b0 || valid[k] !== 1'b0 || irq[k] !== 1'b0 ||
          start[k] !== 1'b0 || arguments[k] !== 832'b0 ||
          counter_reset[k] !== 1'b0 || status[k] !== 32'h00050000)
        $fatal(1,"asynchronous reset ABI kernel=%0d",k+1);
    repeat(3) @(negedge clock);
    resetn=1;
    idle(1);
  endtask

  task automatic launch;
    if (!modulo_only)
      for (int k=0;k<2;k++)
        if (visible[k]!=0 || pending[k]!=0 || delivered[k]!=produced[k])
          $fatal(1,"launch before count1/trailing0 drain kernel=%0d",k+1);
    if (status[0][15] || status[1][15]) $fatal(1,"overlapping launch");
    write_reg(5'd1,64'd1);
    for (int n=0;n<16;n++) begin
      idle(1);
      if (start==2'b11) break;
      if (n==15) $fatal(1,"normal start timeout");
    end
    idle(3);
    if (status[0][15] !== 1'b1 || status[1][15] !== 1'b1)
      $fatal(1,"normal start did not establish running");
  endtask

  task automatic drain;
    cycle(1,0); // Collect any remaining completion.
    cycle(1,0); // Consecutive full64 trailing-zero read.
    for (int k=0;k<2;k++)
      if (data[k] !== 64'b0) $fatal(1,"trailing read must be zero");
    idle(3);
  endtask

  task automatic checkpoint(input longint unsigned expected);
    for (int k=0;k<2;k++)
      if (produced[k]!=expected || delivered[k]!=expected || visible[k]!=0 ||
          pending[k]!=0 || status[k][1] !== 1'b0)
        $fatal(1,"checkpoint kernel=%0d produced=%0d delivered=%0d expected=%0d",
               k+1,produced[k],delivered[k],expected);
    scenarios++;
  endtask

  initial begin
    // Single read and consecutive reads around both sampling and retirement.
    for (int burst=0;burst<2;burst++)
      for (int offset=-2;offset<=2;offset++) begin
        reset_dut(); launch();
        for (int t=0;t<10;t++)
          cycle(burst ? (t>=4 && t<=7) : (t==4), t==4+offset);
        drain(); checkpoint(1);
      end

    // The colliding read returns the old zero; early IRQ is legal. Completion
    // remains visible to the following accepted read and is returned once.
    reset_dut(); launch(); cycle(1,1);
    if (data[0] !== 0 || data[1] !== 0 || irq !== 2'b11)
      $fatal(1,"same-edge old-value/early-IRQ semantics");
    repeat(4) cycle(1,1); // Stretched done must not manufacture events.
    cycle(0,0); cycle(1,1); // New done edge while not running is ignored.
    drain(); checkpoint(1);

    // A held upstream request is blocked before reaching the CRA for 3 edges.
    // Finish occurs during the stall, then the accepted transaction returns1.
    reset_dut(); launch();
    cycle(1,0,1); cycle(1,1,1); cycle(1,0,1); cycle(1,0,0);
    if (data[0] !== 64'd1 || data[1] !== 64'd1)
      $fatal(1,"held upstream request did not collect completion");
    drain(); checkpoint(1);

    // Idle done pulses are not completions; running qualification is retained.
    reset_dut(); cycle(1,1); cycle(1,1); cycle(0,0); cycle(1,1);
    drain(); checkpoint(0);

    // Reset between a sampled read and its delayed retirement cancels the old
    // epoch. A fresh real launch must work with no residual clear/snapshot.
    reset_dut(); launch(); cycle(0,1); cycle(1,0);
    reset_dut(); launch(); cycle(1,1); drain(); checkpoint(1);

    // Existing generator ignores enable/valid_in. Do not silently add gating.
    reset_dut(); launch();
    @(negedge clock); enable=0; valid_in=0;
    cycle(1,1); drain(); checkpoint(1);

    // Several launches in one reset epoch; each completes and drains before
    // the next start. This is the executor's serialized count1-then0 contract.
    reset_dut();
    for (int n=0;n<8;n++) begin
      launch(); cycle(n%2,1); drain();
      for (int k=0;k<2;k++)
        if (produced[k]!=n+1 || delivered[k]!=n+1)
          $fatal(1,"serialized relaunch accounting");
    end
    checkpoint(8);

    // Preserve argument byte writes, normal latching, printf/ack, status read,
    // and profile IRQ. None of these checks infers physical transport behavior.
    reset_dut();
    write_reg(5'd16,64'h1122334455667788);
    write_reg(5'd16,64'haabbccddeeff0099,8'h81);
    write_reg(5'd28,64'hfedcba9876543210);
    write_reg(5'd0,64'h20); // Idle profile pulse must not assert IRQ.
    if (irq !== 0) $fatal(1,"idle profile IRQ");
    idle(1);
    launch();
    write_reg(5'd0,64'h20); // A running profile pulse asserts IRQ.
    if (irq !== 2'b11) $fatal(1,"running profile IRQ");
    idle(1);
    if (irq !== 0 || status[0][5] || status[1][5])
      $fatal(1,"profile IRQ/status self-clear");
    for (int k=0;k<2;k++)
      if (arguments[k][63:0] !== 64'haa22334455667799 ||
          arguments[k][831:768] !== 64'hfedcba9876543210)
        $fatal(1,"argument write/latch ABI kernel=%0d",k+1);
    cycle(0,1); drain(); checkpoint(1);
    write_reg(5'd0,64'h00); // Disable profile.
    @(negedge clock); printf_full=1; lsu_active=1; write_pending=1;
    idle(1);
    if (irq !== 2'b11 || !status[0][12] || !status[0][13] ||
        !status[1][12] || !status[1][13]) $fatal(1,"printf/LSU status");
    @(negedge clock); printf_full=0;
    read_reg(5'd1); // High word is printf_size; low word is sampled status.
    write_reg(5'd0,64'h10);
    if (counter_reset !== 2'b11) $fatal(1,"printf reset request");
    idle(1);
    if (counter_reset !== 0 || irq !== 0) $fatal(1,"printf reset self-clear");

    // OUTSIDE THE ACCEPTANCE CONTRACT: four finished, undrained launches wrap
    // the preserved 2-bit counter. This characterizes ABI, not overflow safety.
    reset_dut(); modulo_only=1;
    for (int n=0;n<4;n++) begin
      launch(); cycle(0,1); idle(3);
    end
    cycle(1,0);
    if (data[0] !== 0 || data[1] !== 0 || produced[0]!=4 || produced[1]!=4)
      $fatal(1,"2-bit modulo overflow characterization");
    drain(); scenarios++;
    if (same_edge==0 || consecutive_reads==0 || blocked_edges<3)
      $fatal(1,"required coverage was not exercised");
    $display("PASS CRA read-clear safe scenarios=%0d agents=2 same_edge=%0d consecutive=%0d blocked=%0d",
             scenarios,same_edge,consecutive_reads,blocked_edges);
    $finish;
  end
  initial begin #1000000; $fatal(1,"regression watchdog"); end
endmodule
