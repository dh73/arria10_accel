// SPDX-License-Identifier: BSD-3-Clause
// Single-clock command mailbox for 32-bit PIO and atomic 64-bit kernel CRA.
// Both interfaces and reset must be in clk; this module is not a CDC bridge.
// Addresses are byte offsets. Map/identity/admission remain external gates.
module kernel_cra_mailbox (
 input logic clk,cold_reset_n,
 input logic read,write,
 input logic [7:0] address,
 input logic [31:0] writedata,
 input logic [3:0] byteenable,
 output logic waitrequest,readdatavalid,
 output logic [31:0] readdata,
 output logic invalid_access,
 output logic cra_read,cra_write,
 output logic [29:0] cra_address,
 output logic [63:0] cra_writedata,
 output logic [7:0] cra_byteenable,
 input logic cra_waitrequest,cra_readdatavalid,
 input logic [63:0] cra_readdata
);
 // 00 target, 04/08 write data low/high, 0c byte mask, 10 command (1 write,
 // 2 read), 14 status (busy/done/error bits 0/1/2), 18/1c captured read data.
 // Every accepted command is a NEW operation. Software must never replay an
 // ambiguously acknowledged command. Reading either result half has no effect.
 typedef enum logic [1:0] {IDLE,ISSUE,RESPONSE} state_t;
 state_t state;
 logic [31:0] target;
 logic [63:0] staging,result_data;
 logic [7:0] mask;
 logic active_read,done,error;
 wire busy=(state!=IDLE);
 assign waitrequest=!cold_reset_n;
 assign cra_read=cold_reset_n && state==ISSUE && active_read;
 assign cra_write=cold_reset_n && state==ISSUE && !active_read;
 always_ff @(posedge clk or negedge cold_reset_n) begin
  if(!cold_reset_n) begin
   state<=IDLE;target<=0;staging<=0;mask<=0;result_data<=0;
   cra_address<=0;cra_writedata<=0;cra_byteenable<=0;
   active_read<=0;done<=0;error<=0;invalid_access<=0;
   readdatavalid<=0;readdata<=0;
  end else begin
   readdatavalid<=0;
   if(read) begin
    readdatavalid<=1;
    if(write || byteenable!=4'hf || address[1:0]!=0) begin
     readdata<=32'hffffffff;invalid_access<=1;
    end else case(address)
     8'h00:readdata<=target;
     8'h04:readdata<=staging[31:0];
     8'h08:readdata<=staging[63:32];
     8'h0c:readdata<={24'd0,mask};
     8'h14:readdata<={29'd0,error,done,busy};
     8'h18:readdata<=result_data[31:0];
     8'h1c:readdata<=result_data[63:32];
     default:begin readdata<=32'hffffffff;invalid_access<=1;end
    endcase
   end
   if(write && !read) begin
    // In-flight command arguments are immutable; rejected setup/command
    // writes have no downstream effect and leave the original result intact.
    if(busy || byteenable!=4'hf || address[1:0]!=0) invalid_access<=1;
    else case(address)
     8'h00:target<=writedata;
     8'h04:staging[31:0]<=writedata;
     8'h08:staging[63:32]<=writedata;
     8'h0c:begin
      if(writedata[31:8]!=0) invalid_access<=1;
      else mask<=writedata[7:0];
     end
     8'h10:begin
      if((writedata!=1 && writedata!=2) || target>=512 || target[2:0]!=0 ||
         (writedata==1 && mask==0)) begin
       invalid_access<=1;done<=1;error<=1;
      end else begin
       cra_address<=target[29:0];cra_writedata<=staging;
       cra_byteenable<=(writedata==2)?8'hff:mask;
       active_read<=(writedata==2);done<=0;error<=0;state<=ISSUE;
      end
     end
     default:invalid_access<=1;
    endcase
   end
   case(state)
    ISSUE:if(!cra_waitrequest) begin
     if(!active_read) begin state<=IDLE;done<=1;end
     else if(cra_readdatavalid) begin
      result_data<=cra_readdata;state<=IDLE;done<=1;
     end else state<=RESPONSE;
    end
    RESPONSE:if(cra_readdatavalid) begin
     result_data<=cra_readdata;state<=IDLE;done<=1;
    end
    default:;
   endcase
  end
 end
endmodule
