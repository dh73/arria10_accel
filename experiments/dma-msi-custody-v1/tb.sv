`timescale 1ns/1ps
module tb;
import dma_status_v2_pkg::*;
logic clk=0,rstn=0,s_valid=0,s_msi=0,dcm_waitrequest=1;
logic [31:0] s_word=0;
logic [63:0] header_base=0;
logic [81:0] msi_interface=0;
wire s_ready,custody_valid,local_writeback_owned,dcm_write;
wire [63:0] dcm_address;
wire [31:0] dcm_data;
wire [3:0] dcm_byteenable;
wire fetch_valid,diagnostic_valid,retired_ack_valid,protocol_fault;
wire [31:0] fetch_word,diagnostic_word,retired_ack_word,fault_word;
logic fetch_ready=0,diagnostic_ready=0,retired_ack_consumed=0;
integer writes=0,receipts=0;
logic [63:0] expected_addr[0:6];
logic [31:0] expected_data[0:6];
dma_status_sink_fetch_v4_status dut(.*);
always #5 clk=~clk;
always @(posedge clk) if(rstn && dcm_write && !dcm_waitrequest) begin
 assert(writes<7) else $fatal(1,"duplicate output");
 assert(dcm_address===expected_addr[writes] && dcm_data===expected_data[writes] && dcm_byteenable===4'hf)
 else $fatal(1,"output %0d address=%h data=%h",writes,dcm_address,dcm_data);
 writes=writes+1;
end
task automatic tick; @(posedge clk); @(negedge clk); endtask
task automatic offer(input integer id,input bit error,input bit request_msi,input bit enabled,input logic[63:0] base,input logic[63:0] address,input logic[15:0] data);
 s_word=status_v2_make(id,0,1,error?DMA_CAUSE_MASTER:0,!error,1,error,!error);
 header_base=base;msi_interface={1'b0,enabled,data,address};s_msi=request_msi;s_valid=1;
 #1;assert(s_ready) else $fatal(1,"queue unexpectedly full");tick();s_valid=0;
endtask
task automatic accept_write;
 wait(dcm_write);@(negedge clk);
 repeat(4)begin assert(local_writeback_owned&&!retired_ack_valid) else $fatal(1,"early custody release");tick();end
 dcm_waitrequest=0;tick();dcm_waitrequest=1;
endtask
task automatic receipt;
 wait(retired_ack_valid);@(negedge clk);receipts++;
 repeat(3)begin assert(local_writeback_owned&&!dcm_write)else $fatal(1,"receipt replay");tick();end
 retired_ack_consumed=1;tick();repeat(3)tick();
 assert(!retired_ack_valid&&local_writeback_owned&&!dcm_write)else $fatal(1,"return-low debt lost");
 retired_ack_consumed=0;tick();
endtask
initial begin
 expected_addr[0]=64'h100c;expected_data[0]=1;
 expected_addr[1]=64'h1234567800000040;expected_data[1]=32'hb0fe;
 expected_addr[2]=64'h2010;expected_data[2]=1;
 expected_addr[3]=64'h8765432100000080;expected_data[3]=32'habcd;
 expected_addr[4]=64'h3014;expected_data[4]=status_v2_make(5,0,1,DMA_CAUSE_MASTER,0,1,1,0);
 expected_addr[5]=64'h00000000fee00000;expected_data[5]=32'h0041;
 expected_addr[6]=64'h4018;expected_data[6]=1;
 repeat(3)tick();rstn=1;tick();
 offer(3,0,1,1,64'h1000,64'h1234567800000040,16'hb0fe);
 offer(4,0,1,1,64'h2000,64'h8765432100000080,16'habcd);
 offer(5,1,1,1,64'h3000,64'hfee00000,16'h0041);
 offer(6,0,1,0,64'h4000,64'hdeadbeef,16'hffff);
 // Later live configuration must not change queued MSI or flag destinations.
 header_base='1;msi_interface='1;s_word=0;s_msi=0;
 accept_write();accept_write();receipt();
 accept_write();accept_write();receipt();
 accept_write();accept_write(); // Error status must interrupt, never success-ACK.
 accept_write();receipt();
 repeat(8)tick();
 assert(writes==7&&receipts==3&&!protocol_fault&&custody_valid&&!local_writeback_owned)
 else $fatal(1,"terminal custody/count mismatch");
 $display("DMA_MSI_CUSTODY_PASS writes=7 receipts=3");$finish;
end
endmodule
