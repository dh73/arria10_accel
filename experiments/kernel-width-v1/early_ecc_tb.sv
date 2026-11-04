module width_early_ecc_tb;
parameter W=512;
localparam LATENCY=17;
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
 d_readdataerror=inject_ecc && response_valid && pending_head==0;
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
task early_ecc;
 int accepted_at_fault, reads_at_fault;
 inject_ecc=1;checking=1;
 while(!fault) begin
  k_read=(issued%3==1);k_write=!k_read;k_address=addr(issued);k_byteenable='1;
  for(int j=0;j<B;j++) k_writedata[j*8+:8]=pattern(longint'(k_address)+j);
  d_waitrequest=(cycles%5<2);tick();
 end
 accepted_at_fault=issued;reads_at_fault=returned;
 if(pending_tail-pending_head<2) $fatal(1,"fixture did not retain multiple owned responses");
 // Keep a new offer asserted through drain: sticky fault must deny it.
 k_read=1;k_write=0;k_address=addr(issued);d_waitrequest=0;
 while(!drained) begin
  tick();
  if(issued!=accepted_at_fault) $fatal(1,"new admission after ECC fault");
 end
 if(dispatched!=issued || returned!=pending_tail || returned<=reads_at_fault)
  $fatal(1,"owned work failed to drain after early ECC");
 if(!fault || fault_code!=8'h20 || !fault_address_valid || fault_address!=addr(1))
  $fatal(1,"first failed response context lost");
 repeat(5) begin
  tick();
  if(!k_waitrequest || !fault || !drained || issued!=accepted_at_fault)
   $fatal(1,"sticky fault admission/drain changed");
 end
 $display("WIDTH_EARLY_ECC_PASS width=%0d accepted=%0d dispatched=%0d returned=%0d",W,issued,dispatched,returned);
endtask
initial begin
 tick();cold_reset_n=1;memory_ready=1;tick();
 early_ecc();$finish;
end
endmodule
