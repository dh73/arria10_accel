`timescale 1ns/1ps
module tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,backend_reset_n=0,context_valid=1,write_permit=1,memory_ready=1;
 logic [191:0] context_identity=192'h123;
 logic read=0,write=0;logic [5:0] address=0;logic [31:0] writedata=0;logic [3:0] byteenable=15;
 wire waitrequest,readdatavalid,pending,fault,m_write,m_read,m_waitrequest,m_readdatavalid,m_readdataerror;
 wire [31:0] readdata;wire [24:0] m_address;wire [511:0] m_writedata,m_readdata;wire [63:0] m_byteenable;
 logic avm_waitrequest=1,avm_readdatavalid=0,avm_readdataerror=0;
 logic [511:0] avm_readdata={64{8'ha1}};
 wire [24:0] avm_address;wire avm_read,avm_write;wire [511:0] avm_writedata;wire [63:0] avm_byteenable;
 wire [1:0] req_waitrequest,rsp_valid,rsp_error;wire mux_fault;
 ddr_byte_mailbox_verified mailbox(.*);
 arria10_dma_ddr_mux #(.READ_DEPTH(64)) mux(
 .clk,.common_cold_reset_n(cold_reset_n),.backend_reset_n,.dma_lock(1'b0),
 .req_address({m_address,25'b0}),.req_read({m_read,1'b0}),.req_write({m_write,1'b0}),
 .req_writedata({m_writedata,512'b0}),.req_byteenable({m_byteenable,64'b0}),
 .req_waitrequest,.rsp_valid,.rsp_error,.rsp_data(m_readdata),
 .avm_address,.avm_read,.avm_write,.avm_writedata,.avm_byteenable,.avm_burstcount(),
 .avm_waitrequest,.avm_readdatavalid,.avm_readdataerror,.avm_readdata,.fault(mux_fault));
 assign m_waitrequest=req_waitrequest[1];assign m_readdatavalid=rsp_valid[1];assign m_readdataerror=rsp_error[1];
 task tick;@(posedge clk);@(negedge clk);endtask
 task reset;
  cold_reset_n=0;backend_reset_n=0;write=0;avm_waitrequest=1;avm_readdatavalid=0;avm_readdataerror=0;
  repeat(3)tick();cold_reset_n=1;backend_reset_n=1;repeat(5)tick();
 endtask
 task put(input [5:0] a,input [31:0] d);
  address=a;writedata=d;write=1;#1;assert(!waitrequest)else $fatal(1,"MMIO stall");tick();write=0;
 endtask
 task submit;
  put(8,32'h1000);put(12,0);put(16,32'hd4c3b2a1);put(20,1);put(24,1);put(28,1);
  assert(pending&&!fault)else $fatal(1,"admission");
 endtask
 initial begin
  for(integer phase=0;phase<3;phase++)begin
   reset();submit();
   if(phase>=1)begin avm_waitrequest=0;tick();avm_waitrequest=1;end
   if(phase>=2)begin avm_waitrequest=0;tick();avm_waitrequest=1;end
   repeat(3)tick();
   // Backend loss alone never resets mailbox or arbiter ownership.
   backend_reset_n=0;avm_readdatavalid=1;#1;
   assert(!avm_write&&!avm_read&&!m_readdatavalid)else $fatal(1,"reset leaked request/response");
   repeat(4)tick();
   assert(mux_fault&&pending&&mailbox.completed_sequence==0)else $fatal(1,"reset discharged debt");
   backend_reset_n=1;avm_waitrequest=0;repeat(6)tick();
   assert(mux_fault&&pending&&!avm_write&&!avm_read&&!m_readdatavalid&&mailbox.completed_sequence==0)
    else $fatal(1,"backend return replayed or retired work");
   $display("BYTE_RESET_PHASE_PASS phase=%0d",phase);
  end
  reset();submit();avm_waitrequest=0;tick();tick();avm_readdatavalid=1;avm_readdataerror=1;tick();
  avm_readdatavalid=0;
  assert(fault&&pending&&mailbox.completed_sequence==0)else $fatal(1,"ECC error accepted");
  $display("DDR_BYTE_RESET_PATH_PASS reset_phases=3 ecc=1");$finish;
 end
endmodule
