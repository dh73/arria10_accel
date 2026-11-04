#pragma once
#include <array>
#include <cmath>
#include <cstdint>
#include <optional>
namespace asus::a10::metrics {
// Caller obtains coherent snapshots under one qualified image/session/reset
// context. This calculator neither discovers hardware nor certifies that context.
struct Snapshot {
 std::array<std::uint64_t,4> context{}; // source-bound session/reset identity
 std::uint64_t sequence{};
 std::array<std::uint64_t,7> counts{}; // order of ddr_traffic_counters.sv
 bool valid{},overflow{},invalid_command{};
};
struct Rates {
 std::uint64_t cycles{},read_beats{},write_beats{},write_bytes{},stall_cycles{},responses{};
 long double read_bus_bytes_per_cycle{},write_bus_bytes_per_cycle{},write_payload_bytes_per_cycle{},stall_fraction{};
 // Absent without an externally established EMIF user-clock frequency.
 std::optional<long double> read_bus_bytes_per_second,write_bus_bytes_per_second,write_payload_bytes_per_second;
};
inline std::optional<Rates> measure(const Snapshot& a,const Snapshot& b,
                                   std::optional<long double> clock_hz={}) noexcept {
 if(!a.valid||!b.valid||a.overflow||b.overflow||a.invalid_command||b.invalid_command||
    a.context!=b.context||a.context==std::array<std::uint64_t,4>{}||b.sequence<=a.sequence)
  return {};
 if(clock_hz&&(!std::isfinite(*clock_hz)||*clock_hz<=0))return {};
 std::array<std::uint64_t,7>d{};
 for(unsigned i=0;i<7;++i){if(b.counts[i]<a.counts[i])return {};d[i]=b.counts[i]-a.counts[i];}
 const auto cycles=d[0],rd=d[1],wr=d[2],bytes=d[3],stall=d[4],responses=d[5],active=d[6];
 if(!cycles||active>cycles||responses>cycles||rd>active||wr>active-rd||stall!=active-rd-wr||
    (bytes/64>wr || (bytes/64==wr && bytes%64!=0)))return {};
 Rates r{cycles,rd,wr,bytes,stall,responses,64.L*rd/cycles,64.L*wr/cycles,
         static_cast<long double>(bytes)/cycles,static_cast<long double>(stall)/cycles,{},{},{}};
 if(clock_hz){
  r.read_bus_bytes_per_second=r.read_bus_bytes_per_cycle * (*clock_hz);
  r.write_bus_bytes_per_second=r.write_bus_bytes_per_cycle * (*clock_hz);
  r.write_payload_bytes_per_second=r.write_payload_bytes_per_cycle * (*clock_hz);
 }
 return r;
}
}
