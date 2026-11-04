#pragma once
#include "kernel_mailbox.hpp"
#include "ddr_traffic_metrics.hpp"
namespace asus::a10::metrics {
enum class CaptureState { Pending, Complete, Rejected, Poisoned };
// The caller holds a qualified mapping and immutable common-reset context.
// This reader adds no admission authority and never retries an uncertain I/O.
class Capture final {
 public:
  Capture(mailbox::Port&,std::uint64_t base,std::array<std::uint64_t,4> context) noexcept;
  Capture(const Capture&)=delete;Capture& operator=(const Capture&)=delete;
  CaptureState advance() noexcept; // at most one I/O, externally serviced
  CaptureState state()const noexcept{return state_;}
  std::optional<Snapshot> snapshot()const noexcept{return state_==CaptureState::Complete?std::optional<Snapshot>{sample_}:std::nullopt;}
 private:
  enum class Step { Magic, Command, Fence, BeforeHi, BeforeLo, BeforeCheck,
                    Flags, Counts, AfterHi, AfterLo, AfterCheck };
  mailbox::Port& port_;std::uint64_t base_,before_{0},after_{0};
  Step step_{Step::Magic};CaptureState state_{CaptureState::Pending};
  unsigned word_{0};Snapshot sample_{};
};
}
