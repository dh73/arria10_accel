module platform_control_tb;
 wire context_bound,context_guard_fault,context_guard_live;
 wire [127:0] bound_session;wire [63:0] bound_epoch;
 logic expect_context_fault=0;
 logic pcie_clk=0;always #7 pcie_clk=~pcie_clk;
 logic health_valid=1;
 logic ddr_read=0,ddr_write=0,ddr_waitrequest=0,ddr_readdatavalid=0;
 logic [63:0] ddr_byteenable=0;
 logic clear_valid=0;logic [15:0] clear_mask=0;
 wire [15:0] fault_pending,first_fault_code,clear_blocked;
 wire [7:0] first_adapter_code;
 wire [40:0] first_adapter_address;
 wire first_adapter_address_valid,clear_done,reset_request,epoch_advance;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,backend_reset_n=0,backend_stall=0;
 logic memory_ready=1,backend_init_failed=0,backend_ecc_interrupt=0;
 logic adapter_fault=0,adapter_fault_address_valid=0;
 logic [7:0] adapter_fault_code=0;
 logic [40:0] adapter_fault_address=0;
 wire adapter_quiescing;
 wire adapter_drained;
 logic host_status_valid=0,host_stop_ack=0,host_fault=0;
 wire host_dma_drained,host_desc_drained,host_writeback_drained;
 wire host_posted_producers_drained,host_tx_local_drained,fence_ready,fence_fault;
 logic external_stop=0,cmd_valid=0;
 logic [2:0] cmd_op=0;
 logic read=0,write=0;
 logic [63:0] address=0;
 logic [31:0] writedata=0;
 logic [3:0] byteenable=15;
 wire waitrequest,readdatavalid,invalid_access;
 wire [31:0] readdata;
 wire cra_read,cra_write,cra_readdatavalid;
 wire [29:0] cra_address;
 wire [63:0] cra_writedata,cra_readdata;
 wire [7:0] cra_byteenable;
 wire cra_waitrequest=backend_stall;
 wire launch_permit,host_submit_permit,kernel_stop_req,host_stop_req,adapter_quiesce_req;
 wire [2:0] state_status,phase_status;
 wire release_ready,fault_latched,cmd_ready,cmd_done,cmd_accepted;
 wire [3:0] cmd_reason;
 wire [15:0] fault_history;
 wire kernel_idle,kernel_stop_ack,kernel_fault,launch_owned,read_pending,write_pending,mailbox_write_permit;
`include "kernel_launch_source_binding.svh"
`include "identity_params.svh"
 platform_provisioned_control_v1 #(.ADDR_W(41),.SOURCE_PROFILE(2),.SOURCE_ID(ID_SOURCE),.BUILD_ID(ID_BUILD),.MGMT_SPACE(2),.CRA_SPACE(32'h80000000),.COPY_SHA(EXPECTED_COPY_SHA),.TRIAD_SHA(EXPECTED_TRIAD_SHA)) dut(.*);
 logic [1:0] done=0;
 wire [1:0] valid,start;
 wire [63:0] data[2];
 wire selected=cra_address>=256;
 assign cra_readdatavalid=|valid;
 assign cra_readdata=valid[1]?data[1]:data[0];
 // Explicitly modeled independent debt. No kernel-idle bit drives these counts.
 int dma_debt=0,desc_debt=0,writeback_debt=0,adapter_debt=0;
 assign adapter_quiescing=adapter_quiesce_req;
 assign adapter_drained=adapter_debt==0;
 assign host_dma_drained=dma_debt==0;
 assign host_desc_drained=desc_debt==0;
 assign host_posted_producers_drained=writeback_debt==0;
 assign host_tx_local_drained=writeback_debt==0; // Explicit status fixture, not actual HIP custody.
 bit new_host_work=0,new_adapter_work=0;
 bit allow_dma=0,allow_desc=0,allow_writeback=0,allow_adapter=0;
 int starts_seen[2]='{0,0};
 int stop_work_debt_cycles=0,blocked_release_cycles=0;
 always @(posedge clk) begin
  if(!cold_reset_n)begin
   host_status_valid<=0;host_stop_ack<=0;
   dma_debt<=0;desc_debt<=0;writeback_debt<=0;adapter_debt<=0;
  end else begin
   host_status_valid<=1;host_stop_ack<=host_stop_req;
   if(new_host_work)begin
    assert(host_submit_permit)else $fatal(1,"model host work admitted while stopped");
    dma_debt<=3;desc_debt<=2;writeback_debt<=4;
   end else begin
    if(allow_dma&&dma_debt!=0)dma_debt<=dma_debt-1;
    if(allow_desc&&desc_debt!=0)desc_debt<=desc_debt-1;
    if(allow_writeback&&writeback_debt!=0)writeback_debt<=writeback_debt-1;
   end
   if(new_adapter_work)begin
    assert(!adapter_quiesce_req)else $fatal(1,"kernel memory admission closed early");
    adapter_debt<=3;
   end else if(allow_adapter&&adapter_debt!=0)adapter_debt<=adapter_debt-1;
   for(int k=0;k<2;k++)if(start[k])starts_seen[k]++;
   if(phase_status==2 && (launch_owned||write_pending))begin
    stop_work_debt_cycles++;
    assert(!adapter_quiesce_req&&!release_ready)else $fatal(1,"STOP_WORK closed accepted kernel memory");
   end
   if(launch_owned||write_pending||dma_debt!=0||desc_debt!=0||writeback_debt!=0||adapter_debt!=0)begin
    blocked_release_cycles++;
    assert(!release_ready)else $fatal(1,"release with independent debt");
   end
   assert((!fault_latched||adapter_fault||expect_context_fault)&&(!kernel_fault||expect_context_fault))else $fatal(1,"unexpected control fault history=%h",fault_history);
  end
 end
