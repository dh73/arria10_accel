// SPDX-License-Identifier: BSD-3-Clause
`default_nettype none
// The engine owns the burst until the actual selected destination accepts it.
// This route contains no posted-write FIFO and never acknowledges an enqueue.
module dma_fetch_return_route_v5 (
  input wire clk, rstn, enable, inhibit,
  input wire [31:0] epoch,
  input wire [63:0] s_address,
  input wire s_write,
  input wire [255:0] s_data,
  input wire [31:0] s_byteenable,
  input wire [4:0] s_burstcount,
  input wire [31:0] s_epoch,
  input wire [19:0] s_token,
  input wire [63:0] s_base,
  input wire [7:0] s_count,
  output logic s_waitrequest,
  output wire [63:0] payload_address,
  output logic payload_write,
  output wire [255:0] payload_data,
  output wire [31:0] payload_byteenable,
  output wire [4:0] payload_burstcount,
  input wire payload_waitrequest,
  output logic [1:0] dts_write,
  output wire [1:0][255:0] dts_data,
  output wire [1:0][31:0] dts_epoch,
  output wire [1:0][19:0] dts_token,
  output wire [1:0][6:0] dts_index,
  input wire [1:0] dts_waitrequest,
  output wire fault_now,
  output logic fault,
  output logic [7:0] fault_reason,
  output logic [31:0] fault_epoch,
  output logic [19:0] fault_token,
  output logic [63:0] fault_address,
  output wire [7:0] reason_now,
  output wire [63:0] beat_address,
  output wire accept,
  output wire busy
);
  localparam logic [64:0] DDR_END=65'h080000000;
  localparam logic [64:0] RD_DTS=65'h080000000, WR_DTS=65'h080002000;
  localparam logic [64:0] DTS_BYTES=65'h02000;
  logic active;
  logic [4:0] accepted_beats, count_q;
  logic [63:0] address_q, base_q;
  logic [31:0] epoch_q, session_epoch;
  logic [19:0] token_q;
  logic [7:0] entries_q;
  logic session_valid;
  logic [7:0] fault_reason_q;
  logic [31:0] fault_epoch_q;
  logic [19:0] fault_token_q;
  logic [63:0] fault_address_q;
  wire [64:0] burst_end={1'b0,s_address}+({60'b0,s_burstcount}<<5);
  wire [64:0] effective={1'b0,s_address}+({60'b0,accepted_beats}<<5);
  wire [64:0] table_end={1'b0,s_base}+({57'b0,s_count}<<5);
  wire [64:0] delta=effective-{1'b0,s_base};
  wire in_payload={1'b0,s_address}<DDR_END && burst_end<=DDR_END;
  wire in_read={1'b0,s_address}>=RD_DTS && burst_end<=RD_DTS+DTS_BYTES;
  wire in_write={1'b0,s_address}>=WR_DTS && burst_end<=WR_DTS+DTS_BYTES;
  wire immutable_ok=!active || {s_address,s_burstcount,s_epoch,s_token,s_base,s_count}==
                                  {address_q,count_q,epoch_q,token_q,base_q,entries_q};
  wire header_ok=s_address[4:0]==0 && s_burstcount>=1 && s_burstcount<=16;
  wire identity_ok=s_token[19:12]!=0 && s_epoch==session_epoch;
  wire table_ok=s_base[4:0]==0 && s_count>=1 && s_count<=128 &&
    effective>={1'b0,s_base} && burst_end<=table_end && delta[4:0]==0 &&
    delta[64:5] < {52'b0,s_count} &&
    (s_token[6] ? ({1'b0,s_base}>=WR_DTS && table_end<=WR_DTS+DTS_BYTES) :
                  ({1'b0,s_base}>=RD_DTS && table_end<=RD_DTS+DTS_BYTES));
  wire session_bad=session_valid && (!enable || epoch!=session_epoch);
  wire route_bad=s_token[7] ? !(s_token[6] ? in_write : in_read) : !in_payload;
  wire [7:0] event_reason=session_bad ? 8'd1 :
    !session_valid || !enable ? 8'd2 :
    !header_ok ? 8'd3 : !immutable_ok ? 8'd4 : !identity_ok ? 8'd5 :
    route_bad ? 8'd6 : s_token[7] && !table_ok ? 8'd7 :
    s_token[7] && s_byteenable!=32'hffffffff ? 8'd8 : 8'd0;
  assign fault_now=fault || session_bad || (s_write && event_reason!=0);
  assign reason_now=fault ? fault_reason_q : event_reason;
  // Context is valid on the offending edge, then retained. Session faults
  // have no attributable owner, even if an unrelated burst owns the port.
  assign fault_reason=reason_now;
  assign fault_epoch=fault ? fault_epoch_q : (session_bad ? epoch : s_epoch);
  assign fault_token=fault ? fault_token_q : (session_bad ? 20'b0 : s_token);
  assign fault_address=fault ? fault_address_q : (session_bad ? 64'b0 : effective[63:0]);
  assign beat_address=effective[63:0];
  assign busy=active || s_write;
  assign accept=s_write && !s_waitrequest;
  assign payload_address=s_address;
  assign payload_data=s_data;
  assign payload_byteenable=s_byteenable;
  assign payload_burstcount=s_burstcount;
  for(genvar p=0;p<2;p++) begin : sidebands
    assign dts_data[p]=s_data;
    assign dts_epoch[p]=s_epoch;
    assign dts_token[p]=s_token;
    assign dts_index[p]=delta[11:5];
  end
  always_comb begin
    payload_write=0; dts_write=0; s_waitrequest=1;
    if(rstn && enable && session_valid && !fault_now && !inhibit) begin
      if(!s_token[7]) begin
        payload_write=s_write;
        s_waitrequest=payload_waitrequest;
      end else begin
        dts_write[s_token[6]]=s_write;
        s_waitrequest=dts_waitrequest[s_token[6]];
      end
    end
  end
  always_ff @(posedge clk or negedge rstn) begin
    if(!rstn) begin
      active<=0; accepted_beats<=0; count_q<=0; address_q<=0;
      epoch_q<=0; token_q<=0; base_q<=0; entries_q<=0;
      session_valid<=0; session_epoch<=0;
      fault<=0; fault_reason_q<=0; fault_epoch_q<=0; fault_token_q<=0; fault_address_q<=0;
    end else begin
      if(enable && !session_valid) begin session_valid<=1; session_epoch<=epoch; end
      if(fault_now && !fault) begin
        fault<=1; fault_reason_q<=event_reason;
        fault_epoch_q<=session_bad ? epoch : s_epoch;
        fault_token_q<=session_bad ? 20'b0 : s_token;
        fault_address_q<=session_bad ? 64'b0 : effective[63:0];
      end
      if(accept) begin
        if(!active) begin
          address_q<=s_address; count_q<=s_burstcount; epoch_q<=s_epoch;
          token_q<=s_token; base_q<=s_base; entries_q<=s_count;
          active<=s_burstcount!=1;
          accepted_beats<=s_burstcount==1 ? 0 : 1;
        end else if(accepted_beats==count_q-1'b1) begin
          active<=0; accepted_beats<=0;
        end else accepted_beats<=accepted_beats+1'b1;
      end
    end
  end
  // The effective address increments ONLY for an accepted beat of this burst.
  assert property (@(posedge clk) disable iff(!rstn)
    accept |-> $onehot({payload_write,dts_write}) && !fault_now);
  assert property (@(posedge clk) disable iff(!rstn)
    active && !accept |=> $stable({accepted_beats,address_q,count_q,epoch_q,token_q,base_q,entries_q}));
  assert property (@(posedge clk) disable iff(!rstn || fault_now)
    s_write && s_waitrequest |=> s_write &&
    $stable({s_address,s_burstcount,s_data,s_byteenable,s_epoch,s_token,s_base,s_count}));
  assert property (@(posedge clk) disable iff(!rstn)
    (|(dts_write & ~dts_waitrequest)) |-> accept && s_token[7] && table_ok &&
    beat_address==s_base+({57'b0,dts_index[s_token[6]]}<<5));
endmodule
`default_nettype wire
