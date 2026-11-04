#pragma once
namespace asus::a10 {
// Owns only its epoll/eventfd descriptors; borrows the qualified driver FD.
// arm() after each submission (including the second leg of a staged copy).
// One waiter thread; caller serializes arm/disarm and operation service.
// interrupt() may run on another thread. Join the waiter before destruction.
// Events, interruptions and errors never release DMA buffers: read the exact
// generation receipt. Retain pending operations when shutting down the waiter.
class AclPciDmaEvents {
 public:
  enum class Event { CompletionReady, Interrupted, Error };
  explicit AclPciDmaEvents(int driver_fd) noexcept;
  ~AclPciDmaEvents();
  AclPciDmaEvents(const AclPciDmaEvents&)=delete;
  AclPciDmaEvents& operator=(const AclPciDmaEvents&)=delete;
  bool valid() const noexcept { return epoll_>=0 && wake_>=0; }
  bool arm() noexcept;
  bool disarm() noexcept;
  bool interrupt() noexcept;
  Event wait() noexcept; // native indefinite blocking wait, no status sampling
 private:
  int driver_,epoll_{-1},wake_{-1};bool registered_{false};
};
}
