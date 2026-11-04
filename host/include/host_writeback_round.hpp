#pragma once
#include "host_writeback_fence.hpp"
#include <array>
#include <cstdint>
namespace asus::a10::writeback {
// One object per exclusively owned, immutable hardware session/epoch/drain round.
// Port reads MUST use the qualified ordered same-function MMIO path, covering
// the DMA ordering domain. A fake/cached/relaxed read cannot certify settlement.
// This class does not discover a BAR, admit a driver, or release any buffer.
class RoundFence final {
 public:
  // expected_round comes from exclusive lifecycle ownership, starting at one.
  // Advance it only after confirmed supervisor consumption, never from an
  // untrusted status read or merely because this attempt settled. This class
  // cannot reopen admission, rearm hardware, or resolve uncertain consumption.
  // Context DWORD order: epoch low/high, then session least significant first.
  RoundFence(mailbox::Port&, std::uint64_t base,
        std::array<std::uint32_t,6> context, std::uint64_t expected_round) noexcept;
  RoundFence(const RoundFence&) = delete;
  RoundFence& operator=(const RoundFence&) = delete;
  // Exactly one I/O per call while pending. Call from an external event/service
  // path; there is no polling loop, timeout, automatic retry, or second commit.
  State advance() noexcept;
  State state() const noexcept {return state_;}
 private:
  enum class Step { Ready, Context, Recheck, Echo, Flush, Commit, Confirm };
  mailbox::Port& port_;
  std::uint64_t base_;
  std::array<std::uint32_t,8> context_;
  State state_{State::Pending}; Step step_{Step::Ready}; unsigned index_{0};
};
}
