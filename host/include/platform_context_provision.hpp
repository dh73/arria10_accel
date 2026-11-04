#pragma once
#include "kernel_mailbox.hpp"
#include <array>
namespace asus::a10::context {
enum class State { Pending, Complete, Rejected, Poisoned };
// Exclusive qualified BAR2 mapping and coordinated reset lifetime required.
// Provisioning does not grant ownership, prove drain, or authorize reset.
// Uncertainty requires external reconciliation; never construct a replacement
// request merely to retry a partial transaction.
class Provision final {
 public:
  Provision(mailbox::Port&,std::uint64_t base,std::uint64_t epoch,
            std::array<std::uint64_t,2> session) noexcept;
  Provision(const Provision&)=delete;
  Provision& operator=(const Provision&)=delete;
  State advance() noexcept; // At most one ordered I/O; no polling or replay.
  State state()const noexcept{return state_;}
 private:
  mailbox::Port& port_;std::uint64_t base_;
  std::array<std::uint32_t,6> words_{};
  unsigned step_{0};State state_{State::Pending};
};
}
