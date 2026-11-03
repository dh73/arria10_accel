#include "dma_operation_lifecycle.hpp"

#include <algorithm>
#include <condition_variable>
#include <deque>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <mutex>
#include <thread>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <vector>

namespace asus::a10::dma {
namespace {

static_assert(std::is_same<aocl_mmd_op_t, void*>::value,
              "The pinned MMD 2024.2 ABI defines aocl_mmd_op_t as void*");
static_assert(std::string_view{AOCL_MMD_VERSION_STRING} == "2024.2",
              "This component requires the pinned MMD 2024.2 header");

struct HandlerSnapshot {
  aocl_mmd_status_handler_fn function{nullptr};
  void* user_data{nullptr};
};

enum class Phase : std::uint8_t {
  Prepared,
  Accepted,
  Orphan,
  Blocking,
};

struct Entry {
  Phase phase{Phase::Prepared};
  Ticket ticket{};
  aocl_mmd_op_t token{nullptr};
  LeaseId lease{0};
  BufferOwner owner{BufferOwner::CallerOwned};
  HandlerSnapshot handler{};

  bool terminal_set{false};
  int terminal_status{0};
  bool completion_observed{false};
  bool drained{false};
  bool callback_queued{false};
  bool release_queued{false};
  bool hold_offline_queued{false};
  bool blocking_finished{false};
};

enum class WorkKind : std::uint8_t {
  Callback,
  ReleaseOnly,
  HoldOnly,
};

struct WorkItem {
  WorkKind kind{WorkKind::HoldOnly};
  Ticket ticket{};
  LeaseId lease{0};
  BufferOwner owner{BufferOwner::CallerOwned};
  aocl_mmd_op_t token{nullptr};
  int status{0};
  HandlerSnapshot handler{};
  bool erase_entry_after{false};
};

}  // namespace

std::size_t TicketHash::operator()(const Ticket& ticket) const noexcept {
  const auto h1 = std::hash<Generation>{}(ticket.generation);
  const auto h2 = std::hash<Sequence>{}(ticket.sequence);
  return h1 ^ (h2 + static_cast<std::size_t>(0x9e3779b97f4a7c15ULL) +
               (h1 << 6U) + (h1 >> 2U));
}

class OperationLifecycle::Impl final {
 public:
  Impl(int mmd_handle, Hooks hooks)
      : mmd_handle_(mmd_handle), hooks_(hooks) {
    if (hooks_.memory_action == nullptr) {
      throw std::invalid_argument(
          "OperationLifecycle requires a non-null memory-action sink");
    }
    worker_ = std::thread([this] { worker_loop(); });
  }

  ~Impl() = default;

  void set_status_handler(aocl_mmd_status_handler_fn handler,
                          void* user_data) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    current_handler_.function = handler;
    current_handler_.user_data = user_data;
  }

