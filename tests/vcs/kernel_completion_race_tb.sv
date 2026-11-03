`timescale 1ns/1ps
module kernel_completion_race_tb;
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
  kernel_ddr_adapter adapter (.*);
  byte unsigned memory [];
  int count, stride;
  string input_file, expected_file;
  logic [511:0] responses[$];
  logic [511:0] response_line;
  logic [31:0] expected[];
  int cycles=0, reads=0,writes=0,returns=0;
  int phase_offset=0, conservation_failures=0;
  int finish_edges[2]='{0,0};
  logic [1:0] last_finish=0;
  wire [1:0] actual_finish={
    kernel.workload_es3_default_early_sys.device_image_ip.Pass2Kernel_std_ic_inst.Pass2Kernel_finish_sig,
    kernel.workload_es3_default_early_sys.device_image_ip.Pass1Kernel_std_ic_inst.Pass1Kernel_finish_sig};
  // Read-only observation terminates the test independently of the suspect CSR.
  // Neither the completion nor any internal DUT state is driven by the test.
  always @(posedge clk) begin
    if(!cold_reset_n) last_finish<=0;
    else begin
      for(int k=0;k<2;k++) if(actual_finish[k] && !last_finish[k]) finish_edges[k]++;
      last_finish<=actual_finish;
    end
  end
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
          if (!((d_address*64+b >= 2*stride+64 && d_address*64+b < 2*stride+64+count*4) ||
                (d_address*64+b >= 3*stride+64 && d_address*64+b < 3*stride+64+count*4)))
            $fatal(1,"write outside result buffers");
          memory[d_address*64+b]=d_writedata[b*8+:8];
        end
        writes++;
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
    longint unsigned observed; int before_finish, idx;
    args[0]=count;
    args[1]=64'(output_base);args[2]=count;args[3]=count;args[4]=0;
    args[5]=64'(first_input);args[6]=count;args[7]=count;args[8]=0;
    args[9]=64'(stride+64);args[10]=count;args[11]=count;args[12]=0;
    for(int a=0;a<13;a++) write_csr(base+128+a*8,args[a]);
    read_csr(base+48,status);
    if(status != 0) $fatal(1,"unreconciled completion before launch base=%h count=%h",base,status);
    idx=base/256; before_finish=finish_edges[idx]; observed=0;
    write_csr(base+8,1);
    repeat(phase_offset) @(negedge clk);
    // Public CRA reads, each respecting waitrequest and response validity.
    // This is simulated adversarial bus traffic, not agent job polling.
    while(finish_edges[idx]==before_finish) begin
      read_csr(base+48,status); observed+=status;
    end
    repeat(2) begin read_csr(base+48,status); observed+=status; end
    if(finish_edges[idx]!=before_finish+1) $fatal(1,"unexpected finish multiplicity");
    $display("CONSERVATION base=%0d phase=%0d total=%0d",base,phase_offset,observed);
    if(observed!=1) conservation_failures++;
    wait(drained); // Actual accepted downstream work must also reconcile.
  endtask
  initial begin
    clk=0;cold_reset_n=0;memory_ready=0;backend_init_failed=0;backend_ecc_interrupt=0;
    quiesce_req=0;d_waitrequest=1;d_readdata=0;d_readdatavalid=0;d_readdataerror=0;
    if(!$value$plusargs("COUNT=%d",count)) count=17;
    if(count<1 || count>1000003) $fatal(1,"invalid fixture count");
    if(!$value$plusargs("INPUT=%s",input_file) || !$value$plusargs("EXPECTED=%s",expected_file))
      $fatal(1,"fixture paths required");
    stride=((count*4+127)/64)*64;
    memory=new[4*stride];expected=new[count];
    foreach(memory[i]) memory[i]=8'hcd;
    $readmemh(input_file,memory);
    $readmemh(expected_file,expected);
    repeat(8) @(negedge clk);cold_reset_n=1;memory_ready=1;
    repeat(32) @(negedge clk);
    for(int round=0;round<16;round++) begin
      phase_offset=round;
      // Every output word differs from the oracle before each launch pair.
      // Poison the intermediate too, preventing reuse of previous Pass1 data.
      for(int i=0;i<count;i++) begin
        for(int b=0;b<4;b++) begin
          memory[2*stride+64+4*i+b]=8'(32'hdeadc000+round+i);
          memory[3*stride+64+4*i+b]=~expected[i][8*b+:8];
        end
      end
      launch(0,2*stride+64,64);launch(256,3*stride+64,2*stride+64);
    for(int i=0;i<count;i++) begin
      if({memory[3*stride+64+4*i+3],memory[3*stride+64+4*i+2],memory[3*stride+64+4*i+1],memory[3*stride+64+4*i]} !== expected[i])
        $fatal(1,"kernel result mismatch index=%0d expected=%h",i,expected[i]);
    end
      if(reads != 4*count*(round+1) || writes != 2*count*(round+1) || returns != reads)
        $fatal(1,"missing fresh per-launch traffic round=%0d",round);
      $display("round=%0d checked=%0d reads=%0d writes=%0d",round,count,reads,writes);
    end
    // This compiler variant declares device_exception_bus but never drives it.
    // Record it as unavailable; platform fault reporting is still an integration gate.
    $display("traffic reads=%0d writes=%0d returns=%0d drained=%b exception_bus=%h (undriven in generated source)",reads,writes,returns,drained,exceptions);
    if(reads==0 || writes==0 || reads!=returns || !drained)
      $fatal(1,"missing traffic or outstanding work");
    if(conservation_failures) $fatal(1,"whole-kernel completion conservation failures=%0d",conservation_failures);
    $display("PASS kernel completion race rounds=16 count=%0d reads=%0d writes=%0d returns=%0d cycles=%0d",count,reads,writes,returns,cycles);
    $finish;
  end
endmodule
