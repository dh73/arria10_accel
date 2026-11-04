#include "generated_kernel_executor.hpp"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <exception>
#include <functional>
#include <iostream>
#include <limits>
#include <map>
#include <thread>
#include <utility>
#include <vector>
#if defined(__unix__)
#include <sys/wait.h>
#include <unistd.h>
#endif

using namespace asus::a10::kernel;
namespace {
[[noreturn]] void fail(const char* expression, int line) {
  std::cerr << "FAIL line " << line << ": " << expression << '\n';
  std::abort();
}
#define CHECK(x) do { if (!(x)) fail(#x, __LINE__); } while (false)
constexpr std::size_t phases = static_cast<std::size_t>(Phase::Retirement) + 1;
std::size_t index(Phase phase) { return static_cast<std::size_t>(phase); }

Launch launch(std::size_t kernel = 0, std::uint64_t bias = 0) {
  const auto& descriptor = generated_abi().kernel(kernel);
  Launch::NamedArguments arguments;
  for (std::size_t i = 0; i < descriptor.arguments.size(); ++i)
    arguments.emplace_back(descriptor.arguments[i].name, bias + 100 + i);
  auto result = Launch::make(descriptor.name, arguments);
  CHECK(result.has_value());
  return *result;
}
struct Allocation {
  explicit Allocation(int& count) : destroyed(count) {}
  ~Allocation() { ++destroyed; }
  int& destroyed;
};
BufferLease lease(int& destroyed, std::uint64_t id = 7) {
  return {id, std::make_shared<Allocation>(destroyed)};
}

// This fake explicitly models ordered posted writes, destructive reads, and
// independently controlled retirement. It has no MMIO/driver/device authority.
class Fake final : public Transport {
 public:
  Verification verification{IoOutcome::Completed, 91, 1, 512,
                            true, true, true, true, true, true};
  std::array<unsigned, phases> calls{};
  std::array<std::uint64_t, 2> counts{};
  unsigned starts{0}, drains{0}, admitted{0}, verify_calls{0};
  std::uint64_t last_request{0}, confirm_extra{0};
  unsigned drain_mask{0}, admission_mask{63};
  bool bad_lease{false}, unknown_executes{true};
  bool fault_enabled{false}, wrong_reply{false};
  Phase fault_phase{Phase::Admission};
  unsigned fault_occurrence{0};
  IoOutcome fault_outcome{IoOutcome::NotIssued};
  std::function<void(Request)> hook;
  const KernelDescriptor* descriptor{nullptr};
  std::vector<std::uint64_t> expected;
  std::map<std::uint32_t, std::uint64_t> posted, visible;
  bool start_in_ticket{false};