  BeginResult begin(aocl_mmd_op_t token, LeaseId lease, BufferOwner owner) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_ || stop_requested_) {
      return {BeginCode::Stopped, {}};
    }
    if (mode_ == DeviceMode::Quiescing) {
      return {BeginCode::RejectedQuiescing, {}};
    }
    if (mode_ == DeviceMode::Offline) {
      return {BeginCode::RejectedOffline, {}};
    }

    const bool blocking = token == nullptr;
    if (!blocking && current_handler_.function == nullptr) {
      return {BeginCode::MissingStatusHandler, {}};
    }
    if (!blocking && lease == 0) {
      return {BeginCode::InvalidLease, {}};
    }
    if (!blocking && active_tokens_.find(token) != active_tokens_.end()) {
      return {BeginCode::DuplicateToken, {}};
    }
    if (lease != 0 && active_leases_.find(lease) != active_leases_.end()) {
      return {BeginCode::DuplicateLease, {}};
    }
    if (next_sequence_ == std::numeric_limits<Sequence>::max()) {
      mode_ = DeviceMode::Offline;
      return {BeginCode::SequenceExhausted, {}};
    }

    const Ticket ticket{generation_, next_sequence_++};
    Entry entry;
    entry.phase = blocking ? Phase::Blocking : Phase::Prepared;
    entry.ticket = ticket;
    entry.token = token;
    entry.lease = lease;
    entry.owner = owner;
    if (!blocking) {
      entry.handler = current_handler_;
    }

    const auto [entry_it, inserted] = entries_.emplace(ticket, entry);
    if (!inserted) {
      mode_ = DeviceMode::Offline;
      return {BeginCode::SequenceExhausted, {}};
    }

    try {
      if (!blocking) {
        active_tokens_.emplace(token, ticket);
      }
      if (lease != 0) {
        active_leases_.emplace(lease, ticket);
      }
    } catch (...) {
      if (!blocking) {
        active_tokens_.erase(token);
      }
      if (lease != 0) {
        active_leases_.erase(lease);
      }
      entries_.erase(entry_it);
      throw;
    }

    return {blocking ? BeginCode::Blocking : BeginCode::Prepared, ticket};
  }

  TransitionCode accept(Ticket ticket) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto classified = classify_locked(ticket);
    if (classified != TransitionCode::Applied) {
      return classified;
    }
    auto& entry = entries_.at(ticket);
    if (entry.phase == Phase::Accepted) {
      // A prior queue allocation failure may have left an otherwise-ready
      // accepted entry unclaimed.  Retrying accept() is classified as a
      // duplicate, but first retries the idempotent callback claim.
      schedule_callback_if_ready_locked(entry);
      ++duplicate_events_;
      return TransitionCode::Duplicate;
    }
    if (entry.phase != Phase::Prepared) {
      return TransitionCode::InvalidState;
    }

    entry.phase = Phase::Accepted;
    ++accepted_total_;
    schedule_callback_if_ready_locked(entry);
    return TransitionCode::Applied;
  }

  TransitionCode reject_not_accepted(Ticket ticket) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto classified = classify_locked(ticket);
    if (classified != TransitionCode::Applied) {
      return classified;
    }
    auto it = entries_.find(ticket);
    Entry& entry = it->second;
    if (entry.phase != Phase::Prepared) {
      return TransitionCode::InvalidState;
    }

    if (entry.completion_observed) {
      // A backend cannot both report "not accepted" and produce a completion.
      // Preserve the lease as an orphan and force recovery instead of guessing.
      active_tokens_.erase(entry.token);
      entry.phase = Phase::Orphan;
      entry.token = nullptr;
      entry.handler = {};
      mode_ = DeviceMode::Offline;
      if (entry.drained) {
        schedule_orphan_release_locked(entry);
      } else {
        queue_hold_if_needed_locked(entry);
      }
      return TransitionCode::ProtocolViolation;
    }

    const WorkItem work{WorkKind::ReleaseOnly,
                        entry.ticket,
                        entry.lease,
                        entry.owner,
                        nullptr,
                        0,
                        {},
                        false};
    // Queue first so an allocation failure leaves the Prepared reservation and
    // active-token guard intact; the caller may retry without permitting token
    // aliasing against an unresolved submission.
    work_queue_.push_back(work);
    active_tokens_.erase(entry.token);
    entries_.erase(it);
    work_cv_.notify_one();
    return TransitionCode::Applied;
  }

  TransitionCode reject_indeterminate(Ticket ticket) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto classified = classify_locked(ticket);
    if (classified != TransitionCode::Applied) {
      return classified;
    }
    auto& entry = entries_.at(ticket);
    if (entry.phase != Phase::Prepared) {
      return TransitionCode::InvalidState;
    }

    active_tokens_.erase(entry.token);
    entry.phase = Phase::Orphan;
    entry.token = nullptr;
    entry.handler = {};
    mode_ = DeviceMode::Offline;
    if (entry.drained) {
      schedule_orphan_release_locked(entry);
    } else {
      queue_hold_if_needed_locked(entry);
    }
    return TransitionCode::Applied;
  }

  TransitionCode finish_blocking(Ticket ticket) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto classified = classify_locked(ticket);
    if (classified != TransitionCode::Applied) {
      return classified;
    }
    auto it = entries_.find(ticket);
    Entry& entry = it->second;
    if (entry.phase != Phase::Blocking) {
      return TransitionCode::InvalidState;
    }
    if (entry.blocking_finished) {
      ++duplicate_events_;
      return TransitionCode::Duplicate;
    }

    if (entry.lease == 0) {
      entry.blocking_finished = true;
      entry.drained = true;
      entries_.erase(it);
      return TransitionCode::Applied;
    }

    WorkItem work;
    work.kind = WorkKind::ReleaseOnly;
    work.ticket = entry.ticket;
    work.lease = entry.lease;
    work.owner = entry.owner;
    work.erase_entry_after = true;
    work_queue_.push_back(work);
    entry.blocking_finished = true;
    entry.drained = true;
    entry.release_queued = true;
    work_cv_.notify_one();
    return TransitionCode::Applied;
  }

  TransitionCode complete(Ticket ticket, int status, DrainEvidence drain) {
    if (status > 0) {
      return TransitionCode::InvalidStatus;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    const auto classified = classify_locked(ticket);
    if (classified != TransitionCode::Applied) {
      return classified;
    }
    auto& entry = entries_.at(ticket);
    if (entry.phase == Phase::Blocking) {
      return TransitionCode::InvalidState;
    }

    bool changed = false;
    if (entry.phase == Phase::Orphan) {
      if (drain == DrainEvidence::PerOperation && !entry.drained) {
        entry.drained = true;
        changed = true;
        schedule_orphan_release_locked(entry);
      }
      if (!changed) {
        ++duplicate_events_;
        return TransitionCode::Duplicate;
      }
      return TransitionCode::Applied;
    }

    if (!entry.completion_observed) {
      entry.completion_observed = true;
      changed = true;
      if (!entry.terminal_set) {
        entry.terminal_set = true;
        entry.terminal_status = status;
      }
    } else {
      ++duplicate_events_;
    }

    if (drain == DrainEvidence::PerOperation && !entry.drained) {
      entry.drained = true;
      changed = true;
    }

    const bool queued_before_accept = entry.phase == Phase::Prepared;
    if (entry.phase == Phase::Accepted) {
      schedule_callback_if_ready_locked(entry);
    }

    if (!changed) {
      return TransitionCode::Duplicate;
    }
    return queued_before_accept ? TransitionCode::QueuedEarly
                                : TransitionCode::Applied;
  }

  TransitionCode note_operation_drained(Ticket ticket) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto classified = classify_locked(ticket);
    if (classified != TransitionCode::Applied) {
      return classified;
    }
    auto& entry = entries_.at(ticket);
    if (entry.drained) {
      // As with accept(), make a duplicate drain report a recovery point for a
      // prior work-queue allocation failure without creating a second claim.
      if (entry.phase == Phase::Accepted) {
        schedule_callback_if_ready_locked(entry);
      } else if (entry.phase == Phase::Orphan) {
        schedule_orphan_release_locked(entry);
      }
      ++duplicate_events_;
      return TransitionCode::Duplicate;
    }
    entry.drained = true;
    if (entry.phase == Phase::Accepted) {
      schedule_callback_if_ready_locked(entry);
    } else if (entry.phase == Phase::Orphan) {
      schedule_orphan_release_locked(entry);
    }
    return TransitionCode::Applied;
  }

  TransitionCode quiesce(int terminal_status) {
    if (terminal_status >= 0) {
      return TransitionCode::InvalidStatus;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_ || stop_requested_) {
      return TransitionCode::Stopped;
    }
    if (mode_ == DeviceMode::Offline) {
      return TransitionCode::NoEffect;
    }
    mode_ = DeviceMode::Quiescing;
    for (auto& pair : entries_) {
      Entry& entry = pair.second;
      if (entry.phase == Phase::Orphan || entry.phase == Phase::Blocking) {
        continue;
      }
      if (!entry.terminal_set) {
        entry.terminal_set = true;
        entry.terminal_status = terminal_status;
      }
      if (entry.phase == Phase::Accepted) {
        schedule_callback_if_ready_locked(entry);
      }
    }
    return TransitionCode::Applied;
  }

  TransitionCode mark_offline(int terminal_status) {
    if (terminal_status >= 0) {
      return TransitionCode::InvalidStatus;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_ || stop_requested_) {
      return TransitionCode::Stopped;
    }
    mode_ = DeviceMode::Offline;
    for (auto& pair : entries_) {
      Entry& entry = pair.second;
      if ((entry.phase == Phase::Prepared ||
           entry.phase == Phase::Accepted) &&
          !entry.terminal_set) {
        entry.terminal_set = true;
        entry.terminal_status = terminal_status;
      }
      if (entry.phase == Phase::Accepted) {
        schedule_callback_if_ready_locked(entry);
      }
      if (!entry.drained && !entry.callback_queued &&
          !entry.release_queued) {
        queue_hold_if_needed_locked(entry);
      }
    }
    return TransitionCode::Applied;
  }

  TransitionCode note_global_drained(Generation generation) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (generation < generation_) {
      ++stale_events_;
      return TransitionCode::StaleGeneration;
    }
    if (generation > generation_) {
      return TransitionCode::UnknownTicket;
    }

    bool changed = false;
    for (auto& pair : entries_) {
      Entry& entry = pair.second;
      if (entry.ticket.generation != generation) {
        continue;
      }
      if (!entry.drained) {
        entry.drained = true;
        changed = true;
      }
      if (entry.phase == Phase::Accepted) {
        schedule_callback_if_ready_locked(entry);
      } else if (entry.phase == Phase::Orphan) {
        schedule_orphan_release_locked(entry);
      }
    }
    return changed ? TransitionCode::Applied : TransitionCode::NoEffect;
  }

  TransitionCode start_new_generation() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_ || stop_requested_) {
      return TransitionCode::Stopped;
    }
    if (mode_ == DeviceMode::Running) {
      return TransitionCode::InvalidState;
    }
    if (!entries_.empty() || !active_tokens_.empty() ||
        !active_leases_.empty() || !work_queue_.empty() ||
        work_in_flight_ != 0) {
      return TransitionCode::DebtRemaining;
    }
    if (generation_ == std::numeric_limits<Generation>::max()) {
      mode_ = DeviceMode::Offline;
      return TransitionCode::GenerationExhausted;
    }
    ++generation_;
    next_sequence_ = 1;
    mode_ = DeviceMode::Running;
    return TransitionCode::Applied;
  }

  void flush_ready() {
    std::unique_lock<std::mutex> lock(mutex_);
    // A callback or memory-action hook runs on the dispatcher itself. Waiting
    // there for work_in_flight_ to reach zero would wait for the current call
    // frame and deadlock. Reentrant flush is therefore a nonblocking fence: all
    // earlier state transitions are already visible, and queued work resumes
    // when the hook returns.
    if (worker_thread_id_ == std::this_thread::get_id()) {
      return;
    }
    idle_cv_.wait(lock, [this] {
      return work_queue_.empty() && work_in_flight_ == 0;
    });
  }

  TransitionCode shutdown() {
    std::thread worker;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopped_ || stop_requested_) {
        return TransitionCode::Stopped;
      }
      if (!entries_.empty() || !active_tokens_.empty() ||
          !active_leases_.empty() || !work_queue_.empty() ||
          work_in_flight_ != 0) {
        return TransitionCode::DebtRemaining;
      }
      stop_requested_ = true;
      work_cv_.notify_all();
      worker = std::move(worker_);
    }

    if (worker.joinable()) {
      worker.join();
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopped_ = true;
    }
    return TransitionCode::Applied;
  }

  Snapshot snapshot() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    Snapshot result;
    result.mode = mode_;
    result.generation = generation_;
    result.next_sequence = next_sequence_;
    for (const auto& pair : entries_) {
      switch (pair.second.phase) {
        case Phase::Prepared:
          ++result.prepared;
          break;
        case Phase::Accepted:
          ++result.accepted_debt;
          break;
        case Phase::Orphan:
          ++result.orphan_holds;
          break;
        case Phase::Blocking:
          ++result.blocking_in_flight;
          break;
      }
    }
    result.queued_work = work_queue_.size();
    result.work_in_flight = work_in_flight_;
    result.active_leases = active_leases_.size();
    result.accepted_total = accepted_total_;
    result.callback_invocations = callback_invocations_;
    result.callback_exceptions = callback_exceptions_;
    result.release_safe_actions = release_safe_actions_;
    result.hold_offline_actions = hold_offline_actions_;
    result.duplicate_events = duplicate_events_;
    result.stale_events = stale_events_;
    result.dispatcher_stopped = stopped_;
    return result;
  }

  void fail_closed_destructor() noexcept {
    std::thread worker;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopped_) {
        return;
      }
      mode_ = DeviceMode::Offline;
      for (auto& pair : entries_) {
        Entry& entry = pair.second;
        if (!entry.callback_queued && !entry.release_queued) {
          try {
            queue_hold_if_needed_locked(entry);
          } catch (...) {
            // Allocation failure on a fail-closed path must still never emit a
            // false ReleaseSafe. The durable owner must retain absent a release.
          }
        }
      }
      stop_requested_ = true;
      work_cv_.notify_all();
      worker = std::move(worker_);
    }
    if (worker.joinable()) {
      worker.join();
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopped_ = true;
    }
  }

 private:
  TransitionCode classify_locked(Ticket ticket) {
    if (stopped_ || stop_requested_) {
      return TransitionCode::Stopped;
    }
    if (ticket.generation < generation_) {
      ++stale_events_;
      return TransitionCode::StaleGeneration;
    }
    if (ticket.generation > generation_) {
      return TransitionCode::UnknownTicket;
    }
    if (entries_.find(ticket) != entries_.end()) {
      return TransitionCode::Applied;
    }
    if (ticket.sequence != 0 && ticket.sequence < next_sequence_) {
      ++duplicate_events_;
      return TransitionCode::Duplicate;
    }
    return TransitionCode::UnknownTicket;
  }

  void schedule_callback_if_ready_locked(Entry& entry) {
    if (entry.phase != Phase::Accepted || !entry.terminal_set ||
        !entry.drained || entry.callback_queued) {
      return;
    }
    WorkItem work;
    work.kind = WorkKind::Callback;
    work.ticket = entry.ticket;
    work.lease = entry.lease;
    work.owner = entry.owner;
    work.token = entry.token;
    work.status = entry.terminal_status;
    work.handler = entry.handler;
    work.erase_entry_after = true;
    work_queue_.push_back(work);
    entry.callback_queued = true;
    work_cv_.notify_one();
  }

  void schedule_orphan_release_locked(Entry& entry) {
    if (entry.phase != Phase::Orphan || !entry.drained ||
        entry.release_queued) {
      return;
    }
    WorkItem work;
    work.kind = WorkKind::ReleaseOnly;
    work.ticket = entry.ticket;
    work.lease = entry.lease;
    work.owner = entry.owner;
    work.erase_entry_after = true;
    work_queue_.push_back(work);
    entry.release_queued = true;
    work_cv_.notify_one();
  }

  void queue_hold_if_needed_locked(Entry& entry) {
    if (entry.lease == 0 || entry.hold_offline_queued) {
      return;
    }
    WorkItem work;
    work.kind = WorkKind::HoldOnly;
    work.ticket = entry.ticket;
    work.lease = entry.lease;
    work.owner = entry.owner;
    work_queue_.push_back(work);
    entry.hold_offline_queued = true;
    work_cv_.notify_one();
  }

  void erase_active_lease_if_matches_locked(LeaseId lease,
                                             Ticket ticket) noexcept {
    const auto it = active_leases_.find(lease);
    if (it != active_leases_.end() && it->second == ticket) {
      active_leases_.erase(it);
    }
  }

  void invoke_memory_action(const WorkItem& work,
                            MemoryActionKind kind) noexcept {
    if (hooks_.memory_action != nullptr) {
      const MemoryAction action{kind, work.ticket, work.lease, work.owner};
      hooks_.memory_action(hooks_.memory_user_data, action);
    }
  }

  void invoke_status(const WorkItem& work) noexcept {
    try {
      work.handler.function(mmd_handle_, work.handler.user_data, work.token,
                            work.status);
    } catch (...) {
      const auto error = std::current_exception();
      {
        std::lock_guard<std::mutex> lock(mutex_);
        ++callback_exceptions_;
      }
      if (hooks_.callback_exception != nullptr) {
        hooks_.callback_exception(hooks_.exception_user_data, error);
      }
    }
  }

  void worker_loop() noexcept {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      worker_thread_id_ = std::this_thread::get_id();
    }
    for (;;) {
      WorkItem work;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        work_cv_.wait(lock, [this] {
          return stop_requested_ || !work_queue_.empty();
        });
        if (work_queue_.empty()) {
          if (stop_requested_) {
            break;
          }
          continue;
        }

        work = work_queue_.front();
        work_queue_.pop_front();
        ++work_in_flight_;

        if (work.kind == WorkKind::Callback) {
          const auto it = entries_.find(work.ticket);
          if (it != entries_.end()) {
            // This is the token-reuse linearization point. The status callback
            // is about to run, and a reentrant begin() may reuse the token.
            active_tokens_.erase(it->second.token);
          }
        }
      }

      switch (work.kind) {
        case WorkKind::Callback:
          if (work.owner == BufferOwner::CallerOwned) {
            // Unpin/unmap caller memory before notification; the allocation is
            // still caller-owned and drain evidence already makes reuse safe.
            invoke_memory_action(work, MemoryActionKind::ReleaseSafe);
            {
              std::lock_guard<std::mutex> lock(mutex_);
              erase_active_lease_if_matches_locked(work.lease, work.ticket);
            }
          }
          invoke_status(work);
          if (work.owner == BufferOwner::DriverOwned) {
            // Keep driver-owned storage alive through the callback, then free or
            // return it after callback completion (also on callback exception).
            invoke_memory_action(work, MemoryActionKind::ReleaseSafe);
          }
          break;
        case WorkKind::ReleaseOnly:
          invoke_memory_action(work, MemoryActionKind::ReleaseSafe);
          break;
        case WorkKind::HoldOnly:
          invoke_memory_action(work, MemoryActionKind::HoldOffline);
          break;
      }

      {
        std::lock_guard<std::mutex> lock(mutex_);
        switch (work.kind) {
          case WorkKind::Callback:
            ++callback_invocations_;
            ++release_safe_actions_;
            erase_active_lease_if_matches_locked(work.lease, work.ticket);
            if (work.erase_entry_after) {
              entries_.erase(work.ticket);
            }
            break;
          case WorkKind::ReleaseOnly:
            ++release_safe_actions_;
            erase_active_lease_if_matches_locked(work.lease, work.ticket);
            if (work.erase_entry_after) {
              entries_.erase(work.ticket);
            }
            break;
          case WorkKind::HoldOnly:
            ++hold_offline_actions_;
            break;
        }
        --work_in_flight_;
        if (work_queue_.empty() && work_in_flight_ == 0) {
          idle_cv_.notify_all();
        }
      }
    }

    std::lock_guard<std::mutex> lock(mutex_);
    worker_thread_id_ = std::thread::id{};
    if (work_queue_.empty() && work_in_flight_ == 0) {
      idle_cv_.notify_all();
    }
  }

  const int mmd_handle_;
  const Hooks hooks_;

  mutable std::mutex mutex_;
  std::condition_variable work_cv_;
  std::condition_variable idle_cv_;
  std::thread worker_;
  std::thread::id worker_thread_id_{};
  bool stop_requested_{false};
  bool stopped_{false};

  DeviceMode mode_{DeviceMode::Running};
  Generation generation_{1};
  Sequence next_sequence_{1};
  HandlerSnapshot current_handler_{};

  std::unordered_map<Ticket, Entry, TicketHash> entries_;
  std::unordered_map<aocl_mmd_op_t, Ticket> active_tokens_;
  std::unordered_map<LeaseId, Ticket> active_leases_;
  std::deque<WorkItem> work_queue_;
  std::size_t work_in_flight_{0};

  std::uint64_t accepted_total_{0};
  std::uint64_t callback_invocations_{0};
  std::uint64_t callback_exceptions_{0};
  std::uint64_t release_safe_actions_{0};
  std::uint64_t hold_offline_actions_{0};
  std::uint64_t duplicate_events_{0};
  std::uint64_t stale_events_{0};
};

