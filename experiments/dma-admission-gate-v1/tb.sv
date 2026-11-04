module tb;
 logic clk=0; always #5 clk=~clk;
 logic reset_n=0,submit_permit=0,stop_req=0,upstream_closed=0;
 logic s_select=0,s_read=0,s_write=0;
 logic [7:0] s_address=0; logic [31:0] s_writedata=0;
 logic [3:0] s_byteenable=0;
 wire s_waitrequest; wire [31:0] s_readdata;
 wire m_select,m_read,m_write; wire [7:0] m_address;
 wire [31:0] m_writedata; wire [3:0] m_byteenable;
 logic m_waitrequest=1; logic [31:0] m_readdata=32'h12345678;
 wire write_owned,stop_ack;
 dma_admission_gate dut(.*);
 task tick; @(posedge clk); #1; endtask
 initial begin
   tick(); @(negedge clk); reset_n=1; submit_permit=1;
   s_select=1;s_write=1;s_address=8'h10;s_writedata=32'h7;s_byteenable=4'hf;
   #1; if(!write_owned || !s_waitrequest) $fatal(1,"same-edge capture not owned");
   tick(); @(negedge clk); stop_req=1;submit_permit=0;upstream_closed=1;
   repeat(5) begin tick();
     if(!m_write || !write_owned || stop_ack || !s_waitrequest ||
        m_address!=8'h10 || m_writedata!=7 || m_byteenable!=15)
       $fatal(1,"stop withdrew retained offer");
   end
   @(negedge clk);m_waitrequest=0;
   #1;if(s_waitrequest || stop_ack) $fatal(1,"early release");
   tick(); @(negedge clk);s_select=0;s_write=0;m_waitrequest=1;
   #1;if(!stop_ack || write_owned) $fatal(1,"local handoff not drained");
   s_select=1;s_write=1;s_writedata=9;
   repeat(3) begin tick(); if(m_select || !s_waitrequest) $fatal(1,"post-stop write admitted"); end
   @(negedge clk);s_write=0;s_read=1;
   tick(); if(!m_read || m_write) $fatal(1,"stopped status read blocked");
   @(negedge clk);m_waitrequest=0;
   #1;if(s_waitrequest || s_readdata!=32'h12345678) $fatal(1,"read result");
   tick(); @(negedge clk);s_select=0;s_read=0;upstream_closed=0;
   #1;if(stop_ack) $fatal(1,"invented upstream closure");
   stop_req=0;submit_permit=1'bx;s_select=1;s_write=1;
   repeat(2) begin tick();if(m_write || write_owned) $fatal(1,"unknown admission");end
   $display("DMA_ADMISSION_GATE_PASS retained_stop read_after_stop upstream_certificate unknown_permit");
   $finish;
 end
endmodule
