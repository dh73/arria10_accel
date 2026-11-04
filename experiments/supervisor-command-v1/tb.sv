module tb;
 logic clk=0;always #5 clk=~clk;
 logic cold_reset_n=0,write_permit=1,read=0,write=0;
 logic [4:0] address=0;logic [31:0] writedata=0;logic [3:0] byteenable=15;
 wire readdatavalid,invalid_access,cmd_valid,busy;wire [31:0] readdata;wire [2:0] cmd_op;
 logic cmd_ready=0,cmd_done=0,cmd_accepted=0;logic [3:0] cmd_reason=0;
 int offers=0;
 supervisor_command_mailbox dut(.*);
 always @(posedge clk)if(cmd_valid&&cmd_ready)offers++;
 task tick;@(posedge clk);#1;endtask
 task wr(input int a,input logic[31:0] d);
  @(negedge clk);address=5'(a);writedata=d;write=1;tick();@(negedge clk);write=0;
 endtask
 task rd(input int a);
  @(negedge clk);address=5'(a);read=1;tick();if(!readdatavalid)$fatal(1,"no read response");@(negedge clk);read=0;
 endtask
 task request(input logic[63:0] id,input int op);
  wr(0,id[31:0]);wr(4,id[63:32]);wr(8,32'(op));wr(12,32'ha10c0001);
 endtask
 task complete(input bit ok,input logic[3:0] why);
  @(negedge clk);cmd_ready=1;tick();@(negedge clk);cmd_ready=0;
  if(cmd_valid||!busy)$fatal(1,"issue replay or dropped custody");
  repeat(3)tick();if(!busy)$fatal(1,"completion invented");
  @(negedge clk);cmd_done=1;cmd_accepted=ok;cmd_reason=why;tick();
  @(negedge clk);cmd_done=0;
 endtask
 initial begin
  repeat(2)tick();@(negedge clk);cold_reset_n=1;tick();
  wr(12,32'ha10c0001);if(busy||cmd_valid)$fatal(1,"partial staging issued");
  request(64'd1,0);if(!cmd_valid||cmd_op!=0)$fatal(1,"capture failed");
  @(negedge clk);write_permit=0;
  repeat(4)tick();if(!cmd_valid||cmd_op!=0)$fatal(1,"permission loss cancelled capture");
  wr(8,2);wr(12,32'ha10c0001);if(cmd_op!=0)$fatal(1,"held command mutated");
  complete(1,0);rd(16);if(readdata!=6)$fatal(1,"result missing");rd(24);if(readdata!=1)$fatal(1,"wrong result owner");
  @(negedge clk);write_permit=1;request(64'd1,2);if(busy)$fatal(1,"replayed ID accepted");
  request(64'h100000002,2);complete(0,5);rd(20);if(readdata!=5)$fatal(1,"rejection reason lost");
  rd(24);if(readdata!=2)$fatal(1,"low ID lost");rd(28);if(readdata!=1)$fatal(1,"high ID lost");
  rd(16);if(readdata!=2)$fatal(1,"rejection mistaken for acceptance");
  request(64'hffffffffffffffff,1);complete(1,0);
  request(64'd1,0);if(busy||offers!=3)$fatal(1,"wrapped or duplicate command");
  $display("SUPERVISOR_COMMAND_PASS retained_offer permission_loss busy_mutation stale_id high_id rejection no_wrap offers=3");$finish;
 end
endmodule
