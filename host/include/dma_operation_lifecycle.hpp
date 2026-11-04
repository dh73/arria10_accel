#pragma once

#include <stddef.h>

#include <MMD/aocl_mmd.h>

#include <cstddef>
#include <cstdint>
#include <exception>
#include <memory>

namespace asus::a10::dma {

using Generation = std::uint64_t;
using Sequence = std::uint64_t;
using LeaseId = std::uint64_t;

struct Ticket {
  Generation generation{0};
  Sequence sequence{0};

  friend constexpr bool operator==(const Ticket& lhs,
                                   const Ticket& rhs) noexcept {
    return lhs.generation == rhs.generation && lhs.sequence == rhs.sequence;
  }
  friend constexpr bool operator!=(const Ticket& lhs,
                                   const Ticket& rhs) noexcept {
    return !(lhs == rhs);
  }
};

struct TicketHash {
  std::size_t operator()(const Ticket& ticket) const noexcept;
};

enum class BufferOwner : std::uint8_t {
  CallerOwned,
  DriverOwned,
};

enum class DeviceMode : std::uint8_t {
  Running,
  Quiescing,
  Offline,
};

enum class DrainEvidence : std::uint8_t {
  None,
  PerOperation,
};

enum class BeginCode : std::uint8_t {
  Prepared,
  Blocking,
  RejectedQuiescing,
  RejectedOffline,
  MissingStatusHandler,
  InvalidLease,
  DuplicateToken,
  DuplicateLease,
  SequenceExhausted,
  Stopped,
};

struct BeginResult {
  BeginCode code{BeginCode::Stopped};
  Ticket ticket{};

  [[nodiscard]] constexpr bool prepared() const noexcept {
    return code == BeginCode::Prepared;
  }
  [[nodiscard]] constexpr bool blocking() const noexcept {
    return code == BeginCode::Blocking;
  }
};

enum class TransitionCode : std::uint8_t {
  Applied,
  NoEffect,
  // A terminal completion was durably recorded while submission ownership was
  // still Prepared; accept() or rejection must still resolve that reservation.
  QueuedEarly,
  Duplicate,
  StaleGeneration,
  UnknownTicket,
  InvalidStatus,
  InvalidState,
  ProtocolViolation,
  DebtRemaining,
  GenerationExhausted,
  Stopped,
};

enum class MemoryActionKind : std::uint8_t {
  // Real drain evidence exists. The mapping/pin/allocation represented by lease
  // may now be released. This is a decision notification, not a driver call.
  ReleaseSafe,

  // Drain is not known. Keep the underlying mapping/pin/allocation retained and
  // take the device offline. A later ReleaseSafe for the same lease is possible
  // after verified recovery/global drain.
  HoldOffline,
};

struct MemoryAction {
  MemoryActionKind kind{MemoryActionKind::HoldOffline};
  Ticket ticket{};
  LeaseId lease{0};
  BufferOwner owner{BufferOwner::CallerOwned};
};

using MemoryActionFn = void (*)(void* user_data,
                                const MemoryAction& action) noexcept;
using CallbackExceptionFn = void (*)(void* user_data,
                                     std::exception_ptr error) noexcept;

struct Hooks {
  MemoryActionFn memory_action{nullptr};
  void* memory_user_data{nullptr};
  CallbackExceptionFn callback_exception{nullptr};
  void* exception_user_data{nullptr};
};

struct Snapshot {
  DeviceMode mode{DeviceMode::Offline};
  Generation generation{0};
  Sequence next_sequence{0};

  std::size_t prepared{0};
  std::size_t blocking_in_flight{0};
  std::size_t accepted_debt{0};
  std::size_t orphan_holds{0};
  std::size_t queued_work{0};
  std::size_t work_in_flight{0};
  std::size_t active_leases{0};

  std::uint64_t accepted_total{0};
  std::uint64_t callback_invocations{0};
  std::uint64_t callback_exceptions{0};
  std::uint64_t release_safe_actions{0};
  std::uint64_t hold_offline_actions{0};
  std::uint64_t duplicate_events{0};
  std::uint64_t stale_events{0};

