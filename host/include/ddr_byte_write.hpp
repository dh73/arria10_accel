#pragma once
#include "kernel_mailbox.hpp"
namespace asus::a10::memory {
enum class WriteState { Progress, AwaitingCompletion, Complete, Rejected, Unknown };
enum class WriteCompletion : std::uint32_t {
  BackendAcceptance=0x42595701, SelectedByteReadback=0x42595702
};
// One command on an exclusively owned, qualified mailbox and common-reset epoch.
// Complete has the explicitly selected ABI semantics; neither ABI is a global
// DMA/host fence. No automatic ABI fallback, read-modify-write or command retry.
class ByteWrite final {
 public:
  ByteWrite(mailbox::Port&,std::uint64_t base,std::uint64_t aperture_bytes,
            std::uint64_t device_address,std::uint32_t data,
            std::uint8_t mask,std::uint32_t sequence,
            WriteCompletion=WriteCompletion::BackendAcceptance) noexcept;
  ByteWrite(const ByteWrite&)=delete;
  ByteWrite& operator=(const ByteWrite&)=delete;
  WriteState advance() noexcept; // At most one transaction per call.
  WriteState state() const noexcept {return state_;}
  bool command_attempted() const noexcept {return attempted_;}
  bool readback_verified() const noexcept {
    return state_==WriteState::Complete && completion_==WriteCompletion::SelectedByteReadback;
  }
 private:
  mailbox::Port& port_;std::uint64_t base_,address_;
  std::uint32_t data_,sequence_;std::uint8_t mask_;
  WriteCompletion completion_;
  unsigned step_{0};WriteState state_{WriteState::Progress};bool attempted_{false};
};
}
