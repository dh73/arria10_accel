`timescale 1ns/1ps
module tb;
 logic clk=0;always #5 clk=~clk;
 logic resetn=0,valid=0,av=1;
 logic [40:0] address=0;
 logic [15:0] req=0;
 wire ready,rsp,error;wire [31:0] data;
 shell_identity_v2 #(.SOURCE_ID(256'd1),.BUILD_ID(256'd2),.MGMT_SPACE(2),.CRA_SPACE(3),.CRA_BYTES(512)) dut(
 .clk,.cold_reset_n(resetn),.context_valid(1'b1),.session(128'd1),.epoch(64'd1),
 .health_valid(1'b1),.state_status(3'd0),.phase_status(3'd0),.release_ready(1'b0),
 .fault_latched(1'b1),.launch_permit(1'b0),.host_submit_permit(1'b0),
 .fault_history(16'd8),.fault_pending(16'd8),.first_fault_code(16'd8),.first_adapter_code(8'd8),
 .first_adapter_address(address),.first_adapter_address_valid(av),
 .req_valid(valid),.req_address(req),.req_byteenable(4'hf),.req_ready(ready),
 .rsp_valid(rsp),.rsp_error(error),.rsp_data(data));
 task read_word(input int wordno,output logic[31:0] value);
  @(negedge clk);req=16'(wordno*4);valid=1;
  @(posedge clk);#1;if(!ready||!rsp||error)$fatal(1,"read rejected");value=data;
  @(negedge clk);valid=0;
 endtask
 logic [31:0] lo,hi,guard0,guard1;
 initial begin
  repeat(3)@(negedge clk);resetn=1;repeat(3)@(negedge clk);
  read_word(1,lo);if(lo!==32'h20000)$fatal(1,"version");
  read_word(2,lo);if(lo!==2)$fatal(1,"layout");
  for(int b=0;b<41;b++)begin
   @(negedge clk);address=41'd1<<b;repeat(2)@(negedge clk);
   read_word(6,guard0);read_word(41,lo);read_word(42,hi);read_word(6,guard1);
   if(guard0==0||guard0!==guard1||{hi,lo}!=={23'b0,address})$fatal(1,"lost bit %0d",b);
  end
  @(negedge clk);av=0;repeat(2)@(negedge clk);
  read_word(41,lo);read_word(42,hi);if({hi,lo}!==0)$fatal(1,"invalid address leaked");
  $display("SHELL_IDENTITY_V2_PASS bits=41");$finish;
 end
endmodule
