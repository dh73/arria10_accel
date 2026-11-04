#pragma once
#include "kernel_mailbox.hpp"
#include <array>
#include <memory>
namespace asus::a10::control {
// Owns protocol bookkeeping only. Caller retains exclusive qualified image,
// mapping, closed publication and reset lifetime throughout and after failure.
// This adapter neither discovers/adopts a device nor grants DMA admission.
class ClosedStartup final {
 public:
  struct Window { mailbox::Port* port; std::uint64_t base; };
  ClosedStartup(std::array<Window,4> windows,
                std::array<std::uint32_t,6> context, std::uint64_t id) noexcept;
  ~ClosedStartup();
  ClosedStartup(const ClosedStartup&)=delete;
  ClosedStartup& operator=(const ClosedStartup&)=delete;
  // 0 pending, 1 accepted, 2 rejected, negative permanent failure.
  // At most one I/O per externally scheduled service event; no retries.
  int advance() noexcept;
  int revoke() noexcept;
  int result() const noexcept;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}
