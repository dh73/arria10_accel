// Context is immutable within a coordinated cold-reset epoch.
// Inputs must be coherent in clk. This does not synchronize an external bus.
module platform_context_guard (
 input logic clk,cold_reset_n,context_valid,
 input logic [127:0] session,
 input logic [63:0] epoch,
 output logic bound,live,fault,
 output logic [127:0] bound_session,
 output logic [63:0] bound_epoch
);
 wire known_context = (^({session,epoch}) !== 1'bx);
 wire valid_context = (context_valid === 1'b1) && known_context && session!=0 && epoch!=0;
 wire matching = valid_context && session==bound_session && epoch==bound_epoch;
 assign live = (cold_reset_n === 1'b1) && bound && !fault && matching;
 always_ff @(posedge clk or negedge cold_reset_n) begin
  if(!cold_reset_n) begin bound<=0;fault<=0;bound_session<=0;bound_epoch<=0;end
  else if(!bound) begin
   if(valid_context) begin bound<=1;bound_session<=session;bound_epoch<=epoch;end
  end else if(!matching) fault<=1;
 end
endmodule