  bool dispatcher_stopped{false};
  // Generation-bound HOST admission observation, sampled under the lifecycle
  // lock. No Prepared/indeterminate/blocking handoff remains and begin is
  // closed. Accepted operations may still own buffers and posted writes.
  // Combine with actual transport admission closure; never use as DMA drain.
  // A new generation invalidates this observation.
  bool submissions_settled{false};
};

// Internal proposed host API. It deliberately performs no device register,
// ioctl, DMA, IRQ, reset, or JTAG operation. The real transport owns those
// actions and reports only acceptance, terminal status, and drain evidence.
class OperationLifecycle final {
 public:
  explicit OperationLifecycle(int mmd_handle, Hooks hooks);
  ~OperationLifecycle() noexcept;

  OperationLifecycle(const OperationLifecycle&) = delete;
  OperationLifecycle& operator=(const OperationLifecycle&) = delete;
  OperationLifecycle(OperationLifecycle&&) = delete;
  OperationLifecycle& operator=(OperationLifecycle&&) = delete;

  // The handler snapshot present at begin() is retained for that operation.
  // Re-registering a handler affects only later operations.
  void set_status_handler(aocl_mmd_status_handler_fn handler,
                          void* user_data) noexcept;

  // A null MMD token is classified as blocking and creates a ticket but no
  // status-callback debt. The caller must execute the backend synchronously and
  // call finish_blocking() exactly once after that call returns. A nonzero lease
  // is retained across the blocking call; zero is allowed for operations such as
  // device-to-device copies that have no host mapping lease.
  [[nodiscard]] BeginResult begin(aocl_mmd_op_t token,
                                  LeaseId lease,
                                  BufferOwner owner);

  // Call exactly one of accept(), reject_not_accepted(), or
  // reject_indeterminate() after the transport submission attempt.
  [[nodiscard]] TransitionCode accept(Ticket ticket);
  [[nodiscard]] TransitionCode reject_not_accepted(Ticket ticket);
  [[nodiscard]] TransitionCode reject_indeterminate(Ticket ticket);

  // Completes a null-token blocking call after the real backend has returned.
  // Return from the backend is the drain evidence required by the MMD contract;
  // no status callback is generated.
  [[nodiscard]] TransitionCode finish_blocking(Ticket ticket);

  // status must be 0 (success) or negative (terminal error). A positive value is
  // rejected as a protocol violation. PerOperation drain evidence must be used
  // only when the actual transport contract proves all DMA references for this
  // operation are gone.
  [[nodiscard]] TransitionCode complete(Ticket ticket,
                                        int status,
                                        DrainEvidence drain);
  [[nodiscard]] TransitionCode note_operation_drained(Ticket ticket);

  // These assign a logical terminal result but never manufacture drain.
  // Callback and ReleaseSafe remain gated by real drain evidence.
  [[nodiscard]] TransitionCode quiesce(int terminal_status);
  [[nodiscard]] TransitionCode mark_offline(int terminal_status);

  // Verified global/function/bus/power recovery may establish that every old
  // operation in the named generation is physically drained.
  [[nodiscard]] TransitionCode note_global_drained(Generation generation);

  // Starts a fresh ticket namespace only after all old records, callbacks, and
  // lease actions have retired. Old-generation completions then remain stale.
  [[nodiscard]] TransitionCode start_new_generation();

  // Waits only for work that is already callback/release/hold ready. It does not
  // wait for missing hardware drain evidence and has no embedded timeout. When
  // called reentrantly from a dispatcher callback/hook, it returns immediately
  // rather than waiting for its own in-flight frame.
  void flush_ready();

  // Orderly dispatcher shutdown succeeds only with no operation/lease debt.
  // On destruction with unresolved debt, the destructor fail-closes: it emits
  // HoldOffline decisions for unresolved leases and never invents ReleaseSafe.
  [[nodiscard]] TransitionCode shutdown();

  [[nodiscard]] Snapshot snapshot() const noexcept;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace asus::a10::dma