  void inject(Phase phase, unsigned occurrence, IoOutcome outcome,
              bool wrong = false) {
    fault_enabled = true; fault_phase = phase;
    fault_occurrence = calls[index(phase)] + occurrence;
    fault_outcome = outcome; wrong_reply = wrong;
  }
  void clear_fault() { fault_enabled = false; wrong_reply = false; }
  unsigned total_calls() const {
    unsigned total = 0;
    for (auto value : calls) total += value;
    return total;
  }
  unsigned reads() const {
    return calls[index(Phase::Baseline)] + calls[index(Phase::Completion)] +
           calls[index(Phase::ConfirmClear)];
  }
  IoReply attempt(Request request, std::uint64_t value = 0) noexcept {
    if (request.phase == Phase::Retirement) CHECK(request.serial == 0);
    else {
      CHECK(request.serial > last_request);
      last_request = request.serial;
    }
    const unsigned occurrence = calls[index(request.phase)]++;
    if (hook) hook(request);
    IoReply result{request, IoOutcome::Completed, value};
    if (fault_enabled && request.phase == fault_phase &&
        occurrence == fault_occurrence) {
      result.outcome = fault_outcome;
      if (wrong_reply) {
        // Stale RPC reply; retirement uses stable serial zero, so corrupt its
        // ticket rather than unsigned-wrapping that reserved serial.
        if (request.phase == Phase::Retirement) --result.request.ticket.sequence;
        else --result.request.serial;
      }
    }
    return result;
  }
  Verification verify(const SourceAbi& abi) noexcept override {
    ++verify_calls;
    CHECK(abi.aperture_bytes() == 512);
    CHECK(abi.kernel_count() == 2 && abi.source_hash_count() == 6);
    // SuppliedSnapshot is deliberately allowed by THIS FAKE ONLY.
    return verification;
  }
  AdmissionReply admit(Request request, const Launch& packet,
                       const BufferLease& buffers) noexcept override {
    CHECK(buffers.id != 0 && buffers.keep_alive);
    descriptor = &packet.descriptor(); expected = packet.arguments();
    posted.clear(); visible.clear(); start_in_ticket = false; ++admitted;
    const auto reply = attempt(request);
    return {reply.request, reply.outcome,
            bool(admission_mask & 1), bool(admission_mask & 2),
            bool(admission_mask & 4), bool(admission_mask & 8),
            bool(admission_mask & 16), bool(admission_mask & 32)};
  }
  IoReply write64(Request request, std::uint32_t offset,
                  std::uint64_t value) noexcept override {
    CHECK(descriptor != nullptr);
    const auto reply = attempt(request);
    if (reply.outcome == IoOutcome::NotIssued ||
        (reply.outcome == IoOutcome::Unknown && !unknown_executes)) return reply;
    if (request.phase == Phase::Argument) {
      const auto& args = descriptor->arguments;
      auto found = std::find_if(args.begin(), args.end(), [&](const auto& arg) {
        return offset == descriptor->base + arg.byte_offset;
      });
      CHECK(found != args.end());
      const auto position = static_cast<std::size_t>(found - args.begin());
      CHECK(value == expected[position] && posted.count(offset) == 0);
      posted.emplace(offset, value);
    } else {
      CHECK(request.phase == Phase::Start);
      CHECK(offset == descriptor->base + descriptor->start_offset && value == 1);
      CHECK(!start_in_ticket && posted.empty());
      CHECK(visible.size() == descriptor->arguments.size());
      for (std::size_t i = 0; i < descriptor->arguments.size(); ++i)
        CHECK(visible.at(descriptor->base + descriptor->arguments[i].byte_offset)
              == expected[i]);
      start_in_ticket = true; ++starts;
    }
    return reply;
  }
  IoReply order(Request request) noexcept override {
    auto reply = attempt(request);
    if (request.phase == Phase::BeforeStart &&
        reply.outcome != IoOutcome::NotIssued) {
      CHECK(posted.size() == descriptor->arguments.size());
      visible = std::move(posted); posted.clear();
    }
    if (request.phase == Phase::AfterStart) CHECK(start_in_ticket);
    return reply;
  }
  IoReply read64(Request request, std::uint32_t offset) noexcept override {
    std::size_t kernel = 0;
    for (; kernel < generated_abi().kernel_count(); ++kernel) {
      const auto& k = generated_abi().kernel(kernel);
      if (offset == k.base + k.finish_count_offset) break;
    }
    CHECK(kernel < counts.size());
    CHECK(request.phase == Phase::Baseline || request.phase == Phase::Completion ||
          request.phase == Phase::ConfirmClear);
    const auto value = request.phase == Phase::ConfirmClear ? confirm_extra : counts[kernel];
    auto reply = attempt(request, value);
    // Unknown deliberately executes and loses the acknowledgement.
    if (reply.outcome == IoOutcome::Completed ||
        (reply.outcome == IoOutcome::Unknown && unknown_executes)) counts[kernel] = 0;
    return reply;
  }
  RetirementReply retirement(Request request, std::uint64_t id) noexcept override {
    ++drains;
    const auto reply = attempt(request);
    return {reply.request, reply.outcome, bad_lease ? id + 1 : id,
            bool(drain_mask & 1), bool(drain_mask & 2), bool(drain_mask & 4),
            bool(drain_mask & 8), bool(drain_mask & 16), bool(drain_mask & 32)};
  }
};

struct Fixture {
  int releases{0};
  std::shared_ptr<Fake> transport{std::make_shared<Fake>()};
  std::shared_ptr<RetirementOwner> owner;
  std::unique_ptr<SerializedExecutor> executor;
  explicit Fixture(std::function<void(Fake&)> configure = {}) {
    if (configure) configure(*transport);
    owner = std::make_shared<RetirementOwner>(transport);
    executor = std::make_unique<SerializedExecutor>(owner);
  }
  ~Fixture() {
    // Test cleanup is an explicit independent fake retirement event, never a
    // reset or manufactured count. Assertions check retention BEFORE cleanup.
    transport->hook = {}; transport->clear_fault(); transport->bad_lease = false;
    transport->drain_mask = 63;
    executor.reset();
    const auto snapshot = owner->snapshot();
    if (snapshot.holds_buffers) {
      const auto result = owner->recover(snapshot.active);
      CHECK(result.code == Code::Retired);
    }
  }
  Result submit(std::size_t kernel = 0) {
    return executor->submit(launch(kernel), lease(releases));
  }
  Result notice(Ticket ticket, std::uint64_t sequence) {
    return executor->service({ticket, sequence});
  }
};

void test_abi() {
  auto original = launch();
  const auto& d = original.descriptor();
  Launch::NamedArguments args;
  for (std::size_t i = 0; i < d.arguments.size(); ++i)
    args.emplace_back(d.arguments[i].name, i);
  std::reverse(args.begin(), args.end());
  auto copied = Launch::make(d.name, args);
  CHECK(copied);
  for (std::size_t i = 0; i < d.arguments.size(); ++i) CHECK(copied->arguments()[i] == i);
  CHECK(copied->writes().size() == d.arguments.size());
  for (std::size_t i = 0; i < d.arguments.size(); ++i) {
    CHECK(copied->writes()[i].byte_offset == d.base + d.arguments[i].byte_offset);
    CHECK(copied->writes()[i].value == i && copied->writes()[i].byte_enable == 255);
  }
  for (auto& arg : args) arg.second = UINT64_MAX;
  auto full_width = Launch::make(d.name, args);
  CHECK(full_width);
  for (const auto& word : full_width->writes()) CHECK(word.value == UINT64_MAX);
  args[0].second = 999;
  CHECK(copied->arguments().back() == d.arguments.size() - 1);
  CHECK(!Launch::make("unknown", args));
  auto invalid = args; invalid.pop_back(); CHECK(!Launch::make(d.name, invalid));
  invalid = args; invalid.push_back(args.front()); CHECK(!Launch::make(d.name, invalid));
  invalid = args; invalid[0].first = invalid[1].first; CHECK(!Launch::make(d.name, invalid));
  invalid = args; invalid[0].first = "unknown"; CHECK(!Launch::make(d.name, invalid));
}

void test_normal_and_notifications() {
  Fixture f;
  auto result = f.submit(); CHECK(result.code == Code::Accepted);
  CHECK(result.start == StartState::Accepted && f.transport->starts == 1);
  CHECK(f.executor->snapshot().holds_buffers && f.releases == 0);
  CHECK(f.owner->recover(result.ticket).code == Code::Busy);
  CHECK(f.notice(result.ticket, 1).code == Code::Pending); // early IRQ, count=0
  auto calls = f.transport->total_calls();
  CHECK(f.notice(result.ticket, 1).code == Code::Duplicate);
  f.notice(result.ticket, 0);
  f.notice({result.ticket.session - 1, result.ticket.sequence}, 2);
  f.notice({result.ticket.session, result.ticket.sequence + 1}, 2);
  CHECK(f.transport->total_calls() == calls);
  f.transport->counts[0] = 1;
  auto complete = f.notice(result.ticket, 2);
  CHECK(complete.kernel_complete && f.releases == 0);
  const auto reads = f.transport->reads();
  for (unsigned bit = 0; bit < 6; ++bit) {
    f.transport->drain_mask = 63U & ~(1U << bit);
    f.notice(result.ticket, 3 + bit);
    CHECK(f.releases == 0 && f.transport->reads() == reads);
  }
  f.transport->drain_mask = 63;
  CHECK(f.notice(result.ticket, 9).code == Code::Retired);
  CHECK(f.releases == 1 && !f.executor->snapshot().holds_buffers);
  calls = f.transport->total_calls(); f.notice(result.ticket, 10);
  CHECK(f.transport->total_calls() == calls && f.releases == 1);
  // Same lease ID may be reused only after the previous owning object retires.
  for (unsigned round = 0; round < 8; ++round) {
    const auto old = result.ticket;
    const auto kernel = (round + 1) % 2;
    result = f.submit(kernel);
    CHECK(result.code == Code::Accepted && result.ticket.sequence == old.sequence + 1);
    calls = f.transport->total_calls(); f.notice(old, 11);
    CHECK(f.transport->total_calls() == calls);
    f.transport->counts[kernel] = 1;
    CHECK(f.notice(result.ticket, 1).code == Code::Retired);
    CHECK(f.releases == static_cast<int>(round + 2));
  }
  CHECK(f.transport->starts == 9 && f.transport->calls[index(Phase::Argument)] == 117);
}

void test_submission_faults() {
  std::vector<std::pair<Phase, unsigned>> points{
      {Phase::Admission, 0}, {Phase::BeforeBaseline, 0}, {Phase::Baseline, 0},
      {Phase::Baseline, 1}, {Phase::BeforeStart, 0}, {Phase::Start, 0},
      {Phase::AfterStart, 0}};
  for (unsigned arg = 0; arg < 13; ++arg) points.emplace_back(Phase::Argument, arg);
  for (auto outcome : {IoOutcome::NotIssued, IoOutcome::Unknown}) {
    for (auto point : points) {
      Fixture f; f.transport->inject(point.first, point.second, outcome);
      const auto result = f.submit();
      CHECK(result.code != Code::Accepted);
      const bool may_start = point.first == Phase::AfterStart ||
          (point.first == Phase::Start && outcome == IoOutcome::Unknown);
      CHECK(f.transport->starts == (may_start ? 1U : 0U));
      if (may_start) {
        CHECK(result.start == StartState::Unknown);
        CHECK(f.releases == 0 && f.executor->snapshot().holds_buffers);
      }
      const bool definitely_released = outcome == IoOutcome::NotIssued &&
          (point.first == Phase::Admission || point.first == Phase::Start);
      if (definitely_released) CHECK(f.releases == 1);
      else CHECK(f.releases == 0);
      // No automatic resubmission or read retry even after a new cue.
      const auto before = f.transport->reads();
      const auto snapshot = f.executor->snapshot();
      f.transport->clear_fault();
      if (snapshot.holds_buffers) f.notice(result.ticket, 1);
      CHECK(f.transport->reads() == before);
      CHECK(f.transport->starts == (may_start ? 1U : 0U));
    }
  }
}

void test_completion_faults() {
  for (auto phase : {Phase::Completion, Phase::ConfirmClear, Phase::Retirement}) {
    for (auto outcome : {IoOutcome::NotIssued, IoOutcome::Unknown}) {
      Fixture f; const auto submitted = f.submit(); f.transport->counts[0] = 1;
      f.transport->inject(phase, 0, outcome);
      f.notice(submitted.ticket, 1);
      CHECK(f.releases == 0 && f.executor->snapshot().holds_buffers);
      CHECK(f.executor->snapshot().poisoned);
      const auto reads = f.transport->reads(); f.transport->clear_fault();
      f.notice(submitted.ticket, 2);
      CHECK(f.transport->reads() == reads && f.releases == 0);
      f.transport->drain_mask = 63;
      auto retired = f.notice(submitted.ticket, 3);
      CHECK(retired.code == Code::Retired && retired.poisoned && f.releases == 1);
    }
  }
  for (auto phase : {Phase::Baseline, Phase::Argument, Phase::BeforeStart,
                     Phase::Start, Phase::AfterStart, Phase::Completion,
                     Phase::ConfirmClear, Phase::Retirement}) {
    Fixture f;
    const bool service_phase = phase == Phase::Completion || phase == Phase::ConfirmClear ||
                               phase == Phase::Retirement;
    if (!service_phase) f.transport->inject(phase, 0, IoOutcome::Completed, true);
    auto submitted = f.submit();
    if (service_phase) {
      f.transport->counts[0] = 1;
      f.transport->inject(phase, 0, IoOutcome::Completed, true);
      f.notice(submitted.ticket, 1);
    }
    CHECK(f.executor->snapshot().poisoned && f.releases == 0);
    const auto reads = f.transport->reads(); f.transport->clear_fault();
    f.notice(submitted.ticket, 2);
    CHECK(f.transport->reads() == reads);
  }
}

void test_unknown_without_execution() {
  { Fixture f; f.transport->unknown_executes = false;
    f.transport->inject(Phase::Start, 0, IoOutcome::Unknown);
    auto result = f.submit();
    CHECK(result.start == StartState::Unknown && f.transport->starts == 0);
    CHECK(f.releases == 0 && f.executor->snapshot().holds_buffers); }
  { Fixture f; auto result = f.submit(); f.transport->unknown_executes = false;
    f.transport->counts[0] = 1;
    f.transport->inject(Phase::Completion, 0, IoOutcome::Unknown);
    f.notice(result.ticket, 1);
    CHECK(f.transport->counts[0] == 1 && f.releases == 0);
    f.transport->clear_fault(); const auto reads = f.transport->reads();
    f.notice(result.ticket, 2);
    CHECK(f.transport->counts[0] == 1 && f.transport->reads() == reads); }
}

void test_counts_and_debt() {
  for (std::uint64_t count : {1ULL, 2ULL, 3ULL, 4ULL, ~0ULL}) {
    for (std::size_t kernel = 0; kernel < 2; ++kernel) {
      Fixture f; f.transport->counts[kernel] = count;
      const auto result = f.submit();
      CHECK(result.code != Code::Accepted && f.transport->starts == 0);
      CHECK(f.executor->snapshot().poisoned && f.releases == 0);
    }
  }
  for (std::uint64_t count : {2ULL, 3ULL, 4ULL, ~0ULL}) {
    Fixture f; const auto result = f.submit(); f.transport->counts[0] = count;
    auto bad = f.notice(result.ticket, 1);
    CHECK(bad.poisoned && !bad.kernel_complete && f.releases == 0);
  }
  { Fixture f; const auto result = f.submit(); f.transport->counts[0] = 1;
    f.transport->confirm_extra = 1;
    auto bad = f.notice(result.ticket, 1);
    CHECK(bad.poisoned && !bad.kernel_complete && f.releases == 0); }
  { Fixture f; const auto result = f.submit(); f.transport->drain_mask = 63;
    CHECK(f.notice(result.ticket, 1).code == Code::Pending);
    CHECK(f.releases == 0); // even a drain cue does not fabricate a completion
    f.transport->counts[0] = 1;
    CHECK(f.notice(result.ticket, 2).code == Code::Retired); }
}

void test_verification_and_admission() {
  for (unsigned field = 0; field < 11; ++field) {
    Fixture f([=](Fake& fake) {
      auto& v = fake.verification;
      switch (field) {
        case 0: v.image_matches_sources = false; break;
        case 1: v.cra_mapping_verified = false; break;
        case 2: v.exclusive_continuous = false; break;
        case 3: v.no_prior_work = false; break;
        case 4: v.at_most_one_completion = false; break;
        case 5: v.read_clear_safe = false; break;
        case 6: v.aperture_bytes = 4096; break;
        case 7: v.session = 0; break;
        case 8: v.first_ticket = 0; break;
        case 9: v.outcome = IoOutcome::NotIssued; break;
        default: v.outcome = IoOutcome::Unknown; break;
      }
    });
    CHECK(f.executor->snapshot().mode == Mode::Offline);
    CHECK(f.submit().code != Code::Accepted && f.transport->total_calls() == 0);
    CHECK(f.releases == 1);
  }
  for (unsigned bit = 0; bit < 6; ++bit) {
    Fixture f; f.transport->admission_mask = 63U & ~(1U << bit);
    CHECK(f.submit().code != Code::Accepted && f.transport->starts == 0);
    CHECK(f.transport->reads() == 0 && f.transport->calls[index(Phase::Argument)] == 0);
  }
  { Fixture f; auto result = f.submit(); f.transport->counts[0] = 1;
    f.transport->drain_mask = 63; f.transport->bad_lease = true;
    f.notice(result.ticket, 1);
    CHECK(f.releases == 0 && f.executor->snapshot().poisoned); }
}

void test_stop_offline_and_limits() {
  { Fixture f; f.executor->stop(); CHECK(f.submit().code != Code::Accepted);
    CHECK(f.transport->total_calls() == 0 && f.releases == 1); }
  { Fixture f; auto result = f.submit(); f.executor->stop();
    CHECK(f.executor->snapshot().mode == Mode::Stopping);
    CHECK(f.executor->shutdown() == Code::Busy);
    f.transport->counts[0] = 1; auto observed = f.notice(result.ticket, 1);
    CHECK(observed.kernel_complete && f.releases == 0);
    f.executor->stop(); f.transport->drain_mask = 63;
    CHECK(f.notice(result.ticket, 2).code == Code::Retired && f.releases == 1);
    CHECK(f.submit().code != Code::Accepted && f.transport->starts == 1);
    f.executor->shutdown(); CHECK(f.executor->snapshot().mode == Mode::Closed); }
  { Fixture f; auto result = f.submit(); const auto reads = f.transport->reads();
    f.executor->mark_offline(); f.transport->counts[0] = 1;
    f.notice(result.ticket, 1); CHECK(f.transport->reads() == reads && f.releases == 0);
    f.transport->drain_mask = 63; auto retired = f.notice(result.ticket, 2);
    CHECK(retired.code == Code::Retired && retired.poisoned && !retired.kernel_complete);
    CHECK(f.submit().code != Code::Accepted); }
  { Fixture f([](Fake& fake) { fake.verification.first_ticket =
                                std::numeric_limits<std::uint64_t>::max(); });
    auto result = f.submit(); CHECK(result.code == Code::Accepted);
    CHECK(result.ticket.sequence == std::numeric_limits<std::uint64_t>::max());
    f.transport->counts[0] = 1; f.transport->drain_mask = 63;
    CHECK(f.notice(result.ticket, 1).code == Code::Retired);
    const auto calls = f.transport->total_calls();
    CHECK(f.submit().code == Code::SequenceExhausted);
    CHECK(f.transport->total_calls() == calls && f.transport->starts == 1); }
  { Fixture f; CHECK(f.executor->submit(launch(), {}).code == Code::InvalidLease);
    CHECK(f.executor->submit(launch(), {0, std::make_shared<int>(1)}).code == Code::InvalidLease);
    auto result = f.submit();
    CHECK(f.executor->submit(launch(), lease(f.releases, 8)).code == Code::Busy);
    CHECK(f.releases == 1 && f.executor->snapshot().active == result.ticket); }
}

void test_strand_and_detached_ownership() {
  Fixture f;
  bool wrong_thread = false;
  std::thread thread([&] {
    try { f.executor->stop(); } catch (const StrandViolation&) { wrong_thread = true; }
  });
  thread.join(); CHECK(wrong_thread && f.executor->snapshot().mode == Mode::Running);
  bool reentered = false;
  f.transport->hook = [&](Request request) {
    if (request.phase == Phase::Argument) {
      try { f.executor->stop(); } catch (const StrandViolation&) { reentered = true; }
    }
  };
  auto result = f.submit(); CHECK(reentered && result.code == Code::Accepted);
  f.transport->hook = {};
  f.executor.reset();
  CHECK(f.releases == 0 && f.owner->snapshot().holds_buffers);
  CHECK(!f.owner->snapshot().executor_attached);
  const auto reads = f.transport->reads();
  f.owner->recover(result.ticket); CHECK(f.releases == 0);
  f.transport->drain_mask = 63;
  auto retired = f.owner->recover(result.ticket);
  CHECK(retired.code == Code::Retired && retired.poisoned && !retired.kernel_complete);
  CHECK(f.transport->reads() == reads && f.releases == 1);
}

void test_exhausted_notice_recovery() {
  Fixture f;
  const auto result = f.submit();
  const auto maximum = std::numeric_limits<std::uint64_t>::max();
  CHECK(f.notice(result.ticket, maximum).code == Code::Pending);
  CHECK(f.releases == 0);
  const auto reads = f.transport->reads();
  CHECK(f.notice(result.ticket, maximum).code == Code::Duplicate);
  CHECK(f.notice(result.ticket, 1).code == Code::Stale);
  CHECK(f.transport->reads() == reads);
  f.transport->drain_mask = 63;
  auto retired = f.executor->recover(result.ticket);
  CHECK(retired.code == Code::Retired && retired.poisoned && !retired.kernel_complete);
  CHECK(f.releases == 1 && f.transport->reads() == reads);
  CHECK(f.submit().code != Code::Accepted); // explicit recovery closes admission
  // Detached recovery has the same sequence-independent, monotonic query.
  Fixture detached;
  const auto submitted = detached.submit();
  CHECK(detached.notice(submitted.ticket, maximum).code == Code::Pending);
  detached.executor.reset();
  detached.transport->drain_mask = 63;
  CHECK(detached.owner->recover(submitted.ticket).code == Code::Retired);
  CHECK(detached.releases == 1);
}

void test_resource_destructor_reentry() {
  Fixture f;
  bool blocked = false;
  struct ReentrantAllocation {
    ReentrantAllocation(SerializedExecutor* e, bool& b, int& r)
        : executor(e), blocked(b), releases(r) {}
    ~ReentrantAllocation() {
      ++releases;
      try { executor->snapshot(); } catch (const StrandViolation&) { blocked = true; }
    }
    SerializedExecutor* executor;
    bool& blocked;
    int& releases;
  };
  auto result = f.executor->submit(launch(),
      {8, std::make_shared<ReentrantAllocation>(f.executor.get(), blocked, f.releases)});
  CHECK(result.code == Code::Accepted);
  f.transport->counts[0] = 1; f.transport->drain_mask = 63;
  CHECK(f.notice(result.ticket, 1).code == Code::Retired);
  CHECK(blocked && f.releases == 1 && !f.executor->snapshot().holds_buffers);
}

void test_destructor_fail_closed() {
#if defined(__unix__)
  const auto pid = fork(); CHECK(pid >= 0);
  if (pid == 0) {
    static int releases = 0;
    std::set_terminate([] { _Exit(releases == 0 ? 71 : 72); });
    auto fake = std::make_shared<Fake>();
    auto owner = std::make_shared<RetirementOwner>(fake);
    auto executor = std::make_unique<SerializedExecutor>(owner);
    CHECK(executor->submit(launch(), lease(releases)).code == Code::Accepted);
    executor.reset(); owner.reset();
    _Exit(73); // silently disposing unresolved ownership is a test failure
  }
  int status = 0; CHECK(waitpid(pid, &status, 0) == pid);
  CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 71);
#endif
}
}  // namespace

int main() {
  test_abi();
  test_normal_and_notifications();
  test_submission_faults();
  test_completion_faults();
  test_unknown_without_execution();
  test_counts_and_debt();
  test_verification_and_admission();
  test_stop_offline_and_limits();
  test_strand_and_detached_ownership();
  test_exhausted_notice_recovery();
  test_resource_destructor_reentry();
  test_destructor_fail_closed();
  std::cout << "PASS generated kernel executor: ABI, ordering, all CSR fault phases, "
               "count debt, tickets, stop, independent retirement, strand and ownership\n";
}
