#include "generated_kernel_executor.hpp"

#include <atomic>
#include <exception>
#include <limits>
#include <thread>
#include <utility>

namespace asus::a10::kernel {

class RetirementOwner::Impl final {
 public:
  explicit Impl(std::shared_ptr<Transport> transport)
      : thread(std::this_thread::get_id()), transport(std::move(transport)) {
    if (!this->transport) throw std::invalid_argument("null kernel transport");
    verification = this->transport->verify(generated_abi());
    const auto& v = verification;
    if (v.outcome == IoOutcome::Completed && v.session != 0 &&
        v.first_ticket != 0 && v.aperture_bytes == generated_abi().aperture_bytes() &&
        v.image_matches_sources && v.cra_mapping_verified &&
        v.exclusive_continuous && v.no_prior_work &&
        v.at_most_one_completion && v.read_clear_safe) {
      mode = Mode::Running;
      next_ticket = v.first_ticket;
    }
  }

  class Guard {
   public:
    explicit Guard(Impl& impl) : impl(impl) {
      // thread is immutable. No mutable state is read before acquiring entry.
      if (impl.thread != std::this_thread::get_id() ||
          impl.entered.test_and_set(std::memory_order_acquire)) {
        throw StrandViolation();
      }
    }
    ~Guard() { impl.entered.clear(std::memory_order_release); }
    Guard(const Guard&) = delete;
    Guard& operator=(const Guard&) = delete;
   private:
    Impl& impl;
  };

  struct Record {
    Record(Ticket t, const Launch& launch, BufferLease lease)
        : ticket(t), launch(launch), lease(std::move(lease)) {}
    Ticket ticket;
    const Launch launch;
    BufferLease lease;
    StartState start{StartState::NotIssued};
    Phase phase{Phase::Admission};
    bool kernel_complete{false}, poisoned{false};
    std::uint64_t last_notice{0};
  };

  Result result(Code code) const noexcept {
    if (!record) return {code, last_ticket};
    return {code, record->ticket, record->start, record->phase,
            record->kernel_complete, record->poisoned};
  }
  Result fault(Code code) noexcept {
    mode = Mode::Offline;
    if (record) record->poisoned = true;
    return result(code);
  }
  Result release(Code code) noexcept {
    const auto answer = result(code);
    // The strand remains held while resource destructors run. Reentrant API
    // calls are rejected, and the record is removed exactly once.
    record.reset();
    return answer;
  }
  bool request(Phase phase, Request& out) noexcept {
    record->phase = phase;
    if (serial_exhausted) {
      fault(Code::SequenceExhausted);
      return false;
    }
    out = {record->ticket, next_serial, phase};
    if (next_serial == std::numeric_limits<std::uint64_t>::max())
      serial_exhausted = true;
    else
      ++next_serial;
    return true;
  }
  Code classify(Request expected, Request echoed, IoOutcome outcome) const noexcept {
    if (!(echoed == expected)) return Code::ProtocolError;
    if (outcome == IoOutcome::Completed) return Code::Pending;
    if (outcome == IoOutcome::NotIssued) return Code::IoNotIssued;
    return Code::IoUnknown;
  }
  bool check(Request expected, IoReply reply, Code& failure) noexcept {
    failure = classify(expected, reply.request, reply.outcome);
    if (failure == Code::Pending) return true;
    fault(failure);
    return false;
  }
  bool fence(Phase phase, Code& failure) noexcept {
    Request req;
    if (!request(phase, req)) {
      failure = Code::SequenceExhausted;
      return false;
    }
    return check(req, transport->order(req), failure);
  }
  bool read(Phase phase, std::uint32_t offset, std::uint64_t& value,
            Code& failure) noexcept {
    Request req;
    if (!request(phase, req)) {
      failure = Code::SequenceExhausted;
      return false;
    }
    const auto reply = transport->read64(req, offset);
    if (!check(req, reply, failure)) return false;
    value = reply.value;
    return true;
  }

