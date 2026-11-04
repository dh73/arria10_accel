#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <sys/types.h>
namespace asus::a10 {
// Borrowed descriptor with exclusive session custody. No image qualification,
// DMA admission, close, reset or automatic service loop. Serialize all calls.
// Accepted is a historical startup receipt, not a live reset/health certificate.
// Retain descriptor/custody on Unknown; this object never proves drain.
class AclPciStartupClient {
 public:
  enum class State { Idle, Pending, Accepted, Rejected, Unknown, Invalid };
  using Call = ssize_t (*)(int, void*, std::size_t, bool) noexcept;
  explicit AclPciStartupClient(int fd, Call call = native) noexcept;
  AclPciStartupClient(const AclPciStartupClient&) = delete;
  AclPciStartupClient& operator=(const AclPciStartupClient&) = delete;
  State arm(const std::array<std::uint32_t,6>& context, std::uint64_t id) noexcept;
  // Advance once on a service event; no polling or automatic retry.
  State advance() noexcept;
  State state() const noexcept { return state_; }
 private:
  static ssize_t native(int, void*, std::size_t, bool) noexcept;
  ssize_t invoke(std::array<std::uint32_t,10>&, bool) noexcept;
  int fd_; Call call_; State state_;
};
}
