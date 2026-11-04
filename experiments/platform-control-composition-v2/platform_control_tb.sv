module platform_control_tb;
 logic pcie_clk=0;always #7 pcie_clk=~pcie_clk;
 logic context_valid=1,health_valid=1;
 logic [127:0] session={32'd4,32'd3,32'd2,32'd1};
 logic [63:0] epoch=9;
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
 platform_control_composition #(.ADDR_W(41),.SOURCE_PROFILE(2),.SOURCE_ID(ID_SOURCE),.BUILD_ID(ID_BUILD),.MGMT_SPACE(2),.CRA_SPACE(32'h80000000),.COPY_SHA(EXPECTED_COPY_SHA),.TRIAD_SHA(EXPECTED_TRIAD_SHA)) dut(.*);
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
 assign host_writeback_drained=writeback_debt==0;
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
   assert((!fault_latched||adapter_fault)&&!kernel_fault)else $fatal(1,"unexpected control fault history=%h",fault_history);
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
 task automatic read_cra(input int a);
  reg [31:0] status;
  pio(0,32'(a));pio(16,2);
  status=1;while(status[0])pio_read(20,status);
  wait(!read_pending&&!cra_read&&!cra_readdatavalid);@(negedge clk);
 endtask
 task automatic command(input logic [2:0] op);
  @(negedge clk);assert(cmd_ready)else $fatal(1,"command not ready");cmd_op=op;cmd_valid=1;
  @(posedge clk);@(negedge clk);cmd_valid=0;
 endtask
 task automatic open_platform(input logic [2:0] op);
  assert(release_ready)else $fatal(1,"open without retired barrier");
  command(op);wait(cmd_done);#1;
  assert(cmd_accepted&&!fault_latched)else $fatal(1,"opening rejected %0d",cmd_reason);
  wait(launch_permit);#1;
  assert(!kernel_stop_ack&&!host_stop_ack&&!kernel_stop_req&&!adapter_quiesce_req&&mailbox_write_permit)
    else $fatal(1,"producer acknowledgement failed to reopen");
 endtask
 reg [31:0] identity_word;
 int cases=0,previous_starts;
 initial begin
  repeat(3)@(negedge clk);cold_reset_n=1;backend_reset_n=1;
  wait(release_ready);@(negedge clk);
  pio_read(256,identity_word);
  assert(identity_word==32'h31444941)else $fatal(1,"identity magic mismatch %h",identity_word);
  open_platform(0);
  for(int k=0;k<2;k++)begin
   @(negedge clk);new_host_work=1;
   @(posedge clk);@(negedge clk);new_host_work=0;
   pio(0,32'(k*256+8));pio(4,1);pio(8,0);pio(12,255);
   previous_starts=starts_seen[k];backend_stall=(k==0);pio(16,1);
   if(k==0)begin
    assert(write_pending&&!launch_owned)else $fatal(1,"pending case did not stall");
    command(2);repeat(4)@(negedge clk);
    assert(phase_status==2&&!adapter_quiesce_req&&!kernel_stop_ack&&!mailbox_write_permit)
      else $fatal(1,"pending STOP_WORK sequencing");
    backend_stall=0;
   end else begin
    wait(launch_owned);command(2);
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
   allow_writeback=1;wait(host_writeback_drained);wait(adapter_quiesce_req);@(negedge clk);
   assert(!release_ready&&adapter_debt==3&&phase_status==3)else $fatal(1,"adapter debt ignored");
   repeat(4)@(negedge clk);allow_adapter=1;wait(adapter_drained);wait(release_ready);
   wait(phase_status==4);@(negedge clk);
   assert(kernel_stop_ack&&kernel_idle&&host_stop_ack&&adapter_quiescing&&!fault_latched)
     else $fatal(1,"release barrier incomplete");
   cases++;allow_dma=0;allow_desc=0;allow_writeback=0;allow_adapter=0;
   if(k==0)open_platform(1);
  end
  assert(cases==2&&stop_work_debt_cycles>0&&blocked_release_cycles>0&&!invalid_access)
    else $fatal(1,"composition coverage missing");
  // Exact 41-bit fault crosses supervisor, identity v2, CDC and host transcript.
  adapter_fault_address=41'h10000000100;adapter_fault_address_valid=1;
  adapter_fault_code=8'h80;adapter_fault=1;repeat(3)@(negedge clk);
  assert(first_adapter_address===41'h10000000100 && first_adapter_address_valid)
    else $fatal(1,"full diagnostic lost");
  pio_read(416,identity_word);
  assert(identity_word[24])else $fatal(1,"identity diagnostic invalid");
  pio_read(420,identity_word);
  assert(identity_word==32'h100)else $fatal(1,"diagnostic low bits lost");
  pio_read(424,identity_word);
  assert(identity_word==32'h100)else $fatal(1,"diagnostic high bits lost");
  begin
   integer fd;fd=$fopen("identity-reads.txt","w");
   assert(fd!=0)else $fatal(1,"transcript open failed");
   for(int n=0;n<72;n++)begin
    pio_read(256+(n<6?n*4:(n==6||n==71?24:(n-7)*4)),identity_word);
    $fdisplay(fd,"%08x",identity_word);
   end
   $fclose(fd);
  end
  $display("PLATFORM_CONTROL_COMPOSITION_PASS cases=%0d stop_work_debt_cycles=%0d blocked_release_cycles=%0d",cases,stop_work_debt_cycles,blocked_release_cycles);
  $finish;
 end
endmodule