  Result submit(const Launch& launch, BufferLease lease) {
    if (mode == Mode::Closed) return {Code::Closed};
    if (mode == Mode::Stopping) return {Code::Stopped};
    if (mode == Mode::Offline) return {Code::Offline};
    if (record) return {Code::Busy};
    if (!lease.keep_alive || lease.id == 0) return {Code::InvalidLease};
    if (ticket_exhausted || serial_exhausted) return fault(Code::SequenceExhausted);

    const Ticket ticket{verification.session, next_ticket};
    // ALL dynamic ownership/argument storage is allocated before the first
    // admission/CSR transaction. Nothing after here allocates executor state.
    auto prepared = std::make_unique<Record>(ticket, launch, std::move(lease));
    record = std::move(prepared);
    last_ticket = ticket;
    if (next_ticket == std::numeric_limits<std::uint64_t>::max())
      ticket_exhausted = true;
    else
      ++next_ticket;

    Request req;
    if (!request(Phase::Admission, req)) return result(Code::SequenceExhausted);
    const auto admission = transport->admit(req, record->launch, record->lease);
    auto failure = classify(req, admission.request, admission.outcome);
    if (failure != Code::Pending) {
      fault(failure);
      // admit() never issues CSR or initiates DMA. A definitely-not-issued
      // admission has acquired no device references. Unknown retains custody.
      return failure == Code::IoNotIssued ? release(failure) : result(failure);
    }
    if (!admission.image_current || !admission.cra_current ||
        !admission.exclusive || !admission.no_debt) {
      return fault(Code::ProtocolError);
    }
    if (!admission.buffers_ready) return fault(Code::AdmissionDenied);
    if (!admission.launch_permitted) return release(Code::AdmissionDenied);
    if (!fence(Phase::BeforeBaseline, failure)) return result(failure);

    // Check the ENTIRE aperture, including the other generated kernel. A
    // nonzero count is prior debt, never a completion for this new ticket.
    for (std::size_t k = 0; k != generated_abi().kernel_count(); ++k) {
      const auto& descriptor = generated_abi().kernel(k);
      std::uint64_t count = 0;
      if (!read(Phase::Baseline, descriptor.base + descriptor.finish_count_offset,
                count, failure)) return result(failure);
      if (count != 0) return fault(Code::ProtocolError);
    }
    const auto& kernel = record->launch.descriptor();
    for (const auto& write : record->launch.writes()) {
      if (!request(Phase::Argument, req)) return result(Code::SequenceExhausted);
      if (!check(req, transport->write64_masked(req, write.byte_offset,
              write.value, write.byte_enable), failure)) return result(failure);
    }
    if (!fence(Phase::BeforeStart, failure)) return result(failure);
    if (!request(Phase::Start, req)) return result(Code::SequenceExhausted);

    // Set uncertainty BEFORE calling out: once a start could escape, there is
    // no path to ordinary release without independent retirement evidence.
    record->start = StartState::Unknown;
    const auto start_reply = transport->write64(req, kernel.base + kernel.start_offset, 1);
    failure = classify(req, start_reply.request, start_reply.outcome);
    if (failure != Code::Pending) {
      fault(failure);
      if (failure == Code::IoNotIssued) {
        record->start = StartState::NotIssued;
        // The preceding fence completed; NotIssued also proves no delayed
        // RPC/store can issue the start later. Never retry this ticket.
        return release(failure);
      }
      return result(failure);
    }
    if (!fence(Phase::AfterStart, failure)) return result(failure);
    record->start = StartState::Accepted;
    return result(Code::Accepted);
  }

  Result retirement() noexcept {
    record->phase = Phase::Retirement;
    // Retirement is an irrevocable fact for this never-reused ticket/lease.
    // Its read-only query has a stable identity independent of exhausted CSR
    // or notification serials. A repeated false reply can only delay release.
    const Request req{record->ticket, 0, Phase::Retirement};
    const auto reply = transport->retirement(req, record->lease.id);
    const auto code = classify(req, reply.request, reply.outcome);
    if (code != Code::Pending) return fault(code);
    if (reply.lease != record->lease.id) return fault(Code::ProtocolError);
    if (reply.no_pending_start && reply.no_future_kernel_access &&
        reply.kernel_memory_drained && reply.host_dma_drained &&
        reply.descriptors_drained && reply.writebacks_drained) {
      // Even a poisoned/ambiguous launch can be safely released after actual
      // independent retirement. poisoned remains in the returned result.
      return release(Code::Retired);
    }
    return result(record->kernel_complete && !record->poisoned
                      ? Code::KernelComplete : Code::Pending);
  }

  Code classify_ticket(Ticket ticket) const noexcept {
    if (ticket.session != verification.session) return Code::Stale;
    if (ticket.sequence == 0 || ticket.sequence < verification.first_ticket ||
        ticket.sequence > last_ticket.sequence) return Code::UnknownTicket;
    if (!record) return Code::Duplicate;
    return ticket == record->ticket ? Code::Pending : Code::Stale;
  }
  Result recover(Ticket ticket) noexcept {
    const auto code = classify_ticket(ticket);
    if (code != Code::Pending) return {code, ticket};
    fault(Code::Offline); // never recover into apparent kernel success
    return retirement();
  }
  Result service(Notice notice) noexcept {
    const auto code = classify_ticket(notice.ticket);
    if (code != Code::Pending) return {code, notice.ticket};
    if (notice.sequence == 0) return result(Code::ProtocolError);
    if (notice.sequence == record->last_notice) return result(Code::Duplicate);
    if (notice.sequence < record->last_notice) return result(Code::Stale);
    record->last_notice = notice.sequence;

    // In recovery or after any loss of accounting, NEVER read-clear again.
    // Only an independent retirement report can discharge the owning record.
    if (record->poisoned) return retirement();
    if (!record->kernel_complete) {
      const auto& kernel = record->launch.descriptor();
      const auto offset = kernel.base + kernel.finish_count_offset;
      std::uint64_t count = 0;
      Code failure = Code::IoUnknown;
      if (!read(Phase::Completion, offset, count, failure)) return result(failure);
      if (count == 0) return result(Code::Pending);
      // Reject multi-completions AND high bits. Do not mask modulo the width.
      if (count != 1) return fault(Code::ProtocolError);
      if (!read(Phase::ConfirmClear, offset, count, failure)) return result(failure);
      if (count != 0) return fault(Code::ProtocolError);
      record->kernel_complete = true;
    }
    return retirement();
  }

