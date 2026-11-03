// EMIF user-clock domain: initialize ECC codewords with full-byte zero writes
// before admitting clients. Reset is common with EMIF; no core-only reset or
// transparent recalibration recovery is implemented by this module.
module arria10_ddr_init #(
  parameter int DATA_W=512,ADDR_W=25,
  parameter logic [ADDR_W-1:0] LAST_ADDRESS='1
) (
  input logic clk,reset_n,cal_success,cal_fail,
  output logic initialized,init_failed,
  input logic [ADDR_W-1:0] client_address,
  input logic client_read,client_write,
  input logic [DATA_W-1:0] client_writedata,
  input logic [DATA_W/8-1:0] client_byteenable,
  input logic [0:0] client_burstcount,
  output logic client_waitrequest,
  input logic amm_ready,
  output logic [ADDR_W-1:0] amm_address,
  output logic amm_read,amm_write,
  output logic [DATA_W-1:0] amm_writedata,
  output logic [DATA_W/8-1:0] amm_byteenable,
  output logic [6:0] amm_burstcount
);
  typedef enum logic [1:0] {WAIT_CAL,SCRUB,ONLINE,FAILED} state_t;
  state_t state;
  logic [ADDR_W-1:0] cursor;
  logic failed_q;
  assign initialized=reset_n && state==ONLINE && !failed_q && cal_success && !cal_fail;
  assign init_failed=reset_n && (failed_q || cal_fail);
  // Even after a live calibration fault, retain ONLINE routing so an already
  // stalled client command is never withdrawn. initialized blocks NEW client
  // admissions through arria10_ddr_service. Recovery requires coordinated reset.
  always_comb begin
    amm_address=cursor;amm_read=0;amm_write=0;
    amm_writedata='0;amm_byteenable='1;amm_burstcount=7'd1;
    client_waitrequest=1;
    if(reset_n && state==SCRUB)amm_write=1;
    if(reset_n && state==ONLINE)begin
      amm_address=client_address;amm_read=client_read;amm_write=client_write;
      amm_writedata=client_writedata;amm_byteenable=client_byteenable;
      amm_burstcount={6'b0,client_burstcount};
      client_waitrequest=!amm_ready;
    end
  end
  always_ff @(posedge clk or negedge reset_n)begin
    if(!reset_n)begin state<=WAIT_CAL;cursor<=0;failed_q<=0;end
    else begin
      if(cal_fail || (state!=WAIT_CAL && !cal_success))failed_q<=1;
      case(state)
        WAIT_CAL:if(cal_fail)state<=FAILED;
                 else if(cal_success)state<=SCRUB;
        SCRUB:if(amm_ready)begin
          if(failed_q || cal_fail || !cal_success)state<=FAILED;
          else if(cursor==LAST_ADDRESS)state<=ONLINE;
          else cursor<=cursor+1'b1;
        end
        ONLINE:begin end
        FAILED:begin end
        default:state<=FAILED;
      endcase
    end
  end
`ifdef ARRIA10_ASSERTIONS
  assert property(@(posedge clk) disable iff(!reset_n)
    (amm_read || amm_write) && !amm_ready |=>
      $stable({amm_address,amm_read,amm_write,amm_writedata,amm_byteenable,amm_burstcount}));
  assert property(@(posedge clk) disable iff(!reset_n)
    state!=ONLINE |-> client_waitrequest && !initialized);
`endif
endmodule
