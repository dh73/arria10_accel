module mailbox_custody_tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,backend_reset_n=0,stop_req=0,backend_stall=0;
 logic read=0,write=0;
 logic [7:0] address=0;
 logic [31:0] writedata=0;
 logic [3:0] byteenable=15;
 wire waitrequest,readdatavalid,invalid_access;
 wire [31:0] readdata;
 wire cra_read,cra_write,cra_readdatavalid;
 wire [29:0] cra_address;
 wire [63:0] cra_writedata,cra_readdata;
 wire [7:0] cra_byteenable;
 wire cra_waitrequest=backend_stall;
 wire write_pending,write_permit,busy,kernel_idle,kernel_stop_ack,fault,launch_owned,launch_kernel,read_pending;
`include "kernel_launch_source_binding.svh"
 kernel_cra_mailbox_guarded mailbox(.*);
 kernel_launch_custody #(.COPY_SHA(EXPECTED_COPY_SHA),.TRIAD_SHA(EXPECTED_TRIAD_SHA)) custody(.*);
 logic [1:0] done=0;
 wire [1:0] valid,start;
 wire [63:0] data[2];
 wire selected=cra_address>=256;
 assign cra_readdatavalid=|valid;
 assign cra_readdata=valid[1]?data[1]:data[0];
`define PORTS(N) \
 .clock(clk),.resetn(cold_reset_n),.acl_counter_full(1'b0),.acl_counter_size(32'b0), \
 .avs_cra_address(cra_address[7:3]),.avs_cra_byteenable(cra_byteenable),.avs_cra_enable(1'b1), \
 .avs_cra_read(cra_read&&!cra_waitrequest&&(selected==N)), \
 .avs_cra_write(cra_write&&!cra_waitrequest&&(selected==N)),.avs_cra_writedata(cra_writedata), \
 .has_a_lsu_active(1'b0),.has_a_write_pending(1'b0),.kernel_done(done[N]),.valid_in(1'b1), \
 .acl_counter_reset(),.avs_cra_readdata(data[N]),.avs_cra_readdatavalid(valid[N]), \
 .cra_irq(),.kernel_arguments(),.kernel_start(start[N]),.status()
 a10_streaming_Copy_function_cra_agent copy_agent(`PORTS(0));
 a10_streaming_Triad_function_cra_agent triad_agent(`PORTS(1));
`undef PORTS
 task automatic pio(input logic [7:0] a,input logic [31:0] d);
  @(negedge clk);write=1;address=a;writedata=d;
  @(posedge clk);@(negedge clk);write=0;
 endtask
 task automatic read_cra(input int a);
  pio(0,32'(a));pio(8'h10,2);
  wait(cra_readdatavalid);@(posedge clk);@(negedge clk);
 endtask
 int cases=0;
 initial begin
  repeat(3)@(negedge clk);cold_reset_n=1;backend_reset_n=1;repeat(4)@(negedge clk);
  for(int k=0;k<2;k++)begin
   // Accepted write_pending precedes the actual CRA start by a backend stall.
   pio(0,32'(k*256+8));pio(4,1);pio(8,0);pio(12,255);
   backend_stall=1;pio(16,1);stop_req=1;#1;
   assert(write_pending&&!kernel_idle&&!kernel_stop_ack&&!launch_owned)else $fatal(1,"mailbox pending gap");
   repeat(3)@(negedge clk);backend_stall=0;
   wait(start[k]);#1;assert(launch_owned&&!kernel_idle&&kernel_stop_ack&&!fault)else $fatal(1,"mailbox start tracking");
   // Sticky status and a zero counter do not retire this actual started agent.
   read_cra(k*256);read_cra(k*256+48);
   assert(launch_owned&&!kernel_idle&&!fault)else $fatal(1,"early read retirement");
   // Race completion with an actual accepted mailbox count read. The corrected
   // source must retain it for the following read instead of losing it.
   pio(0,32'(k*256+48));pio(16,2);
   wait(cra_read);done[k]=1;
   @(posedge clk);@(negedge clk);done[k]=0;
   wait(!read_pending&&!cra_read&&!cra_readdatavalid);
   read_cra(k*256+48);
   assert(!launch_owned&&kernel_idle&&kernel_stop_ack&&!fault&&!invalid_access)
     else $fatal(1,"corrected mailbox completion retirement");
   stop_req=0;cases++;
  end
  // Stop wins command admission when asserted before the command PIO edge.
  pio(0,8);stop_req=1;pio(16,1);repeat(3)@(negedge clk);
  assert(invalid_access&&!launch_owned&&!write_pending&&kernel_idle&&kernel_stop_ack)
    else $fatal(1,"stop permitted a new start");
  $display("MAILBOX_VECTOR_CUSTODY_PASS launches=%0d",cases);$finish;
 end
endmodule
