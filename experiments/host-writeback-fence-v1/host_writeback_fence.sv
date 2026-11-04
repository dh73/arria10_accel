// SPDX-License-Identifier: BSD-3-Clause
// One fence per coordinated cold-reset epoch. All inputs are coherent in clk.
// REQUIRED transport contract: the trusted driver observes READY with an
// ordered, non-relaxed same-function MMIO read before echoing context/commit.
// All relevant posted writes use that ordering domain (no relaxed/IDO bypass).
// local_drained includes every producer and TX pipeline, not FIFO count alone.
// A common reset requires a fresh session/epoch and separately proven old-DMA
// containment. Resetting this module never proves PCIe settlement.
module host_writeback_fence (
 input logic clk,cold_reset_n,context_valid,
 input logic [127:0] session,
 input logic [63:0] epoch,
 input logic admission_closed,local_drained,
 input logic read,write,
 input logic [4:0] address,
 input logic [31:0] writedata,
 input logic [3:0] byteenable,
 output logic readdatavalid,
 output logic [31:0] readdata,
 output logic ready,settled,fault
);
 logic armed,acknowledged,read_seen;
 logic [191:0] bound_context,echo;
 logic [5:0] echoed;
 wire live=((context_valid && session!=0 && epoch!=0 &&
             admission_closed && local_drained)===1'b1);
 wire context_matches=({session,epoch}===bound_context);
 wire safe_now=live && context_matches;
 assign ready=armed && !fault && safe_now;
 assign settled=ready && acknowledged;
 always_ff @(posedge clk or negedge cold_reset_n) begin
  if(!cold_reset_n)begin
   armed<=0;acknowledged<=0;read_seen<=0;bound_context<=0;
   echo<=0;echoed<=0;fault<=0;readdata<=0;readdatavalid<=0;
  end else begin
   readdatavalid<=0;
   if(!armed && live && !fault)begin
    armed<=1;bound_context<={session,epoch};
   end
   if(armed && !safe_now)fault<=1;
   if(read || write)begin
    if(byteenable!==4'hf || address[1:0]!==0 || (read && write))begin
     fault<=1;
     if(read)begin readdatavalid<=1;readdata<=32'hffffffff;end
    end else if(read)begin
     readdatavalid<=1;
     case(address)
      0:begin readdata<={29'd0,fault,settled,ready};
        if(ready)read_seen<=1;end
      4,8,12,16,20,24:readdata<=bound_context[(address/4-1)*32+:32];
      default:begin readdata<=32'hffffffff;fault<=1;end
     endcase
    end else if(write)begin
     if(!ready || !read_seen || acknowledged)fault<=1;
     else case(address)
      4,8,12,16,20,24:begin
       echo[(address/4-1)*32+:32]<=writedata;
       echoed[address/4-1]<=1;
      end
      28:begin
       if(writedata===32'ha10f0001 && echoed===6'h3f && echo===bound_context)
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
