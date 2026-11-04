#pragma once
#include "host_writeback_round.hpp"
#include "supervisor_command.hpp"
#include <optional>

namespace asus::a10::control {
// Single opening attempt for an exclusively owned immutable image/session.
// Caller closes host submission before construction and keeps it closed until
// Accepted. Neither an accepted command nor this class qualifies a device,
// establishes upstream closure, or permits releasing outstanding DMA buffers.
class OpenRequest final {
 public:
  OpenRequest(mailbox::Port& fence_port, std::uint64_t fence_base,
              mailbox::Port& command_port, std::uint64_t command_base,
              std::array<std::uint32_t,6> context, std::uint64_t round,
              std::uint64_t command_id, Command command) noexcept;
  OpenRequest(const OpenRequest&) = delete;
  OpenRequest& operator=(const OpenRequest&) = delete;
  // At most one I/O per external service event; no retry or internal wait.
  State advance() noexcept;
  State state() const noexcept { return state_; }
  std::uint32_t reason() const noexcept { return command_.reason(); }
  // Only a matched accepted START/RESUME consumes the settled hardware round.
  // Unknown or rejected consumption never advances host generation tracking.
  std::optional<std::uint64_t> next_round() const noexcept;
 private:
  writeback::RoundFence fence_;
  Request command_;
  const std::uint64_t round_;
  State state_{State::Pending};
  bool fence_done_{false};
};
}
