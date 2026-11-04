`timescale 1ns/1ps
module width_case #(parameter A=41)(output logic done=0);
 logic clk=0; always #5 clk=~clk;
 logic rst=0, fault=0, valid=0, clear=0;
 logic [A-1:0] address=0, first_address;
 logic first_valid, latched;
 platform_supervisor_address_width #(.ADDR_W(A)) dut (
 .clk, .cold_reset_n(rst), .memory_ready(1'b1), .backend_init_failed(1'b0),
 .backend_ecc_interrupt(1'b0), .adapter_fault(fault), .adapter_fault_code(8'h08),
 .adapter_fault_address(address), .adapter_fault_address_valid(valid),
 .adapter_quiescing(1'b1), .adapter_drained(1'b1),
 .kernel_status_valid(1'b1), .kernel_stop_ack(1'b1), .kernel_idle(1'b1), .kernel_fault(1'b0),
 .host_status_valid(1'b1), .host_stop_ack(1'b1), .host_dma_drained(1'b1),
 .host_desc_drained(1'b1), .host_writeback_drained(1'b1), .host_fault(1'b0),
 .external_stop(1'b0), .cmd_valid(1'b0), .cmd_op(3'b0),
 .clear_valid(clear), .clear_mask(16'hffff), .fault_latched(latched),
 .first_adapter_address(first_address), .first_adapter_address_valid(first_valid));
 task tick; @(posedge clk); #1; endtask
 initial begin
   for(int bitno=31; bitno<A; bitno++) begin
     @(negedge clk); rst=0; fault=0; valid=0; clear=0;
     tick(); @(negedge clk); rst=1; tick();
     @(negedge clk); address=(A'(1)<<bitno)|A'('h12340); valid=1; fault=1;
     tick();
     if(!latched || !first_valid || first_address!==address) $fatal(1,"lost high address A=%0d bit=%0d",A,bitno);
     @(negedge clk); address=0; clear=1;
     repeat(3) tick();
     if(first_address!==((A'(1)<<bitno)|A'('h12340))) $fatal(1,"first fault overwritten");
   end
   @(negedge clk); rst=0; tick();
   if(first_valid || first_address!==0 || latched) $fatal(1,"reset did not clear fault");
   @(negedge clk); rst=1; fault=1; valid=0; address='1; tick();
   if(!latched || first_valid || first_address!==0) $fatal(1,"invalid diagnostic admitted");
   $display("SUPERVISOR_ADDRESS_PASS width=%0d",A); done=1;
 end
endmodule
module tb;
 wire a,b,c;
 width_case #(32) x(a); width_case #(35) y(b); width_case #(41) z(c);
 initial begin wait(a&&b&&c); $display("SUPERVISOR_ADDRESS_MATRIX_PASS"); $finish; end
 initial begin #10000; $fatal(1,"test sequence deadlocked"); end
endmodule
