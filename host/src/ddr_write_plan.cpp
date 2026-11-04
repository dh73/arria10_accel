#include "ddr_write_plan.hpp"
#include <algorithm>

namespace asus::a10::memory {
WritePlan plan_write(std::uint64_t aperture, std::uint64_t address,
                     const void* source, std::size_t bytes) noexcept {
  WritePlan p;
  if(aperture<4 || aperture>0x80000000ULL || (aperture&3) ||
     address>aperture || bytes>aperture-address || (bytes&&!source)) return p;
  p.valid=true;
  const auto* data=static_cast<const unsigned char*>(source);
  std::size_t offset=0, remaining=bytes;
  auto edge=[&](std::size_t n) {
    auto& s=p.segments[p.count++];
    s.route=WriteRoute::MaskedWord;s.device_address=address&~std::uint64_t(3);
    s.source_offset=offset;s.bytes=n;
    const unsigned lane=address&3;
    for(std::size_t i=0;i<n;++i){
      s.data|=std::uint32_t(data[offset+i])<<(8*(lane+i));
      s.mask|=std::uint8_t(1u<<(lane+i));
    }
    address+=n;offset+=n;remaining-=n;
  };
  if(remaining && (address&3)) edge(std::min(remaining,std::size_t(4-(address&3))));
  const auto bulk=remaining&~std::size_t(3);
  if(bulk){
    auto& s=p.segments[p.count++];
    s.route=WriteRoute::Dma;s.device_address=address;
    s.source_offset=offset;s.bytes=bulk;
    address+=bulk;offset+=bulk;remaining-=bulk;
  }
  if(remaining)edge(remaining);
  return p;
}
}
