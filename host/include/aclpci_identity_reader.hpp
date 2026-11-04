#pragma once
#include "shell_identity_v1.hpp"
#include "aclpci_mailbox_port.hpp"
namespace asus::a10::image {
// Borrowed fd and explicit BAR2 identity range under caller-held image custody.
// Reading identity never grants driver admission or proves physical source identity.
class AclPciReader final : public Reader {
 public:
  using Call = mailbox::AclPciPort::Call;
  AclPciReader(int fd, std::uint64_t base, std::uint64_t channel,
               Call call = native) noexcept;
  Reply read32(Request) noexcept override;
 private:
  static ssize_t native(int, void*, std::size_t, bool) noexcept;
  int fd_; std::uint64_t base_, channel_, last_{0}; Call call_; bool closed_;
};
}
