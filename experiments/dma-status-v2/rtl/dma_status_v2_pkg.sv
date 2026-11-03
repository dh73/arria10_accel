// SPDX-License-Identifier: BSD-3-Clause
package dma_status_v2_pkg;
localparam logic [3:0] DMA_STATUS_VERSION_V2 = 4'h2;
localparam logic [3:0] DMA_CAUSE_MASTER = 4'h1;
localparam logic [3:0] DMA_CAUSE_PAUSE  = 4'h2;
localparam logic [3:0] DMA_CAUSE_ABORT  = 4'h4;
localparam logic [3:0] DMA_CAUSE_FLUSH  = 4'h8;
function automatic logic status_v2_success(input logic [31:0] word);
return word[31:28] == DMA_STATUS_VERSION_V2 &&
word[27:24] == 4'h0 && word[23:16] != 8'h0 &&
word[11:8] == 4'b1101;
endfunction
function automatic logic status_v2_valid(input logic [31:0] word);
logic [3:0] cause;
cause = word[27:24];
return word[31:28] == DMA_STATUS_VERSION_V2 &&
word[23:16] != 8'h0 &&
(status_v2_success(word) ||
(cause == DMA_CAUSE_PAUSE && word[11:8] == 4'b0000) ||
((cause & (DMA_CAUSE_MASTER | DMA_CAUSE_ABORT | DMA_CAUSE_FLUSH)) != 0 &&
word[10:8] == 3'b110));
endfunction
function automatic logic [31:0] status_v2_make(
input logic [7:0] id, input logic [3:0] slot,
input logic [7:0] generation, input logic [3:0] cause,
input logic local_retired, input logic terminal,
input logic error, input logic success);
return {DMA_STATUS_VERSION_V2, cause, generation, slot,
local_retired, terminal, error, success, id};
endfunction
endpackage
