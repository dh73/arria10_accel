#pragma once
#include <cstdint>
#include "svdpi.h"
extern "C" int exchange_adapter(unsigned long long p_clk, unsigned long long p_cold_reset_n, unsigned long long p_memory_ready, unsigned long long p_backend_init_failed, unsigned long long p_backend_ecc_interrupt, unsigned long long p_quiesce_req, unsigned long long p_k_read, unsigned long long p_k_write, unsigned long long p_k_address, unsigned long long p_k_writedata, unsigned long long p_k_byteenable, unsigned long long p_k_burstcount, unsigned long long* p_k_waitrequest, unsigned long long* p_k_readdata, unsigned long long* p_k_readdatavalid, unsigned long long* p_k_writeack, unsigned long long* p_d_address, unsigned long long* p_d_read, unsigned long long* p_d_write, svBitVecVal* p_d_writedata, unsigned long long* p_d_byteenable, unsigned long long* p_d_burstcount, unsigned long long p_d_waitrequest, svBitVecVal* p_d_readdata, unsigned long long p_d_readdatavalid, unsigned long long p_d_readdataerror, unsigned long long* p_fault, unsigned long long* p_fault_code, unsigned long long* p_fault_address, unsigned long long* p_fault_address_valid, unsigned long long* p_quiescing, unsigned long long* p_drained);
struct VcsAdapter {
  unsigned long long clk = 0;
  unsigned long long cold_reset_n = 0;
  unsigned long long memory_ready = 0;
  unsigned long long backend_init_failed = 0;
  unsigned long long backend_ecc_interrupt = 0;
  unsigned long long quiesce_req = 0;
  unsigned long long k_read = 0;
  unsigned long long k_write = 0;
  unsigned long long k_address = 0;
  unsigned long long k_writedata = 0;
  unsigned long long k_byteenable = 0;
  unsigned long long k_burstcount = 0;
  unsigned long long k_waitrequest = 0;
  unsigned long long k_readdata = 0;
  unsigned long long k_readdatavalid = 0;
  unsigned long long k_writeack = 0;
  unsigned long long d_address = 0;
  unsigned long long d_read = 0;
  unsigned long long d_write = 0;
  svBitVecVal d_writedata[16]{};
  unsigned long long d_byteenable = 0;
  unsigned long long d_burstcount = 0;
  unsigned long long d_waitrequest = 0;
  svBitVecVal d_readdata[16]{};
  unsigned long long d_readdatavalid = 0;
  unsigned long long d_readdataerror = 0;
  unsigned long long fault = 0;
  unsigned long long fault_code = 0;
  unsigned long long fault_address = 0;
  unsigned long long fault_address_valid = 0;
  unsigned long long quiescing = 0;
  unsigned long long drained = 0;
  void eval() { exchange_adapter(clk, cold_reset_n, memory_ready, backend_init_failed, backend_ecc_interrupt, quiesce_req, k_read, k_write, k_address, k_writedata, k_byteenable, k_burstcount, &k_waitrequest, &k_readdata, &k_readdatavalid, &k_writeack, &d_address, &d_read, &d_write, d_writedata, &d_byteenable, &d_burstcount, d_waitrequest, d_readdata, d_readdatavalid, d_readdataerror, &fault, &fault_code, &fault_address, &fault_address_valid, &quiescing, &drained); }
  void final() {}
};
