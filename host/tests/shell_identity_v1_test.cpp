#include "shell_identity_v1.hpp"
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

namespace im = asus::a10::image;
namespace kn = asus::a10::kernel;
using Words = std::array<std::uint32_t, 72>;
static void need(bool ok, const char* why) {
  if (!ok) throw std::runtime_error(why);
}
static im::Expected expected() {
  im::Expected e{{}, {7, 0x1000, 256}, {7, 0x2000, 512}};
  for (unsigned i = 0; i != 32; ++i) e.build[i] = std::uint8_t(0xa0 + i);
  return e;
}
static const im::Context context{{1, 2, 3, 4}, 9};
static const std::vector<im::Resource> resources{{7, 0x10000}};
static im::Code good_code() {
  return kn::generated_abi().validation() == kn::SourceValidation::Reextracted ?
      im::Code::Consistent : im::Code::TestSourceOnly;
}
static void put64(im::RawSnapshot& r, unsigned i, std::uint64_t v) {
  r.words[i] = std::uint32_t(v); r.words[i + 1] = std::uint32_t(v >> 32);
}
static im::RawSnapshot sample() {
  im::RawSnapshot r;
  auto& w = r.words;
  w[0] = 0x31444941; w[1] = 0x10000; w[2] = 1; w[3] = 256;
  w[4] = 31; w[5] = 31; w[6] = r.before = r.after = 12; w[7] = 1;
  const auto source = kn::generated_abi().contract_sha256();
  const auto e = expected();
  for (unsigned b = 0; b != 32; ++b) {
    w[8 + b / 4] |= std::uint32_t(source[b]) << (8 * (b % 4));
    w[16 + b / 4] |= std::uint32_t(e.build[b]) << (8 * (b % 4));
  }
  w[24] = e.management.space; w[25] = e.cra.space;
  put64(r, 26, e.management.offset); put64(r, 28, e.cra.offset);
  put64(r, 30, e.cra.bytes);
  for (unsigned i = 0; i != 4; ++i) w[32 + i] = context.session[i];
  put64(r, 36, context.epoch);
  w[38] = 1 | (1 << 1) | (1 << 4) | (1 << 9) | (1 << 10);
  return r;
}
static im::Report check(const im::RawSnapshot& r) {
  return im::check(r, kn::generated_abi(), expected(), context, resources);
}
static Words flatten(const im::RawSnapshot& r) {
  Words words{}; words[6] = r.before; words[71] = r.after;
  for (unsigned i = 0; i != 6; ++i) words[i] = r.words[i];
  for (unsigned i = 0; i != 64; ++i) words[i + 7] = r.words[i];
  return words;
}
// Replays a finite TEST transcript, including a native RTL bus dump.
// This is not a device/MMIO adapter and has no launch/write/admission method.
class Transcript final : public im::Reader {
 public:
  explicit Transcript(Words w) : words(w) {}
  Words words;
  unsigned reads{0};
  int fail_at{-1}, stale_at{-1}, foreign_at{-1}, offset_at{-1};
  im::Reply read32(im::Request request) noexcept override {
    const auto index = reads++;
    const auto offset = index < 6 ? index * 4 :
        index == 6 || index == 71 ? 24u : (index - 7) * 4;
    if (index >= words.size() || request.offset != offset)
      return {request, false, 0};
    auto reply = im::Reply{request, int(index) != fail_at, words[index]};
    if (int(index) == stale_at) --reply.request.serial;
    if (int(index) == foreign_at) ++reply.request.channel;
    if (int(index) == offset_at) reply.request.offset ^= 4;
    return reply;
  }
};
static void host_tests() {
  const auto baseline = sample();
  need(check(baseline).code == good_code(), "valid source association");
  auto mutate = [&](unsigned word, std::uint32_t value, im::Code code) {
    auto r = baseline; r.words[word] = value;
    need(check(r).code == code, "mutated snapshot accepted/wrong classification");
  };
  mutate(0, 0, im::Code::Unsupported);
  mutate(1, 0x20000, im::Code::Unsupported);
  mutate(1, 0x10001, im::Code::Unsupported);
  mutate(2, 2, im::Code::Unsupported);
  mutate(3, 512, im::Code::Unsupported);
  mutate(4, 63, im::Code::Unsupported);
  mutate(5, 63, im::Code::Unsupported);
  mutate(4, 15, im::Code::Unsupported);
  mutate(5, 15, im::Code::Unsupported);
  mutate(6, 13, im::Code::Torn);
  mutate(7, 0, im::Code::Invalid); mutate(7, 2, im::Code::Invalid);
  mutate(8, baseline.words[8] ^ 1, im::Code::SourceMismatch);
  mutate(16, baseline.words[16] ^ 1, im::Code::BuildMismatch);
  mutate(32, 0, im::Code::StaleContext);
  mutate(36, 10, im::Code::StaleContext);
  mutate(24, 8, im::Code::BadRange);
  mutate(26, 0x1001, im::Code::BadRange);
  mutate(28, 0x1000, im::Code::BadRange); // overlap
  mutate(28, 0x2004, im::Code::BadRange); // CRA width alignment
  mutate(28, 0x10000, im::Code::BadRange);
  mutate(28, 0x3000, im::Code::MappingMismatch);
  mutate(30, 0, im::Code::BadRange);
  mutate(30, 1024, im::Code::BadRange);
  mutate(38, 0x800, im::Code::Malformed);
  mutate(38, 1 | (7 << 1), im::Code::Malformed);
  mutate(38, 1 | (6 << 4), im::Code::Malformed);
  mutate(40, 1u << 25, im::Code::Malformed);
  mutate(42, 8, im::Code::Malformed);
  mutate(41, 1, im::Code::Malformed); // Invalid address must encode zero.
  for (unsigned i = 43; i != 64; ++i) mutate(i, 1, im::Code::Malformed);
  auto r = baseline; r.before = 0;
  need(check(r).code == im::Code::Invalid, "zero guard");
  r = baseline; ++r.after;
  need(check(r).code == im::Code::Torn, "changing guard");
  r = baseline; for (unsigned i = 8; i != 16; ++i) r.words[i] = 0;
  need(check(r).code == im::Code::Malformed, "empty source ID");
  r = baseline; put64(r, 28, std::numeric_limits<std::uint64_t>::max() - 511);
  const std::vector<im::Resource> huge{{7, std::numeric_limits<std::uint64_t>::max()}};
  need(im::check(r, kn::generated_abi(), expected(), context, huge).code ==
       im::Code::BadRange, "overflowing endpoint");
  auto e = expected(); e.management.bytes = 0;
  need(im::check(baseline, kn::generated_abi(), e, context, resources).code ==
       im::Code::BadRange, "invalid expected mapping");
  auto duplicates = resources; duplicates.push_back(resources[0]);
  need(im::check(baseline, kn::generated_abi(), expected(), context, duplicates).code ==
       im::Code::BadRange, "ambiguous resource");
  // Abutting ranges and equal offsets in DIFFERENT declared resources are legal.
  r = baseline; e = expected(); e.cra.offset = 0x1100; put64(r, 28, e.cra.offset);
  need(im::check(r, kn::generated_abi(), e, context, resources).code == good_code(),
       "valid adjacency");
  r = baseline; e = expected(); e.cra = {8, 0x1000, 512};
  r.words[25] = 8; put64(r, 28, 0x1000);
  need(im::check(r, kn::generated_abi(), e, context, {{7, 0x10000}, {8, 0x10000}}).code ==
       good_code(), "separate resource ranges");
  // Healthy, faulted/drained and invalid health snapshots never grant authority.
  r = baseline; r.words[38] = 1 | (6 << 1) | (4 << 4) | 128 | 256;
  r.words[39] = 0x00040004; r.words[40] = 4;
  const auto faulted = check(r);
  need(faulted.code == good_code() && faulted.observed.health.fault &&
       faulted.observed.health.release_ready && !faulted.observed.health.launch_permit,
       "faulted diagnostic snapshot");
  r = baseline; r.words[38] = 0;
  need(check(r).code == good_code() && !check(r).observed.health.valid, "invalid health");
  r.words[39] = 1;
  need(check(r).code == im::Code::Malformed, "unqualified health payload");
  // V2 preserves all 41 address bits; the V1 reserved bits remain strict.
  for(unsigned bit=0;bit<41;++bit) {
    auto wide=baseline;wide.words[1]=0x20000;wide.words[2]=2;
    wide.words[40]|=1u<<24;put64(wide,41,std::uint64_t(1)<<bit);
    const auto decoded=check(wide);
    need(decoded.code==good_code() && decoded.observed.health.address==(std::uint64_t(1)<<bit), "wide address lost");
    Transcript tr(flatten(wide));im::Cursor cur(91);
    const auto captured=im::capture(tr,cur);
    need(captured.code==im::Code::Consistent && check(captured.raw).code==good_code(), "v2 capture failed");
  }
  auto wide=baseline;wide.words[1]=0x20000;wide.words[2]=2;wide.words[40]|=1u<<24;
  put64(wide,41,std::uint64_t(1)<<41);
  need(check(wide).code==im::Code::Malformed,"out-of-range v2 address");
  for (unsigned failure = 0; failure != 72; ++failure) {
    Transcript transport(flatten(baseline)); transport.fail_at = int(failure);
    im::Cursor cursor(77);
    need(im::capture(transport, cursor).code == im::Code::IoFailure, "I/O failure");
    const auto reads = transport.reads;
    need(im::capture(transport, cursor).code == im::Code::CursorClosed &&
         transport.reads == reads, "failed cursor reused");
    Transcript stale(flatten(baseline)); stale.stale_at = int(failure);
    im::Cursor second(78);
    need(im::capture(stale, second).code == im::Code::ReplyMismatch, "stale response");
  }
  for (unsigned i = 0; i != 6; ++i) {
    auto bad_header = baseline; bad_header.words[i] ^= 0x80000000u;
    Transcript unsupported(flatten(bad_header)); im::Cursor probe(79);
    need(im::capture(unsupported, probe).code == im::Code::Unsupported &&
         unsupported.reads == i + 1, "unsupported layout read past discovery prefix");
  }
  Transcript transport(flatten(baseline)); im::Cursor cursor(80);
  const auto capture = im::capture(transport, cursor);
  need(capture.code == im::Code::Consistent && transport.reads == 72 &&
       check(capture.raw).code == good_code(), "reader/parser integration");
  r = baseline; ++r.after;
  Transcript changing(flatten(r)); im::Cursor third(81);
  need(im::capture(changing, third).code == im::Code::Torn, "torn reader");
  r = baseline; r.words[32] = 99; // old reader data against current external session
  Transcript old(flatten(r)); im::Cursor fourth(82);
  need(check(im::capture(old, fourth).raw).code == im::Code::StaleContext,
       "old session replay");
  Transcript never(flatten(baseline)); im::Cursor zero(0);
  need(im::capture(never, zero).code == im::Code::CursorClosed && never.reads == 0,
       "zero channel must not read");
  Transcript last(flatten(baseline));
  im::Cursor boundary(91, std::numeric_limits<std::uint64_t>::max() - 71);
  need(im::capture(last, boundary).code == im::Code::Consistent, "last serial usable");
  need(im::capture(last, boundary).code == im::Code::CursorClosed && last.reads == 72,
       "serial wrapped");
  Transcript insufficient(flatten(baseline));
  im::Cursor exhausted(92, std::numeric_limits<std::uint64_t>::max());
  need(im::capture(insufficient, exhausted).code == im::Code::CursorClosed &&
       insufficient.reads == 1, "partial serial budget");
  Transcript foreign(flatten(baseline)); foreign.foreign_at = 31;
  im::Cursor fc(93);
  need(im::capture(foreign, fc).code == im::Code::ReplyMismatch, "foreign channel");
  Transcript wrong_offset(flatten(baseline)); wrong_offset.offset_at = 71;
  im::Cursor oc(94);
  need(im::capture(wrong_offset, oc).code == im::Code::ReplyMismatch, "wrong offset");
  std::cout << "A10_IDENTITY_HOST_PASS\n";
}
static std::string hex(const im::Digest& d) {
  const char* chars = "0123456789abcdef";
  std::string result;
  for (auto i = d.rbegin(); i != d.rend(); ++i) {
    result += chars[*i >> 4]; result += chars[*i & 15];
  }
  return result; // packed RTL bit[7:0] contains digest byte0
}
static void emit_rtl(const char* path) {
  std::ofstream out(path);
  need(bool(out), "open test parameter output");
  out << "// TEST fixture only; contains no physical mapping or loaded-image evidence.\n"
      << "localparam logic [255:0] ID_SOURCE = 256'h" << hex(kn::generated_abi().contract_sha256()) << ";\n"
      << "localparam logic [255:0] ID_BUILD = 256'h" << hex(expected().build) << ";\n"
      << "localparam logic [31:0] ID_MGMT_SPACE=7, ID_CRA_SPACE=7;\n"
      << "localparam logic [63:0] ID_MGMT_BASE=64'h1000, ID_CRA_BASE=64'h2000,\n"
      << "  ID_CRA_BYTES=64'd512;\n";
  out.close(); need(bool(out), "write test parameters");
}
static void from_rtl(const char* path) {
  std::ifstream in(path); need(bool(in), "open RTL transcript");
  Words words{};
  for (auto& word : words) {
    std::string s; need(bool(in >> s) && s.size() == 8, "RTL transcript size");
    word = 0;
    for (char c : s) {
      const int d = c >= '0' && c <= '9' ? c - '0' :
                    c >= 'a' && c <= 'f' ? c - 'a' + 10 :
                    c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
      need(d >= 0, "RTL transcript contains X/Z/nonhex");
      word = (word << 4) | std::uint32_t(d);
    }
  }
  std::string extra; need(!(in >> extra), "extra RTL data");
  Transcript transport(words); im::Cursor cursor(90);
  const auto captured = im::capture(transport, cursor);
  need(captured.code == im::Code::Consistent && transport.reads == 72,
       "RTL transcript capture");
  const auto report = check(captured.raw);
  need(report.code == good_code(), "RTL/host decoder disagreement");
  need(report.observed.health.valid && report.observed.health.state == 1 &&
       report.observed.health.phase == 1 && report.observed.health.launch_permit &&
       report.observed.health.host_submit_permit, "supervisor snapshot disagreement");
  std::cout << "A10_IDENTITY_RTL_HOST_PASS\n";
}
int main(int argc, char** argv) {
  try {
    if (argc == 1) host_tests();
    else if (argc == 3 && std::string(argv[1]) == "--emit-rtl") emit_rtl(argv[2]);
    else if (argc == 3 && std::string(argv[1]) == "--from-rtl") from_rtl(argv[2]);
    else throw std::runtime_error("usage: test [--emit-rtl PARAMS | --from-rtl DUMP]");
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "Error: " << error.what() << '\n'; return 1;
  }
}
