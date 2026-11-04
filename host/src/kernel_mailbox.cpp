#include "kernel_mailbox.hpp"
#include <limits>
#include <stdexcept>

namespace asus::a10::mailbox {
Sequencer::Sequencer(Port& port, std::uint64_t base) : port_(port), base_(base) {
  if ((base & 3) || base > std::numeric_limits<std::uint64_t>::max() - 31)
    throw std::invalid_argument("mailbox aperture");
}
bool Sequencer::begin(std::uint64_t id, std::uint32_t target, bool read,
                      std::uint64_t data, std::uint8_t mask) noexcept {
  if (state_ == State::Pending || state_ == State::Poisoned ||
      !id || id <= last_id_ || target >= 512 || (target & 7) || (!read && !mask))
    return false;
  last_id_=id; target_=target; read_=read; data_=data; mask_=mask;
  value_=0; command_issued_=false; step_=Step::Check; state_=State::Pending;
  return true;
}
State Sequencer::advance() noexcept {
  if (state_ != State::Pending) return state_;
  Reply r{Outcome::Unknown};
  const Step old=step_;
  switch (old) {
    case Step::Check: r=port_.read32(base_+20); break;
    case Step::Target: r=port_.write32(base_,target_); break;
    case Step::Low: r=port_.write32(base_+4,static_cast<std::uint32_t>(data_)); break;
    case Step::High: r=port_.write32(base_+8,static_cast<std::uint32_t>(data_>>32)); break;
    case Step::Mask: r=port_.write32(base_+12,mask_); break;
    case Step::Before: case Step::After: r=port_.fence(); break;
    case Step::Command: r=port_.write32(base_+16,read_?2:1); break;
    case Step::Status: r=port_.read32(base_+20); break;
    case Step::ResultLow: r=port_.read32(base_+24); break;
    case Step::ResultHigh: r=port_.read32(base_+28); break;
  }
  if (r.outcome != Outcome::Completed) {
    // Only positively unissued I/O BEFORE command acceptance can certify no
    // CRA effect. Unknown staging/fence writes poison the mailbox too: delayed
    // arrivals must not corrupt a future transaction's staging registers.
    state_ = r.outcome == Outcome::NotIssued && !command_issued_
               ? State::NotIssued : State::Poisoned;
    return state_;
  }
  switch (old) {
    case Step::Check:
      if (r.value != 0 && r.value != 2) state_=State::Poisoned;
      else step_=Step::Target;
      break;
    case Step::Target: step_=read_?Step::Before:Step::Low; break;
    case Step::Low: step_=Step::High; break;
    case Step::High: step_=Step::Mask; break;
    case Step::Mask: step_=Step::Before; break;
    case Step::Before: step_=Step::Command; break;
    case Step::Command: command_issued_=true; step_=Step::After; break;
    case Step::After: step_=Step::Status; break;
    case Step::Status:
      if (r.value == 2) {
        if (read_) step_=Step::ResultLow; else state_=State::Completed;
      } else if (r.value != 1) state_=State::Poisoned;
      break;
    case Step::ResultLow: value_=r.value; step_=Step::ResultHigh; break;
    case Step::ResultHigh: value_|=std::uint64_t(r.value)<<32; state_=State::Completed; break;
  }
  return state_;
}
}
