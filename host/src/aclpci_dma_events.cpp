#include "aclpci_dma_events.hpp"
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <cerrno>
#include <cstdint>
namespace asus::a10 {
AclPciDmaEvents::AclPciDmaEvents(int fd) noexcept:driver_(fd) {
 if(fd<0)return;
 epoll_=epoll_create1(EPOLL_CLOEXEC);
 if(epoll_<0)return;
 wake_=eventfd(0,EFD_CLOEXEC|EFD_NONBLOCK);
 epoll_event ev{};ev.events=EPOLLIN;ev.data.u64=2;
 if(wake_<0 || epoll_ctl(epoll_,EPOLL_CTL_ADD,wake_,&ev)<0){
  if(wake_>=0)close(wake_);
  close(epoll_);wake_=epoll_=-1;
 }
}
AclPciDmaEvents::~AclPciDmaEvents(){if(epoll_>=0)close(epoll_);if(wake_>=0)close(wake_);}
bool AclPciDmaEvents::arm() noexcept {
 if(!valid())return false;
 epoll_event ev{};ev.events=EPOLLIN|EPOLLONESHOT;ev.data.u64=1;
 if(epoll_ctl(epoll_,registered_?EPOLL_CTL_MOD:EPOLL_CTL_ADD,driver_,&ev)<0)return false;
 registered_=true;return true;
}
bool AclPciDmaEvents::disarm() noexcept {
 if(!valid())return false;
 if(!registered_)return true;
 if(epoll_ctl(epoll_,EPOLL_CTL_DEL,driver_,nullptr)<0)return false;
 registered_=false;return true;
}
bool AclPciDmaEvents::interrupt() noexcept {
 if(!valid())return false;
 std::uint64_t one=1;ssize_t n;
 do {n=write(wake_,&one,sizeof one);}while(n<0&&errno==EINTR);
 return n==sizeof one || (n<0&&errno==EAGAIN); // Already has a wake pending.
}
AclPciDmaEvents::Event AclPciDmaEvents::wait() noexcept {
 if(!valid())return Event::Error;
 epoll_event ev{};int n;
 do {n=epoll_wait(epoll_,&ev,1,-1);}while(n<0&&errno==EINTR);
 if(n!=1)return Event::Error;
 if(ev.data.u64==2){
  std::uint64_t count;ssize_t got;
  do {got=read(wake_,&count,sizeof count);}while(got<0&&errno==EINTR);
  return got==sizeof count?Event::Interrupted:Event::Error;
 }
 if(ev.data.u64==1 && (ev.events&EPOLLIN) && !(ev.events&(EPOLLERR|EPOLLHUP)))
  return Event::CompletionReady;
 return Event::Error;
}
}
