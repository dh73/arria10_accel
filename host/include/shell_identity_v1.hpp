#pragma once
#include "generated_kernel_abi.hpp"
#include "../../drivers/aclpci/shell_identity_abi.h"
#include <array>
#include <cstdint>
#include <vector>

namespace asus::a10::image {
using Digest = std::array<std::uint8_t, 32>;
using Session = std::array<std::uint32_t, 4>;
constexpr std::uint32_t block_bytes = ACLPCI_ID_BYTES, capabilities = ACLPCI_ID_CAPABILITIES;
struct Range {
  std::uint32_t space;
  std::uint64_t offset, bytes;
};
struct Resource { std::uint32_t space; std::uint64_t bytes; };
// Explicit integration declarations, never discovered by scanning unknown BARs.
struct Expected { Digest build; Range management, cra; };
struct Context { Session session; std::uint64_t epoch; };
struct Request {
  std::uint64_t channel, serial;
  std::uint32_t offset;  // Management-relative byte offset.
};
struct Reply { Request request; bool completed; std::uint32_t value; };
class Reader {
 public:
  virtual ~Reader() = default;
  // One ordered, bounded, non-destructive 32-bit device transaction.
  // No cached/relabelled response, implicit retry or guessed MMIO mapping.
  virtual Reply read32(Request) noexcept = 0;
};
enum class Code {
  Consistent, TestSourceOnly, IoFailure, ReplyMismatch, CursorClosed,
  Torn, Invalid, Unsupported, Malformed, BadRange, MappingMismatch,
  StaleContext, SourceMismatch, BuildMismatch
};
struct RawSnapshot {
  std::uint32_t before{};
  std::array<std::uint32_t, 64> words{};
  std::uint32_t after{};
};
struct Capture { Code code{Code::Invalid}; RawSnapshot raw{}; };
class Cursor final {
 public:
  // The real adapter must obtain a nonzero, never-reused channel under driver
  // custody. This number is correlation data, not physical authority.
  explicit Cursor(std::uint64_t channel, std::uint64_t first_serial = 1)
      : channel_(channel), next_(first_serial),
        closed_(channel == 0 || first_serial == 0) {}
  Cursor(const Cursor&) = delete;
  Cursor& operator=(const Cursor&) = delete;
 private:
  std::uint64_t channel_, next_;
  bool closed_;
  friend Capture capture(Reader&, Cursor&) noexcept;
};
struct Health {
  bool valid{}, fault{}, release_ready{}, launch_permit{}, host_submit_permit{};
  std::uint8_t state{}, phase{}, adapter_code{};
  std::uint16_t history{}, pending{}, first_code{};
  bool address_valid{};
  std::uint64_t address{};
};
struct Observation {
  Digest source{}, build{};
  Context context{};
  Range management{}, cra{};
  std::uint32_t sequence{};
  Health health{};
};
struct Report {
  Code code{Code::Invalid};
  Observation observed{};
  // Deliberately no admission flag, Transport adapter or conversion to
  // kernel::Verification. Even Consistent is self-reported identity only.
};
Capture capture(Reader&, Cursor&) noexcept; // At most 72 reads, never a retry loop.
Report check(const RawSnapshot&, const kernel::SourceAbi&, const Expected&,
             const Context&, const std::vector<Resource>&) noexcept;
}  // namespace asus::a10::image
