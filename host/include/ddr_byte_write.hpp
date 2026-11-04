#pragma once
#include "kernel_mailbox.hpp"
namespace asus::a10::memory {
enum class WriteState { Progress, AwaitingCompletion, Complete, Rejected, Unknown };
// One command on an exclusively owned, qualified mailbox and common-reset epoch.
// Complete means DDR request acceptance; platform visibility/drain fences remain
// required. No read-modify-write, background polling or automatic command retry.
class ByteWrite final {
 public:
  ByteWrite(mailbox::Port&,std::uint64_t base,std::uint64_t aperture_bytes,
            std::uint64_t device_address,std::uint32_t data,
            std::uint8_t mask,std::uint32_t sequence) noexcept;
  ByteWrite(const ByteWrite&)=delete;
  ByteWrite& operator=(const ByteWrite&)=delete;
  WriteState advance() noexcept; // At most one transaction per call.
  WriteState state() const noexcept {return state_;}
  bool command_attempted() const noexcept {return attempted_;}
 private:
  mailbox::Port& port_;std::uint64_t base_,address_;
  std::uint32_t data_,sequence_;std::uint8_t mask_;
  unsigned step_{0};WriteState state_{WriteState::Progress};bool attempted_{false};
};
}
