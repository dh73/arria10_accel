`timescale 1ns/1ps
module opencl_cra_retirement_tb;
  logic clock=0, resetn=0, rd=0, wr=0, done=0;
  logic [4:0] address=0;
  logic [63:0] wd=0;
  wire [63:0] data[2];
  wire [31:0] status[2];
  wire [1:0] valid, start;
  longint unsigned observed[2];
  int failures=0;
  always #5 clock=~clock;
`define PORTS(N) \
    .clock(clock), .resetn(resetn), .acl_counter_full(1'b0), \
    .acl_counter_size(32'b0), .avs_cra_address(address), \
    .avs_cra_byteenable(8'hff), .avs_cra_enable(1'b1), \
    .avs_cra_read(rd), .avs_cra_write(wr), .avs_cra_writedata(wd), \
    .has_a_lsu_active(1'b0), .has_a_write_pending(1'b0), \
    .kernel_done(done), .valid_in(1'b1), .acl_counter_reset(), \
    .avs_cra_readdata(data[N]), .avs_cra_readdatavalid(valid[N]), \
    .cra_irq(), .kernel_arguments(), .kernel_start(start[N]), .status(status[N])
  stream_copy512_function_cra_agent p1 (`PORTS(0));
  stream_triad512_function_cra_agent p2 (`PORTS(1));
`undef PORTS
  task automatic sample_read;
    for(int k=0;k<2;k++) begin
      if(valid[k] !== 1'b1 || $isunknown(data[k]))
        $fatal(1,"invalid CRA response kernel=%0d",k);
      observed[k]+=data[k];
    end
  endtask
  initial begin
    // Each case starts normally. No force, internal writes, or invented state.
    // Completion spans every edge surrounding the read and delayed clear.
    for(int pattern=0;pattern<2;pattern++) for(int offset=-2;offset<=2;offset++) begin
      @(negedge clock); resetn=0; rd=0; wr=0; done=0;
      observed[0]=0; observed[1]=0;
      repeat(3) @(negedge clock);
      resetn=1;
      @(negedge clock); address=1; wd=1; wr=1;
      @(negedge clock); wr=0;
      wait(start==2'b11);
      repeat(3) @(negedge clock);
      if(status[0][15] !== 1'b1 || status[1][15] !== 1'b1)
        $fatal(1,"normal start did not establish running state");
      for(int cycle=0;cycle<10;cycle++) begin
        @(negedge clock); address=6; rd=pattern==0 ? cycle==4 : (cycle>=2 && cycle<=6); done=(cycle==4+offset);
        @(posedge clock); #1;
        if(rd) sample_read();
      end
      // A later read collects anything not returned by the racing read.
      @(negedge clock); rd=1; done=0;
      @(posedge clock); #1; sample_read();
      @(negedge clock); rd=0;
      repeat(3) @(negedge clock);
      for(int k=0;k<2;k++) begin
        $display("OBSERVATION kernel=%0d pattern=%0d done_offset=%0d total=%0d",k+1,pattern,offset,observed[k]);
        if(observed[k]!=1) failures++;
      end
    end
    if(failures) $fatal(1,"completion conservation failed cases=%0d",failures);
    $display("OPENCL_CORRECTED_CRA_PASS cases=20");
    $finish;
  end
endmodule
