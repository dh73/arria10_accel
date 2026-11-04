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
  // Bind expected classification to exact source bodies, not a caller flag.
  for (std::size_t i=0; i<2; ++i) {
    const auto& kernel = abi.kernel(i);
    const bool is_copy = kernel.name == "stream_copy512";
    CHECK(is_copy || kernel.name == "stream_triad512");
    const std::string path = "kernel_hdl/" + std::string(kernel.name) + "/" +
                             std::string(kernel.name) + "_function_cra_agent.sv";
    const std::string_view corrected = is_copy
      ? "69a0e196e0137b7c83232178cde4d0a40e294c6f87bfcff8b452e4ab6ebb6407"
      : "b68329a2df74165713acb080692e2bfcbceed411242bfe8b88283a04698183ea";
    const std::string_view original = is_copy
      ? "a11d7be4c514e2d7152f09d00d31ff795c1f9a55fada7a0f7f225f01f36430ce"
      : "73f76b1b45667d9e8402bdcbaef73c2bfad3610ae3e69c1a529c781c953e0318";
    bool found=false;
    for(std::size_t h=0;h<abi.source_hash_count();++h) if(abi.source_hash(h).path==path) {
      const auto digest=abi.source_hash(h).sha256;
      CHECK(digest==original || digest==corrected);
      CHECK(kernel.completion_accounting == (digest==corrected
        ? CompletionAccounting::DelayedSnapshotV1 : CompletionAccounting::Unqualified));
      found=true;
    }
    CHECK(found);
  }
  Launch::NamedArguments args{{"output0",0x1234567887654321},
                             {"count",17},{"input0",0x1122334455667788}};
  const auto copy = Launch::make("stream_copy512",args);
  CHECK(copy);
  const std::vector<ArgumentWrite> expected{{128,0x1122334455667788,255},
      {136,0x1234567887654321,255},{144,17,15}};
  check(copy->writes(),expected);
  args[1].second = UINT64_C(1)<<32;
  CHECK(!Launch::make("stream_copy512",args));
  args[1].second = 17; args[0].first = "input0";
  CHECK(!Launch::make("stream_copy512",args));
  args[0].first = "unknown";
  CHECK(!Launch::make("stream_copy512",args));
  CHECK(!Launch::make("unknown",args));
  args.pop_back(); CHECK(!Launch::make("stream_copy512",args));
  check(copy->writes(),expected); // Caller mutations cannot alter the prepared launch.
  const auto triad = Launch::make("stream_triad512",{{"count",17},
    {"a",0x1122334455667788},{"b",0x1234567887654321},
    {"scale",0xaabbccdd},{"output0",0x8877665544332211}});
  CHECK(triad);
  check(triad->writes(),{{384,0x1122334455667788,255},{392,0x1234567887654321,255},
    {400,0x8877665544332211,255},{408,0x00000011aabbccdd,255}});
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
  std::cout << "OPENCL_KERNEL_EXECUTOR_HOST_PASS\n";
}
