#include "dma_operation_lifecycle.hpp"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <exception>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

using asus::a10::dma::BeginCode;
using asus::a10::dma::BufferOwner;
using asus::a10::dma::DeviceMode;
using asus::a10::dma::DrainEvidence;
using asus::a10::dma::Hooks;
using asus::a10::dma::LeaseId;
using asus::a10::dma::MemoryAction;
using asus::a10::dma::MemoryActionKind;
using asus::a10::dma::OperationLifecycle;
using asus::a10::dma::Ticket;
using asus::a10::dma::TransitionCode;

namespace {

class TestFailure : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

#define CHECK(expr)                                                           \
  do {                                                                        \
    if (!(expr)) {                                                            \
      throw TestFailure(std::string("CHECK failed: ") + #expr + " at " +     \
                        __FILE__ + ":" + std::to_string(__LINE__));           \
    }                                                                         \
  } while (false)

struct Event {
  std::string kind;
  std::uintptr_t token{0};
  int status{0};
  LeaseId lease{0};
};

struct Recorder {
  mutable std::mutex mutex;
  std::vector<Event> events;
  std::atomic<unsigned> exceptions{0};

  void push(Event event) {
    std::lock_guard<std::mutex> lock(mutex);
    events.push_back(std::move(event));
  }

  std::vector<Event> copy() const {
    std::lock_guard<std::mutex> lock(mutex);
    return events;
  }
};

void memory_action(void* opaque, const MemoryAction& action) noexcept {
  auto& recorder = *static_cast<Recorder*>(opaque);
  recorder.push({action.kind == MemoryActionKind::ReleaseSafe ? "release"
                                                              : "hold",
                 0,
                 0,
                 action.lease});
}

void callback_exception(void* opaque, std::exception_ptr) noexcept {
  auto& recorder = *static_cast<Recorder*>(opaque);
  ++recorder.exceptions;
}

void record_status(int, void* opaque, aocl_mmd_op_t token, int status) {
  auto& recorder = *static_cast<Recorder*>(opaque);
  recorder.push({"callback", reinterpret_cast<std::uintptr_t>(token), status,
                 0});
}

void throwing_status(int, void*, aocl_mmd_op_t, int) {
  throw std::runtime_error("intentional callback exception");
}

Hooks hooks_for(Recorder& recorder) {
  return {memory_action, &recorder, callback_exception, &recorder};
}

void* token(std::uintptr_t value) {
  return reinterpret_cast<void*>(value);
}

void require_shutdown(OperationLifecycle& lifecycle) {
  lifecycle.flush_ready();
  CHECK(lifecycle.shutdown() == TransitionCode::Applied);
}

void test_out_of_order_completion() {
  Recorder recorder;
  OperationLifecycle lifecycle(7, hooks_for(recorder));
  lifecycle.set_status_handler(record_status, &recorder);

  const auto a = lifecycle.begin(token(0x100), 1, BufferOwner::CallerOwned);
  const auto b = lifecycle.begin(token(0x200), 2, BufferOwner::CallerOwned);
  CHECK(a.prepared() && b.prepared());
  CHECK(lifecycle.accept(a.ticket) == TransitionCode::Applied);
  CHECK(lifecycle.accept(b.ticket) == TransitionCode::Applied);

  CHECK(lifecycle.complete(b.ticket, 0, DrainEvidence::PerOperation) ==
        TransitionCode::Applied);
  CHECK(lifecycle.complete(a.ticket, 0, DrainEvidence::PerOperation) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();

  const auto events = recorder.copy();
  std::vector<std::uintptr_t> callbacks;
  for (const auto& event : events) {
    if (event.kind == "callback") {
      callbacks.push_back(event.token);
    }
  }
  CHECK((callbacks == std::vector<std::uintptr_t>{0x200, 0x100}));
  CHECK(lifecycle.snapshot().callback_invocations == 2);
  require_shutdown(lifecycle);
}

void test_duplicate_completion_race() {
  Recorder recorder;
  OperationLifecycle lifecycle(7, hooks_for(recorder));
  lifecycle.set_status_handler(record_status, &recorder);
  const auto submission =
      lifecycle.begin(token(0x300), 3, BufferOwner::CallerOwned);
  CHECK(submission.prepared());
  CHECK(lifecycle.accept(submission.ticket) == TransitionCode::Applied);

  std::atomic<unsigned> applied{0};
  std::atomic<unsigned> duplicate{0};
  auto racer = [&] {
    const auto result = lifecycle.complete(submission.ticket, 0,
                                           DrainEvidence::PerOperation);
    if (result == TransitionCode::Applied) {
      ++applied;
    } else if (result == TransitionCode::Duplicate) {
      ++duplicate;
    }
  };
  std::thread first(racer);
  std::thread second(racer);
  first.join();
  second.join();
  lifecycle.flush_ready();

  CHECK(applied == 1);
  CHECK(duplicate == 1);
  CHECK(lifecycle.snapshot().callback_invocations == 1);
  require_shutdown(lifecycle);
}

struct ReentrantContext {
  OperationLifecycle* lifecycle{nullptr};
  Recorder* recorder{nullptr};
  std::atomic<unsigned> calls{0};
};

void reentrant_status(int,
                      void* opaque,
                      aocl_mmd_op_t op,
                      int status) {
  auto& context = *static_cast<ReentrantContext*>(opaque);
  context.recorder->push(
      {"callback", reinterpret_cast<std::uintptr_t>(op), status, 0});
  if (context.calls.fetch_add(1) == 0) {
    const auto next = context.lifecycle->begin(op, 4, BufferOwner::CallerOwned);
    CHECK(next.prepared());
    CHECK(context.lifecycle->accept(next.ticket) == TransitionCode::Applied);
    CHECK(context.lifecycle->complete(next.ticket, 0,
                                      DrainEvidence::PerOperation) ==
          TransitionCode::Applied);
    // The second callback is queued behind this callback. A reentrant fence
    // must not wait for the current dispatcher frame and deadlock.
    context.lifecycle->flush_ready();
  }
}

void test_callback_reentrancy_and_token_reuse() {
  Recorder recorder;
  OperationLifecycle lifecycle(7, hooks_for(recorder));
  ReentrantContext context{&lifecycle, &recorder, 0};
  lifecycle.set_status_handler(reentrant_status, &context);

  const auto first =
      lifecycle.begin(token(0x400), 4, BufferOwner::CallerOwned);
  CHECK(first.prepared());
  CHECK(lifecycle.begin(token(0x400), 5, BufferOwner::CallerOwned).code ==
        BeginCode::DuplicateToken);
  CHECK(lifecycle.begin(token(0x401), 4, BufferOwner::CallerOwned).code ==
        BeginCode::DuplicateLease);
  CHECK(lifecycle.accept(first.ticket) == TransitionCode::Applied);
  CHECK(lifecycle.complete(first.ticket, 0, DrainEvidence::PerOperation) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();

  CHECK(context.calls == 2);
  CHECK(recorder.exceptions == 0);
  CHECK(lifecycle.snapshot().callback_invocations == 2);
  CHECK(lifecycle.complete(first.ticket, 0, DrainEvidence::PerOperation) ==
        TransitionCode::Duplicate);
  require_shutdown(lifecycle);
}

void test_quiesce_does_not_fake_drain() {
  Recorder recorder;
  OperationLifecycle lifecycle(7, hooks_for(recorder));
  lifecycle.set_status_handler(record_status, &recorder);
  const auto accepted =
      lifecycle.begin(token(0x500), 6, BufferOwner::CallerOwned);
  const auto submission_racing_quiesce =
      lifecycle.begin(token(0x501), 7, BufferOwner::CallerOwned);
  CHECK(accepted.prepared() && submission_racing_quiesce.prepared());
  CHECK(lifecycle.accept(accepted.ticket) == TransitionCode::Applied);
  CHECK(lifecycle.quiesce(-1001) == TransitionCode::Applied);

  // A launch that was already reserved may report acceptance after the gate.
  // The quiesce-assigned terminal state follows it into Accepted, but no
  // callback is eligible until real drain evidence arrives.
  CHECK(lifecycle.accept(submission_racing_quiesce.ticket) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();

  CHECK(recorder.copy().empty());
  CHECK(lifecycle.snapshot().accepted_debt == 2);
  CHECK(lifecycle.begin(token(0x502), 20, BufferOwner::CallerOwned).code ==
        BeginCode::RejectedQuiescing);

  // A later hardware completion cannot replace the earlier control terminal,
  // but its per-operation drain evidence makes notification safe.
  CHECK(lifecycle.complete(accepted.ticket, 0,
                           DrainEvidence::PerOperation) ==
        TransitionCode::Applied);
  CHECK(lifecycle.note_operation_drained(submission_racing_quiesce.ticket) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();
  const auto events = recorder.copy();
  CHECK(events.size() == 4);
  CHECK(events[0].kind == "release");
  CHECK(events[1].kind == "callback" && events[1].status == -1001);
  CHECK(events[2].kind == "release");
  CHECK(events[3].kind == "callback" && events[3].status == -1001);
  require_shutdown(lifecycle);
}

void test_device_loss_retains_until_global_drain() {
  Recorder recorder;
  OperationLifecycle lifecycle(7, hooks_for(recorder));
  lifecycle.set_status_handler(record_status, &recorder);
  const auto submission =
      lifecycle.begin(token(0x600), 8, BufferOwner::DriverOwned);
  CHECK(submission.prepared());
  CHECK(lifecycle.accept(submission.ticket) == TransitionCode::Applied);
  CHECK(lifecycle.mark_offline(-2001) == TransitionCode::Applied);
  lifecycle.flush_ready();

  auto events = recorder.copy();
  CHECK(events.size() == 1);
  CHECK(events[0].kind == "hold");
  CHECK(lifecycle.snapshot().accepted_debt == 1);
  CHECK(lifecycle.shutdown() == TransitionCode::DebtRemaining);

  CHECK(lifecycle.note_global_drained(submission.ticket.generation) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();
  events = recorder.copy();
  CHECK(events.size() == 3);
  CHECK(events[1].kind == "callback");
  CHECK(events[2].kind == "release");
  CHECK(events[1].status == -2001);
  require_shutdown(lifecycle);
}

void test_stale_generation_isolation() {
  Recorder recorder;
  OperationLifecycle lifecycle(7, hooks_for(recorder));
  lifecycle.set_status_handler(record_status, &recorder);
  const auto old = lifecycle.begin(token(0x700), 9, BufferOwner::CallerOwned);
  CHECK(old.prepared());
  CHECK(lifecycle.accept(old.ticket) == TransitionCode::Applied);
  CHECK(lifecycle.complete(old.ticket, 0, DrainEvidence::PerOperation) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();

  CHECK(lifecycle.quiesce(-3001) == TransitionCode::Applied);
  CHECK(lifecycle.start_new_generation() == TransitionCode::Applied);
  const auto current =
      lifecycle.begin(token(0x700), 10, BufferOwner::CallerOwned);
  CHECK(current.prepared());
  CHECK(current.ticket.generation == old.ticket.generation + 1);
  CHECK(lifecycle.accept(current.ticket) == TransitionCode::Applied);
  CHECK(lifecycle.complete(old.ticket, 0, DrainEvidence::PerOperation) ==
        TransitionCode::StaleGeneration);
  CHECK(lifecycle.complete(current.ticket, 0, DrainEvidence::PerOperation) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();
  CHECK(lifecycle.snapshot().callback_invocations == 2);
  require_shutdown(lifecycle);
}

void test_submission_failure_and_indeterminate_submission() {
  Recorder recorder;
  OperationLifecycle lifecycle(7, hooks_for(recorder));
  lifecycle.set_status_handler(record_status, &recorder);

  const auto rejected =
      lifecycle.begin(token(0x800), 11, BufferOwner::CallerOwned);
  CHECK(rejected.prepared());
  CHECK(lifecycle.reject_not_accepted(rejected.ticket) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();
  CHECK(lifecycle.snapshot().accepted_total == 0);
  CHECK(lifecycle.snapshot().accepted_debt == 0);
  CHECK(recorder.copy().size() == 1);
  CHECK(recorder.copy()[0].kind == "release");

  const auto uncertain =
      lifecycle.begin(token(0x801), 12, BufferOwner::CallerOwned);
  CHECK(uncertain.prepared());
  CHECK(lifecycle.reject_indeterminate(uncertain.ticket) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();
  CHECK(lifecycle.snapshot().accepted_total == 0);
  CHECK(lifecycle.snapshot().accepted_debt == 0);
  CHECK(lifecycle.snapshot().orphan_holds == 1);
  CHECK(recorder.copy().back().kind == "hold");

  CHECK(lifecycle.note_global_drained(uncertain.ticket.generation) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();
  CHECK(recorder.copy().back().kind == "release");
  CHECK(lifecycle.snapshot().orphan_holds == 0);

  CHECK(lifecycle.start_new_generation() == TransitionCode::Applied);
  const auto already_drained =
      lifecycle.begin(token(0x802), 21, BufferOwner::CallerOwned);
  CHECK(already_drained.prepared());
  CHECK(lifecycle.complete(already_drained.ticket, -77,
                           DrainEvidence::PerOperation) ==
        TransitionCode::QueuedEarly);
  CHECK(lifecycle.reject_indeterminate(already_drained.ticket) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();
  CHECK(recorder.copy().back().kind == "release");
  CHECK(lifecycle.snapshot().orphan_holds == 0);
  CHECK(lifecycle.snapshot().hold_offline_actions == 1);
  require_shutdown(lifecycle);
}

void test_early_completion_and_contradictory_rejection() {
  Recorder recorder;
  OperationLifecycle lifecycle(7, hooks_for(recorder));
  lifecycle.set_status_handler(record_status, &recorder);

  const auto early = lifecycle.begin(token(0x900), 13,
                                     BufferOwner::CallerOwned);
  CHECK(early.prepared());
  CHECK(lifecycle.complete(early.ticket, 0, DrainEvidence::PerOperation) ==
        TransitionCode::QueuedEarly);
  CHECK(lifecycle.accept(early.ticket) == TransitionCode::Applied);
  lifecycle.flush_ready();
  CHECK(lifecycle.snapshot().callback_invocations == 1);

  const auto contradiction = lifecycle.begin(token(0x901), 14,
                                             BufferOwner::CallerOwned);
  CHECK(contradiction.prepared());
  CHECK(lifecycle.complete(contradiction.ticket, -9, DrainEvidence::None) ==
        TransitionCode::QueuedEarly);
  CHECK(lifecycle.reject_not_accepted(contradiction.ticket) ==
        TransitionCode::ProtocolViolation);
  lifecycle.flush_ready();
  CHECK(lifecycle.snapshot().mode == DeviceMode::Offline);
  CHECK(lifecycle.snapshot().accepted_total == 1);
  CHECK(lifecycle.snapshot().orphan_holds == 1);
  CHECK(lifecycle.note_global_drained(contradiction.ticket.generation) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();
  require_shutdown(lifecycle);
}

void test_callback_exception_and_owner_ordering() {
  Recorder recorder;
  OperationLifecycle lifecycle(7, hooks_for(recorder));
  lifecycle.set_status_handler(throwing_status, nullptr);
  const auto throwing = lifecycle.begin(token(0xa00), 15,
                                        BufferOwner::DriverOwned);
  CHECK(throwing.prepared());
  CHECK(lifecycle.accept(throwing.ticket) == TransitionCode::Applied);
  CHECK(lifecycle.complete(throwing.ticket, 0, DrainEvidence::PerOperation) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();
  CHECK(recorder.exceptions == 1);
  CHECK(lifecycle.snapshot().callback_exceptions == 1);
  CHECK(recorder.copy().size() == 1);
  CHECK(recorder.copy()[0].kind == "release");
  require_shutdown(lifecycle);

  Recorder ordered;
  OperationLifecycle second(8, hooks_for(ordered));
  second.set_status_handler(record_status, &ordered);
  const auto caller =
      second.begin(token(0xa01), 16, BufferOwner::CallerOwned);
  const auto driver =
      second.begin(token(0xa02), 17, BufferOwner::DriverOwned);
  CHECK(caller.prepared() && driver.prepared());
  CHECK(second.accept(caller.ticket) == TransitionCode::Applied);
  CHECK(second.accept(driver.ticket) == TransitionCode::Applied);
  CHECK(second.complete(caller.ticket, 0, DrainEvidence::PerOperation) ==
        TransitionCode::Applied);
  CHECK(second.complete(driver.ticket, 0, DrainEvidence::PerOperation) ==
        TransitionCode::Applied);
  second.flush_ready();
  const auto events = ordered.copy();
  CHECK(events.size() == 4);
  CHECK(events[0].kind == "release" && events[0].lease == 16);
  CHECK(events[1].kind == "callback" && events[1].token == 0xa01);
  CHECK(events[2].kind == "callback" && events[2].token == 0xa02);
  CHECK(events[3].kind == "release" && events[3].lease == 17);
  require_shutdown(second);
}


void test_destructor_fail_closed_without_drain() {
  Recorder recorder;
  {
    OperationLifecycle lifecycle(7, hooks_for(recorder));
    lifecycle.set_status_handler(record_status, &recorder);
    const auto submission =
        lifecycle.begin(token(0xb00), 18, BufferOwner::CallerOwned);
    CHECK(submission.prepared());
    CHECK(lifecycle.accept(submission.ticket) == TransitionCode::Applied);
    // No terminal event and no drain evidence. Destruction must retain the
    // lease and emit HoldOffline, never callback or ReleaseSafe.
  }

  const auto events = recorder.copy();
  CHECK(events.size() == 1);
  CHECK(events[0].kind == "hold");
  CHECK(events[0].lease == 18);
}

void test_blocking_mode() {
  Recorder recorder;
  OperationLifecycle lifecycle(7, hooks_for(recorder));

  // Blocking mode does not require a status handler, but it is still admitted
  // through the device gate and remains teardown debt until the synchronous
  // backend call returns and finish_blocking() is reported.
  const auto blocking =
      lifecycle.begin(nullptr, 19, BufferOwner::CallerOwned);
  CHECK(blocking.blocking());
  CHECK(blocking.ticket.sequence != 0);
  auto state = lifecycle.snapshot();
  CHECK(state.blocking_in_flight == 1);
  CHECK(state.accepted_debt == 0);
  CHECK(state.active_leases == 1);
  CHECK(lifecycle.quiesce(-5001) == TransitionCode::Applied);
  CHECK(lifecycle.begin(nullptr, 20, BufferOwner::CallerOwned).code ==
        BeginCode::RejectedQuiescing);
  CHECK(lifecycle.shutdown() == TransitionCode::DebtRemaining);

  CHECK(lifecycle.finish_blocking(blocking.ticket) == TransitionCode::Applied);
  lifecycle.flush_ready();
  const auto events = recorder.copy();
  CHECK(events.size() == 1);
  CHECK(events[0].kind == "release" && events[0].lease == 19);
  state = lifecycle.snapshot();
  CHECK(state.blocking_in_flight == 0);
  CHECK(state.active_leases == 0);
  CHECK(state.callback_invocations == 0);

  CHECK(lifecycle.start_new_generation() == TransitionCode::Applied);

  // Fatal loss during a blocking call emits HoldOffline, but still cannot
  // release the mapping until the synchronous backend actually returns.
  const auto lost_blocking =
      lifecycle.begin(nullptr, 22, BufferOwner::DriverOwned);
  CHECK(lost_blocking.blocking());
  CHECK(lifecycle.mark_offline(-5002) == TransitionCode::Applied);
  lifecycle.flush_ready();
  CHECK(recorder.copy().back().kind == "hold");
  CHECK(recorder.copy().back().lease == 22);
  CHECK(lifecycle.finish_blocking(lost_blocking.ticket) ==
        TransitionCode::Applied);
  lifecycle.flush_ready();
  CHECK(recorder.copy().back().kind == "release");
  CHECK(recorder.copy().back().lease == 22);
  CHECK(lifecycle.snapshot().callback_invocations == 0);
  CHECK(lifecycle.start_new_generation() == TransitionCode::Applied);

  const auto lease_free =
      lifecycle.begin(nullptr, 0, BufferOwner::CallerOwned);
  CHECK(lease_free.blocking());
  CHECK(lifecycle.finish_blocking(lease_free.ticket) == TransitionCode::Applied);
  CHECK(lifecycle.finish_blocking(lease_free.ticket) ==
        TransitionCode::Duplicate);
  lifecycle.flush_ready();
  CHECK(recorder.copy().size() == 3);
  require_shutdown(lifecycle);
}

using Test = void (*)();

}  // namespace

int main() {
  const std::vector<std::pair<const char*, Test>> tests = {
      {"out_of_order_completion", test_out_of_order_completion},
      {"duplicate_completion_race", test_duplicate_completion_race},
      {"callback_reentrancy_and_token_reuse",
       test_callback_reentrancy_and_token_reuse},
      {"quiesce_does_not_fake_drain", test_quiesce_does_not_fake_drain},
      {"device_loss_retains_until_global_drain",
       test_device_loss_retains_until_global_drain},
      {"stale_generation_isolation", test_stale_generation_isolation},
      {"submission_failure_and_indeterminate_submission",
       test_submission_failure_and_indeterminate_submission},
      {"early_completion_and_contradictory_rejection",
       test_early_completion_and_contradictory_rejection},
      {"callback_exception_and_owner_ordering",
       test_callback_exception_and_owner_ordering},
      {"destructor_fail_closed_without_drain",
       test_destructor_fail_closed_without_drain},
      {"blocking_mode", test_blocking_mode},
  };

  unsigned failures = 0;
  for (const auto& test : tests) {
    try {
      test.second();
      std::cout << "PASS " << test.first << '\n';
    } catch (const std::exception& error) {
      ++failures;
      std::cerr << "FAIL " << test.first << ": " << error.what() << '\n';
    }
  }
  if (failures != 0) {
    std::cerr << failures << " test(s) failed\n";
    return 1;
  }
  std::cout << "All DMA lifecycle tests passed\n";
  return 0;
}
