#include "aclpci_dma_events.hpp"
#include <sys/eventfd.h>
#include <unistd.h>
#include <cassert>
#include <cstdint>
#include <future>
#include <iostream>
using Events=asus::a10::AclPciDmaEvents;
int main(){
 Events invalid(-1);assert(!invalid.valid()&&!invalid.arm()&&!invalid.interrupt());
 assert(invalid.wait()==Events::Event::Error);
 int fd=eventfd(0,EFD_NONBLOCK|EFD_CLOEXEC);assert(fd>=0);
 {
  Events events(fd);assert(events.valid()&&events.arm());
  auto waiting=std::async(std::launch::async,[&]{return events.wait();});
  std::uint64_t one=1;assert(write(fd,&one,sizeof one)==sizeof one);
  assert(waiting.get()==Events::Event::CompletionReady);
  // The source stays readable. ONESHOT must suppress another completion until
  // rearmed; an explicit interrupt is the next event, without time-based tests.
  assert(events.interrupt());assert(events.wait()==Events::Event::Interrupted);
  // Register/check race: readiness predates rearm and must still be delivered.
  assert(events.arm());assert(events.wait()==Events::Event::CompletionReady);
  assert(events.disarm());assert(events.arm());assert(events.disarm());
  assert(events.interrupt());assert(events.wait()==Events::Event::Interrupted);
 }
 // Borrowed driver descriptor survives waiter destruction.
 std::uint64_t value;assert(read(fd,&value,sizeof value)==sizeof value&&value==1);close(fd);
 std::cout<<"DMA_EVENTS_PASS blocking one_shot rearm preexisting_ready interrupt borrowed_fd\n";
}