  Snapshot snapshot() const noexcept {
    Snapshot s;
    s.mode = mode;
    s.next_ticket = next_ticket;
    s.ticket_space_exhausted = ticket_exhausted;
    s.executor_attached = attached;
    if (record) {
      s.active = record->ticket;
      s.last_notice = record->last_notice;
      s.start = record->start;
      s.holds_buffers = true;
      s.kernel_complete = record->kernel_complete;
      s.poisoned = record->poisoned;
    }
    return s;
  }

  const std::thread::id thread;
  mutable std::atomic_flag entered = ATOMIC_FLAG_INIT;
  const std::shared_ptr<Transport> transport;
  Verification verification{};
  Mode mode{Mode::Offline};
  bool attached{false}, ticket_exhausted{false}, serial_exhausted{false};
  std::uint64_t next_ticket{0}, next_serial{1};
  Ticket last_ticket{};
  std::unique_ptr<Record> record;
};

RetirementOwner::RetirementOwner(std::shared_ptr<Transport> transport)
    : impl_(std::make_unique<Impl>(std::move(transport))) {}

RetirementOwner::~RetirementOwner() noexcept {
  if (impl_->thread != std::this_thread::get_id() ||
      impl_->entered.test_and_set(std::memory_order_acquire) ||
      impl_->record || impl_->attached) std::terminate();
}

Result RetirementOwner::recover(Ticket ticket) {
  Impl::Guard guard(*impl_);
  if (impl_->attached) return impl_->result(Code::Busy);
  return impl_->recover(ticket);
}
Snapshot RetirementOwner::snapshot() const {
  Impl::Guard guard(*impl_);
  return impl_->snapshot();
}

SerializedExecutor::SerializedExecutor(std::shared_ptr<RetirementOwner> owner)
    : owner_(std::move(owner)) {
  if (!owner_) throw std::invalid_argument("null retirement owner");
  RetirementOwner::Impl::Guard guard(*owner_->impl_);
  if (owner_->impl_->attached || owner_->impl_->mode == Mode::Closed)
    throw std::invalid_argument("retirement owner already attached or closed");
  owner_->impl_->attached = true;
}
SerializedExecutor::~SerializedExecutor() noexcept {
  auto& state = *owner_->impl_;
  // Explicit enforcement of the documented destruction/strand contract.
  if (state.thread != std::this_thread::get_id() ||
      state.entered.test_and_set(std::memory_order_acquire)) std::terminate();
  state.attached = false;
  if (state.record) state.fault(Code::Offline);
  else state.mode = Mode::Closed;
  state.entered.clear(std::memory_order_release);
}
Result SerializedExecutor::submit(const Launch& launch, BufferLease lease) {
  RetirementOwner::Impl::Guard guard(*owner_->impl_);
  return owner_->impl_->submit(launch, std::move(lease));
}
Result SerializedExecutor::service(Notice notice) {
  RetirementOwner::Impl::Guard guard(*owner_->impl_);
  return owner_->impl_->service(notice);
}
Result SerializedExecutor::recover(Ticket ticket) {
  RetirementOwner::Impl::Guard guard(*owner_->impl_);
  return owner_->impl_->recover(ticket);
}
Code SerializedExecutor::stop() {
  RetirementOwner::Impl::Guard guard(*owner_->impl_);
  auto& state = *owner_->impl_;
  if (state.mode == Mode::Closed) return Code::Closed;
  if (state.mode == Mode::Offline) return Code::Offline;
  state.mode = Mode::Stopping;
  return Code::Stopped;
}
Code SerializedExecutor::mark_offline() {
  RetirementOwner::Impl::Guard guard(*owner_->impl_);
  auto& state = *owner_->impl_;
  if (state.mode == Mode::Closed) return Code::Closed;
  state.fault(Code::Offline);
  return Code::Offline;
}
Code SerializedExecutor::shutdown() {
  RetirementOwner::Impl::Guard guard(*owner_->impl_);
  auto& state = *owner_->impl_;
  if (state.mode == Mode::Closed) return Code::Closed;
  if (state.mode == Mode::Running) state.mode = Mode::Stopping;
  if (state.record) return Code::Busy;
  state.mode = Mode::Closed;
  return Code::Closed;
}
Snapshot SerializedExecutor::snapshot() const {
  RetirementOwner::Impl::Guard guard(*owner_->impl_);
  return owner_->impl_->snapshot();
}

}  // namespace asus::a10::kernel