OperationLifecycle::OperationLifecycle(int mmd_handle, Hooks hooks)
    : impl_(std::make_unique<Impl>(mmd_handle, hooks)) {}

OperationLifecycle::~OperationLifecycle() noexcept {
  if (!impl_) {
    return;
  }
  if (impl_->shutdown() == TransitionCode::DebtRemaining) {
    impl_->fail_closed_destructor();
  }
}

void OperationLifecycle::set_status_handler(
    aocl_mmd_status_handler_fn handler, void* user_data) noexcept {
  impl_->set_status_handler(handler, user_data);
}

BeginResult OperationLifecycle::begin(aocl_mmd_op_t token,
                                      LeaseId lease,
                                      BufferOwner owner) {
  return impl_->begin(token, lease, owner);
}

TransitionCode OperationLifecycle::accept(Ticket ticket) {
  return impl_->accept(ticket);
}

TransitionCode OperationLifecycle::reject_not_accepted(Ticket ticket) {
  return impl_->reject_not_accepted(ticket);
}

TransitionCode OperationLifecycle::reject_indeterminate(Ticket ticket) {
  return impl_->reject_indeterminate(ticket);
}

TransitionCode OperationLifecycle::finish_blocking(Ticket ticket) {
  return impl_->finish_blocking(ticket);
}

TransitionCode OperationLifecycle::complete(Ticket ticket,
                                            int status,
                                            DrainEvidence drain) {
  return impl_->complete(ticket, status, drain);
}

TransitionCode OperationLifecycle::note_operation_drained(Ticket ticket) {
  return impl_->note_operation_drained(ticket);
}

TransitionCode OperationLifecycle::quiesce(int terminal_status) {
  return impl_->quiesce(terminal_status);
}

TransitionCode OperationLifecycle::mark_offline(int terminal_status) {
  return impl_->mark_offline(terminal_status);
}

TransitionCode OperationLifecycle::note_global_drained(
    Generation generation) {
  return impl_->note_global_drained(generation);
}

TransitionCode OperationLifecycle::start_new_generation() {
  return impl_->start_new_generation();
}

void OperationLifecycle::flush_ready() { impl_->flush_ready(); }

TransitionCode OperationLifecycle::shutdown() { return impl_->shutdown(); }

Snapshot OperationLifecycle::snapshot() const noexcept {
  return impl_->snapshot();
}

}  // namespace asus::a10::dma
