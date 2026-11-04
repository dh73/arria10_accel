#pragma once
#include "kernel_mailbox.hpp"
#include <cstddef>
#include <sys/types.h>
namespace asus::a10::mailbox {
// Borrowed descriptor: caller retains exclusive verified image/session custody.
// No open, binding, reset, admission, retry or descriptor ownership is implied.
// This ABI returns ZERO on successful PIO, not the transferred byte count.
class AclPciPort final : public Port {
 public:
  using Call = ssize_t (*)(int, void*, std::size_t, bool) noexcept;
  // Explicit verified aperture; includes a non-destructive ordered read at +20.
  AclPciPort(int fd, std::uint64_t mailbox_base, Call call = native,
             std::uint64_t aperture_bytes = 32) noexcept;
  Reply write32(std::uint64_t, std::uint32_t) noexcept override;
  Reply read32(std::uint64_t) noexcept override;
  Reply fence() noexcept override;
 private:
  static ssize_t native(int, void*, std::size_t, bool) noexcept;
  Reply access(std::uint64_t, std::uint32_t, bool) noexcept;
  int fd_; std::uint64_t base_, aperture_bytes_; Call call_; bool valid_, poisoned_{false};
};
}
