// Kernel-clock local provisioning window; caller provides serialized MMIO.
// One immutable session/epoch per coordinated cold reset. Identity only:
// this does not establish host ownership, reset containment, health, or drain.
// Read 0: signature; write 0: commit. 4: valid/fault. 8..28: six context words.
module platform_context_mailbox(
 input logic clk,cold_reset_n,read,write,
 input logic [5:0] address,
 input logic [31:0] writedata,
 input logic [3:0] byteenable,
 output logic readdatavalid,
 output logic [31:0] readdata,
 output logic invalid_access,context_valid,fault,
 output logic [63:0] epoch,
 output logic [127:0] session
);
 logic bound;
 logic [5:0] staged;
 logic [191:0] staging;
 wire word_selected=address>=8 && address<=28 && address[1:0]==0;
 wire [2:0] index=(address-6'd8)>>2;
 assign context_valid=bound && !fault && cold_reset_n;
 always_ff @(posedge clk or negedge cold_reset_n)begin
  if(!cold_reset_n)begin
   bound<=0;staged<=0;staging<=0;epoch<=0;session<=0;fault<=0;
   readdatavalid<=0;readdata<=0;invalid_access<=0;
  end else begin
   readdatavalid<=read;readdata<=0;invalid_access<=0;
   if(read && !write)begin
    case(address)
     0:readdata<=32'ha10e0001;
     4:readdata<={30'b0,fault,context_valid};
     8:readdata<=epoch[31:0];12:readdata<=epoch[63:32];
     16:readdata<=session[31:0];20:readdata<=session[63:32];
     24:readdata<=session[95:64];28:readdata<=session[127:96];
     default:invalid_access<=1;
    endcase
   end
   if(write)begin
    if(read || byteenable!=4'hf || bound || fault)begin fault<=1;invalid_access<=1;end
    else if(word_selected)begin
     staging[32*index+:32]<=writedata;staged[index]<=1;
    end else if(address==0 && writedata==32'ha10e0001 && staged==6'h3f &&
                staging[63:0]!=0 && staging[191:64]!=0)begin
     epoch<=staging[63:0];session<=staging[191:64];bound<=1;
    end else begin fault<=1;invalid_access<=1;end
   end
  end
 end
endmodule
