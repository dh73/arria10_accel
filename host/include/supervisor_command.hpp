#pragma once
#include "kernel_mailbox.hpp"
#include <cstdint>
namespace asus::a10::control {
enum class Command : std::uint32_t { Start=0, Resume=1, Quiesce=2 };
enum class State { Pending, Accepted, Rejected, Poisoned };
// One immutable request on an exclusively owned, qualified session/mapping.
// Cold reset/reconfiguration invalidates this object; it proves no DMA drain.
class Request final {
 public:
  Request(mailbox::Port&,std::uint64_t base,std::uint64_t id,Command) noexcept;
  Request(const Request&)=delete;
  Request& operator=(const Request&)=delete;
  // One I/O per advance. Pending needs an external completion/service event.
  // No timeout, automatic retry, reset, or second commit after uncertainty.
  State advance() noexcept;
  State state()const noexcept{return state_;}
  std::uint32_t reason()const noexcept{return reason_;}
 private:
  enum class Step { Ready,PreviousLow,PreviousHigh,IdLow,IdHigh,Op,Flush,Commit,Status,ResultLow,ResultHigh,Reason };
  mailbox::Port& port_;
  const std::uint64_t base_,id_;
  const Command command_;
  State state_{State::Pending};Step step_{Step::Ready};
  std::uint64_t previous_{0},result_{0};std::uint32_t reason_{0};bool accepted_{false};
};
}
