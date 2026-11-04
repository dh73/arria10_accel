`timescale 1ns/1ps
module streaming_kernel_execution_tb;
logic [0:0] clk;
logic [0:0] cold_reset_n;
logic [0:0] memory_ready;
logic [0:0] backend_init_failed;
logic [0:0] backend_ecc_interrupt;
logic [0:0] quiesce_req;
logic [0:0] k_read;
logic [0:0] k_write;
logic [34:0] k_address;
logic [511:0] k_writedata;
logic [63:0] k_byteenable;
logic [0:0] k_burstcount;
logic [0:0] k_waitrequest;
logic [511:0] k_readdata;
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
  logic cra_read=0,cra_write=0;
  logic [7:0] cra_byteenable=8'hff;
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
    .kernel_cra_writedata(cra_writedata),.kernel_cra_byteenable(cra_byteenable),
    .kernel_cra_waitrequest(cra_waitrequest),.kernel_cra_readdata(cra_readdata),
    .kernel_cra_readdatavalid(cra_readdatavalid),.kernel_irq_irq(irq),.device_exception_bus(exceptions));
  kernel_ddr_width_adapter #(.DATA_W(512)) adapter (.*);
  byte unsigned memory [];
  int count, stride;
  string input_file, expected_file;
  logic [511:0] responses[$];
  logic [511:0] response_line;
  logic [31:0] expected[];
  int cycles=0, reads=0,writes=0,returns=0;
  int full_writes=0, write_bytes=0, active_output=-1;
  always #5 clk=!clk;
  always @(posedge clk) if(cold_reset_n) begin
    cycles++;
    if(fault) $fatal(1,"adapter fault %h address %h",fault_code,fault_address);
    if($isunknown({k_read,k_write,d_read,d_write})) $fatal(1,"unknown request");
    if((d_read||d_write)&&!d_waitrequest) begin
      if((longint'(d_address)*64+63)>=memory.size() || $isunknown({d_address,d_byteenable})) $fatal(1,"invalid model address");
      if(d_write) begin
        for(int b=0;b<64;b++) if(d_byteenable[b]) begin
          if($isunknown(d_writedata[b*8+:8])) $fatal(1,"unknown enabled write byte");
          if (!(active_output>=0 && d_address*64+b >= active_output &&
                d_address*64+b < active_output+count*4))
            $fatal(1,"write outside result buffers");
          memory[d_address*64+b]=d_writedata[b*8+:8];
        end
        writes++;
        write_bytes += $countones(d_byteenable);
        if(d_byteenable==64'hffffffffffffffff) full_writes++;
      end
      if(d_read) begin
        for(int b=0;b<64;b++) response_line[b*8+:8]=memory[d_address*64+b];
        responses.push_back(response_line);reads++;
      end
    end
    if(d_readdatavalid) returns++;
  end
  always @(negedge clk) begin
    d_waitrequest = !cold_reset_n || (cycles%7==3);
    d_readdatavalid=0;
    if(cold_reset_n && responses.size()!=0 && cycles%3!=1) begin
      d_readdata=responses.pop_front();d_readdatavalid=1;
    end
  end
  task automatic write_csr(input int address,input logic[63:0] value);
    @(negedge clk);cra_byteenable=8'hff;cra_address=30'(address);cra_writedata=value;cra_write=1;#1;
    while(cra_waitrequest) begin @(negedge clk);#1;end
    @(posedge clk);@(negedge clk);cra_write=0;
  endtask
  task automatic write_arg_csr(input int address,input logic[63:0] value,input logic[7:0] mask);
    @(negedge clk);cra_byteenable=mask;cra_address=30'(address);cra_writedata=value;cra_write=1;#1;
    while(cra_waitrequest) begin @(negedge clk);#1;end
    @(posedge clk);@(negedge clk);cra_write=0;cra_byteenable=8'hff;
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
    logic [63:0] status;
    int start_cycles,start_reads,start_writes,start_returns,start_bytes,start_full;
    active_output=output_base;
`ifdef STREAM_GENERATED_LAUNCH
    `include "stream_launch.svh"
`else
    // Generated CRA packs 32-bit count followed by 64-bit pointers.
    write_csr(base+128,{32'(output_base),32'(count)});
    write_csr(base+136,{32'(first_input),32'b0});
    if(base==0) write_csr(base+144,64'b0);
    else begin
      write_csr(base+144,{32'(stride+64),32'b0});
      write_csr(base+152,{32'd7,32'b0});
    end
`endif
    read_csr(base,status);$display("launch base=%h status=%h",base,status);
    start_cycles=cycles;start_reads=reads;start_writes=writes;
    start_returns=returns;start_bytes=write_bytes;start_full=full_writes;
    write_csr(base+8,1);
    do read_csr(base,status); while(!status[1]);
    $display("completed base=%h status=%h cycles=%0d",base,status,cycles);
    wait(drained); // Actual accepted downstream work must also reconcile.
    @(negedge clk);
    if(write_bytes-start_bytes != count*4) $fatal(1,"duplicate/missing enabled output bytes");
    if(reads-start_reads != returns-start_returns) $fatal(1,"unreconciled kernel reads");
    $display("STREAM_METRIC base=%0d count=%0d reads=%0d writes=%0d full_writes=%0d write_bytes=%0d cycles=%0d",base,count,reads-start_reads,writes-start_writes,full_writes-start_full,write_bytes-start_bytes,cycles-start_cycles);
    active_output=-1;
  endtask
  initial begin
    clk=0;cold_reset_n=0;memory_ready=0;backend_init_failed=0;backend_ecc_interrupt=0;
    quiesce_req=0;d_waitrequest=1;d_readdata=0;d_readdatavalid=0;d_readdataerror=0;
    if(!$value$plusargs("COUNT=%d",count)) count=17;
    if(count<1) $fatal(1,"positive fixture count required");
    stride=((count*4+127)/64)*64;
    memory=new[4*stride];expected=new[count];
    foreach(memory[i]) memory[i]=8'hcd;
    for(int i=0;i<count;i++) begin
      logic [31:0] a,b;
      a=32'(i)*32'h9e3779b1+32'hfffffff0;
      b=32'(i)^32'ha5a55a5a;
      expected[i]=a+b*32'd7;
      for(int k=0;k<4;k++) begin
        memory[64+4*i+k]=a[8*k+:8];
        memory[stride+64+4*i+k]=b[8*k+:8];
      end
    end
    repeat(8) @(negedge clk);cold_reset_n=1;memory_ready=1;
    repeat(32) @(negedge clk);
    launch(0,2*stride+64,64);
    for(int i=0;i<count*4;i++)
      if(memory[2*stride+64+i]!==memory[64+i]) $fatal(1,"copy mismatch byte=%0d",i);
    launch(256,3*stride+64,2*stride+64);
    for(int i=0;i<count;i++) begin
      if({memory[3*stride+64+4*i+3],memory[3*stride+64+4*i+2],memory[3*stride+64+4*i+1],memory[3*stride+64+4*i]} !== expected[i])
        $fatal(1,"kernel result mismatch index=%0d expected=%h",i,expected[i]);
    end
    // This compiler variant declares device_exception_bus but never drives it.
    // Record it as unavailable; platform fault reporting is still an integration gate.
    $display("traffic reads=%0d writes=%0d returns=%0d drained=%b exception_bus=%h (undriven in generated source)",reads,writes,returns,drained,exceptions);
    if(reads==0 || writes==0 || reads!=returns || !drained)
      $fatal(1,"missing traffic or outstanding work");
    $display("PASS wide streaming kernels count=%0d reads=%0d writes=%0d returns=%0d cycles=%0d",count,reads,writes,returns,cycles);
    $finish;
  end
endmodule
