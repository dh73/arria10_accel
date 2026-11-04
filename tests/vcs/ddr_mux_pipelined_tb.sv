module mux_tb;
  parameter int DEPTH=3;
  logic clk=0;always #5 clk=~clk;
  logic common_cold_reset_n=0,backend_reset_n=0,dma_lock=0;
  logic [1:0][24:0] req_address='0;
  logic [1:0] req_read=0,req_write=0,req_waitrequest,rsp_valid,rsp_error;
  logic [1:0][511:0] req_writedata='0;
  logic [1:0][63:0] req_byteenable='1;
  wire [511:0] rsp_data;
  logic [24:0] avm_address;
  logic avm_read,avm_write;
  logic [511:0] avm_writedata;
  logic [63:0] avm_byteenable;
  wire [0:0] avm_burstcount;
  logic avm_waitrequest=0,avm_readdatavalid=0,avm_readdataerror=0;
  logic [511:0] avm_readdata=0;
  logic fault;
  arria10_dma_ddr_mux_pipelined #(.READ_DEPTH(DEPTH)) dut(.*);
  typedef struct packed {logic owner;logic [24:0] address;} tag_t;
  tag_t pending[$];
  tag_t expected,newtag;
  int accepts=0,responses=0,max_pending=0,simultaneous=0,zero_returns=0;
  int full_replacements=0,error_returns=0;
  logic [1:0] accepted_clients;
  bit monitor=1;
  always @(posedge clk) begin
    accepted_clients=0;
    if(common_cold_reset_n && monitor && dut.live) begin
      for(int i=0;i<2;i++) if((req_read[i]||req_write[i])&&!req_waitrequest[i]) accepted_clients[i]=1;
      assert($onehot0(accepted_clients)) else $fatal(1,"multiple accepts");
      assert((|accepted_clients)==((avm_read||avm_write)&&!avm_waitrequest)) else $fatal(1,"early ack");
      if(|accepted_clients) begin
        newtag.owner=accepted_clients[1];newtag.address=req_address[newtag.owner];
        assert(avm_address==newtag.address && avm_read==req_read[newtag.owner] &&
          avm_writedata==req_writedata[newtag.owner] && avm_byteenable==req_byteenable[newtag.owner]) else $fatal(1,"command mismatch");
        accepts++;
      end
      if(avm_readdatavalid) begin
        if(pending.size()!=0) expected=pending.pop_front();
        else begin
          assert(avm_read&&!avm_waitrequest) else $fatal(1,"bench unsolicited response");
          expected=newtag;zero_returns++;
        end
        assert(rsp_valid==(2'b01<<expected.owner) && rsp_error==(avm_readdataerror?(2'b01<<expected.owner):0)) else $fatal(1,"response owner/error mismatch");
        assert(rsp_data==512'(expected.address)) else $fatal(1,"response data mismatch");
        responses++;if(avm_readdataerror) error_returns++;
      end else assert(rsp_valid==0 && rsp_error==0) else $fatal(1,"extra response");
      if(avm_read&&!avm_waitrequest) begin
        if(avm_readdatavalid) begin
          simultaneous++;
          if(dut.count==DEPTH) full_replacements++;
        end
        if(!(avm_readdatavalid && dut.count==0)) pending.push_back(newtag);
      end
      if(pending.size()>max_pending) max_pending=pending.size();
      assert(pending.size()<=DEPTH) else $fatal(1,"overcommit");
    end
  end
  task automatic tick(input bit stalled=0,input bit give_response=0,input bit zero=0,input bit error=0);
    @(negedge clk);
    avm_waitrequest=stalled;avm_readdatavalid=0;avm_readdataerror=error;
    if(give_response && pending.size()!=0) begin
      avm_readdatavalid=1;avm_readdata=512'(pending[0].address);
    end
    #1;
    if(zero && pending.size()==0 && avm_read && !avm_waitrequest) begin
      avm_readdatavalid=1;avm_readdata=512'(avm_address);
    end
    @(posedge clk);#1;
    for(int i=0;i<2;i++) if(accepted_clients[i]) begin
      req_address[i]=req_address[i]+1'b1;
      req_writedata[i]=req_writedata[i]+1'b1;
      req_byteenable[i]={req_byteenable[i][62:0],req_byteenable[i][63]};
    end
  endtask
  task automatic drain;
    while(|(req_read|req_write)) begin
      tick(0,1);
      req_read=req_read&~accepted_clients;req_write=req_write&~accepted_clients;
    end
    while(pending.size()!=0) tick(0,1);
    tick();assert(!fault && dut.count==0) else $fatal(1,"drain fault");
  endtask
  task automatic reset;
    @(negedge clk);common_cold_reset_n=0;backend_reset_n=0;
    req_read=0;req_write=0;dma_lock=0;avm_readdatavalid=0;pending.delete();
    repeat(3) @(negedge clk);
    common_cold_reset_n=1;backend_reset_n=1;
    repeat(5) tick();
    assert(!fault) else $fatal(1,"cold reset failed");
  endtask
  int before_count,seed=17,discard;
  initial begin
    discard=$value$plusargs("SEED=%d",seed);discard=$urandom(seed);
    reset();req_address[0]=25'h100;req_address[1]=25'h10000;
    req_byteenable[0]=64'h123456789abcdef0;req_byteenable[1]=64'hfedcba9876543210;
    req_read=3;
    repeat(DEPTH) tick();
    before_count=accepts;repeat(3) tick();
    assert(accepts==before_count && pending.size()==DEPTH) else $fatal(1,"full FIFO did not backpressure");
    before_count=accepts;
    repeat(20) tick(0,1,0,1);
    assert(accepts-before_count==20 && pending.size()==DEPTH)
      else $fatal(1,"delayed read pipeline bubble");
    repeat(100) tick($urandom_range(0,1),$urandom_range(0,1),0,$urandom_range(0,1));
    drain();
    req_read=3;repeat(20) tick(0,0,1);drain();
    req_write=3;before_count=accepts;repeat(20) tick();
    assert(accepts-before_count==20) else $fatal(1,"write pipeline bubble");drain();
    // An already stalled core offer survives a newly asserted DMA lock.
    req_read=1;tick(1);dma_lock=1;req_read=3;
    repeat(3) tick(1);tick();
    assert(accepted_clients==1 && pending.size()==1) else $fatal(1,"held core lost");
    req_read[0]=0;before_count=accepts;repeat(3) tick();
    assert(accepts==before_count) else $fatal(1,"DMA granted before core drain");
    tick(0,1);tick();assert(accepted_clients==2) else $fatal(1,"DMA did not acquire");
    req_read[1]=0;while(pending.size()!=0) tick(0,1);
    // Lock excludes a waiting core even when DMA has no command.
    req_write=1;before_count=accepts;repeat(3) tick();
    assert(accepts==before_count) else $fatal(1,"DMA exclusion broken");
    dma_lock=0;drain();
    // A DMA offer made BEFORE lock assertion is also immutable, even with
    // older core read debt. The drain rule gates NEW offers, never revocation.
    if(DEPTH>1) begin
      req_read=1;tick();req_read=2;tick(1);
      assert(dut.held && dut.held_owner && dut.core_count==1)
        else $fatal(1,"held DMA transition setup");
      dma_lock=1;repeat(3) tick(1);tick();
      assert(accepted_clients==2 && pending.size()==2 && dut.core_count==1)
        else $fatal(1,"held DMA offer was revoked");
      req_read=0;req_write=2;before_count=accepts;repeat(3) tick();
      assert(accepts==before_count) else $fatal(1,"new DMA offer bypassed core debt");
      tick(0,1);tick();assert(accepted_clients==2) else $fatal(1,"new DMA offer failed after core drain");
      req_write=0;while(pending.size()!=0) tick(0,1);dma_lock=0;tick();
    end
    assert(max_pending==DEPTH && full_replacements>0 && zero_returns>0 && error_returns>0)
      else $fatal(1,"coverage missing");
    // Backend reset invalidates the epoch; recovery cannot silently rearm.
    req_read=1;tick();req_read=0;req_write=2;tick(1);
    backend_reset_n=0;repeat(3) tick(1);backend_reset_n=1;repeat(5) tick(1);
    assert(fault && !(avm_read||avm_write) && req_waitrequest==3 && dut.count==1 && dut.held)
      else $fatal(1,"backend loss did not quarantine");
    reset();
    // Unexpected response is a sticky failure, no invented owner.
    monitor=0;@(negedge clk);avm_readdatavalid=1;
    @(posedge clk);#1;
    assert(fault && rsp_valid==0) else $fatal(1,"unsolicited response accepted");
    $display("PIPELINED_MUX_PASS depth=%0d accepts=%0d responses=%0d max_pending=%0d full_replace=%0d zero=%0d error=%0d",DEPTH,accepts,responses,max_pending,full_replacements,zero_returns,error_returns);
    $finish;
  end
endmodule
