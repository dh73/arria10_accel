#include "ddr_snapshot_reader.hpp"
#include "aclpci_mailbox_port.hpp"
#include "pcie_linux_driver_exports.h"
#include <cerrno>
#include <stdexcept>
#include <cstdio>
using namespace asus::a10;
extern "C" int control_reset();
extern "C" int control_get(unsigned long long,unsigned*);
extern "C" int control_put(unsigned long long,unsigned);
extern "C" int control_traffic();
namespace {
constexpr std::uint64_t base=0x100000280ull;
unsigned calls=0,fail=0,captures=0;
ssize_t io(int fd,void* raw,std::size_t n,bool reading)noexcept{
 ++calls;auto& c=*static_cast<acl_cmd*>(raw);auto a=reinterpret_cast<std::uintptr_t>(c.device_addr);
 if(fd!=91||n!=4||c.size!=4||c.bar_id!=2||c.command!=ACLPCI_CMD_DEFAULT||a<base||a>=base+80||(a&3))return -1;
 auto& v=*static_cast<std::uint32_t*>(c.user_addr);
 if(reading)control_get(a,&v);else{control_put(a,v);++captures;}
 if(calls==fail){errno=EINTR;return -1;}return 0;
}
void need(bool b,const char*msg){if(!b)throw std::runtime_error(msg);}
void finish(metrics::Capture& c){while(c.state()==metrics::CaptureState::Pending)c.advance();}
}
extern "C" int run_snapshot_host(int* result){*result=1;try{
 control_reset();calls=fail=captures=0;mailbox::AclPciPort p(91,base,io,80);
 metrics::Capture first(p,base,{1,1,0,0});finish(first);need(first.snapshot().has_value(),"first capture");
 control_traffic();metrics::Capture second(p,base,{1,1,0,0});finish(second);need(second.snapshot().has_value(),"second capture");
 auto rates=metrics::measure(*first.snapshot(),*second.snapshot());need(rates.has_value(),"invalid interval");
 need(rates->write_beats==9&&rates->write_bytes==36&&rates->read_beats==1&&rates->responses==1&&rates->stall_cycles==6,"hardware counter decode mismatch");
 need(!rates->write_bus_bytes_per_second&&rates->write_bus_bytes_per_cycle>rates->write_payload_bytes_per_cycle,"fabricated rate");
 for(unsigned n=1;n<=24;++n){
  control_reset();calls=captures=0;fail=n;mailbox::AclPciPort port(91,base,io,80);
  metrics::Capture request(port,base,{1,1,0,0});finish(request);
  need(request.state()==metrics::CaptureState::Poisoned&&calls==n&&!request.snapshot(),"uncertain I/O accepted");
  request.advance();need(calls==n&&captures<=1,"capture replayed");
 }
 std::puts("DDR_CAPTURE_CXX_RTL_PASS io_boundaries=24 write_beats=9 write_bytes=36 read_beats=1 stalls=6");*result=0;
}catch(const std::exception& e){std::fprintf(stderr,"DDR_CAPTURE_CXX_RTL_FAIL %s\n",e.what());}return 0;}
