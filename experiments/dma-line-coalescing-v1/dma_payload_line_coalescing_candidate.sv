// Bounded PAYLOAD slave for the actual HIP's two 256-bit DMA masters.
// Descriptor-table traffic MUST be demultiplexed before this module.
// One complete burst (1..16 beats) owns this transport in either direction.
// Common cold reset is the ONLY operation that releases quarantined ownership.
// Bundled-data CDC: banks/header remain stable from req_toggle until done_toggle;
// return bank remains stable until the next request. Constrain these held buses
// as multicycle CDC data, not as unconstrained false paths, before hardware use.
module dma_payload_line_coalescing_candidate (
  input logic pcie_clk, user_clk, common_cold_reset_n,
  input logic app_nreset_status, backend_reset_n,
  input logic memory_ready, memory_failed, // user_clk domain
  input logic quiesce,                    // pcie_clk domain, level request
  input logic [63:0] rd_dma_address_o,
  input logic rd_dma_write_o,
  input logic [255:0] rd_dma_write_data_o,
  input logic [31:0] rd_dma_byte_enable_o,
  input logic [4:0] rd_dma_burst_count_o,
  output logic rd_dma_wait_request_i,
  input logic [63:0] wr_dma_address_o,
  input logic wr_dma_read_o,
  input logic [31:0] wr_dma_read_byte_enable_o,
  input logic [4:0] wr_dma_burst_count_o,
  output logic wr_dma_wait_request_i,
  output wire [255:0] wr_dma_read_data_i,
  output wire wr_dma_read_data_valid_i,
  output wire busy, quiesced,
  output logic fault,
  output logic [3:0] fault_code,
  output logic [63:0] fault_address,
  output wire [4:0] owned_beats,
  output wire ddr_lock,
  output wire [24:0] avm_address,
  output wire avm_read, avm_write,
  output logic [511:0] avm_writedata,
  output logic [63:0] avm_byteenable,
  output wire [0:0] avm_burstcount,
  input logic avm_waitrequest, avm_readdatavalid, avm_readdataerror,
  input logic [511:0] avm_readdata
);
  (* async_reg = "true", preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) logic [1:0] pr, cr, ph, ch, bh;
  wire health_n = common_cold_reset_n && app_nreset_status && backend_reset_n;
  wire backend_health_n = common_cold_reset_n && backend_reset_n;
  always_ff @(posedge pcie_clk or negedge common_cold_reset_n)
    if (!common_cold_reset_n) pr<=0; else pr<={pr[0],1'b1};
  always_ff @(posedge user_clk or negedge common_cold_reset_n)
    if (!common_cold_reset_n) cr<=0; else cr<={cr[0],1'b1};
  // A short reset pulse, including one while a clock is stopped, clears these
  // qualification flops. The armed/sticky flops below are NOT reset by it.
  always_ff @(posedge pcie_clk or negedge health_n)
    if (!health_n) ph<=0; else ph<={ph[0],1'b1};
  always_ff @(posedge user_clk or negedge health_n)
    if (!health_n) ch<=0; else ch<={ch[0],1'b1};
  always_ff @(posedge user_clk or negedge backend_health_n)
    if (!backend_health_n) bh<=0; else bh<={bh[0],1'b1};
  wire p_reset_n=pr[1], c_reset_n=cr[1];
  (* async_reg = "true", preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) logic [1:0] cp_ready, pc_ready;
  always_ff @(posedge pcie_clk or negedge p_reset_n)
    if (!p_reset_n) cp_ready<=0; else cp_ready<={cp_ready[0],cr[1]&&ch[1]};
  always_ff @(posedge user_clk or negedge c_reset_n)
    if (!c_reset_n) pc_ready<=0; else pc_ready<={pc_ready[0],pr[1]&&ph[1]};
  wire p_online=pr[1] && ph[1] && cp_ready[1];
  wire c_online=cr[1] && ch[1] && pc_ready[1];

  typedef enum logic [1:0] {P_IDLE,P_COLLECT,P_WAIT,P_RETURN} pstate_t;
  typedef enum logic [2:0] {C_IDLE,C_ISSUE,C_READ_WAIT,C_NEXT,C_DONE} cstate_t;
  pstate_t ps;
  cstate_t cs;
  logic p_armed, c_armed, backend_dead, c_epoch_dead, c_fault, c_error;
  logic prefer_write, write_q, c_write, req_toggle, done_toggle, c_ticket;
  logic [63:0] base_q, c_base;
  logic [31:0] read_mask_q, c_read_mask;
  logic [4:0] count_q, fill_index, return_index, c_count, c_index;
  logic [255:0] upload_bank [0:15];
  logic [31:0] enable_bank [0:15];
  logic [255:0] return_bank [0:15], snapshot_bank [0:15];
  (* async_reg = "true", preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) logic [1:0] request_sync, done_sync, fault_sync;
  always_ff @(posedge pcie_clk or negedge p_reset_n)
    if (!p_reset_n) begin done_sync<=0; fault_sync<=0; end
    else begin
      done_sync<={done_sync[0],done_toggle};
      fault_sync<={fault_sync[0],c_fault};
    end
  always_ff @(posedge user_clk or negedge c_reset_n)
    if (!c_reset_n) request_sync<=0;
    else request_sync<={request_sync[0],req_toggle};

  function automatic logic bad_header(input logic [63:0] address,
                                      input logic [4:0] beats);
    logic [64:0] end_exclusive;
    end_exclusive={1'b0,address}+({60'b0,beats}<<5);
    return (address[4:0]!=0 || beats==0 || beats>16 ||
            end_exclusive>65'h080000000);
  endfunction
  // D2H enables index the aligned 32-byte response, not address-relative data.
  // Only native single-beat heads may have a nonzero DWORD offset. Aligned
  // commands retain the previous arbitrary command-mask semantics (also zero).
  function automatic logic bad_read_header(input logic [63:0] address,
                                           input logic [4:0] beats,
                                           input logic [31:0] mask);
    logic [63:0] beat_base;
    logic [64:0] end_exclusive;
    logic [31:0] below_start;
    beat_base={address[63:5],5'b0};
    end_exclusive={1'b0,beat_base}+({60'b0,beats}<<5);
    below_start=~(32'hffffffff << address[4:0]);
    return (address[1:0]!=0 || beats==0 || beats>16 ||
            end_exclusive>65'h080000000 ||
            (address[4:0]!=0 &&
             (beats!=1 || mask==0 || (mask & below_start)!=0)));
  endfunction
  wire choose_write=rd_dma_write_o && (!wr_dma_read_o || prefer_write);
  wire selected_valid=choose_write ? rd_dma_write_o : wr_dma_read_o;
  wire [63:0] selected_address=choose_write ? rd_dma_address_o : wr_dma_address_o;
  wire [4:0] selected_count=choose_write ? rd_dma_burst_count_o : wr_dma_burst_count_o;
  // H2D validation is deliberately unchanged; descriptor routing is external.
  wire selected_bad=choose_write ? bad_header(selected_address,selected_count) :
    bad_read_header(selected_address,selected_count,wr_dma_read_byte_enable_o);
  wire p_lost=p_armed && !p_online;
  wire p_live=p_online && !fault && !fault_sync[1];
  always_comb begin
    rd_dma_wait_request_i=1;
    wr_dma_wait_request_i=1;
    if (p_live) begin
      if (ps==P_COLLECT) rd_dma_wait_request_i=0; // finish accepted burst under quiesce
      else if (ps==P_IDLE && !quiesce && selected_valid && !selected_bad) begin
        if (choose_write) rd_dma_wait_request_i=0;
        else wr_dma_wait_request_i=0;
      end
    end
  end
  assign busy=(ps!=P_IDLE);
  // This means transport ownership empty, NOT DDR physical write drain.
  assign quiesced=quiesce && p_live && ps==P_IDLE;
  assign owned_beats=ps==P_COLLECT ? count_q-fill_index :
                     ps==P_RETURN ? count_q-return_index :
                     ps==P_WAIT ? count_q : 5'd0;
  assign wr_dma_read_data_valid_i=p_live && ps==P_RETURN;
  assign wr_dma_read_data_i=snapshot_bank[return_index[3:0]];

  always_ff @(posedge pcie_clk or negedge p_reset_n) begin
    if (!p_reset_n) begin
      ps<=P_IDLE; p_armed<=0; fault<=0; fault_code<=0; fault_address<=0;
      req_toggle<=0; write_q<=0; base_q<=0; count_q<=0; read_mask_q<=0;
      fill_index<=0; return_index<=0; prefer_write<=1;
    end else begin
      if (p_online) p_armed<=1;
      if (!fault && (p_lost || fault_sync[1])) begin
        fault<=1; fault_code<=p_lost ? 4'd2 : 4'd3; fault_address<=base_q;
      end
      // On failure, retain ps/header/banks/remaining ownership. No auto-rearm.
      if (p_live && !p_lost) case (ps)
        P_IDLE: if (!quiesce && selected_valid) begin
          if (selected_bad) begin
            fault<=1; fault_code<=1; fault_address<=selected_address;
          end else if ((choose_write && !rd_dma_wait_request_i) ||
                       (!choose_write && !wr_dma_wait_request_i)) begin
            base_q<=selected_address; count_q<=selected_count;
            read_mask_q<=wr_dma_read_byte_enable_o;
            write_q<=choose_write; prefer_write<=!choose_write;
            return_index<=0;
            if (choose_write) begin
              upload_bank[0]<=rd_dma_write_data_o;
              enable_bank[0]<=rd_dma_byte_enable_o;
              fill_index<=1;
              if (selected_count==1) begin req_toggle<=!req_toggle; ps<=P_WAIT; end
              else ps<=P_COLLECT;
            end else begin req_toggle<=!req_toggle; ps<=P_WAIT; end
          end
        end
        P_COLLECT: if (rd_dma_write_o && !rd_dma_wait_request_i) begin
          // Actual IP constantBurstBehavior=false: later address/count are don't-care.
          upload_bank[fill_index[3:0]]<=rd_dma_write_data_o;
          enable_bank[fill_index[3:0]]<=rd_dma_byte_enable_o;
          fill_index<=fill_index+1'b1;
          if (fill_index+1'b1==count_q) begin req_toggle<=!req_toggle; ps<=P_WAIT; end
        end
        P_WAIT: if (done_sync[1]==req_toggle) begin
          if (c_error) begin fault<=1; fault_code<=3; fault_address<=base_q; end
          else if (write_q) ps<=P_IDLE;
          else begin
            for (int i=0;i<16;i++) snapshot_bank[i]<=return_bank[i];
            return_index<=0; ps<=P_RETURN;
          end
        end
        P_RETURN: begin
          if (return_index+1'b1==count_q) ps<=P_IDLE;
          else return_index<=return_index+1'b1;
        end
        default: begin fault<=1; fault_code<=4; end
      endcase
    end
  end

  wire backend_live=cr[1] && bh[1] && !backend_dead;
  // Keep base_q/c_base raw for fault diagnostics. Do not shift mask or data.
  wire [63:0] byte_address={c_base[63:5],5'b0}+({59'b0,c_index}<<5);
  // Only adjacent halves already owned by THIS burst may share a line command.
  // c_index/header/banks stay unchanged through ISSUE and READ_WAIT stalls.
  wire pair_line=!byte_address[5] && c_index+5'd1<c_count;
  wire [4:0] advance=pair_line?5'd2:5'd1;
  wire [3:0] next_bank=c_index[3:0]+4'd1;
  assign avm_address=byte_address[30:6];
  assign avm_burstcount=1'b1;
  assign avm_read=backend_live && cs==C_ISSUE && !c_write;
  assign avm_write=backend_live && cs==C_ISSUE && c_write;
  assign ddr_lock=(cs!=C_IDLE); // finish an already selected core command first
  always_comb begin
    avm_writedata='0; avm_byteenable='0;
    avm_byteenable[32*byte_address[5]+:32]=c_read_mask;
    if(pair_line) avm_byteenable={c_read_mask,c_read_mask};
    if (c_write) begin
      avm_byteenable='0;
      avm_writedata[256*byte_address[5]+:256]=upload_bank[c_index[3:0]];
      avm_byteenable[32*byte_address[5]+:32]=enable_bank[c_index[3:0]];
      if(pair_line) begin
        avm_writedata={upload_bank[next_bank],upload_bank[c_index[3:0]]};
        avm_byteenable={enable_bank[next_bank],enable_bank[c_index[3:0]]};
      end
    end
  end
  wire read_arrival=avm_readdatavalid &&
    (cs==C_READ_WAIT || (cs==C_ISSUE && !c_write && !avm_waitrequest));
  always_ff @(posedge user_clk or negedge c_reset_n) begin
    if (!c_reset_n) begin
      cs<=C_IDLE; c_armed<=0; backend_dead<=0; c_epoch_dead<=0; c_fault<=0; c_error<=0;
      done_toggle<=0; c_ticket<=0; c_write<=0; c_base<=0; c_count<=0; c_index<=0; c_read_mask<=0;
    end else begin
      if (c_online) c_armed<=1;
      if (c_armed && !c_online) c_epoch_dead<=1;
      if (c_armed && !bh[1]) begin backend_dead<=1; c_fault<=1; end
      if (c_armed && memory_failed) c_fault<=1;
      if (avm_readdatavalid && !read_arrival) c_fault<=1;
      // Link loss does not reset this bank or cancel a command already presented
      // to DDR. Backend reset loss is a fatal epoch change: no replay on recovery.
      if (backend_live) case (cs)
        C_IDLE: if (request_sync[1]!=done_toggle && c_online && !c_epoch_dead && !c_fault && !avm_readdatavalid &&
                    memory_ready && !memory_failed) begin
          c_ticket<=request_sync[1]; c_base<=base_q; c_count<=count_q;
          c_write<=write_q; c_read_mask<=read_mask_q; c_index<=0; c_error<=0; cs<=C_ISSUE;
        end
        C_ISSUE: if (!avm_waitrequest) begin
          if (c_write) cs<=C_NEXT;
          else if (avm_readdatavalid) begin
            return_bank[c_index[3:0]]<=avm_readdata[256*byte_address[5]+:256];
            if(pair_line) return_bank[next_bank]<=avm_readdata[511:256];
            if (avm_readdataerror) begin c_error<=1; c_fault<=1; end
            cs<=C_NEXT;
          end else cs<=C_READ_WAIT;
        end
        C_READ_WAIT: if (avm_readdatavalid) begin
          return_bank[c_index[3:0]]<=avm_readdata[256*byte_address[5]+:256];
            if(pair_line) return_bank[next_bank]<=avm_readdata[511:256];
          if (avm_readdataerror) begin c_error<=1; c_fault<=1; end
          cs<=C_NEXT;
        end
        C_NEXT: begin
          if (c_fault || memory_failed || !memory_ready || c_error) begin
            c_error<=1; c_fault<=1; cs<=C_DONE;
          end else if (c_index+advance==c_count) cs<=C_DONE;
          else begin c_index<=c_index+advance; cs<=C_ISSUE; end
        end
        C_DONE: begin done_toggle<=c_ticket; cs<=C_IDLE; end
        default: begin c_error<=1; c_fault<=1; end
      endcase
    end
  end
`ifdef ARRIA10_ASSERTIONS
  // Accepted ownership retains the ORIGINAL diagnostic address. Normalize
  // only the backend beat, preserving the captured command mask and lane order.
  assert property (@(posedge pcie_clk) disable iff (!p_reset_n)
    wr_dma_read_o && !wr_dma_wait_request_i |=>
      base_q==$past(wr_dma_address_o) &&
      read_mask_q==$past(wr_dma_read_byte_enable_o) && !write_q);
  assert property (@(posedge user_clk) disable iff (!c_reset_n)
    cs!=C_IDLE && !c_write |-> !bad_read_header(c_base,c_count,c_read_mask));
  assert property (@(posedge user_clk) disable iff (!c_reset_n)
    cs!=C_IDLE && $past(cs)!=C_IDLE |->
      $stable({c_base,c_count,c_write,c_read_mask,c_ticket}));
  assert property (@(posedge user_clk) disable iff (!c_reset_n)
    avm_read |-> byte_address[4:0]==0 && byte_address<64'h80000000 &&
      avm_byteenable==(pair_line?{c_read_mask,c_read_mask}:
        ({32'b0,c_read_mask} << (32*byte_address[5]))));
  assert property (@(posedge user_clk) disable iff (!c_reset_n)
    pair_line && cs!=C_IDLE |-> !byte_address[5] && c_index<15 && c_index+advance<=c_count);
  // Simulation assertions; no inductive proof is claimed. Backend reset changes
  // the epoch, so its loss explicitly terminates the normal Avalon obligation.
  assert property (@(posedge user_clk) disable iff (!c_reset_n || !backend_live)
    (avm_read || avm_write) && avm_waitrequest |=>
    $stable({avm_read,avm_write,avm_address,avm_writedata,avm_byteenable}));
  assert property (@(posedge pcie_clk) disable iff (!p_reset_n)
    fault |=> fault && rd_dma_wait_request_i && wr_dma_wait_request_i &&
               !wr_dma_read_data_valid_i);
  assert property (@(posedge pcie_clk) disable iff (!p_reset_n)
    ps==P_WAIT && $past(ps)==P_WAIT |-> $stable({base_q,count_q,write_q,read_mask_q,req_toggle}));
  assert property (@(posedge pcie_clk) disable iff (!p_reset_n)
    ps!=P_IDLE |-> count_q>=1 && count_q<=16);
`endif
endmodule
