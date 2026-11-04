`timescale 1ns/1ps
// Full default aperture, interface-level oracle; no physical DDR model.
module ddr_full_scrub_tb;
  logic clk=0,reset_n=0,cal_success=0,cal_fail=0;
  wire initialized,init_failed,client_waitrequest;
  logic [24:0] client_address=25'h123456;
  logic client_read=1,client_write=0;
  logic [511:0] client_writedata='1;
  logic [63:0] client_byteenable=64'h55aa55aa55aa55aa;
  logic client_burstcount=1,amm_ready=0;
  wire [24:0] amm_address;
  wire amm_read,amm_write;
  wire [511:0] amm_writedata;
  wire [63:0] amm_byteenable;
  wire [6:0] amm_burstcount;
  longint unsigned writes=0,cycles=0,stalls=0,client_reads=0;
  localparam longint unsigned LINES=64'd33554432;
  arria10_ddr_init dut(.*);
  always #5 clk=~clk;
  always @(negedge clk) begin
    cycles++;
    amm_ready=(cycles%97!=0 && cycles%97!=1);
  end
  always @(posedge clk) if(reset_n) begin
    if(init_failed) $fatal(1,"unexpected initialization fault");
    if(!initialized) begin
      if(!client_waitrequest || amm_read) $fatal(1,"client admitted before scrub completion");
      if(amm_write) begin
        if(writes>=LINES || amm_address!==25'(writes) || amm_writedata!=='0 ||
           amm_byteenable!=='1 || amm_burstcount!==7'd1)
          $fatal(1,"scrub address/data mismatch at line %0d",writes);
        if(amm_ready)writes++;else stalls++;
      end
    end else begin
      if(writes!=LINES || amm_write || !amm_read || amm_address!==client_address ||
         amm_byteenable!==client_byteenable || amm_burstcount!==7'd1)
        $fatal(1,"full-aperture handoff mismatch");
      if(amm_ready)client_reads++;
    end
  end
  task cycle;
    @(posedge clk);#1;@(negedge clk);#1;
  endtask
  initial begin
    repeat(2)cycle();reset_n=1;
    repeat(3)cycle();
    if(writes || initialized || amm_write) $fatal(1,"scrub before calibration");
    cal_success=1;
    while(!initialized)cycle();
    if(writes!=LINES || stalls==0) $fatal(1,"incomplete aperture/stall coverage");
    while(client_reads==0)cycle();
    $display("DDR_FULL_SCRUB_PASS lines=%0d payload_bytes=%0d stalls=%0d client_reads=%0d",writes,writes*64,stalls,client_reads);
    $finish;
  end
endmodule
