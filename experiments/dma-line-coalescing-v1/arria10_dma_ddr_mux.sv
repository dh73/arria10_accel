// Owner-preserving arbiter BELOW the existing two-owner DWORD DDR service.
// Requester 0 = unchanged core/normalized-host service; requester 1 = DMA.
// No early write acknowledgement: selected waitrequest falls only when the
// actual backend accepts the captured command. All commands have burstcount 1.
module arria10_dma_ddr_mux (
  input logic clk, common_cold_reset_n, backend_reset_n, dma_lock,
  input logic [1:0][24:0] req_address,
  input logic [1:0] req_read, req_write,
  input logic [1:0][511:0] req_writedata,
  input logic [1:0][63:0] req_byteenable,
  output logic [1:0] req_waitrequest,
  output logic [1:0] rsp_valid, rsp_error,
  output wire [511:0] rsp_data,
  output wire [24:0] avm_address,
  output wire avm_read, avm_write,
  output wire [511:0] avm_writedata,
  output wire [63:0] avm_byteenable,
  output wire [0:0] avm_burstcount,
  input logic avm_waitrequest, avm_readdatavalid, avm_readdataerror,
  input logic [511:0] avm_readdata,
  output logic fault
);
  (* async_reg = "true", preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) logic [1:0] release_q, health;
  wire health_n=common_cold_reset_n && backend_reset_n;
  always_ff @(posedge clk or negedge common_cold_reset_n)
    if (!common_cold_reset_n) release_q<=0; else release_q<={release_q[0],1'b1};
  always_ff @(posedge clk or negedge health_n)
    if (!health_n) health<=0; else health<={health[0],1'b1};
  wire reset_n=release_q[1];
  wire live=reset_n && health[1] && !fault;
  typedef enum logic [1:0] {IDLE,ISSUE,READ_WAIT} state_t;
  state_t state;
  logic owner, prefer_dma, armed, read_q, write_q;
  logic [24:0] address_q;
  logic [511:0] data_q;
  logic [63:0] be_q;
  wire [1:0] valid=req_read|req_write;
  wire select_dma=dma_lock || (valid[1] && (!valid[0] || prefer_dma));
  wire read_return=avm_readdatavalid &&
    (state==READ_WAIT || (state==ISSUE && read_q && !avm_waitrequest));
  assign avm_address=address_q;
  assign avm_read=live && state==ISSUE && read_q;
  assign avm_write=live && state==ISSUE && write_q;
  assign avm_writedata=data_q;
  assign avm_byteenable=be_q;
  assign avm_burstcount=1'b1;
  assign rsp_data=avm_readdata;
  always_comb begin
    req_waitrequest='1; rsp_valid='0; rsp_error='0;
    if (live) begin
      if (state==ISSUE) req_waitrequest[owner]=avm_waitrequest;
      if (read_return) begin
        rsp_valid[owner]=1;
        rsp_error[owner]=avm_readdataerror;
      end
    end
  end
  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      state<=IDLE; owner<=0; prefer_dma<=0; armed<=0; fault<=0;
      read_q<=0; write_q<=0; address_q<=0; data_q<=0; be_q<=0;
    end else begin
      if (health[1]) armed<=1;
      if (armed && !health[1]) fault<=1;
      if (avm_readdatavalid && !read_return) fault<=1;
      if (live) case (state)
        IDLE: if (valid[select_dma] && !avm_readdatavalid) begin
          if (req_read[select_dma] && req_write[select_dma]) fault<=1;
          else begin
            owner<=select_dma; address_q<=req_address[select_dma];
            read_q<=req_read[select_dma]; write_q<=req_write[select_dma];
            data_q<=req_writedata[select_dma]; be_q<=req_byteenable[select_dma];
            state<=ISSUE;
          end
        end
        ISSUE: if (!avm_waitrequest) begin
          prefer_dma<=!owner;
          if (read_q && !avm_readdatavalid) state<=READ_WAIT;
          else state<=IDLE;
        end
        READ_WAIT: if (avm_readdatavalid) state<=IDLE;
        default: fault<=1;
      endcase
    end
  end
`ifdef ARRIA10_ASSERTIONS
  assert property (@(posedge clk) disable iff (!reset_n || !live)
    state==ISSUE && avm_waitrequest |=>
    $stable({owner,avm_read,avm_write,avm_address,avm_writedata,avm_byteenable}));
  assert property (@(posedge clk) disable iff (!reset_n)
    $onehot0(rsp_valid) && !(~req_waitrequest[0] && ~req_waitrequest[1]));
  assert property (@(posedge clk) disable iff (!reset_n || !live)
    state==ISSUE |-> valid[owner] && req_read[owner]==read_q && req_write[owner]==write_q &&
      req_address[owner]==address_q && (!write_q ||
      (req_writedata[owner]==data_q && req_byteenable[owner]==be_q)));
`endif
endmodule
