module tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,context_valid=1,write_permit=1,memory_ready=1;
 logic [191:0] context_identity=192'h123;
 logic read=0,write=0;logic [5:0] address=0;logic [31:0] writedata=0;logic [3:0] byteenable=15;
 wire waitrequest,readdatavalid,pending,fault,m_write;
 wire [31:0] readdata;wire [24:0] m_address;wire [511:0] m_writedata;wire [63:0] m_byteenable;
 logic m_waitrequest=1;
 ddr_byte_mailbox dut(.*);
 task reset;
  @(negedge clk);cold_reset_n=0;write=0;read=0;context_valid=1;context_identity=192'h123;
  write_permit=1;memory_ready=1;m_waitrequest=1;byteenable=15;
  repeat(2)@(negedge clk);cold_reset_n=1;
 endtask
 task put(input [5:0] a,input [31:0] d);
  @(negedge clk);address=a;writedata=d;write=1;
  @(posedge clk);if(waitrequest)$fatal(1,"unexpected MMIO stall");
  @(negedge clk);write=0;
 endtask
 task submit(input [31:0] a,input [31:0] mask,input [31:0] seq);
  put(8,a);put(12,0);put(16,32'hd4c3b2a1);put(20,mask);put(24,seq);put(28,1);
 endtask
 integer slot,mask,accepted=0;logic [511:0] line,expected,held_data;logic [63:0] held_mask;
 initial begin
  for(slot=0;slot<16;slot=slot+1)for(mask=1;mask<16;mask=mask+1)begin
   reset();submit(32'h1000+slot*4,mask,1);
   if(!pending||fault||!m_write||m_address!=64)$fatal(1,"admission/address");
   held_data=m_writedata;held_mask=m_byteenable;
   if(held_mask!=(64'(mask)<<(slot*4)))$fatal(1,"mask placement");
   repeat(3)begin @(negedge clk);
    if(!m_write||m_writedata!==held_data||m_byteenable!==held_mask)$fatal(1,"stalled offer changed");
   end
   // A concurrent agent has changed all other bytes. Masked acceptance must
   // preserve them, including adjacent bytes within the same DWORD.
   line={64{8'h5a}};expected=line;
   for(integer b=0;b<4;b=b+1)if(mask&(1<<b))expected[8*(slot*4+b)+:8]=8'(32'hd4c3b2a1>>(8*b));
   for(integer b=0;b<64;b=b+1)if(m_byteenable[b])line[8*b+:8]=m_writedata[8*b+:8];
   if(line!==expected)$fatal(1,"neighbor byte overwritten");
   m_waitrequest=0;@(negedge clk);
   if(pending||fault||dut.completed_sequence!=1)$fatal(1,"retirement");
   accepted=accepted+1;
  end
  reset();submit(32'h7ffffffc,15,1);if(fault||!pending)$fatal(1,"aperture end rejected");
  reset();submit(32'h80000000,15,1);if(!fault||pending||m_write)$fatal(1,"aperture overflow accepted");
  reset();submit(32'h1001,15,1);if(!fault||pending)$fatal(1,"unaligned DWORD accepted");
  reset();submit(32'h1000,0,1);if(!fault||pending)$fatal(1,"empty mask accepted");
  reset();submit(32'h1000,1,1);write_permit=0;@(negedge clk);
  if(!m_write||!pending)$fatal(1,"admission close lost existing offer");
  context_identity=192'h124;@(negedge clk);
  if(!fault||!pending||m_write||dut.completed_sequence!=0)$fatal(1,"context loss discharged custody");
  context_identity=192'h123;m_waitrequest=0;@(negedge clk);
  if(!pending||m_write)$fatal(1,"context return replayed command");
  $display("DDR_BYTE_MAILBOX_PASS masks=%0d stalls neighbors aperture context_custody",accepted);$finish;
 end
endmodule
