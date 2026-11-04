#pragma once
#include "kernel_mailbox.hpp"
#include <array>
#include <cstdint>
namespace asus::a10::writeback {
enum class State { Pending, Settled, Poisoned };
// One object per exclusively owned, immutable hardware session/epoch.
// Port reads MUST use the qualified ordered same-function MMIO path, covering
// the DMA ordering domain. A fake/cached/relaxed read cannot certify settlement.
// This class does not discover a BAR, admit a driver, or release any buffer.
class Fence final {
 public:
  // Context DWORD order: epoch low/high, then session least significant first.
  Fence(mailbox::Port&, std::uint64_t base,
        std::array<std::uint32_t,6> context) noexcept;
  Fence(const Fence&) = delete;
  Fence& operator=(const Fence&) = delete;
  // Exactly one I/O per call while pending. Call from an external event/service
  // path; there is no polling loop, timeout, automatic retry, or second commit.
  State advance() noexcept;
  State state() const noexcept {return state_;}
 private:
  enum class Step { Ready, Context, Recheck, Echo, Flush, Commit, Confirm };
  mailbox::Port& port_;
  std::uint64_t base_;
  std::array<std::uint32_t,6> context_;
  State state_{State::Pending}; Step step_{Step::Ready}; unsigned index_{0};
};
}
