// Read-only diagnostic observation; no admission, reset or drain authority.
// status is coherent in clk domain. Bits: 0 snapshot epoch valid, 1 external
// containment, 2 DMA snapshot valid, 3 DMA epoch lost, 4 shared path fault,
// 5 initialization failed, 6 ECC interrupt, 7 memory ready. Upper bits reserved.
module platform_reset_diagnostics(
 input logic clk,cold_reset_n,read,write,
 input logic [2:0] address,
 input logic [3:0] byteenable,
 input logic [7:0] status,
 output wire waitrequest,
 output logic readdatavalid,invalid_access,
 output logic [31:0] readdata
);
 assign waitrequest=!cold_reset_n;
 always_ff @(posedge clk or negedge cold_reset_n)begin
  if(!cold_reset_n)begin readdatavalid<=0;readdata<=0;invalid_access<=0;end
  else begin
   readdatavalid<=0;
   if(write)invalid_access<=1;
   if(read)begin
    readdatavalid<=1;
    if(write || byteenable!=4'hf || (address!=0 && address!=4))begin
     readdata<=32'hffffffff;invalid_access<=1;
    end else if(address==0)readdata<=32'h52534401;
    else readdata<={24'b0,status};
   end
  end
 end
endmodule
