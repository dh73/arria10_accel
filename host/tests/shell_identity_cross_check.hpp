// Test-only comparison of independently compiled C and C++ decoders.
#include "../../drivers/aclpci/aclpci_identity.h"
#include <algorithm>
#include <cstdlib>
#include <iostream>
static unsigned cross_checks;
static void same(bool value) {
  if (!value) { std::cerr << "C/C++ identity decoder mismatch\n"; std::abort(); }
}
static im::Report cross_check(const im::RawSnapshot& raw, const kn::SourceAbi& source,
                              const im::Expected& expected, const im::Context& context,
                              const std::vector<im::Resource>& resources) {
  const auto cpp = im::check(raw, source, expected, context, resources);
  aclpci_identity_raw c_raw{};
  c_raw.before = raw.before; c_raw.after = raw.after;
  std::copy(raw.words.begin(), raw.words.end(), c_raw.words);
  aclpci_identity_expected e{};
  std::copy(source.contract_sha256().begin(), source.contract_sha256().end(), e.source);
  std::copy(expected.build.begin(), expected.build.end(), e.build);
  e.management = {expected.management.space, expected.management.offset, expected.management.bytes};
  e.cra = {expected.cra.space, expected.cra.offset, expected.cra.bytes};
  std::copy(context.session.begin(), context.session.end(), e.context.session);
  e.context.epoch = context.epoch;
  e.aperture_bytes = source.aperture_bytes();
  e.source_reextracted = source.validation() == kn::SourceValidation::Reextracted;
  std::vector<aclpci_identity_resource> v;
  for (const auto& r : resources) v.push_back({r.space, r.bytes});
  aclpci_identity_observation c{};
  const auto code = aclpci_identity_check(&c_raw, &e, v.data(), unsigned(v.size()), &c);
  same(int(code) == int(cpp.code));
  const auto& o = cpp.observed;
  same(c.sequence == o.sequence && c.context.epoch == o.context.epoch);
  same(std::equal(o.source.begin(), o.source.end(), c.source));
  same(std::equal(o.build.begin(), o.build.end(), c.build));
  same(std::equal(o.context.session.begin(), o.context.session.end(), c.context.session));
  same(c.management.space == o.management.space && c.management.offset == o.management.offset &&
       c.management.bytes == o.management.bytes && c.cra.space == o.cra.space &&
       c.cra.offset == o.cra.offset && c.cra.bytes == o.cra.bytes);
  const auto& a = c.health; const auto& b = o.health;
  same(a.valid == b.valid && a.fault == b.fault && a.release_ready == b.release_ready &&
       a.launch_permit == b.launch_permit && a.host_submit_permit == b.host_submit_permit &&
       a.state == b.state && a.phase == b.phase && a.adapter_code == b.adapter_code &&
       a.history == b.history && a.pending == b.pending && a.first_code == b.first_code &&
       a.address_valid == b.address_valid && a.address == b.address);
  if (code == ACLPCI_ID_CONSISTENT || code == ACLPCI_ID_TEST_SOURCE_ONLY) {
    // Only trusted provenance affects this classification; words cannot elevate it.
    e.source_reextracted = 0;
    same(aclpci_identity_check(&c_raw, &e, v.data(), unsigned(v.size()), &c) == ACLPCI_ID_TEST_SOURCE_ONLY);
    e.source_reextracted = 1;
    same(aclpci_identity_check(&c_raw, &e, v.data(), unsigned(v.size()), &c) == ACLPCI_ID_CONSISTENT);
  }
  same(aclpci_identity_check(nullptr, &e, nullptr, 0, &c) == ACLPCI_ID_INVALID);
  same(aclpci_identity_check(&c_raw, nullptr, nullptr, 0, &c) == ACLPCI_ID_INVALID);
  same(aclpci_identity_check(&c_raw, &e, nullptr, 1, &c) == ACLPCI_ID_INVALID);
  same(aclpci_identity_check(&c_raw, &e, nullptr, 0, nullptr) == ACLPCI_ID_INVALID);
  ++cross_checks;
  return cpp;
}
