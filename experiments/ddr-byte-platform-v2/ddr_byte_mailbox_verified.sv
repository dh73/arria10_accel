// BAR2-relative DWORD registers: 0 version, 4 status, 8/12 address,
// 16 data, 20 byte mask, 24 sequence, 28 submit=1, 32 completed sequence.
// One masked DWORD write followed by a same-line read; never read-modify-write.
// Completion requires matching selected bytes from the accepted read response.
// Requires an ordered, non-cached memory port and exclusive ownership of the
// selected bytes until completion. This is not a global DMA/host fence.
module ddr_byte_mailbox_verified #(
 parameter logic [63:0] MEMORY_BYTES=64'h80000000
)(
 input logic clk,cold_reset_n,context_valid,write_permit,memory_ready,
 input logic [191:0] context_identity,
 input logic read,write,
 input logic [5:0] address,
 input logic [31:0] writedata,
 input logic [3:0] byteenable,
 output wire waitrequest,
 output logic readdatavalid,
 output logic [31:0] readdata,
 output logic pending,fault,
 output wire m_write,m_read,
 output wire [24:0] m_address,
 output wire [511:0] m_writedata,
 output wire [63:0] m_byteenable,
 input logic m_waitrequest,m_readdatavalid,m_readdataerror,
 input logic [511:0] m_readdata
);
 typedef enum logic [1:0] {WRITE_OFFER,READ_OFFER,READ_RESPONSE} phase_t;
 phase_t phase;
 logic [63:0] staged_address,owned_address;
 logic [31:0] staged_data,staged_mask,staged_sequence,owned_data,owned_sequence;
 logic [3:0] owned_mask;
 logic [4:0] staged_valid;
 logic [31:0] last_sequence,completed_sequence;
 logic [191:0] owned_context;
 wire same_context=context_valid && context_identity==owned_context;
 assign waitrequest=!cold_reset_n || (write && pending);
 assign m_write=pending && !fault && same_context && phase==WRITE_OFFER;
 assign m_read=pending && !fault && same_context && phase==READ_OFFER;
 assign m_address=owned_address[30:6];
 assign m_writedata=({480'b0,owned_data} << (8*owned_address[5:0]));
 assign m_byteenable=({60'b0,owned_mask} << owned_address[5:0]);
 wire response_owned=pending && same_context && !fault &&
  (phase==READ_RESPONSE || (m_read && !m_waitrequest));
 logic response_matches;
 always_comb begin
  response_matches=1'b1;
  for(integer lane=0;lane<64;lane=lane+1)
   if(m_byteenable[lane] && m_readdata[lane*8+:8]!==m_writedata[lane*8+:8])response_matches=1'b0;
 end
 wire can_submit=context_valid && context_identity!=0 && write_permit && memory_ready &&
  staged_valid==5'b11111 && staged_address[1:0]==0 &&
  MEMORY_BYTES>=4 && staged_address<=MEMORY_BYTES-4 && staged_address[63:31]==0 &&
  staged_mask[31:4]==0 && staged_mask[3:0]!=0 &&
  last_sequence!=32'hffffffff && staged_sequence==last_sequence+1;
 always_ff @(posedge clk or negedge cold_reset_n) begin
  if(!cold_reset_n)begin
   staged_address<=0;owned_address<=0;staged_data<=0;staged_mask<=0;staged_sequence<=0;
   owned_data<=0;owned_mask<=0;owned_sequence<=0;owned_context<=0;staged_valid<=0;
   pending<=0;fault<=0;last_sequence<=0;completed_sequence<=0;phase<=WRITE_OFFER;
   readdatavalid<=0;readdata<=0;
  end else begin
   readdatavalid<=0;
   // Context loss cannot discharge an accepted mailbox command. Preserve debt
   // and require platform reset containment/recovery; do not replay it.
   if(pending && !same_context)fault<=1;
   if(m_write && !m_waitrequest)phase<=READ_OFFER;
   if(m_read && !m_waitrequest)phase<=READ_RESPONSE;
   if(m_readdatavalid)begin
    if(!response_owned || !response_matches || m_readdataerror)fault<=1;
    else begin pending<=0;completed_sequence<=owned_sequence;end
   end
   if(read && !waitrequest)begin
    readdatavalid<=1;
    case(address)
     0:readdata<=32'h42595702;
     4:readdata<={29'b0,completed_sequence!=0,fault,pending};
     32:readdata<=completed_sequence;
     default:readdata<=32'hffffffff;
    endcase
   end
   if(write && !waitrequest)begin
    if(byteenable!=4'hf || read || fault)fault<=1;
    else case(address)
     8:begin staged_address[31:0]<=writedata;staged_valid[0]<=1;end
     12:begin staged_address[63:32]<=writedata;staged_valid[1]<=1;end
     16:begin staged_data<=writedata;staged_valid[2]<=1;end
     20:begin staged_mask<=writedata;staged_valid[3]<=1;end
     24:begin staged_sequence<=writedata;staged_valid[4]<=1;end
     28:if(writedata==1 && can_submit)begin
      owned_address<=staged_address;owned_data<=staged_data;owned_mask<=staged_mask[3:0];
      owned_sequence<=staged_sequence;last_sequence<=staged_sequence;owned_context<=context_identity;
      staged_valid<=0;pending<=1;phase<=WRITE_OFFER;
     end else fault<=1;
     default:fault<=1;
    endcase
   end
  end
 end
endmodule
