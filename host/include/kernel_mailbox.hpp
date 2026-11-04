#pragma once
#include <cstdint>

namespace asus::a10::mailbox {
enum class Outcome { Completed, NotIssued, Unknown };
struct Reply { Outcome outcome; std::uint32_t value{0}; };
// Caller owns an exclusively held, verified image/mapping and common-reset
// epoch for this object's entire lifetime. No raw-device discovery/admission.
// Completed writes may be posted; fence MUST prove all preceding writes have
// reached the mailbox, in order, before returning Completed. Reads are fresh,
// ordered, full-width transactions. Unknown must never be retried underneath.
class Port {
 public:
  virtual ~Port() = default;
  virtual Reply write32(std::uint64_t address, std::uint32_t value) noexcept = 0;
  virtual Reply read32(std::uint64_t address) noexcept = 0;
  virtual Reply fence() noexcept = 0;
};
enum class State { Idle, Pending, Completed, NotIssued, Poisoned };
// Externally serialized, non-reentrant. Each advance performs at most ONE I/O;
// Pending at status requires a subsequent device/event-driven service call.
// There is no polling thread, reset recovery or automatic retry. A poisoned
// instance retains uncertainty; constructing another does not retire that debt.
class Sequencer final {
 public:
  Sequencer(Port& port, std::uint64_t base);
  Sequencer(const Sequencer&) = delete;
  Sequencer& operator=(const Sequencer&) = delete;
  bool begin(std::uint64_t id, std::uint32_t target, bool read,
             std::uint64_t data = 0, std::uint8_t mask = 255) noexcept;
  State advance() noexcept;
  State state() const noexcept { return state_; }
  std::uint64_t value() const noexcept { return value_; }
  std::uint64_t id() const noexcept { return last_id_; }
 private:
  enum class Step { Check, Target, Low, High, Mask, Before, Command, After,
                    Status, ResultLow, ResultHigh };
  Port& port_;
  const std::uint64_t base_;
  State state_{State::Idle};
  Step step_{Step::Check};
  std::uint64_t last_id_{0}, data_{0}, value_{0};
  std::uint32_t target_{0};
  std::uint8_t mask_{255};
  bool read_{false}, command_issued_{false};
};
}
