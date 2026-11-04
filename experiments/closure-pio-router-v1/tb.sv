module tb;
 logic pclk=0,kclk=0;always #7 pclk=~pclk;always #5 kclk=~kclk;
 logic rst=0,rd=0,wr=0,stall=1;
 logic [63:0] addr=0;
 wire waitreq,valid,nrd,nwr,nwait,nvalid,mrd,mwr,mvalid;
 wire [31:0] data,ndata,mdata;wire [63:0] ma;wire [31:0] mw;wire [3:0] mb;
 wire ack,closed,fault;wire [63:0] round;
 logic response;logic [31:0] response_data;
 closure_pio_router router(.clk(pclk),.cold_reset_n(rst),.read(rd),.write(wr),.address(addr),
 .writedata(32'b0),.byteenable(4'hf),.waitrequest(waitreq),.readdatavalid(valid),.readdata(data),
 .normal_read(nrd),.normal_write(nwr),.normal_waitrequest(nwait),.normal_readdatavalid(nvalid),.normal_readdata(ndata),
 .context_valid(1'b1),.context_fault(1'b0),.context_identity({128'd1,64'hfedcba9800000009}),
 .reopen_request(1'b0),.reopen_round(64'd0),.reopen_ack(ack),.upstream_closed(closed),.fault,.round);
 pio_cdc_bridge normal(.src_clk(pclk),.dst_clk(kclk),.common_cold_reset_n(rst),
 .s_read(nrd),.s_write(nwr),.s_address(addr),.s_writedata(32'b0),.s_byteenable(4'hf),
 .s_waitrequest(nwait),.s_readdatavalid(nvalid),.s_readdata(ndata),
 .m_read(mrd),.m_write(mwr),.m_address(ma),.m_writedata(mw),.m_byteenable(mb),
 .m_waitrequest(stall),.m_readdatavalid(response),.m_readdata(response_data));
 always_ff @(posedge kclk or negedge rst)
  if(!rst)begin response<=0;response_data<=0;end
  else begin response<=mrd&&!stall;if(mrd&&!stall)response_data<=32'h12345678;end
 int normal_responses=0,closure_responses=0;
 always @(negedge pclk)if(rst&&valid)begin
  assert(!(nvalid&&router.local_valid))else $fatal(1,"colliding responses");
  if(data==32'h12345678)normal_responses++;
  else if(data==32'ha10b0001)closure_responses++;
  else $fatal(1,"wrong response");
 end
 initial begin
  repeat(3)@(negedge pclk);rst=1;repeat(5)@(negedge pclk);
  addr=64'h100000100;rd=1;@(negedge pclk);rd=0;
  wait(mrd);@(negedge pclk);addr=64'h100000340;rd=1;
  repeat(8)begin @(posedge pclk);assert(waitreq&&!router.local_valid&&!nrd)else $fatal(1,"closure bypassed outstanding CDC");end
  @(negedge kclk);stall=0;
  do @(posedge pclk);while(waitreq);
  @(negedge pclk);rd=0;
  repeat(4)@(negedge pclk);
  assert(normal_responses==1&&closure_responses==1&&!fault&&!closed)else $fatal(1,"response ordering");
  $display("CLOSURE_PIO_ROUTER_PASS delayed_normal response_order HIP_relative_address");$finish;
 end
endmodule
