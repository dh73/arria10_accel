`timescale 1ns/1ps
module kernel_ddr_init_integration_tb;
logic [0:0] clk;
logic [0:0] cold_reset_n;
logic [0:0] memory_ready;
logic [0:0] backend_init_failed;
logic [0:0] backend_ecc_interrupt;
logic [0:0] quiesce_req;
logic [0:0] k_read;
logic [0:0] k_write;
logic [34:0] k_address;
logic [63:0] k_writedata;
logic [7:0] k_byteenable;
logic [0:0] k_burstcount;
logic [0:0] k_waitrequest;
logic [63:0] k_readdata;
logic [0:0] k_readdatavalid;
logic [0:0] k_writeack;
logic [24:0] d_address;
logic [0:0] d_read;
logic [0:0] d_write;
logic [511:0] d_writedata;
logic [63:0] d_byteenable;
logic [0:0] d_burstcount;
logic [0:0] d_waitrequest;
logic [511:0] d_readdata;
logic [0:0] d_readdatavalid;
logic [0:0] d_readdataerror;
logic [0:0] fault;
logic [7:0] fault_code;
logic [34:0] fault_address;
logic [0:0] fault_address_valid;
logic [0:0] quiescing;
logic [0:0] drained;
  logic cal_success, cal_fail, amm_ready;
  wire [24:0] amm_address;
  wire amm_read, amm_write;
  wire [511:0] amm_writedata;
  wire [63:0] amm_byteenable;
  wire [6:0] amm_burstcount;
  int scrub_writes=0, client_reads=0, client_writes=0, returns=0;
  logic [511:0] saved_line;
  kernel_ddr_adapter #(.CMD_DEPTH(4), .READ_DEPTH(8)) dut (.*);
  // Reduced scrub range is a test parameter, not a physical aperture claim.
  arria10_ddr_init #(.LAST_ADDRESS(25'd3)) init (
    .clk, .reset_n(cold_reset_n), .cal_success, .cal_fail,
    .initialized(memory_ready), .init_failed(backend_init_failed),
    .client_address(d_address), .client_read(d_read), .client_write(d_write),
    .client_writedata(d_writedata), .client_byteenable(d_byteenable),
    .client_burstcount(d_burstcount), .client_waitrequest(d_waitrequest),
    .amm_ready, .amm_address, .amm_read, .amm_write, .amm_writedata,
    .amm_byteenable, .amm_burstcount);
  always #5 clk = !clk;
  always @(posedge clk) if (cold_reset_n) begin
    if (amm_write && amm_ready && !memory_ready && scrub_writes<4) begin
      if (amm_address !== 25'(scrub_writes) || amm_writedata !== '0 ||
          amm_byteenable !== '1 || amm_burstcount !== 7'd1)
        $fatal(1,"bad ECC scrub sequence");
      scrub_writes++;
    end else if (amm_write && amm_ready) begin
      client_writes++;
      for (int b=0;b<64;b++)
        if (amm_byteenable[b]) saved_line[8*b +: 8] = amm_writedata[8*b +: 8];
    end
    if (amm_read && amm_ready) client_reads++;
    if (k_readdatavalid) begin
      returns++;
      if (k_readdata !== 64'hfedcba9876543210) $fatal(1,"returned wrong lane/data");
    end
  end
  task automatic cycle;
    @(posedge clk); #1; @(negedge clk);
  endtask
  task automatic submit(input bit read_op);
    k_read=read_op; k_write=!read_op; k_address=35'h18;
    k_writedata=64'hfedcba9876543210; k_byteenable=8'hff;
    #1;
    while(k_waitrequest) cycle();
    cycle(); k_read=0; k_write=0;
  endtask
  initial begin
    clk=0; cold_reset_n=0; cal_success=0;cal_fail=0;amm_ready=0;
    backend_ecc_interrupt=0; quiesce_req=0;
    k_read=0;k_write=0;k_address=0;k_writedata=0;k_byteenable='1;k_burstcount=1;
    d_readdatavalid=0;d_readdataerror=0;d_readdata=0;saved_line=0;
    repeat(2) cycle();cold_reset_n=1;
    k_write=1;
    repeat(3) begin cycle();if(!k_waitrequest || amm_read || amm_write) $fatal(1,"traffic before calibration");end
    k_write=0;cal_success=1;cycle();
    // Scrub request remains stable across backpressure.
    repeat(3) begin cycle();if(!amm_write || amm_address!==0 || memory_ready) $fatal(1,"scrub stall");end
    amm_ready=1;
    while(!memory_ready) cycle();
    if(scrub_writes!=4 || fault) $fatal(1,"scrub handoff failed");
    submit(0);cycle();
    if(client_writes!=1 || saved_line[192 +: 64]!==64'hfedcba9876543210) $fatal(1,"client write mapping");
    submit(1);cycle();
    if(client_reads!=1 || drained) $fatal(1,"read ownership lost");
    // Issue another write then stall its downstream offer.
    amm_ready=0;submit(0);cycle();
    if(!amm_write || amm_address!==0) $fatal(1,"missing held write");
    cal_fail=1;cal_success=0;quiesce_req=1;
    repeat(3) begin
      cycle();
      if(!amm_write || amm_writedata[192 +: 64]!==64'hfedcba9876543210 || !k_waitrequest)
        $fatal(1,"calibration fault withdrew accepted command");
    end
    // Backend can still retire previously issued traffic after readiness loss.
    d_readdata=saved_line;d_readdatavalid=1;d_readdataerror=1;
    cycle();d_readdatavalid=0;d_readdataerror=0;
    if(returns!=1 || drained || !fault || !fault_code[4] || !fault_code[5])
      $fatal(1,"fault response/drain contract");
    amm_ready=1;cycle();cycle();
    if(client_writes!=2 || !drained || memory_ready || !backend_init_failed)
      $fatal(1,"final drain or persistent failure lost");
    $display("PASS adapter/initializer integration scrub=%0d writes=%0d reads=%0d returns=%0d",scrub_writes,client_writes,client_reads,returns);
    $finish;
  end
endmodule
