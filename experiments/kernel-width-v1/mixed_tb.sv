module width_mixed_tb;
parameter W=512;
localparam LATENCY=3;
bit inject_ecc=0;
logic response_valid=0;
logic [511:0] response_data=0;
logic [24:0] pending_line[0:256];
int pending_due[0:256];
int pending_head=0,pending_tail=0;
localparam B=W/8, N=257;
logic clk=0,cold_reset_n=0,memory_ready=0;
logic backend_init_failed=0,backend_ecc_interrupt=0,quiesce_req=0;
logic k_read=0,k_write=0,k_burstcount=1,k_waitrequest;
logic [34:0] k_address=0;
logic [W-1:0] k_writedata=0,k_readdata;
logic [B-1:0] k_byteenable='1;
logic k_readdatavalid,k_writeack;
logic [24:0] d_address;
logic d_read,d_write,d_burstcount,d_waitrequest=0;
logic [511:0] d_writedata,d_readdata;
logic [63:0] d_byteenable;
logic d_readdatavalid,d_readdataerror=0;
logic fault,fault_address_valid,quiescing,drained;
logic [7:0] fault_code;
logic [34:0] fault_address;
int issued=0,dispatched=0,returned=0,cycles=0;
longint useful=0;
bit checking=0,reads=0;
kernel_ddr_width_adapter #(.DATA_W(W),.CMD_DEPTH(3),.READ_DEPTH(5)) dut(.*);
function automatic logic [34:0] addr(int n);
 return 35'(n*B);
endfunction
function automatic logic [7:0] pattern(longint address);
 return 8'(address ^ (address>>8) ^ 8'h5a);
endfunction
function automatic logic [B-1:0] mask(int n);
 logic [B-1:0] result;
 for(int j=0;j<B;j++) result[j]=1;
 return result;
endfunction
assign d_readdatavalid=response_valid;
assign d_readdata=response_data;
task tick;
 response_valid=checking && pending_head<pending_tail && pending_due[pending_head]<=cycles;
 if(response_valid)
  for(int j=0;j<64;j++) response_data[j*8+:8]=pattern(longint'(pending_line[pending_head])*64+j);
 d_readdataerror=inject_ecc && response_valid && pending_head==85;
 #5;
 if(checking) begin
  if(fault && !inject_ecc) $fatal(1,"unexpected fault %h",fault_code);
  if(k_readdatavalid) begin
   if(returned>=86 || 3*returned+1>=issued) $fatal(1,"unowned response");
   for(int j=0;j<B;j++)
    if(k_readdata[j*8+:8] !== pattern(longint'(addr(3*returned+1))+j))
     $fatal(1,"read byte mismatch width=%0d index=%0d byte=%0d",W,returned,j);
   returned++;
   pending_head++;
  end
  if((d_read||d_write)&&!d_waitrequest) begin
   if(dispatched>=issued || d_address !== 25'(addr(dispatched)>>6) || d_read!=(dispatched%3==1) || d_write!=(dispatched%3!=1))
    $fatal(1,"command identity mismatch");
   for(int j=0;j<64;j++) begin
    bit enabled;
    enabled=j>=int'(addr(dispatched)%64) && j<int'(addr(dispatched)%64)+B;
    if(enabled) enabled=((mask(dispatched) >> (j-int'(addr(dispatched)%64))) & 1'b1);
    if(d_byteenable[j] !== enabled) $fatal(1,"byte enable mismatch");
    if(d_write && enabled && d_writedata[j*8+:8] !== pattern(longint'(d_address)*64+j))
     $fatal(1,"write byte mismatch");
    if(enabled) useful++;
   end
   if(d_read) begin
    if(pending_tail>=N) $fatal(1,"fixture request count overflow");
    pending_line[pending_tail]=d_address;
    pending_due[pending_tail]=cycles+LATENCY;
    pending_tail++;
   end
   dispatched++;
  end
  if((k_read||k_write)&&!k_waitrequest) issued++;
  cycles++;
 end
 clk=1;#5;clk=0;
endtask
task mixed(bit stalls,bit ecc);
 inject_ecc=ecc;
 issued=0;dispatched=0;returned=0;cycles=0;useful=0;reads=0;pending_head=0;pending_tail=0;checking=1;
 while(issued<N) begin
  k_read=(issued%3==1);k_write=!k_read;k_address=addr(issued);k_byteenable=mask(issued);
  for(int j=0;j<B;j++) k_writedata[j*8+:8]=pattern(longint'(k_address)+j);
  d_waitrequest=stalls && (cycles%5<2);tick();
 end
 k_read=0;k_write=0;d_waitrequest=0;
 while(!drained) tick();
 if(dispatched!=N || returned!=86) $fatal(1,"missing work");
 if(!stalls && cycles!=N+1+LATENCY) $fatal(1,"unexpected throughput bubble cycles=%0d",cycles);
 if(ecc && (!fault || fault_code!=8'h20 || !fault_address_valid || fault_address!=addr(256)))
  $fatal(1,"owned ECC response lost exact fault context");
 if(!ecc && fault) $fatal(1,"unexpected mixed stream fault");
 $display("WIDTH_MIXED_STREAM width=%0d stalled=%0d ecc=%0d commands=%0d responses=%0d cycles=%0d",W,stalls,ecc,dispatched,returned,cycles);
 checking=0;
endtask
initial begin
 tick();cold_reset_n=1;memory_ready=1;tick();
 mixed(0,0);mixed(1,0);mixed(1,1);
 if(!drained || !k_waitrequest || !fault) $fatal(1,"ECC drain/admission failed");
 $display("WIDTH_MIXED_PASS width=%0d",W);$finish;
end
endmodule
