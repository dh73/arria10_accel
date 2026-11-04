module ddr_mux_unknown_lanes_tb;
logic clk=0; always #5 clk=~clk;
logic common_cold_reset_n=0,backend_reset_n=0,dma_lock=0;
logic [1:0][24:0] req_address='0;
logic [1:0] req_read=0,req_write=0,req_waitrequest,rsp_valid,rsp_error;
logic [1:0][511:0] req_writedata='0;
logic [1:0][63:0] req_byteenable='0;
wire [511:0] rsp_data;
logic [24:0] avm_address;
logic avm_read,avm_write;
logic [511:0] avm_writedata;
logic [63:0] avm_byteenable;
wire [0:0] avm_burstcount;
logic avm_waitrequest=1,avm_readdatavalid=0,avm_readdataerror=0;
logic [511:0] avm_readdata=0;
logic fault;
int mode;
arria10_dma_ddr_mux_pipelined dut(.*);
initial begin
 if(!$value$plusargs("MODE=%d",mode))mode=0;
 repeat(2)@(negedge clk); common_cold_reset_n=1;backend_reset_n=1;
 repeat(5)@(negedge clk);
 req_write=1;req_address[0]=25'h123;req_byteenable[0]=1;
 req_writedata[0]='x;req_writedata[0][7:0]=8'h42;
 repeat(2)@(negedge clk);
 if(mode==1)req_writedata[0][7:0]=8'h43;
 if(mode==2)req_address[0]=25'h124;
 repeat(2)@(negedge clk);
 avm_waitrequest=0;
 @(negedge clk);req_write=0;
 if(fault)$fatal(1,"unexpected fault");
 $display("WITNESS_FINISHED mode=%0d",mode);$finish;
end
endmodule
