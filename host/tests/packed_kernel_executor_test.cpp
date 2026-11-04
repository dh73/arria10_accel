// Fake transport only: no image, physical CRA or completion qualification.
#include "generated_kernel_executor.hpp"
#include <cstdlib>
#include <iostream>
#include <vector>
using namespace asus::a10::kernel;
#define CHECK(x) do { if (!(x)) { std::cerr << "FAIL " << __LINE__ << ": " #x "\n"; std::abort(); } } while (false)

class Legacy : public Transport {
 public:
  unsigned starts{0}, full_writes{0};
  Verification verify(const SourceAbi& a) noexcept override {
    return {IoOutcome::Completed, 19, 1, a.aperture_bytes(), true,true,true,true,true,true};
  }
  AdmissionReply admit(Request r, const Launch&, const BufferLease&) noexcept override {
    return {r, IoOutcome::Completed, true,true,true,true,true,true};
  }
  IoReply write64(Request r, std::uint32_t, std::uint64_t) noexcept override {
    ++full_writes;
    if (r.phase == Phase::Start) ++starts;
    return {r, IoOutcome::Completed, 0};
  }
  IoReply read64(Request r, std::uint32_t) noexcept override {
    return {r, IoOutcome::Completed, 0};
  }
  IoReply order(Request r) noexcept override { return {r, IoOutcome::Completed, 0}; }
  RetirementReply retirement(Request r, std::uint64_t id) noexcept override {
    return {r, IoOutcome::Completed, id, true,true,true,true,true,true};
  }
};
class Masked final : public Legacy {
 public:
  std::vector<ArgumentWrite> observed;
  bool unknown_partial{false}, before_start{false};
  IoReply write64_masked(Request r, std::uint32_t o, std::uint64_t v,
                         std::uint8_t m) noexcept override {
    CHECK(r.phase == Phase::Argument && !before_start && starts == 0);
    observed.push_back({o,v,m});
    return {r, unknown_partial && m != 255 ? IoOutcome::Unknown : IoOutcome::Completed, 0};
  }
  IoReply order(Request r) noexcept override {
    if (r.phase == Phase::BeforeStart) { CHECK(!observed.empty()); before_start = true; }
    return {r, IoOutcome::Completed, 0};
  }
  IoReply write64(Request r, std::uint32_t o, std::uint64_t v) noexcept override {
    CHECK(r.phase == Phase::Start && before_start && starts == 0 && o == 8 && v == 1);
    return Legacy::write64(r,o,v);
  }
};
void check(const std::vector<ArgumentWrite>& actual, const std::vector<ArgumentWrite>& expected) {
  CHECK(actual.size() == expected.size());
  for (std::size_t i=0; i<actual.size(); ++i) {
    CHECK(actual[i].byte_offset == expected[i].byte_offset);
    CHECK(actual[i].value == expected[i].value);
    CHECK(actual[i].byte_enable == expected[i].byte_enable);
  }
}
int main() {
  const auto& abi = generated_abi();
  CHECK(abi.validation() == SourceValidation::Reextracted);
  CHECK(abi.kernel_count() == 2 && abi.source_hash_count() == 6);
  for (std::size_t i=0; i<2; ++i)
    CHECK(abi.kernel(i).completion_accounting == CompletionAccounting::Unqualified);
  Launch::NamedArguments args{{"arg_dst",0x1234567887654321},
                             {"arg_count",17},{"arg_src",0x1122334455667788}};
  const auto copy = Launch::make("a10_streaming_Copy",args);
  CHECK(copy);
  const std::vector<ArgumentWrite> expected{{128,0x5566778800000011,255},
      {136,0x8765432111223344,255},{144,0x12345678,15}};
  check(copy->writes(),expected);
  args[1].second = UINT64_C(1)<<32;
  CHECK(!Launch::make("a10_streaming_Copy",args));
  args[1].second = 17; args[0].first = "arg_src";
  CHECK(!Launch::make("a10_streaming_Copy",args));
  args[0].first = "unknown";
  CHECK(!Launch::make("a10_streaming_Copy",args));
  CHECK(!Launch::make("unknown",args));
  args.pop_back(); CHECK(!Launch::make("a10_streaming_Copy",args));
  check(copy->writes(),expected); // Caller mutations cannot alter the prepared launch.
  const auto triad = Launch::make("a10_streaming_Triad",{{"arg_count",17},
    {"arg_a",0x1122334455667788},{"arg_b",0x1234567887654321},
    {"arg_scale",0xaabbccdd},{"arg_dst",0x8877665544332211}});
  CHECK(triad);
  check(triad->writes(),{{384,0x5566778800000011,255},{392,0x8765432111223344,255},
    {400,0xaabbccdd12345678,255},{408,0x8877665544332211,255}});
  for (int mode=0; mode<3; ++mode) {
    const auto legacy = std::make_shared<Legacy>();
    const auto masked = std::make_shared<Masked>();
    masked->unknown_partial = mode == 2;
    std::shared_ptr<Transport> transport = mode == 0 ? std::static_pointer_cast<Transport>(legacy)
                                                  : std::static_pointer_cast<Transport>(masked);
    auto owner = std::make_shared<RetirementOwner>(transport);
    SerializedExecutor executor(owner);
    auto keep = std::make_shared<int>(7);
    std::weak_ptr<int> weak = keep;
    const auto result = executor.submit(*copy,{7,keep});
    keep.reset();
    CHECK(!weak.expired() && executor.snapshot().holds_buffers);
    if (mode == 0) {
      CHECK(result.code == Code::IoNotIssued && legacy->starts == 0 && legacy->full_writes == 2);
    } else {
      check(masked->observed,expected);
      CHECK(masked->starts == (mode == 1 ? 1u : 0u));
      CHECK(result.code == (mode == 1 ? Code::Accepted : Code::IoUnknown));
    }
    // No replay on a second submit; debt retained until independent retirement.
    executor.submit(*copy,{8,std::make_shared<int>(8)});
    CHECK(mode == 0 ? legacy->starts == 0 : masked->starts == (mode == 1 ? 1u : 0u));
    CHECK(executor.recover(result.ticket).code == Code::Retired);
    CHECK(weak.expired());
  }
  std::cout << "PACKED_KERNEL_EXECUTOR_HOST_PASS\n";
}
