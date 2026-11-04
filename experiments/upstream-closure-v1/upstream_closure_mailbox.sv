// PCIe-clock mailbox for an ordered host producer-closure marker. This accepts
// a software closure assertion; it does not infer DMA drain or prove ordering
// before the endpoint. A caller must close publication, then deliver the marker
// before hardware STOP can stall earlier posted writes in the shared RX FIFO.
// Trusted reopen is a held request/ack handshake. Admission stays closed until
// ack; requests and context must be coherent in clk. Only cold reset resets round.
module upstream_closure_mailbox(
 input logic clk,cold_reset_n,
 input logic context_valid,context_fault,
 input logic [191:0] context_identity,
 input logic read,write,
 input logic [5:0] address,
 input logic [31:0] writedata,
 input logic [3:0] byteenable,
 output logic readdatavalid,
 output logic [31:0] readdata,
 input logic reopen_request,
 input logic [63:0] reopen_round,
 output logic reopen_ack,
 output logic [63:0] round,
 output wire upstream_closed,
 output logic fault
);
 logic closed;
 logic [255:0] staging;
 logic [7:0] staged;
 logic [63:0] acknowledged_round;
 logic have_identity;
 logic [191:0] held_identity;
 wire word_selected=address>=8 && address<=36 && address[1:0]==0;
 wire [2:0] index=(address-6'd8)>>2;
 wire [255:0] expected={round,context_identity};
 wire identity_changed=have_identity && (!context_valid || context_identity!=held_identity);
 assign upstream_closed=closed && !fault && context_valid && !context_fault && !identity_changed && cold_reset_n;
 always_ff @(posedge clk or negedge cold_reset_n)begin
  if(!cold_reset_n)begin
   round<=1;closed<=0;fault<=0;staging<=0;staged<=0;
   reopen_ack<=0;acknowledged_round<=0;readdata<=0;readdatavalid<=0;
   have_identity<=0;held_identity<=0;
  end else begin
   readdatavalid<=read;readdata<=0;
   if(context_fault || identity_changed)fault<=1;
   if(!reopen_request)reopen_ack<=0;
   else if(reopen_ack)begin
    if(reopen_round!=acknowledged_round)fault<=1;
   end else if(!fault && !context_fault && context_valid && !identity_changed)begin
    if(!closed || reopen_round!=round || round==64'hffffffffffffffff || write)fault<=1;
    else begin
     closed<=0;round<=round+1'b1;staged<=0;staging<=0;
     reopen_ack<=1;acknowledged_round<=round;
    end
   end
   if(read && !write)begin
    case(address)
     0:readdata<=32'ha10b0001;
     4:readdata<={28'b0,context_valid,reopen_ack,fault,upstream_closed};
     8,12,16,20,24,28,32,36:readdata<=expected[32*index+:32];
     40:readdata<=0;
     44:readdata<=1;
     default:fault<=1;
    endcase
   end
   if(write)begin
    if(read || byteenable!=4'hf || fault || context_fault || !context_valid || identity_changed ||
       closed || reopen_request || reopen_ack)fault<=1;
    else if(word_selected)begin staging[32*index+:32]<=writedata;staged[index]<=1;end
    else if(address==40 && writedata==32'ha10b0001 && staged==8'hff && staging==expected &&
            context_identity[191:64]!=0 && context_identity[63:0]!=0)begin
     closed<=1;have_identity<=1;held_identity<=context_identity;
    end
    else fault<=1;
   end
  end
 end
endmodule
