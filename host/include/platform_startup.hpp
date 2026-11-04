#pragma once
#include "platform_context_provision.hpp"
#include "platform_open.hpp"
namespace asus::a10::control {
// First START after a qualified coordinated reset, with exclusive device
// custody and closed host submission. Does not discover or admit hardware.
// RESUME uses OpenRequest directly; it must never reprovision the context.
class Startup final {
 public:
  Startup(mailbox::Port& provisioning,std::uint64_t provisioning_base,
          mailbox::Port& fence,std::uint64_t fence_base,
          mailbox::Port& command,std::uint64_t command_base,
          std::uint64_t epoch,std::array<std::uint64_t,2> session,
          std::uint64_t command_id) noexcept;
  Startup(const Startup&)=delete;Startup& operator=(const Startup&)=delete;
  State advance() noexcept; // One I/O per external service event, no retries.
  State state()const noexcept{return state_;}
  std::optional<std::uint64_t> next_round()const noexcept{return state_==State::Accepted?open_.next_round():std::nullopt;}
 private:
  context::Provision provision_;OpenRequest open_;
  State state_{State::Pending};bool provisioned_{false};
};
}
