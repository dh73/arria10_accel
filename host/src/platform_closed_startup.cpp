#include "platform_closed_startup.hpp"
#include <cerrno>
#include <limits>
#include <new>
extern "C" {
#include "aclpci_startup.h"
}
namespace asus::a10::control {
struct ClosedStartup::Impl {
 std::array<Window,4> windows;
 aclpci_startup request{};
 static int read(void* raw,unsigned offset,u32* value) {
  auto& w=*static_cast<Window*>(raw);auto r=w.port->read32(w.base+offset);
  if(r.outcome!=mailbox::Outcome::Completed)return -EIO;
  *value=r.value;return 0;
 }
 static int write(void* raw,unsigned offset,u32 value) {
  auto& w=*static_cast<Window*>(raw);
  return w.port->write32(w.base+offset,value).outcome==mailbox::Outcome::Completed?0:-EIO;
 }
 static int flush(void* raw) {
  auto& w=*static_cast<Window*>(raw);
  return w.port->fence().outcome==mailbox::Outcome::Completed?0:-EIO;
 }
};
ClosedStartup::ClosedStartup(std::array<Window,4> w,std::array<std::uint32_t,6> c,
                            std::uint64_t id) noexcept :impl_(new(std::nothrow) Impl){
 if(!impl_)return;
 impl_->windows=w;
 constexpr unsigned bytes[4]={32,48,40,32};
 for(unsigned i=0;i<4;++i)if(!w[i].port || w[i].base%4 ||
    w[i].base>std::numeric_limits<std::uint64_t>::max()-(bytes[i]-1)) {
  impl_->request.result=-EINVAL;return;
 }
 aclpci_startup_closed_init(&impl_->request,c.data(),id);
}
ClosedStartup::~ClosedStartup()=default;
int ClosedStartup::result()const noexcept{return impl_?impl_->request.result:-ENOMEM;}
int ClosedStartup::revoke()noexcept{return impl_?aclpci_startup_revoke(&impl_->request):-ENOMEM;}
int ClosedStartup::advance()noexcept{
 if(!impl_)return -ENOMEM;
 aclpci_fence_io io[4];
 for(unsigned i=0;i<4;++i)io[i]={&impl_->windows[i],Impl::read,Impl::write,Impl::flush};
 return aclpci_startup_closed_step(&impl_->request,&io[0],&io[1],&io[2],&io[3]);
}
}
