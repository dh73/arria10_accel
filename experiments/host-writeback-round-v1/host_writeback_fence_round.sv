// SPDX-License-Identifier: BSD-3-Clause
// Reusable drain certificate. CSR: status0, epoch4/8, session12..24,
// round28/32, commit36 (0xa10f0001). Eight full-word echoes are required.
// Ordered same-function MMIO and coherent producer closure remain contracts.
// reopen is a trusted one-cycle supervisor consumption event, never host MMIO.
// Initial startup requires the same real fence handshake as later resume.
// Context remains immutable across rounds; counter exhaustion fails closed.
// Cold reset requires fresh context and independently established DMA containment.
module host_writeback_fence_round (
 input logic clk,cold_reset_n,context_valid,
 input logic [127:0] session,
 input logic [63:0] epoch,
 input logic admission_closed,local_drained,tx_checkpoint_empty,
 input logic stop_requested,reopen,
 input logic read,write,
 input logic [5:0] address,
 input logic [31:0] writedata,
 input logic [3:0] byteenable,
 output logic readdatavalid,
 output logic [31:0] readdata,
 output logic ready,settled,fault
);
 logic armed,acknowledged,read_seen,context_bound,await_open;
 logic [63:0] round_id;
 logic [191:0] immutable_context;
 logic [255:0] bound_context,echo;
 logic [7:0] echoed;
 wire live=((context_valid && session!=0 && epoch!=0 &&
             stop_requested && admission_closed && local_drained)===1'b1);
 wire context_matches=({session,epoch}===immutable_context);
 wire safe_now=live && context_matches;
 assign ready=armed && !fault && safe_now;
 assign settled=ready && acknowledged;
 always_ff @(posedge clk or negedge cold_reset_n) begin
  if(!cold_reset_n)begin
   armed<=0;acknowledged<=0;read_seen<=0;bound_context<=0;
   context_bound<=0;immutable_context<=0;await_open<=0;round_id<=1;
   echo<=0;echoed<=0;fault<=0;readdata<=0;readdatavalid<=0;
  end else begin
   readdatavalid<=0;
   if(context_bound && (context_valid!==1'b1 || !context_matches))fault<=1;
   if(await_open && stop_requested===1'b0)await_open<=0;
   if(!armed && !await_open && live && tx_checkpoint_empty===1'b1 && !fault)begin
    armed<=1;bound_context<={round_id,session,epoch};
    if(!context_bound)begin context_bound<=1;immutable_context<={session,epoch};end
   end
   if(reopen!==1'b0)begin
    // Trusted supervisor consumes the certificate before opening admission.
    // Never wrap a generation or permit MMIO concurrently with consumption.
    if(reopen===1'b1 && settled && !read && !write && round_id!=64'hffffffffffffffff)begin
     armed<=0;acknowledged<=0;read_seen<=0;echo<=0;echoed<=0;
     round_id<=round_id+1;await_open<=1;
    end else fault<=1;
   end else if(armed && !safe_now)fault<=1;
   if(read || write)begin
    if(byteenable!==4'hf || address[1:0]!==0 || (read && write))begin
     fault<=1;
     if(read)begin readdatavalid<=1;readdata<=32'hffffffff;end
    end else if(read)begin
     readdatavalid<=1;
     case(address)
      0:begin readdata<={29'd0,fault,settled,ready};
        if(ready)read_seen<=1;end
      4,8,12,16,20,24,28,32:readdata<=bound_context[(address/4-1)*32+:32];
      default:begin readdata<=32'hffffffff;fault<=1;end
     endcase
    end else if(write)begin
     if(!ready || !read_seen || acknowledged)fault<=1;
     else case(address)
      4,8,12,16,20,24,28,32:begin
       echo[(address/4-1)*32+:32]<=writedata;
       echoed[address/4-1]<=1;
      end
      36:begin
       if(writedata===32'ha10f0001 && echoed===8'hff && echo===bound_context)
        acknowledged<=1;
       else fault<=1;
      end
      default:fault<=1;
     endcase
    end
   end
  end
 end
endmodule
