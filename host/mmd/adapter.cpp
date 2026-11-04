#include "adapter.hpp"
#include <cstring>
#include <limits>
#include <mutex>
#include <unordered_map>

namespace asus::a10::mmd {
namespace {
constexpr int error = -1;
struct Pending {
  std::vector<unsigned char> bytes;
  void* destination{};
  aocl_mmd_op_t token{};
  aocl_mmd_status_handler_fn handler{};
  void* user{};
};
struct Device {
  std::mutex mutex;
  std::shared_ptr<Transport> transport;
  std::unordered_map<dma::LeaseId, std::shared_ptr<Pending>> pending;
  std::unordered_map<aocl_mmd_op_t, dma::LeaseId> tokens;
  dma::LeaseId next{1};
  unsigned calls{};
  bool closing{};
  aocl_mmd_status_handler_fn handler{};
  void* user{};
  dma::OperationLifecycle life;
  static void memory(void* context, const dma::MemoryAction& action) noexcept {
    if (action.kind != dma::MemoryActionKind::ReleaseSafe) return;
    auto& d = *static_cast<Device*>(context);
    std::lock_guard<std::mutex> lock(d.mutex);
    auto it = d.pending.find(action.lease);
    if (it != d.pending.end()) {
      auto token = d.tokens.find(it->second->token);
      if (token != d.tokens.end() && token->second == action.lease) d.tokens.erase(token);
      d.pending.erase(it);
    }
  }
  static void status(int h, void* context, aocl_mmd_op_t token, int s) {
    auto& d = *static_cast<Device*>(context);
    auto& p = *static_cast<Pending*>(token);
    {
      std::lock_guard<std::mutex> lock(d.mutex);
      d.tokens.erase(p.token);
    }
    if (s == 0 && p.destination && !p.bytes.empty())
      std::memcpy(p.destination, p.bytes.data(), p.bytes.size());
    p.handler(h, p.user, p.token, s);
  }
  Device(int h, std::shared_ptr<Transport> t)
      : transport(std::move(t)), life(h, {memory, this, nullptr, nullptr}) {
    life.set_status_handler(status, this);
  }
};
struct Registry {
  std::mutex mutex;
  std::shared_ptr<Backend> backend;
  std::unordered_map<int, std::shared_ptr<Device>> devices;
  std::vector<std::shared_ptr<Transport>> quarantined;
  int next{};
};
// Unresolved hardware ownership must survive process-static destruction order.
Registry& registry() { static auto* r = new Registry; return *r; }
struct Call {
  std::shared_ptr<Device> d;
  explicit Call(int h) {
    auto& r = registry();
    std::lock_guard<std::mutex> lock(r.mutex);
    auto it = r.devices.find(h);
    if (it == r.devices.end()) return;
    std::lock_guard<std::mutex> dl(it->second->mutex);
    if (it->second->closing) return;
    d = it->second;
    ++d->calls;
  }
  ~Call() { if (d) { std::lock_guard<std::mutex> lock(d->mutex); --d->calls; } }
};
int value(const void* data, size_t len, size_t capacity, void* out, size_t* size) {
  if (size) *size = len;
  if (!out) return capacity == 0 ? 0 : error;
  if (capacity < len) return error;
  std::memcpy(out, data, len);
  return 0;
}
int transfer(int h, aocl_mmd_op_t token, size_t len, void* dst,
             const void* src, int iface, size_t from, size_t to, Kind kind) {
  Call call(h);
  if (!call.d || (len && ((kind == Kind::Read && !dst) ||
      (kind == Kind::Write && !src))) || len > SIZE_MAX-from || len > SIZE_MAX-to)
    return error;
  auto d = call.d;
  auto p = std::make_shared<Pending>();
  if (kind != Kind::Copy) p->bytes.resize(len);
  p->destination = dst; p->token = token;
  if (kind == Kind::Write && len) std::memcpy(p->bytes.data(), src, len);
  dma::BeginResult begin;
  dma::LeaseId lease;
  {
    std::lock_guard<std::mutex> lock(d->mutex);
    if ((token && (!d->handler || d->tokens.count(token))) || d->next == UINT64_MAX)
      return error;
    lease = d->next++;
    p->handler = d->handler; p->user = d->user;
    d->pending.emplace(lease, p);
    try {
      if (token) d->tokens.emplace(token, lease);
      begin = d->life.begin(token ? p.get() : nullptr, lease, dma::BufferOwner::DriverOwned);
    } catch (...) {
      d->pending.erase(lease); if (token) d->tokens.erase(token); throw;
    }
    if (!begin.prepared() && !begin.blocking()) {
      d->pending.erase(lease); if (token) d->tokens.erase(token); return error;
    }
  }
  Request req{kind, iface, len, from, to, p->bytes.data(), begin.ticket};
  if (!token) {
    const int s = d->transport->blocking(req);
    if (s == 0 && dst && len) std::memcpy(dst, p->bytes.data(), len);
    (void)d->life.finish_blocking(begin.ticket);
    return s <= 0 ? s : error;
  }
  Submission result = Submission::Indeterminate;
  try {
    // Weak capture avoids a backend/device cycle; registry retains unresolved debt.
    std::weak_ptr<Device> weak = d;
    result = d->transport->submit(req, [weak](dma::Ticket ticket, int s, dma::DrainEvidence drain) {
      if (auto device = weak.lock()) {
        try { (void)device->life.complete(ticket, s, drain); } catch (...) { /* retain debt */ }
      }
    });
  } catch (...) { /* uncertain acceptance retains adapter-owned staging */ }
  if (result == Submission::Accepted) {
    // Hardware accepted: even allocation failure must not tell the caller it
    // may reuse a read destination. Retain debt if dispatch allocation fails.
    try { (void)d->life.accept(begin.ticket); } catch (...) { /* retain debt */ }
    return 0;
  }
  if (result == Submission::NotAccepted) (void)d->life.reject_not_accepted(begin.ticket);
  else (void)d->life.reject_indeterminate(begin.ticket);
  return error;
}
}
bool flush_ready(int h) {
  Call c(h); if (!c.d) return false; c.d->life.flush_ready(); return true;
}
bool install_backend(std::shared_ptr<Backend> backend) {
  auto& r = registry(); std::lock_guard<std::mutex> lock(r.mutex);
  if (!r.devices.empty() || !r.quarantined.empty()) return false;
  r.backend = std::move(backend); return true;
}
}
using namespace asus::a10::mmd;
#define MMD_TRY try
#define MMD_CATCH catch (...) { return -1; }
extern "C" {
int aocl_mmd_get_offline_info(aocl_mmd_offline_info_t id, size_t n, void* out, size_t* size) MMD_TRY {
  std::shared_ptr<Backend> backend;
  { auto& r = registry(); std::lock_guard<std::mutex> lock(r.mutex); backend = r.backend; }
  std::string text;
  int number = 0;
  switch (id) {
    case AOCL_MMD_VERSION: text = AOCL_MMD_VERSION_STRING; break;
    case AOCL_MMD_VENDOR_NAME: text = "Arria10 project transport adapter"; break;
    case AOCL_MMD_USES_YIELD: number = 1; return value(&number, sizeof(number), n, out, size);
    case AOCL_MMD_NUM_BOARDS:
    case AOCL_MMD_BOARD_NAMES: {
      auto names = backend ? backend->discover() : std::vector<std::string>{};
      if (names.size() > static_cast<size_t>(INT32_MAX)) return -1;
      for (const auto& name : names) {
        if (name.empty() || name.find(';') != std::string::npos || name.find('\0') != std::string::npos) return -1;
        if (!text.empty()) text += ';';
        text += name;
      }
      if (id == AOCL_MMD_NUM_BOARDS) {
        number = static_cast<int>(names.size()); return value(&number, sizeof(number), n, out, size);
      }
      break;
    }
    default: return backend ? backend->offline_info(id,n,out,size) : -1;
  }
  return value(text.c_str(), text.size()+1, n, out, size);
} MMD_CATCH
int aocl_mmd_open(const char* name) MMD_TRY {
  if (!name || !*name) return -1;
  auto& r = registry(); std::lock_guard<std::mutex> lock(r.mutex);
  if (!r.backend || r.next == INT32_MAX) return -1;
  r.quarantined.reserve(r.quarantined.size()+1);
  auto t = r.backend->open(name);
  if (!t) return -1;
  // Keep an owner before inspecting/closing an unqualified transport.
  r.quarantined.push_back(t);
  if (!t->qualified_and_owned()) {
    if (t->close() == 0) r.quarantined.pop_back();
    return -1;
  }
  int h = r.next++;
  try { r.devices.emplace(h, std::make_shared<Device>(h, t)); }
  catch (...) { if (t->close() == 0) r.quarantined.pop_back(); throw; }
  r.quarantined.pop_back();
  return h;
} MMD_CATCH
int aocl_mmd_get_info(int h, aocl_mmd_info_t id, size_t n, void* out, size_t* size) MMD_TRY {
  Call c(h); return c.d ? c.d->transport->info(id,n,out,size) : -1;
} MMD_CATCH
int aocl_mmd_set_status_handler(int h, aocl_mmd_status_handler_fn fn, void* user) MMD_TRY {
  Call c(h); if (!c.d) return -1;
  std::lock_guard<std::mutex> lock(c.d->mutex); c.d->handler=fn; c.d->user=user; return 0;
} MMD_CATCH
int aocl_mmd_set_interrupt_handler(int h, aocl_mmd_interrupt_handler_fn fn, void* user) MMD_TRY {
  Call c(h); return c.d ? c.d->transport->interrupt_handler(fn,user) : -1;
} MMD_CATCH
int aocl_mmd_yield(int h) MMD_TRY { Call c(h); return c.d ? c.d->transport->yield() : -1; } MMD_CATCH
int aocl_mmd_read(int h, aocl_mmd_op_t op, size_t len, void* dst, int iface, size_t offset) MMD_TRY {
  return transfer(h,op,len,dst,nullptr,iface,offset,0,Kind::Read);
} MMD_CATCH
int aocl_mmd_write(int h, aocl_mmd_op_t op, size_t len, const void* src, int iface, size_t offset) MMD_TRY {
  return transfer(h,op,len,nullptr,src,iface,0,offset,Kind::Write);
} MMD_CATCH
int aocl_mmd_copy(int h, aocl_mmd_op_t op, size_t len, int iface, size_t src, size_t dst) MMD_TRY {
  return transfer(h,op,len,nullptr,nullptr,iface,src,dst,Kind::Copy);
} MMD_CATCH
int aocl_mmd_close(int h) MMD_TRY {
  auto& r = registry();
  std::shared_ptr<Device> d;
  {
    std::lock_guard<std::mutex> lock(r.mutex);
    auto it = r.devices.find(h); if (it == r.devices.end()) return -1;
    d = it->second;
    std::lock_guard<std::mutex> dl(d->mutex);
    if (d->calls || d->closing || !d->pending.empty()) return -1;
    auto s = d->life.snapshot();
    if (s.work_in_flight || s.queued_work || s.accepted_debt || s.prepared || s.orphan_holds || s.blocking_in_flight) return -1;
    d->closing = true;
  }
  int result;
  try { result = d->transport->close(); } catch (...) { result = -1; }
  // Failed/uncertain close retains handle and custody, disables new calls.
  if (result != 0) return -1;
  if (d->life.shutdown() != asus::a10::dma::TransitionCode::Applied) return -1;
  { std::lock_guard<std::mutex> lock(r.mutex); r.devices.erase(h); }
  return 0;
} MMD_CATCH
}
