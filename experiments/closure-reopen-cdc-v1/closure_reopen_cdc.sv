// Bundled held-round handshake. Both domains share a coordinated cold reset.
// A supervisor consumption pulse is held until the PCIe mailbox acknowledges;
// no next round is accepted before the four-phase handshake returns to idle.
// Physical CDC constraints and reset containment remain integration obligations.
module closure_reopen_cdc(
 input logic kernel_clk,pcie_clk,common_cold_reset_n,
 input logic consume,
 output wire kernel_ready,
 output logic fault,
 output wire reopen_request,
 output wire [63:0] reopen_round,
 input logic reopen_ack,
 output wire pcie_ready
);
 typedef enum logic [1:0] {IDLE,WAIT_ACK,WAIT_LOW} state_t;
 state_t state;
 logic request,opened;
 logic [63:0] held_round,next_round;
 (* async_reg="true" *) logic ack_meta,ack_sync;
 (* async_reg="true" *) logic req_meta,req_sync;
 (* async_reg="true" *) logic ready_meta,ready_sync;
 assign kernel_ready=opened && state==IDLE && !fault && !consume && common_cold_reset_n;
 assign reopen_request=req_sync && common_cold_reset_n;
 // Held before req_sync rises and through the return acknowledgment.
 assign reopen_round=held_round;
 assign pcie_ready=ready_sync && !req_sync && !reopen_ack && common_cold_reset_n;
 always_ff @(posedge kernel_clk or negedge common_cold_reset_n)begin
  if(!common_cold_reset_n)begin
   state<=IDLE;request<=0;opened<=0;fault<=0;held_round<=0;next_round<=1;
   ack_meta<=0;ack_sync<=0;
  end else begin
   ack_meta<=reopen_ack;ack_sync<=ack_meta;
   if(consume && (state!=IDLE || ack_sync || next_round==64'hffffffffffffffff))fault<=1;
   if(!fault)case(state)
    IDLE:if(consume && !ack_sync && next_round!=64'hffffffffffffffff)begin
     held_round<=next_round;request<=1;opened<=0;state<=WAIT_ACK;
    end
    WAIT_ACK:if(ack_sync)begin request<=0;state<=WAIT_LOW;end
    WAIT_LOW:if(!ack_sync)begin next_round<=next_round+1'b1;opened<=1;state<=IDLE;end
    default:fault<=1;
   endcase
  end
 end
 always_ff @(posedge pcie_clk or negedge common_cold_reset_n)begin
  if(!common_cold_reset_n)begin req_meta<=0;req_sync<=0;ready_meta<=0;ready_sync<=0;end
  else begin req_meta<=request;req_sync<=req_meta;ready_meta<=kernel_ready;ready_sync<=ready_meta;end
 end
endmodule
