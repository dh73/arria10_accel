#pragma once
#include "dma_operation_lifecycle.hpp"
#include <functional>
#include <string>
#include <vector>

namespace asus::a10::mmd {
enum class Kind { Read, Write, Copy };
enum class Submission { Accepted, NotAccepted, Indeterminate };
struct Request {
  Kind kind;
  int interface_id;
  std::size_t size, source_offset, destination_offset;
  // Adapter-owned staging; never a runtime caller buffer. Valid until drain.
  void* staging;
  dma::Ticket ticket;
};
using Completion = std::function<void(dma::Ticket, int, dma::DrainEvidence)>;
class Transport {
 public:
  virtual ~Transport() = default;
  // Must establish live exact-image qualification AND exclusive custody.
  virtual bool qualified_and_owned() const noexcept = 0;
  virtual int info(aocl_mmd_info_t, size_t, void*, size_t*) = 0;
  // No hardware may retain references after blocking returns, even on error.
  virtual int blocking(const Request&) noexcept = 0;
  // May complete before returning. Exceptions are treated as indeterminate.
  virtual Submission submit(const Request&, Completion) = 0;
  virtual int yield() = 0;
  // Successful close synchronizes completion/interrupt producers and releases custody.
  virtual int close() = 0;
  virtual int interrupt_handler(aocl_mmd_interrupt_handler_fn, void*) = 0;
};
class Backend {
 public:
  virtual ~Backend() = default;
  virtual std::vector<std::string> discover() = 0;
  // Vendor ID and memory capabilities are backend facts, never guessed.
  virtual int offline_info(aocl_mmd_offline_info_t, size_t, void*, size_t*) { return -1; }
  virtual std::shared_ptr<Transport> open(const std::string&) = 0;
};
// Internal injection, not Intel ABI. Refuses replacement while handles exist.
// Default is no backend, no boards. No environment-selected fake backend.
bool install_backend(std::shared_ptr<Backend>);
// Fence only already-ready callbacks/releases; never waits for hardware.
bool flush_ready(int handle);
// Internal host admission only. Accepted DMA remains owned until actual drain.
// No transport/device closure certificate is inferred from this observation.
bool quiesce_submissions(int handle, int terminal_status);
bool submission_snapshot(int handle, dma::Snapshot& out);

}
