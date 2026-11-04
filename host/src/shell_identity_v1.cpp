#include "shell_identity_v1.hpp"
#include <limits>

namespace asus::a10::image {
namespace {
bool equal(Request a, Request b) noexcept {
  return a.channel == b.channel && a.serial == b.serial && a.offset == b.offset;
}
template<class T> bool nonzero(const T& value) noexcept {
  for (auto x : value) if (x != 0) return true;
  return false;
}
std::uint64_t u64(const RawSnapshot& raw, unsigned word) noexcept {
  return raw.words[word] | (std::uint64_t(raw.words[word + 1]) << 32);
}
Digest digest(const RawSnapshot& raw, unsigned first) noexcept {
  Digest result{};
  for (unsigned b = 0; b != 32; ++b)
    result[b] = std::uint8_t(raw.words[first + b / 4] >> ((b % 4) * 8));
  return result;
}
bool equal(Range a, Range b) noexcept {
  return a.space == b.space && a.offset == b.offset && a.bytes == b.bytes;
}
bool in_resource(Range r, unsigned alignment,
                 const std::vector<Resource>& resources) noexcept {
  if (r.bytes == 0 || r.offset % alignment != 0 || r.bytes % alignment != 0)
    return false;
  for (const auto& v : resources)
    if (v.space == r.space)
      return r.offset <= v.bytes && r.bytes <= v.bytes - r.offset;
  return false;
}
bool ranges(Range a, Range b, std::uint64_t cra_bytes,
            const std::vector<Resource>& resources) noexcept {
  for (std::size_t i = 0; i != resources.size(); ++i) {
    if (resources[i].bytes == 0) return false;
    for (std::size_t j = 0; j != i; ++j)
      if (resources[j].space == resources[i].space) return false;
  }
  if (a.bytes != block_bytes || b.bytes != cra_bytes ||
      !in_resource(a, 4, resources) || !in_resource(b, 8, resources)) return false;
  // Subtraction above established representable endpoints.
  return a.space != b.space || a.offset + a.bytes <= b.offset ||
         b.offset + b.bytes <= a.offset;
}
}  // namespace

Capture capture(Reader& reader, Cursor& cursor) noexcept {
  Capture result;
  if (cursor.closed_) { result.code = Code::CursorClosed; return result; }
  auto read = [&](std::uint32_t offset, std::uint32_t& data) {
    if (cursor.closed_) { result.code = Code::CursorClosed; return false; }
    const Request request{cursor.channel_, cursor.next_, offset};
    if (cursor.next_ == std::numeric_limits<std::uint64_t>::max())
      cursor.closed_ = true;
    else ++cursor.next_;
    const auto reply = reader.read32(request);
    if (!equal(reply.request, request)) {
      result.code = Code::ReplyMismatch; cursor.closed_ = true; return false;
    }
    if (!reply.completed) {
      result.code = Code::IoFailure; cursor.closed_ = true; return false;
    }
    data = reply.value;
    return true;
  };
  // The six-word discovery prefix is read before any layout-specific register.
  constexpr std::array<std::uint32_t, 6> prefix{
      ACLPCI_ID_MAGIC, ACLPCI_ID_V1, 1, block_bytes, capabilities, capabilities};
  std::uint32_t version = 0;
  for (unsigned i = 0; i != prefix.size(); ++i) {
    std::uint32_t value = 0;
    if (!read(i * 4, value)) return result;
    const bool supported = i == 1 ? (value == ACLPCI_ID_V1 || value == ACLPCI_ID_V2)
                         : i == 2 ? value == (version >> 16) : value == prefix[i];
    if (!supported) { result.code = Code::Unsupported; return result; }
    if (i == 1) version = value;
  }
  if (!read(24, result.raw.before)) return result;
  if (result.raw.before == 0) { result.code = Code::Invalid; return result; }
  for (unsigned i = 0; i != 64; ++i)
    if (!read(i * 4, result.raw.words[i])) return result;
  if (!read(24, result.raw.after)) return result;
  result.code = result.raw.before == result.raw.after &&
                result.raw.before == result.raw.words[6] ? Code::Consistent : Code::Torn;
  return result;
}

Report check(const RawSnapshot& raw, const kernel::SourceAbi& source,
             const Expected& expected, const Context& context,
             const std::vector<Resource>& resources) noexcept {
  Report result;
  auto fail = [&](Code code) { result.code = code; return result; };
  const auto& w = raw.words;
  if (raw.before == 0 || raw.after == 0 || w[7] != 1)
    return fail(Code::Invalid);
  if (raw.before != raw.after || raw.before != w[6]) return fail(Code::Torn);
  if (w[0] != ACLPCI_ID_MAGIC || !((w[1] == ACLPCI_ID_V1 && w[2] == 1) ||
                             (w[1] == ACLPCI_ID_V2 && w[2] == 2)) ||
      w[3] != block_bytes || w[4] != capabilities || w[5] != capabilities)
    return fail(Code::Unsupported);
  for (unsigned i = 43; i != 64; ++i)
    if (w[i] != 0) return fail(Code::Malformed);
  if ((w[38] & ~0x7ffu) || (w[40] & 0xfe000000u) || (w[42] & ~(w[2] == 2 ? ACLPCI_ID_V2_ADDRESS_HIGH_MASK : ACLPCI_ID_V1_ADDRESS_HIGH_MASK)))
    return fail(Code::Malformed);
  if (!(w[40] & (1u << 24)) && u64(raw, 41) != 0)
    return fail(Code::Malformed);
  if (!(w[38] & 1u)) {
    for (unsigned i = 38; i != 43; ++i)
      if (w[i] != 0) return fail(Code::Malformed);
  } else if (((w[38] >> 1) & 7) > 6 || ((w[38] >> 4) & 7) > 5) {
    return fail(Code::Malformed);
  }
  auto& o = result.observed;
  o.sequence = raw.before;
  o.source = digest(raw, 8); o.build = digest(raw, 16);
  o.management = {w[24], u64(raw, 26), block_bytes};
  o.cra = {w[25], u64(raw, 28), u64(raw, 30)};
  for (unsigned i = 0; i != 4; ++i) o.context.session[i] = w[32 + i];
  o.context.epoch = u64(raw, 36);
  if (!nonzero(o.source) || !nonzero(o.build)) return fail(Code::Malformed);
  if (!nonzero(context.session) || context.epoch == 0 ||
      o.context.session != context.session || o.context.epoch != context.epoch)
    return fail(Code::StaleContext);
  if (!ranges(expected.management, expected.cra, source.aperture_bytes(), resources) ||
      !ranges(o.management, o.cra, source.aperture_bytes(), resources))
    return fail(Code::BadRange);
  if (!equal(o.management, expected.management) || !equal(o.cra, expected.cra))
    return fail(Code::MappingMismatch);
  if (o.source != source.contract_sha256()) return fail(Code::SourceMismatch);
  if (o.build != expected.build) return fail(Code::BuildMismatch);
  auto& h = o.health;
  h.valid = (w[38] & 1) != 0;
  h.state = std::uint8_t((w[38] >> 1) & 7);
  h.phase = std::uint8_t((w[38] >> 4) & 7);
  h.fault = (w[38] & 128) != 0; h.release_ready = (w[38] & 256) != 0;
  h.launch_permit = (w[38] & 512) != 0; h.host_submit_permit = (w[38] & 1024) != 0;
  h.history = std::uint16_t(w[39]); h.pending = std::uint16_t(w[39] >> 16);
  h.first_code = std::uint16_t(w[40]); h.adapter_code = std::uint8_t(w[40] >> 16);
  h.address_valid = (w[40] & (1u << 24)) != 0; h.address = u64(raw, 41);
  result.code = source.validation() == kernel::SourceValidation::Reextracted ?
      Code::Consistent : Code::TestSourceOnly;
  return result;
}
}  // namespace asus::a10::image