`define PORTS(N) \
 .clock(clk),.resetn(cold_reset_n),.acl_counter_full(1'b0),.acl_counter_size(32'b0), \
 .avs_cra_address(cra_address[7:3]),.avs_cra_byteenable(cra_byteenable),.avs_cra_enable(1'b1), \
 .avs_cra_read(cra_read&&!cra_waitrequest&&(selected==N)), \
 .avs_cra_write(cra_write&&!cra_waitrequest&&(selected==N)),.avs_cra_writedata(cra_writedata), \
 .has_a_lsu_active(1'b0),.has_a_write_pending(1'b0),.kernel_done(done[N]),.valid_in(1'b1), \
 .acl_counter_reset(),.avs_cra_readdata(data[N]),.avs_cra_readdatavalid(valid[N]), \
 .cra_irq(),.kernel_arguments(),.kernel_start(start[N]),.status()
 stream_copy512_function_cra_agent copy_agent(`PORTS(0));
 stream_triad512_function_cra_agent triad_agent(`PORTS(1));
`undef PORTS
 task automatic pio(input logic [63:0] a,input logic [31:0] d);
  @(negedge pcie_clk);write=1;address=a;writedata=d;
  do @(posedge pcie_clk);while(waitrequest);
  @(negedge pcie_clk);write=0;wait(!waitrequest);
 endtask
 task automatic pio_read(input logic [63:0] a,output logic [31:0] d);
  @(negedge pcie_clk);read=1;address=a;
  do @(posedge pcie_clk);while(waitrequest);
  @(negedge pcie_clk);read=0;
  wait(readdatavalid);d=readdata;@(negedge pcie_clk);
 endtask
 task automatic settle_host;
  logic [31:0] value;
  logic [255:0] token;
  wait(fence_ready);
  pio_read(512,value);assert(value==1)else $fatal(1,"fence not ready");
  for(int i=0;i<8;i++)begin pio_read(516+4*i,value);token[i*32+:32]=value;end
  assert(token[191:0]=={bound_session,bound_epoch})else $fatal(1,"wrong immutable fence context");
  for(int i=0;i<8;i++)pio(516+4*i,token[i*32+:32]);
  // Ordered same-function read fixture before commit.
  pio_read(532,value);pio(548,32'ha10f0001);pio_read(512,value);
  assert(value==3&&host_writeback_drained&&!fence_fault)else $fatal(1,"fence settlement rejected");
 endtask
 task automatic read_cra(input int a);
  reg [31:0] status;
  pio(0,32'(a));pio(16,2);
  status=1;while(status[0])pio_read(20,status);
  wait(!read_pending&&!cra_read&&!cra_readdatavalid);@(negedge clk);
 endtask
 logic [63:0] control_request_id=0;
 logic [31:0] control_status,control_reason;
 task automatic command(input logic [2:0] op);
  logic [31:0] lo,hi;
  control_request_id++;
  pio(576,control_request_id[31:0]);pio(580,control_request_id[63:32]);pio(584,{29'd0,op});
  pio_read(596,control_reason);pio(588,32'ha10c0001);
  control_status=1;while(control_status==1)pio_read(592,control_status);
  assert(control_status==2 || control_status==6)else $fatal(1,"control result absent %h",control_status);
  pio_read(600,lo);pio_read(604,hi);pio_read(596,control_reason);
  assert({hi,lo}==control_request_id)else $fatal(1,"control result ID mismatch");
 endtask
 task automatic open_platform(input logic [2:0] op);
  assert(release_ready)else $fatal(1,"open without retired barrier");
  command(op);
  assert(control_status==6&&control_reason==0&&!fault_latched)else $fatal(1,"opening rejected %0d",control_reason);
  wait(launch_permit);#1;
  assert(!kernel_stop_ack&&!host_stop_ack&&!kernel_stop_req&&!adapter_quiesce_req&&mailbox_write_permit)
    else $fatal(1,"producer acknowledgement failed to reopen");
 endtask
 task automatic provision;
  logic [31:0] status;
  pio(776,9);pio(780,0);
  for(int i=0;i<4;i++)pio(784+4*i,i+1);
  assert(!context_bound&&!launch_permit&&!host_submit_permit)
   else $fatal(1,"partial provisioning enabled platform");
  pio(768,32'ha10e0001);pio_read(772,status);
  assert(status==1)else $fatal(1,"provisioning failed");
  wait(context_bound);
 endtask
 task automatic inject_context_change(input int testcase);
  logic [31:0] status;
  @(negedge clk);expect_context_fault=1;
  // Replacement write or second commit through actual BAR2/CDC must revoke
  // authority without replacing the retained owner or erasing accepted work.
  if(testcase<2)pio(784,32'h9999);else pio(768,32'ha10e0001);
  pio_read(772,status);
  assert(status==2 && !launch_permit&&!host_submit_permit&&!mailbox_write_permit)
    else $fatal(1,"invalid provisioning did not close admissions");
  assert(context_guard_fault&&fault_latched&&kernel_fault)else $fatal(1,"context fault not latched");
  pio(784,1);pio_read(772,status);
  assert(status==2&&!launch_permit&&!host_submit_permit&&context_guard_fault)
    else $fatal(1,"context restoration reopened admission");
 endtask
 reg [31:0] identity_word;
 int cases=0,previous_starts;
 initial begin
  repeat(3)@(negedge clk);cold_reset_n=1;backend_reset_n=1;
  repeat(5)@(negedge clk);
  assert(!context_bound&&!release_ready&&phase_status==0&&!launch_permit&&!host_submit_permit)
   else $fatal(1,"unbound initialization escaped HOLD");
  provision();
  settle_host();wait(release_ready);@(negedge clk);
  pio_read(256,identity_word);
  assert(identity_word==32'h31444941)else $fatal(1,"identity magic mismatch %h",identity_word);
  open_platform(0);
  command(2);assert(control_status==6&&control_reason==0)else $fatal(1,"MMIO QUIESCE rejected");
  settle_host();wait(release_ready);wait(phase_status==4);open_platform(1);
  $display("MMIO_SUPERVISOR_START_QUIESCE_RESUME_PASS");
  for(int testcase=0;testcase<4;testcase++)begin
   int k;k=testcase%2;
   @(negedge clk);new_host_work=1;
   @(posedge clk);@(negedge clk);new_host_work=0;
   pio(0,32'(k*256+8));pio(4,1);pio(8,0);pio(12,255);
   previous_starts=starts_seen[k];backend_stall=(k==0);pio(16,1);
   if(k==0)begin
    assert(write_pending&&!launch_owned)else $fatal(1,"pending case did not stall");
    inject_context_change(testcase);repeat(4)@(negedge clk);
    assert(phase_status==2&&!adapter_quiesce_req&&!kernel_stop_ack&&!mailbox_write_permit)
      else $fatal(1,"pending STOP_WORK sequencing");
    backend_stall=0;
   end else begin
    wait(launch_owned);inject_context_change(testcase);
    repeat(3)@(negedge clk);
    assert(phase_status==2&&!adapter_quiesce_req&&kernel_stop_ack&&!kernel_idle)
      else $fatal(1,"accepted STOP_WORK sequencing");
   end
   wait(starts_seen[k]>previous_starts);
   @(negedge clk);new_adapter_work=1;
   @(posedge clk);@(negedge clk);new_adapter_work=0;
   read_cra(k*256);read_cra(k*256+48);
   assert(launch_owned&&!kernel_idle&&!adapter_quiesce_req)else $fatal(1,"status/zero retired computation");
   repeat(5)@(negedge clk);
   // Actual corrected generated counter: completion races the sampling read.
   pio(0,32'(k*256+48));
   fork
    pio(16,2);
    begin wait(cra_read);done[k]=1;@(posedge clk);@(negedge clk);done[k]=0;end
   join
   wait(!read_pending&&!cra_read&&!cra_readdatavalid);
   read_cra(k*256+48);
   assert(kernel_idle&&kernel_stop_ack&&!launch_owned)else $fatal(1,"real matching completion did not retire");
   repeat(3)@(negedge clk);
   assert(phase_status==2&&!adapter_quiesce_req&&!release_ready)else $fatal(1,"host debt ignored");
   allow_dma=1;wait(host_dma_drained);@(negedge clk);
   assert(!release_ready&&!adapter_quiesce_req)else $fatal(1,"descriptor/writeback debt ignored");
   allow_desc=1;wait(host_desc_drained);@(negedge clk);
   assert(!release_ready&&!adapter_quiesce_req)else $fatal(1,"writeback debt ignored");
   allow_writeback=1;wait(writeback_debt==0);settle_host();wait(host_writeback_drained);wait(adapter_quiesce_req);@(negedge clk);
   assert(!release_ready&&adapter_debt==3&&phase_status==3)else $fatal(1,"adapter debt ignored");
   repeat(4)@(negedge clk);allow_adapter=1;wait(adapter_drained);wait(release_ready);
   wait(phase_status==4);@(negedge clk);
   assert(kernel_stop_ack&&kernel_idle&&host_stop_ack&&adapter_quiescing&&fault_latched&&context_guard_fault)
     else $fatal(1,"release barrier incomplete");
   cases++;allow_dma=0;allow_desc=0;allow_writeback=0;allow_adapter=0;
   assert(bound_session=={32'd4,32'd3,32'd2,32'd1} && bound_epoch==9)
    else $fatal(1,"identity rebound to replacement context");
   $display("CONTEXT_CUSTODY_DRAIN_PASS testcase=%0d pending=%0d loss=%0d",testcase,k==0,testcase>=2);
   if(testcase!=3)begin
    // Only a coordinated reset AFTER every debt is retired starts the next test epoch.
    @(negedge clk);cold_reset_n=0;backend_reset_n=0;expect_context_fault=0;
    repeat(4)@(negedge clk);cold_reset_n=1;backend_reset_n=1;
    provision();settle_host();wait(release_ready);@(negedge clk);open_platform(0);
   end
  end
  assert(cases==4&&stop_work_debt_cycles>0&&blocked_release_cycles>0&&!invalid_access)
    else $fatal(1,"composition coverage missing");
  // Context was the first fault: preserve its diagnostic, never overwrite it.
  assert(first_fault_code[4] && !first_adapter_address_valid)
   else $fatal(1,"context first fault diagnostic lost");
  begin
   integer fd;fd=$fopen("identity-reads.txt","w");
   assert(fd!=0)else $fatal(1,"transcript open failed");
   for(int n=0;n<72;n++)begin
    pio_read(256+(n<6?n*4:(n==6||n==71?24:(n-7)*4)),identity_word);
    $fdisplay(fd,"%08x",identity_word);
   end
   $fclose(fd);
  end
  $display("PLATFORM_PROVISIONED_CONTROL_PASS cases=%0d stop_work_debt_cycles=%0d blocked_release_cycles=%0d",cases,stop_work_debt_cycles,blocked_release_cycles);
  $finish;
 end
endmodule
