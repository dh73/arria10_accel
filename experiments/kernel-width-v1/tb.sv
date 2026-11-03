module width_tb;
parameter W=512;
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
 for(int j=0;j<B;j++) result[j]=(n%3==0) || (j%2==0);
 return result;
endfunction
always_comb begin
 d_readdatavalid=d_read && !d_waitrequest;
 for(int j=0;j<64;j++) d_readdata[j*8+:8]=pattern(longint'(d_address)*64+j);
end
task tick;
 #5;
 if(checking) begin
  if(fault) $fatal(1,"unexpected fault %h",fault_code);
  if(k_readdatavalid) begin
   if(!reads || returned>=issued) $fatal(1,"unowned response");
   for(int j=0;j<B;j++)
    if(k_readdata[j*8+:8] !== pattern(longint'(addr(returned))+j))
     $fatal(1,"read byte mismatch width=%0d index=%0d byte=%0d",W,returned,j);
   returned++;
  end
  if((d_read||d_write)&&!d_waitrequest) begin
   if(dispatched>=issued || d_address !== 25'(addr(dispatched)>>6) || d_read!=reads || d_write==reads)
    $fatal(1,"command identity mismatch");
   for(int j=0;j<64;j++) begin
    bit enabled;
    enabled=j>=int'(addr(dispatched)%64) && j<int'(addr(dispatched)%64)+B;
    if(enabled) enabled=((mask(dispatched) >> (j-int'(addr(dispatched)%64))) & 1'b1);
    if(d_byteenable[j] !== enabled) $fatal(1,"byte enable mismatch");
    if(!reads && enabled && d_writedata[j*8+:8] !== pattern(longint'(d_address)*64+j))
     $fatal(1,"write byte mismatch");
    if(enabled) useful++;
   end
   dispatched++;
  end
  if((k_read||k_write)&&!k_waitrequest) issued++;
  cycles++;
 end
 clk=1;#5;clk=0;
endtask
task stream(bit rd,bit stalls);
 issued=0;dispatched=0;returned=0;cycles=0;useful=0;reads=rd;checking=1;
 while(issued<N) begin
  k_read=rd;k_write=!rd;k_address=addr(issued);k_byteenable=mask(issued);
  for(int j=0;j<B;j++) k_writedata[j*8+:8]=pattern(longint'(k_address)+j);
  d_waitrequest=stalls && (cycles%5<2);tick();
 end
 k_read=0;k_write=0;d_waitrequest=0;
 while(!drained) tick();
 if(dispatched!=N || (rd && returned!=N)) $fatal(1,"missing work");
 if(!stalls && cycles!=N+1) $fatal(1,"unexpected throughput bubble cycles=%0d",cycles);
 $display("WIDTH_STREAM width=%0d read=%0d stalled=%0d commands=%0d cycles=%0d enabled_bytes=%0d transported_bytes=%0d",W,rd,stalls,dispatched,cycles,useful,dispatched*64);
 checking=0;
endtask
initial begin
 tick();cold_reset_n=1;memory_ready=1;tick();
 stream(0,0);stream(1,0);stream(0,1);stream(1,1);
 quiesce_req=1;tick();if(!drained || !k_waitrequest) $fatal(1,"quiesce failure");
 $display("WIDTH_ADAPTER_PASS width=%0d",W);$finish;
end
endmodule
