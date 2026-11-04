// Local 80-byte management window, same clock as the observed DDR interface.
// Read 0: ABI magic. Write 0/full byte-enable/magic: capture a snapshot.
// Read 4: valid/overflow/invalid-command bits. Read 8/12: sequence low/high.
// Read 16..68: seven 64-bit counters, low DWORD first. Reserved accesses reject.
// Exclusive snapshot writers or sequence-before/after checking prevent torn reads.
module ddr_traffic_mmio (
 input logic clk,cold_reset_n,
 input logic read,write,input logic [6:0] address,
 input logic [31:0] writedata,input logic [3:0] byteenable,
 output logic readdatavalid,output logic [31:0] readdata,
 output logic invalid_access,
 input logic ddr_read,ddr_write,ddr_waitrequest,ddr_readdatavalid,
 input logic [63:0] ddr_byteenable
);
 localparam logic [31:0] MAGIC=32'ha10d0001;
 wire capture=write&&!read&&address==0&&byteenable==4'hf&&writedata==MAGIC;
 wire valid,overflow,invalid_command;
 wire [63:0] sequence_id;
 wire [6:0][63:0] counts;
 ddr_traffic_counters counters(.clk,.cold_reset_n,.snapshot(capture),
  .read(ddr_read),.write(ddr_write),.waitrequest(ddr_waitrequest),
  .readdatavalid(ddr_readdatavalid),.byteenable(ddr_byteenable),
  .snapshot_valid(valid),.snapshot_sequence(sequence_id),.snapshot_counts(counts),
  .snapshot_overflow(overflow),.snapshot_invalid_command(invalid_command));
 logic [31:0] value;
 logic legal_read;
 always_comb begin
  value=0;legal_read=address[1:0]==0;
  case(address)
   0:value=MAGIC;
   4:value={29'b0,invalid_command,overflow,valid};
   8:value=sequence_id[31:0];
   12:value=sequence_id[63:32];
   default:begin
    if(address>=16&&address<=68&&address[1:0]==0)
     value=address[2]?counts[(address-16)>>3][63:32]:counts[(address-16)>>3][31:0];
    else legal_read=0;
   end
  endcase
 end
 always_ff @(posedge clk or negedge cold_reset_n)begin
  if(!cold_reset_n)begin readdatavalid<=0;readdata<=0;invalid_access<=0;end
  else begin
   readdatavalid<=read;
   invalid_access<=(read&&write)||(read&&!legal_read)||(write&&!capture);
   readdata<=read&&!write&&legal_read?value:0;
  end
 end
endmodule
