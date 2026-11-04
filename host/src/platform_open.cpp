#include "platform_open.hpp"
#include <limits>

namespace asus::a10::control {
OpenRequest::OpenRequest(mailbox::Port& fp, std::uint64_t fb,
                         mailbox::Port& cp, std::uint64_t cb,
                         std::array<std::uint32_t,6> context,
                         std::uint64_t round, std::uint64_t id,
                         Command command) noexcept
 : fence_(fp,fb,context,round), command_(cp,cb,id,command), round_(round) {
  if (command!=Command::Start && command!=Command::Resume)
    state_=State::Poisoned;
  if (round==std::numeric_limits<std::uint64_t>::max() ||
      fence_.state()==writeback::State::Poisoned ||
      command_.state()==State::Poisoned) state_=State::Poisoned;
}
State OpenRequest::advance() noexcept {
  if (state_!=State::Pending) return state_;
  if (!fence_done_) {
    const auto result=fence_.advance();
    if (result==writeback::State::Poisoned) state_=State::Poisoned;
    if (result==writeback::State::Settled) fence_done_=true;
    return state_;
  }
  return state_=command_.advance();
}
std::optional<std::uint64_t> OpenRequest::next_round() const noexcept {
  if (state_!=State::Accepted) return std::nullopt;
  return round_+1;
}
}
