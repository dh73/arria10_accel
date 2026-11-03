#pragma once

#include "generated_kernel_abi.hpp"

#include <cstdint>
#include <memory>
#include <stdexcept>

namespace asus::a10::kernel {

// A transport-issued, nonreused session namespace. This is NOT an FPGA image ID
// and is deliberately distinct from dma::Ticket / MMD callback ownership.
struct Ticket {
  std::uint64_t session{0}, sequence{0};
  friend bool operator==(Ticket a, Ticket b) noexcept {
    return a.session == b.session && a.sequence == b.sequence;
  }
  friend bool operator!=(Ticket a, Ticket b) noexcept { return !(a == b); }
};

enum class IoOutcome : std::uint8_t { Completed, NotIssued, Unknown };
enum class Phase : std::uint8_t {
  Admission, BeforeBaseline, Baseline, Argument, BeforeStart, Start,
  AfterStart, Completion, ConfirmClear, Retirement
};
struct Request {
  Ticket ticket{};
  // Zero is reserved for an idempotent retirement-certificate query.
  // All CSR/admission/ordering requests use nonzero monotonic serials.
  std::uint64_t serial{0};
  Phase phase{Phase::Admission};
  friend bool operator==(Request a, Request b) noexcept {
    return a.ticket == b.ticket && a.serial == b.serial && a.phase == b.phase;
  }
};
struct IoReply {
  Request request{};
  IoOutcome outcome{IoOutcome::Unknown};
  std::uint64_t value{0};
};

// One owning object may aggregate all allocations, pins, device mappings and
// DMA ownership references used by the launch. Its destructor releases those
// resources. The transport must check that it covers EVERY memory argument.
// Callers must not manually free/unmap resources retained by keep_alive.
struct BufferLease {
  std::uint64_t id{0};
  std::shared_ptr<void> keep_alive;
};

struct Verification {
  IoOutcome outcome{IoOutcome::Unknown};
  std::uint64_t session{0}, first_ticket{1};
  std::uint32_t aperture_bytes{0};
  bool image_matches_sources{false}, cra_mapping_verified{false};
  bool exclusive_continuous{false}, no_prior_work{false};
  bool at_most_one_completion{false}, read_clear_safe{false};
};
struct AdmissionReply {
  Request request{};
  IoOutcome outcome{IoOutcome::Unknown};
  bool image_current{false}, cra_current{false}, exclusive{false};
  bool no_debt{false}, buffers_ready{false}, launch_permitted{false};
};
struct RetirementReply {
  Request request{};
  IoOutcome outcome{IoOutcome::Unknown};
  std::uint64_t lease{0};
  bool no_pending_start{false}, no_future_kernel_access{false};
  bool kernel_memory_drained{false}, host_dma_drained{false};
  bool descriptors_drained{false}, writebacks_drained{false};
};

// Synchronous bounded transactions, never an internal polling loop. Production
// adapters must implement the contracts in docs/GENERATED_KERNEL_EXECUTOR.md.
// Methods must not throw. An exception/timeout/lost acknowledgement is Unknown,
// unless the adapter positively proves the transaction cannot execute later.
class Transport {
 public:
  virtual ~Transport() = default;
  // Must refuse an unqualified/snapshot build in production. An explicit fake
  // can accept SuppliedSnapshot; this cannot confer physical authority.
  virtual Verification verify(const SourceAbi&) noexcept = 0;
  // Grants one launch only while continuously holding the verified session.
  // Checks the actual current image/mapping, producer gate and complete lease.
  virtual AdmissionReply admit(Request, const Launch&,
                               const BufferLease&) noexcept = 0;
  // Values represent little-endian 64-bit CRA words, byte-enable 0xff. Offsets
  // are aperture-relative, never BAR offsets. No splitting/replay of start.
  virtual IoReply write64(Request, std::uint32_t offset,
                          std::uint64_t value) noexcept = 0;
  // Exactly one device read-clear transaction. A replayed RPC response must
  // retain its original Request; the adapter must not relabel it as fresh.
  virtual IoReply read64(Request, std::uint32_t offset) noexcept = 0;
  // Completed fences mean previous writes reached the verified CRA in order.
  // BeforeStart also ensures arguments are visible before start; AfterStart
  // establishes acceptance of the one start, including posted-write ordering.
  virtual IoReply order(Request) noexcept = 0;
  // Independent, ticket AND lease bound evidence. Reset, IRQ, count=1 and CPU
  // fences alone are never enough. False evidence bits mean "not yet known".
  // A true certificate is irrevocable for this never-reused ticket+lease.
  // Request serial is always zero: this non-destructive query remains usable
  // after notification/CSR serial exhaustion and can be explicitly rechecked.
  virtual RetirementReply retirement(Request, std::uint64_t lease) noexcept = 0;
};

enum class Mode : std::uint8_t { Running, Stopping, Offline, Closed };
enum class StartState : std::uint8_t { NotIssued, Accepted, Unknown };
enum class Code : std::uint8_t {
  Accepted, AdmissionDenied, NotStarted, Pending, KernelComplete, Retired,
  Stopped, Offline, Busy, InvalidLease, Duplicate, Stale, UnknownTicket,
  IoNotIssued, IoUnknown, ProtocolError, SequenceExhausted, Closed
};
struct Result {
  Code code{Code::Offline};
  Ticket ticket{};
  StartState start{StartState::NotIssued};
  Phase phase{Phase::Admission};
  bool kernel_complete{false}, poisoned{false};
};
struct Notice {
  Ticket ticket{};
  // Nonzero, increasing per ticket. Capture at the transport/event source,
  // before queueing on the strand. Duplicate/stale delivery never reads CSR.
  std::uint64_t sequence{0};
};
struct Snapshot {
  Mode mode{Mode::Offline};
  Ticket active{};
  std::uint64_t next_ticket{0}, last_notice{0};
  StartState start{StartState::NotIssued};
  bool holds_buffers{false}, kernel_complete{false}, poisoned{false};
  bool ticket_space_exhausted{false}, executor_attached{false};
};
class StrandViolation : public std::logic_error {
 public:
  StrandViolation() : std::logic_error("kernel executor strand violation") {}
};

class SerializedExecutor;

// This owner MUST outlive unresolved work. Executor destruction detaches but
// leaves the actual shared ownership here, with the transport/session intact.
// Destroying the last owner with debt terminates before destroying the lease;
// there is no implicit free, leak-to-nowhere or reset-based retirement path.
class RetirementOwner final {
 public:
  explicit RetirementOwner(std::shared_ptr<Transport>);
  ~RetirementOwner() noexcept;
  RetirementOwner(const RetirementOwner&) = delete;
  RetirementOwner& operator=(const RetirementOwner&) = delete;
  // Only after the executor is detached. Uses independent retirement evidence;
  // never fabricates a kernel completion or replays a read-clear transaction.
  Result recover(Ticket);
  Snapshot snapshot() const;
 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
  friend class SerializedExecutor;
};

// One fixed-thread externally serialized strand, enforced for EVERY public
// entry (including snapshots and destruction). No workers or user callbacks.
// Wrong-thread/reentrant calls throw before accessing mutable state. Destruction
// from a wrong thread or inside a transport/resource-destructor call terminates.
// Queue IRQs/drain events until the outer call returns; never acknowledge a cue
// merely because a forbidden reentrant delivery was rejected.
class SerializedExecutor final {
 public:
  explicit SerializedExecutor(std::shared_ptr<RetirementOwner>);
  ~SerializedExecutor() noexcept;
  SerializedExecutor(const SerializedExecutor&) = delete;
  SerializedExecutor& operator=(const SerializedExecutor&) = delete;
  Result submit(const Launch&, BufferLease);
  Result service(Notice);
  // Explicitly abandon completion accounting, close admission, and query ONLY
  // independent retirement. Usable even when notification/I/O IDs exhaust.
  Result recover(Ticket);
  // Stops NEW launches. No reset, fabricated terminal success or forced MMD
  // callback; service() continues actual accepted completion and retirement.
  Code stop();
  Code mark_offline();
  Code shutdown();
  Snapshot snapshot() const;
 private:
  std::shared_ptr<RetirementOwner> owner_;
};

}  // namespace asus::a10::kernel
