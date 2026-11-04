// SPDX-License-Identifier: BSD-3-Clause
// Ordered, single-outstanding 32-bit PIO crossing. Both domains share a cold
// reset epoch; unilateral reset is unsupported. Bundled command/response buses
// stay stable until their two-stage synchronized toggle acknowledgements.
// Hardware integration must constrain bundled-data paths and audit synchronizers.
module pio_cdc_bridge (
 input logic src_clk,dst_clk,common_cold_reset_n,
 input logic s_read,s_write,
 input logic [63:0] s_address,
 input logic [31:0] s_writedata,
 input logic [3:0] s_byteenable,
 output logic s_waitrequest,s_readdatavalid,
 output logic [31:0] s_readdata,
 output logic m_read,m_write,
 output logic [63:0] m_address,
 output logic [31:0] m_writedata,
 output logic [3:0] m_byteenable,
 input logic m_waitrequest,m_readdatavalid,
 input logic [31:0] m_readdata
);
 (* async_reg="true" *) logic [1:0] req_sync,ack_sync;
 (* async_reg="true" *) logic [1:0] src_release,dst_release;
 logic req_toggle,ack_toggle,busy;
 logic held_read,held_write;
 logic [63:0] held_address;
 logic [31:0] held_data,response_data;
 logic [3:0] held_mask;
 typedef enum logic [1:0] {IDLE,ISSUE,RESPONSE} state_t;
 state_t state;
 assign s_waitrequest=!src_release[1] || busy;
 assign m_read=dst_release[1] && state==ISSUE && held_read;
 assign m_write=dst_release[1] && state==ISSUE && held_write;
 assign m_address=held_address;
 assign m_writedata=held_data;
 assign m_byteenable=held_mask;
 always_ff @(posedge src_clk or negedge common_cold_reset_n) begin
  if(!common_cold_reset_n) begin
   src_release<=0;ack_sync<=0;req_toggle<=0;busy<=0;
   held_read<=0;held_write<=0;held_address<=0;held_data<=0;held_mask<=0;
   s_readdatavalid<=0;s_readdata<=0;
  end else begin
   src_release<={src_release[0],1'b1};
   ack_sync<={ack_sync[0],ack_toggle};
   s_readdatavalid<=0;
   if(src_release[1]) begin
    if(busy && ack_sync[1]==req_toggle) begin
     busy<=0;
     if(held_read) begin s_readdata<=response_data;s_readdatavalid<=1;end
    end
    if((s_read || s_write) && !s_waitrequest) begin
     held_read<=s_read;held_write<=s_write;
     held_address<=s_address;held_data<=s_writedata;held_mask<=s_byteenable;
     req_toggle<=!req_toggle;busy<=1;
    end
   end
  end
 end
 always_ff @(posedge dst_clk or negedge common_cold_reset_n) begin
  if(!common_cold_reset_n) begin
   dst_release<=0;req_sync<=0;ack_toggle<=0;response_data<=0;state<=IDLE;
  end else begin
   dst_release<={dst_release[0],1'b1};
   req_sync<={req_sync[0],req_toggle};
   if(dst_release[1]) case(state)
    IDLE:if(req_sync[1]!=ack_toggle) state<=ISSUE;
    ISSUE:if(!m_waitrequest) begin
     if(!held_read) begin ack_toggle<=req_sync[1];state<=IDLE;end
     else if(m_readdatavalid) begin
      response_data<=m_readdata;ack_toggle<=req_sync[1];state<=IDLE;
     end else state<=RESPONSE;
    end
    RESPONSE:if(m_readdatavalid) begin
     response_data<=m_readdata;ack_toggle<=req_sync[1];state<=IDLE;
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
