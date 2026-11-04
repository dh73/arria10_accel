// Source-bound monitor/gate, one globally outstanding launch, same CRA clock.
// Default hashes refuse admission. Only a coordinated cold-reset epoch clears
// debt/fault. Every CRA master and start must be inside the observed boundary.
module kernel_launch_custody #(
 parameter logic [255:0] COPY_SHA=0,TRIAD_SHA=0
)(
 input logic clk,cold_reset_n,backend_reset_n,stop_req,write_pending,
 input logic cra_read,cra_write,
 input logic [29:0] cra_address,
 input logic [63:0] cra_writedata,cra_readdata,
 input logic [7:0] cra_byteenable,
 input logic cra_waitrequest,cra_readdatavalid,
 output wire write_permit,busy,kernel_idle,kernel_stop_ack,
 output logic fault,launch_owned,launch_kernel,read_pending
);
`include "kernel_launch_source_binding.svh"
 wire profile_bound=COPY_SHA==EXPECTED_COPY_SHA && TRIAD_SHA==EXPECTED_TRIAD_SHA;
 (* async_reg="true",preserve *) logic [1:0] health;
 wire health_n=cold_reset_n&&backend_reset_n;
 always_ff @(posedge clk or negedge health_n)
   if(!health_n) health<=0;else health<={health[0],1'b1};
 logic armed;
 logic [29:0] read_address;
 wire live=cold_reset_n&&health[1]&&profile_bound&&!fault;
 wire accepted=(cra_read||cra_write)&&!cra_waitrequest;
 wire accepted_read=accepted&&cra_read;
 wire accepted_start=accepted&&cra_write&&(cra_address==8||cra_address==264);
 wire reply_owned=read_pending||accepted_read;
 wire [29:0] reply_address=read_pending?read_address:cra_address;
 wire count_reply=cra_readdatavalid&&reply_owned&&(reply_address==48||reply_address==304);
 wire nonzero_reply=count_reply&&cra_readdata!=0;
 wire reply_kernel=reply_address==304;
 wire retiring=nonzero_reply&&cra_readdata==1&&launch_owned&&reply_kernel==launch_kernel;
 wire event_fault=(armed&&!health[1]) ||
   (accepted && (cra_read&&cra_write || cra_address>=512 || cra_address[2:0]!=0)) ||
   (accepted_read&&read_pending) ||
   (cra_readdatavalid&&!reply_owned) ||
   (accepted_start&&(launch_owned||read_pending||cra_readdatavalid||
                    cra_writedata!=1||cra_byteenable!=8'hff)) ||
   (nonzero_reply&&!retiring);
 // Direct combinational gating is required: stop closes NEW mailbox command
 // admission on the same edge. The mailbox preserves already accepted writes.
 assign write_permit=live&&!stop_req&&!launch_owned&&!read_pending&&!event_fault;
 assign kernel_idle=live&&!event_fault&&!launch_owned&&!read_pending&&
                    !write_pending&&!cra_read&&!cra_write&&!cra_readdatavalid;
 assign busy=!kernel_idle;
 // A stopped producer may still own an executing launch; idle is separate.
 assign kernel_stop_ack=live&&!event_fault&&stop_req&&!write_permit&&
                        !write_pending&&!cra_write;
 always_ff @(posedge clk or negedge cold_reset_n) begin
  if(!cold_reset_n)begin
   armed<=0;fault<=0;launch_owned<=0;launch_kernel<=0;read_pending<=0;read_address<=0;
  end else begin
   if(health[1])armed<=1;
   if(event_fault)fault<=1;
   // Quarantine has priority over all retirement; no simultaneous-start hole.
   if(live&&!event_fault)begin
    if(accepted_start)begin launch_owned<=1;launch_kernel<=cra_address==264;end
    if(retiring)launch_owned<=0;
    if(accepted_read)begin read_pending<=1;read_address<=cra_address;end
    if(cra_readdatavalid&&reply_owned)read_pending<=0;
   end
  end
 end
endmodule
