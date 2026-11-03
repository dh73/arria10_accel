`timescale 1ns/1ps
// Integration test: scheduler bookkeeping is a test driver observing real CSR
// start/completion. Host DMA is absent; its drain inputs represent no host work.
module initialized_kernel_execution_tb;
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
logic [24:0] amm_address;
logic [0:0] amm_read;
logic [0:0] amm_write;
logic [511:0] amm_writedata;
logic [63:0] amm_byteenable;
logic [6:0] amm_burstcount;
logic amm_waitrequest;
wire amm_ready = !amm_waitrequest;
logic cal_success=0, cal_fail=0;
int scrub_writes=0;
logic [511:0] amm_readdata;
logic [0:0] amm_readdatavalid;
logic [0:0] amm_readdataerror;
logic [0:0] fault;
logic [7:0] fault_code;
logic [34:0] fault_address;
logic [0:0] fault_address_valid;
logic [0:0] quiescing;
logic [0:0] drained;
  logic cra_read=0,cra_write=0;
  logic [29:0] cra_address=0;
  logic [63:0] cra_writedata=0;
  wire cra_waitrequest,cra_readdatavalid,irq;
  wire [63:0] cra_readdata,exceptions;
  wire unused_enable;
  kernel_system kernel (
    .clock_reset_clk(clk),.clock_reset_reset_reset_n(cold_reset_n),.cc_snoop_clk_clk(clk),
    .mem0_rw_enable(unused_enable),.mem0_rw_read(k_read),.mem0_rw_write(k_write),
    .mem0_rw_address(k_address),.mem0_rw_writedata(k_writedata),.mem0_rw_byteenable(k_byteenable),
    .mem0_rw_burstcount(k_burstcount),.mem0_rw_waitrequest(k_waitrequest),
    .mem0_rw_readdata(k_readdata),.mem0_rw_readdatavalid(k_readdatavalid),.mem0_rw_writeack(k_writeack),
    .kernel_cra_debugaccess(1'b0),.kernel_cra_burstcount(1'b1),.kernel_cra_enable(1'b1),
    .kernel_cra_read(cra_read),.kernel_cra_write(cra_write),.kernel_cra_address(cra_address),
    .kernel_cra_writedata(cra_writedata),.kernel_cra_byteenable(8'hff),
    .kernel_cra_waitrequest(cra_waitrequest),.kernel_cra_readdata(cra_readdata),
    .kernel_cra_readdatavalid(cra_readdatavalid),.kernel_irq_irq(irq),.device_exception_bus(exceptions));

  logic kernel_idle=1, kernel_stop_ack=1, host_stop_ack=1;
  logic external_stop=0, cmd_valid=0;
  logic [2:0] cmd_op=0;
  wire launch_permit, host_submit_permit, kernel_stop_req, host_stop_req;
  wire release_ready, supervisor_fault, cmd_ready, cmd_done, cmd_accepted;
  wire [3:0] cmd_reason;
  wire [2:0] state_status, phase_status;
  int traffic_during_stop=0, stops_completed=0;
  platform_initialized_ddr #(.SCRUB_LAST_ADDRESS(25'd127)) dut (
    .clk(clk),.cold_reset_n(cold_reset_n),.memory_ready(memory_ready),
    .cal_success(cal_success), .cal_fail(cal_fail), .backend_init_failed(backend_init_failed),.backend_ecc_interrupt(backend_ecc_interrupt),
    .adapter_fault(fault),.adapter_fault_code(fault_code),
    .adapter_fault_address(fault_address),.adapter_fault_address_valid(fault_address_valid),
    .adapter_quiescing(quiescing),.adapter_drained(drained),
    .k_read, .k_write, .k_address, .k_writedata, .k_byteenable, .k_burstcount,
    .k_waitrequest, .k_readdata, .k_readdatavalid, .k_writeack,
    .amm_address, .amm_read, .amm_write, .amm_writedata, .amm_byteenable,
    .amm_burstcount, .amm_ready, .amm_readdata, .amm_readdatavalid, .amm_readdataerror,
    .kernel_status_valid(1'b1),.kernel_stop_ack(kernel_stop_ack),
    .kernel_idle(kernel_idle),.kernel_fault(1'b0),
    .host_status_valid(1'b1),.host_stop_ack(host_stop_ack),
    .host_dma_drained(1'b1),.host_desc_drained(1'b1),.host_writeback_drained(1'b1),
    .host_fault(1'b0),.external_stop(external_stop),
    .cmd_valid(cmd_valid),.cmd_op(cmd_op),.clear_valid(1'b0),.clear_mask(16'b0),
    .launch_permit(launch_permit),.host_submit_permit(host_submit_permit),
    .kernel_stop_req(kernel_stop_req),.host_stop_req(host_stop_req),
    .adapter_quiesce_req(quiesce_req),.state_status(state_status),.phase_status(phase_status),
    .release_ready(release_ready),.fault_latched(supervisor_fault),
    .cmd_ready(cmd_ready),.cmd_done(cmd_done),.cmd_accepted(cmd_accepted),.cmd_reason(cmd_reason)
  );
  always @(posedge clk) if(cold_reset_n) begin
    if(!memory_ready && (launch_permit || host_submit_permit)) $fatal(1,"admission before initialization");
    if(supervisor_fault) $fatal(1,"unexpected supervisor fault");
    if(external_stop && (launch_permit || host_submit_permit))
      $fatal(1,"launch admission during stop");
    if(external_stop && !kernel_idle) begin
      if(quiesce_req || release_ready) $fatal(1,"running kernel memory closed or released");
      if((amm_read || amm_write) && !amm_waitrequest) traffic_during_stop++;
    end
  end
  task automatic supervisor_command(input logic [2:0] operation);
    @(negedge clk);
    if(!cmd_ready) $fatal(1,"supervisor command not ready");
    cmd_op=operation; cmd_valid=1;
    @(posedge clk); #1;
    @(negedge clk); cmd_valid=0;
    while(!cmd_done) begin @(posedge clk); #1; end
    if(!cmd_accepted) $fatal(1,"supervisor rejected command %0d reason %0d",operation,cmd_reason);
    @(negedge clk); kernel_stop_ack=0; host_stop_ack=0; #1;
    if(!launch_permit) $fatal(1,"start/resume failed admission");
  endtask
  byte unsigned memory [];
  int count, stride;
  string input_file, expected_file;
  logic [511:0] responses[$];
  logic [511:0] response_line;
  logic [31:0] expected[];
  int cycles=0, reads=0,writes=0,returns=0;
  always #5 clk=!clk;
  always @(posedge clk) if(cold_reset_n) begin
    cycles++;
    if(fault) $fatal(1,"adapter fault %h address %h",fault_code,fault_address);
    if($isunknown({k_read,k_write,amm_read,amm_write})) $fatal(1,"unknown request");
    if((amm_read||amm_write)&&!amm_waitrequest) begin
      if((longint'(amm_address)*64+63)>=memory.size() || $isunknown({amm_address,amm_byteenable})) $fatal(1,"invalid model address");
      if(amm_write) begin
        for(int b=0;b<64;b++) if(amm_byteenable[b]) begin
          if($isunknown(amm_writedata[b*8+:8])) $fatal(1,"unknown enabled write byte");
          if (memory_ready && !((amm_address*64+b >= 2*stride+64 && amm_address*64+b < 2*stride+64+count*4) ||
                (amm_address*64+b >= 3*stride+64 && amm_address*64+b < 3*stride+64+count*4)))
            $fatal(1,"write outside result buffers");
          memory[amm_address*64+b]=amm_writedata[b*8+:8];
        end
        if(memory_ready) writes++;
        else begin
          if(amm_address!==25'(scrub_writes) || amm_writedata!=='0 ||
             amm_byteenable!=='1 || amm_burstcount!==7'd1 || !cal_success)
            $fatal(1,"bad scrub sequence");
          scrub_writes++;
        end
      end
      if(amm_read) begin
        for(int b=0;b<64;b++) response_line[b*8+:8]=memory[amm_address*64+b];
        responses.push_back(response_line);reads++;
      end
    end
    if(amm_readdatavalid) returns++;
  end
  always @(negedge clk) begin
    amm_waitrequest = !cold_reset_n || (cycles%7==3);
    amm_readdatavalid=0;
    if(cold_reset_n && responses.size()!=0 && cycles%3!=1) begin
      amm_readdata=responses.pop_front();amm_readdatavalid=1;
    end
  end
  task automatic write_csr(input int address,input logic[63:0] value);
    @(negedge clk);cra_address=30'(address);cra_writedata=value;cra_write=1;#1;
    while(cra_waitrequest) begin @(negedge clk);#1;end
    @(posedge clk);@(negedge clk);cra_write=0;
  endtask
  task automatic read_csr(input int address,output logic[63:0] value);
    @(negedge clk);cra_address=30'(address);cra_read=1;#1;
    while(cra_waitrequest) begin @(negedge clk);#1;end
    @(posedge clk);#1;
    if(cra_readdatavalid) begin value=cra_readdata;@(negedge clk);cra_read=0;end
    else begin
      @(negedge clk);cra_read=0;
      do begin @(posedge clk);#1;end while(!cra_readdatavalid);
      value=cra_readdata;
    end
    if($isunknown(value)) $fatal(1,"unknown CSR read at %h",address);
  endtask
  task automatic launch(input int base,input int output_base,input int first_input);
    logic [63:0] args[13];logic[63:0] status;
    int stop_traffic_start;
    args[0]=count;
    args[1]=64'(output_base);args[2]=count;args[3]=count;args[4]=0;
    args[5]=64'(first_input);args[6]=count;args[7]=count;args[8]=0;
    args[9]=64'(stride+64);args[10]=count;args[11]=count;args[12]=0;
    for(int a=0;a<13;a++) write_csr(base+128+a*8,args[a]);
    read_csr(base,status);$display("launch base=%h status=%h",base,status);
    if(!launch_permit || !kernel_idle) $fatal(1,"launch without admission/idle");
    kernel_idle=0; // Test scheduler owns launch until its real CSR completes.
    write_csr(base+8,1);
    @(negedge clk); external_stop=1; kernel_stop_ack=1; host_stop_ack=1;
    stop_traffic_start=traffic_during_stop;
    do read_csr(base,status); while(!status[1]);
    $display("completed base=%h status=%h cycles=%0d",base,status,cycles);
    @(negedge clk); kernel_idle=1;
    wait(release_ready); #1;
    if(!drained || reads!=returns || responses.size()!=0)
      $fatal(1,"supervisor release before memory drain");
    if(traffic_during_stop==stop_traffic_start)
      $fatal(1,"test did not exercise memory traffic during stop");
    if(launch_permit || host_submit_permit) $fatal(1,"admission reopened without resume");
    stops_completed++;
    // PARKED is registered after the barrier is observed.
    do begin @(negedge clk); end while(phase_status!=4);
  endtask
  initial begin
    clk=0;cold_reset_n=0;backend_ecc_interrupt=0;
    amm_waitrequest=1;amm_readdata=0;amm_readdatavalid=0;amm_readdataerror=0;
    if(!$value$plusargs("COUNT=%d",count)) count=17;
    if(count<1 || count>1000003) $fatal(1,"invalid fixture count");
    if(!$value$plusargs("INPUT=%s",input_file) || !$value$plusargs("EXPECTED=%s",expected_file))
      $fatal(1,"fixture paths required");
    stride=((count*4+127)/64)*64;
    memory=new[(4*stride>8192)?4*stride:8192];expected=new[count];
    foreach(memory[i]) memory[i]=8'hcd;

    $readmemh(expected_file,expected);
    repeat(8) @(negedge clk);cold_reset_n=1;
    repeat(8) @(negedge clk);
    if(amm_read || amm_write || memory_ready) $fatal(1,"traffic before calibration");
    cal_success=1;
    wait(memory_ready); @(negedge clk);
    if(scrub_writes!=128) $fatal(1,"incomplete scrub");
    for(int i=0;i<8192;i++) if(memory[i]!==0) $fatal(1,"nonzero scrub byte");
    $readmemh(input_file,memory);
    repeat(32) @(negedge clk);
    supervisor_command(0);
    launch(0,2*stride+64,64);
    @(negedge clk); external_stop=0;
    supervisor_command(1);
    launch(256,3*stride+64,2*stride+64);
    if(stops_completed!=2 || !release_ready) $fatal(1,"missing stop/resume coverage");
    for(int i=0;i<count;i++) begin
      if({memory[3*stride+64+4*i+3],memory[3*stride+64+4*i+2],memory[3*stride+64+4*i+1],memory[3*stride+64+4*i]} !== expected[i])
        $fatal(1,"kernel result mismatch index=%0d expected=%h",i,expected[i]);
    end
    // This compiler variant declares device_exception_bus but never drives it.
    // Record it as unavailable; platform fault reporting is still an integration gate.
    $display("traffic reads=%0d writes=%0d returns=%0d drained=%b exception_bus=%h (undriven in generated source)",reads,writes,returns,drained,exceptions);
    if(reads==0 || writes==0 || reads!=returns || !drained)
      $fatal(1,"missing traffic or outstanding work");
    $display("PASS initialized kernels scrub=128 count=%0d reads=%0d writes=%0d returns=%0d cycles=%0d",count,reads,writes,returns,cycles);
    $finish;
  end
endmodule
