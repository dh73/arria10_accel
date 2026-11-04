#include "reset_diagnostics.hpp"
#include <limits>
namespace asus::a10::diagnostics {
Snapshot capture(mailbox::Port& port,std::uint64_t base) noexcept {
 if((base&3) || base>std::numeric_limits<std::uint64_t>::max()-7)
  return {Code::InvalidMapping,0};
 const auto signature=port.read32(base);
 if(signature.outcome!=mailbox::Outcome::Completed)
  return {signature.outcome==mailbox::Outcome::NotIssued?Code::NotIssued:Code::Unknown,0};
 if(signature.value!=0x52534401u)return {Code::Unsupported,0};
 const auto status=port.read32(base+4);
 if(status.outcome!=mailbox::Outcome::Completed)
  return {status.outcome==mailbox::Outcome::NotIssued?Code::NotIssued:Code::Unknown,0};
 if(status.value&0xffffff00u)return {Code::Malformed,0};
 return {Code::Observed,static_cast<std::uint8_t>(status.value)};
}
}
