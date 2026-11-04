#pragma once
#include "kernel_mailbox.hpp"
namespace asus::a10::diagnostics {
enum class Code { Observed, InvalidMapping, NotIssued, Unknown, Unsupported, Malformed };
struct Snapshot {
 Code code{Code::Unknown};
 std::uint8_t flags{0};
 // Diagnostic bits only; none certifies admission, transaction drain or recovery.
 enum Flag : std::uint8_t {
  SnapshotEpochValid=1, ExternalContainment=2, DmaSnapshotValid=4,
  DmaEpochLost=8, SharedPathFault=16, InitializationFailed=32,
  EccInterrupt=64, MemoryReady=128
 };
 bool reports(Flag f) const noexcept { return code==Code::Observed && (flags&f)!=0; }
};
// Caller holds the qualified mapping/common epoch. Exactly two ordered reads
// on success, no writes, fences, retries, discovery or state transitions.
Snapshot capture(mailbox::Port&,std::uint64_t base) noexcept;
}
