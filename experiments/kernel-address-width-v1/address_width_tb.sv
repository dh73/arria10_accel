module address_width_case #(parameter int A=35,W=64)(output bit finished=0);
 localparam int B=W/8,N=37;
 logic clk=0,cold_reset_n=0,memory_ready=1,backend_init_failed=0,backend_ecc_interrupt=0,quiesce_req=0;
 logic k_read=0,k_write=0,k_burstcount=1;
 logic [A-1:0] k_address=0,fault_address;
 logic [W-1:0] k_writedata=0,k_readdata;
 logic [B-1:0] k_byteenable='1;
 logic k_waitrequest,k_readdatavalid,k_writeack;
 logic [24:0] d_address;
 logic d_read,d_write,d_burstcount,d_waitrequest=0,d_readdatavalid,d_readdataerror=0;
 logic [511:0] d_writedata,d_readdata;
 logic [63:0] d_byteenable;
 logic fault,fault_address_valid,quiescing,drained;
 logic [7:0] fault_code;
 kernel_ddr_address_width_adapter #(.ADDR_W(A),.DATA_W(W),.CMD_DEPTH(3),.READ_DEPTH(5)) dut(.*);
 bit auto_reply=1,manual_reply=0,checking=0,reads=0;
 logic [511:0] manual_data=0;
 int issued=0,dispatched=0,returned=0,cycles=0,high_rejections=0;
 function automatic logic [A-1:0] addr(input int n);
  return n==N-1?A'(64'h80000000-B):A'(n*B);
 endfunction
 function automatic logic [7:0] pattern(input longint unsigned a);
  return 8'(a^(a>>8)^(a>>16)^8'h5a);
 endfunction
 function automatic logic [B-1:0] mask(input int n);
  for(int j=0;j<B;j++)mask[j]=n%3==0?0:n%3==1?1:(j%2==0);
 endfunction
 always_comb begin
  d_readdatavalid=auto_reply?(d_read&&!d_waitrequest):manual_reply;
  d_readdata=manual_data;
  if(auto_reply)for(int j=0;j<64;j++)d_readdata[j*8+:8]=pattern(64'(d_address)*64+j);
 end
 task automatic tick;
  #5;
  if(checking)begin
   assert(!fault)else $fatal(1,"unexpected stream fault A=%0d W=%0d code=%h",A,W,fault_code);
   if(k_readdatavalid)begin
    assert(reads&&returned<issued)else $fatal(1,"unowned stream response");
    for(int j=0;j<B;j++)assert(k_readdata[j*8+:8]===pattern(64'(addr(returned))+j))else $fatal(1,"read lane mismatch");
    returned++;
   end
   if((d_read||d_write)&&!d_waitrequest)begin
    assert(dispatched<issued&&d_address==25'(addr(dispatched)>>6)&&d_read==reads&&d_write!=reads&&d_burstcount)
      else $fatal(1,"dispatch identity");
    for(int j=0;j<64;j++)begin
     bit enabled;
     enabled=j>=int'(addr(dispatched)%64)&&j<int'(addr(dispatched)%64)+B;
     if(enabled)enabled=((mask(dispatched)>>(j-int'(addr(dispatched)%64)))&1'b1);
     assert(d_byteenable[j]===enabled)else $fatal(1,"mask widening/lane mismatch");
     if(!reads&&enabled)assert(d_writedata[j*8+:8]===pattern(64'(d_address)*64+j))else $fatal(1,"write lane mismatch");
    end
    dispatched++;
   end
   if((k_read||k_write)&&!k_waitrequest)issued++;
   cycles++;
  end
  clk=1;#5;clk=0;
 endtask
 task automatic reset;
  cold_reset_n=0;k_read=0;k_write=0;k_burstcount=1;d_waitrequest=0;manual_reply=0;d_readdataerror=0;
  auto_reply=1;checking=0;quiesce_req=0;tick();cold_reset_n=1;tick();
  assert(drained&&!fault&&k_writeack==0)else $fatal(1,"reset/default contract");
 endtask
 task automatic stream(input bit rd,input bit stalls);
  issued=0;dispatched=0;returned=0;cycles=0;reads=rd;checking=1;
  while(issued<N)begin
   k_read=rd;k_write=!rd;k_address=addr(issued);k_byteenable=mask(issued);
   for(int j=0;j<B;j++)k_writedata[j*8+:8]=pattern(64'(k_address)+j);
   d_waitrequest=stalls&&(cycles%5<2);tick();
  end
  k_read=0;k_write=0;d_waitrequest=0;
  while(!drained)tick();
  assert(dispatched==N&&(!rd||returned==N))else $fatal(1,"lost stream work");
  if(!stalls)assert(cycles==N+1)else $fatal(1,"throughput regression");
  checking=0;
 endtask
 task automatic reject(input logic [A-1:0] a,input bit rd,input int bitcode);
  reset();k_address=a;k_read=rd;k_write=!rd;k_byteenable='1;
  #1;assert(k_waitrequest&&!d_read&&!d_write)else $fatal(1,"invalid request admitted/narrowed");
  tick();k_read=0;k_write=0;
  assert(fault&&fault_code[bitcode]&&fault_address_valid&&fault_address===a&&drained)
    else $fatal(1,"full-width rejection diagnostic A=%0d W=%0d got=%h expected=%h",A,W,fault_address,a);
  repeat(3)begin tick();assert(!d_read&&!d_write)else $fatal(1,"high alias escaped to DDR");end
 endtask
 logic [A-1:0] bad,old;
 initial begin
  reset();stream(0,0);stream(1,0);stream(0,1);stream(1,1);
  // Every address bit outside the 2GiB aperture is exercised, including the
  // named 31/34/35/40 aliases when present. Bit32+ must not truncate to low DDR.
  for(int bitno=31;bitno<A;bitno++)for(int rd=0;rd<2;rd++)begin
   bad=(A'(1)<<bitno)|A'(64'h1000);reject(bad,rd!=0,3);high_rejections++;
  end
  reject(A'(64'h1001),1,2);
  // Preserve old ownership across a new rejected high request and later ECC.
  reset();auto_reply=0;d_waitrequest=1;old=A'(64'h80000000-B);bad=(A'(1)<<(A-1))|A'(64'h1000);
  k_read=1;k_address=old;tick();k_read=0;tick();
  assert(d_read&&!drained&&dut.cmd_address[dut.cmd_rd_q]===old&&dut.read_address[dut.read_rd_q]===old)
    else $fatal(1,"full-width FIFOs lost valid owner");
  k_read=1;k_address=bad;#1;assert(k_waitrequest)else $fatal(1,"invalid new request accepted");tick();k_read=0;
  assert(fault&&fault_address===bad&&!drained)else $fatal(1,"high first-fault identity lost");
  d_waitrequest=0;tick();assert(!drained)else $fatal(1,"accepted read ownership disappeared");
  for(int j=0;j<64;j++)manual_data[j*8+:8]=pattern((64'(old)&~64'd63)+j);
  manual_reply=1;d_readdataerror=1;#1;
  assert(k_readdatavalid)else $fatal(1,"old response suppressed after fault");
  for(int j=0;j<B;j++)assert(k_readdata[j*8+:8]===pattern(64'(old)+j))else $fatal(1,"old owner lane changed");
  tick();manual_reply=0;d_readdataerror=0;tick();
  assert(drained&&fault_code[3]&&fault_code[5]&&fault_address===bad)else $fatal(1,"late ECC overwrote high first fault");
  // With ECC as first cause, diagnostic is the FULL old read-owner address,
  // not a concurrent invalid new address (upper bits must remain exact zero).
  reset();auto_reply=0;k_read=1;k_address=old;tick();k_read=0;tick();
  k_read=1;k_address=bad;manual_reply=1;d_readdataerror=1;#1;
  assert(k_waitrequest&&k_readdatavalid)else $fatal(1,"simultaneous invalid/ECC ownership");
  tick();k_read=0;manual_reply=0;d_readdataerror=0;tick();
  assert(fault&&fault_address_valid&&fault_address===old&&fault_code[3]&&fault_code[5]&&drained)
    else $fatal(1,"ECC full-width owner diagnostic");
  $display("KERNEL_ADDRESS_WIDTH_PASS A=%0d W=%0d high_rejections=%0d stream_commands=%0d",A,W,high_rejections,N*4);
  finished=1;
 end
endmodule
module address_width_tb;
 wire [8:0] finished;
 address_width_case #(.A(35),.W(64)) a0(finished[0]);
 address_width_case #(.A(35),.W(128)) a1(finished[1]);
 address_width_case #(.A(35),.W(256)) a2(finished[2]);
 address_width_case #(.A(35),.W(512)) a3(finished[3]);
 address_width_case #(.A(41),.W(64)) a4(finished[4]);
 address_width_case #(.A(41),.W(128)) a5(finished[5]);
 address_width_case #(.A(41),.W(256)) a6(finished[6]);
 address_width_case #(.A(41),.W(512)) a7(finished[7]);
 address_width_case #(.A(32),.W(64)) a8(finished[8]);
 initial begin wait(&finished);$display("ADDRESS_WIDTH_MATRIX_PASS configurations=9");$finish;end
endmodule
