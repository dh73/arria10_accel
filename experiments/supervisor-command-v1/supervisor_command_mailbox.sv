// SPDX-License-Identifier: BSD-3-Clause
// Single-clock supervisor command endpoint. Caller supplies coherent permission
// for an exclusively owned immutable session. Coordinated reset and old-command
// containment are external requirements. Commands survive permission loss once
// captured; the supervisor independently checks current safety before acceptance.
// Offsets: 0/4 staged ID, 8 operation, 12 commit(0xa10c0001), 16 status
// {accepted,done,busy}, 20 result reason, 24/28 completed ID. No read clears state.
// IDs strictly increase within a session; no wrap or automatic replay.
module supervisor_command_mailbox(
 input logic clk,cold_reset_n,write_permit,
 input logic read,write,
 input logic [4:0] address,
 input logic [31:0] writedata,
 input logic [3:0] byteenable,
 output logic readdatavalid,
 output logic [31:0] readdata,
 output logic invalid_access,
 output wire cmd_valid,
 output logic [2:0] cmd_op,
 input logic cmd_ready,cmd_done,cmd_accepted,
 input logic [3:0] cmd_reason,
 output wire busy
);
 typedef enum logic [1:0] {IDLE,ISSUE,RESPONSE} state_t;
 state_t state;
 logic [63:0] staged_id,last_id,active_id,completed_id;
 logic [2:0] staged_op,staged;
 logic done,accepted;
 logic [3:0] reason;
 assign busy=state!=IDLE;
 assign cmd_valid=cold_reset_n && state==ISSUE;
 always_ff @(posedge clk or negedge cold_reset_n)begin
  if(!cold_reset_n)begin
   state<=IDLE;staged_id<=0;last_id<=0;active_id<=0;completed_id<=0;
   staged_op<=0;staged<=0;cmd_op<=0;done<=0;accepted<=0;reason<=0;
   invalid_access<=0;readdatavalid<=0;readdata<=0;
  end else begin
   readdatavalid<=0;
   if(state==ISSUE && cmd_ready===1'b1)state<=RESPONSE;
   if(state==RESPONSE && cmd_done===1'b1)begin
    state<=IDLE;done<=1;completed_id<=active_id;
    accepted<=(cmd_accepted===1'b1);reason<=cmd_reason;
   end
   if(read || write)begin
    if((read && write) || byteenable!==4'hf || address[1:0]!==0)begin
     invalid_access<=1;
     if(read)begin readdatavalid<=1;readdata<=32'hffffffff;end
    end else if(read)begin
     readdatavalid<=1;
     case(address)
      0:readdata<=staged_id[31:0];4:readdata<=staged_id[63:32];
      8:readdata<={29'd0,staged_op};16:readdata<={29'd0,accepted,done,busy};
      20:readdata<={28'd0,reason};24:readdata<=completed_id[31:0];28:readdata<=completed_id[63:32];
      default:begin readdata<=32'hffffffff;invalid_access<=1;end
     endcase
    end else if(busy || write_permit!==1'b1)invalid_access<=1;
    else case(address)
     0:begin staged_id[31:0]<=writedata;staged[0]<=1;end
     4:begin staged_id[63:32]<=writedata;staged[1]<=1;end
     8:if(writedata<=2)begin staged_op<=writedata[2:0];staged[2]<=1;end
       else begin staged[2]<=0;invalid_access<=1;end
     12:begin
      // Every commit attempt consumes staging, including a rejected request.
      staged<=0;
      if(writedata===32'ha10c0001 && staged===3'b111 && staged_id>last_id)begin
       active_id<=staged_id;last_id<=staged_id;cmd_op<=staged_op;
       state<=ISSUE;done<=0;accepted<=0;reason<=0;
      end else invalid_access<=1;
     end
     default:invalid_access<=1;
    endcase
   end
  end
 end
endmodule
