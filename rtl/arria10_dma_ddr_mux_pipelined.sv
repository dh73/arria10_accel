// Isolated candidate: ordered, exactly-once DDR responses are an environment contract.
// A requester is acknowledged only at actual backend acceptance. No early writes.
module arria10_dma_ddr_mux_pipelined #(parameter int READ_DEPTH=8) (
  input logic clk, common_cold_reset_n, backend_reset_n, dma_lock,
  input logic [1:0][24:0] req_address,
  input logic [1:0] req_read, req_write,
  input logic [1:0][511:0] req_writedata,
  input logic [1:0][63:0] req_byteenable,
  output logic [1:0] req_waitrequest, rsp_valid, rsp_error,
  output wire [511:0] rsp_data,
  output logic [24:0] avm_address,
  output logic avm_read,avm_write,
  output logic [511:0] avm_writedata,
  output logic [63:0] avm_byteenable,
  output wire [0:0] avm_burstcount,
  input logic avm_waitrequest,avm_readdatavalid,avm_readdataerror,
  input logic [511:0] avm_readdata,
  output logic fault
);
  localparam int PW=READ_DEPTH>1?$clog2(READ_DEPTH):1;
  localparam int CW=$clog2(READ_DEPTH+1);
  (* async_reg="true",preserve *) logic [1:0] release_q,health;
  wire health_n=common_cold_reset_n && backend_reset_n;
  always_ff @(posedge clk or negedge common_cold_reset_n)
    if(!common_cold_reset_n) release_q<=0; else release_q<={release_q[0],1'b1};
  always_ff @(posedge clk or negedge health_n)
    if(!health_n) health<=0; else health<={health[0],1'b1};
  wire reset_n=release_q[1];
  logic armed,held,held_owner,held_read,prefer_dma;
  logic [24:0] held_address;
  logic [511:0] held_data;
  logic [63:0] held_be;
  logic owners[0:READ_DEPTH-1];
  logic [PW-1:0] head,tail;
  logic [CW-1:0] count,core_count;
  wire live=reset_n && health[1] && !fault;
  wire [1:0] valid=req_read|req_write;
  wire selected=dma_lock || (valid[1] && (!valid[0] || prefer_dma));
  wire owner=held?held_owner:selected;
  wire old_return=avm_readdatavalid && count!=0;
  wire space=count<CW'(READ_DEPTH) || old_return;
  wire accepted=(avm_read||avm_write) && !avm_waitrequest;
  wire push=accepted && avm_read;
  wire response_owned=count!=0 || push;
  wire pop=live && avm_readdatavalid && response_owned;
  wire response_owner=count!=0?owners[head]:owner;
  // A response to an empty-FIFO same-cycle read bypasses the ownership array.
  wire bypass=pop && count==0;
  wire enqueue=push && !bypass;
  wire dequeue=pop && count!=0;
  assign rsp_data=avm_readdata;
  assign avm_burstcount=1'b1;
  always_comb begin
    avm_address=held?held_address:req_address[selected];
    avm_writedata=held?held_data:req_writedata[selected];
    avm_byteenable=held?held_be:req_byteenable[selected];
    avm_read=0;avm_write=0;req_waitrequest='1;rsp_valid='0;rsp_error='0;
    if(live) begin
      // Once offered, neither lock changes nor arbitration can replace a stall.
      if(held) begin avm_read=held_read;avm_write=!held_read;end
      else if(valid[selected] && !(req_read[selected]&&req_write[selected]) &&
              (!dma_lock || core_count==0) && (!req_read[selected] || space)) begin
        avm_read=req_read[selected];avm_write=req_write[selected];
      end
      if(avm_read||avm_write) req_waitrequest[owner]=avm_waitrequest;
      if(pop) begin rsp_valid[response_owner]=1; rsp_error[response_owner]=avm_readdataerror;end
    end
  end
  function automatic [PW-1:0] next_ptr(input logic [PW-1:0] p);
    return p==PW'(READ_DEPTH-1)?'0:p+1'b1;
  endfunction
  always_ff @(posedge clk or negedge reset_n) begin
    if(!reset_n) begin
      fault<=0;armed<=0;held<=0;held_owner<=0;held_read<=0;prefer_dma<=0;
      held_address<=0;held_data<=0;held_be<=0;head<=0;tail<=0;count<=0;core_count<=0;
    end else begin
      if(health[1]) armed<=1;
      if(armed&&!health[1]) fault<=1;
      if(live) begin
        if(avm_readdatavalid&&!response_owned) fault<=1;
        if(!held && valid[selected] && req_read[selected]&&req_write[selected]) fault<=1;
        if((avm_read||avm_write)&&avm_waitrequest&&!held) begin
          held<=1;held_owner<=owner;held_read<=avm_read;
          held_address<=avm_address;held_data<=avm_writedata;held_be<=avm_byteenable;
        end
        if(accepted) begin held<=0;prefer_dma<=!owner;end
        if(enqueue) begin owners[tail]<=owner;tail<=next_ptr(tail);end
        if(dequeue) head<=next_ptr(head);
        case({enqueue,dequeue})
          2'b10:count<=count+1'b1;
          2'b01:count<=count-1'b1;
          default:begin end
        endcase
        case({push&&!owner,pop&&!response_owner})
          2'b10:core_count<=core_count+1'b1;
          2'b01:core_count<=core_count-1'b1;
          default:begin end
        endcase
      end
    end
  end
`ifndef SYNTHESIS
  initial if(READ_DEPTH<1) $fatal(1,"READ_DEPTH must be positive");
  assert property(@(posedge clk) disable iff(!reset_n||!live)
    (avm_read||avm_write)&&avm_waitrequest |=>
      $stable({avm_read,avm_write,avm_address,avm_writedata,avm_byteenable}));
  assert property(@(posedge clk) disable iff(!reset_n) count<=READ_DEPTH && core_count<=count);
  assert property(@(posedge clk) disable iff(!reset_n) $onehot0(rsp_valid));
  assert property(@(posedge clk) disable iff(!reset_n||!live)
    held |-> valid[held_owner] && req_read[held_owner]==held_read &&
      req_address[held_owner]==held_address && (!req_write[held_owner] ||
      {req_writedata[held_owner],req_byteenable[held_owner]}==={held_data,held_be}));
`endif
endmodule
