#include "Vkernel_ddr_adapter.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <iostream>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>

#ifndef TEST_CMD_DEPTH
#define TEST_CMD_DEPTH 4
#endif
#ifndef TEST_READ_DEPTH
#define TEST_READ_DEPTH 8
#endif

// Verilator 4.028 calls this symbol when an enabled assertion prints $time.
static uint64_t simulation_time = 0;
double sc_time_stamp() { return static_cast<double>(simulation_time); }

// The scoreboard observes interfaces only. No DUT FIFO/counter/pointer is read.
// Its memory changes at actual DDR write acceptance, and read snapshots are
// taken at actual DDR read acceptance. Returned words are checked against those
// snapshots and the sequence of actual upstream read acceptances.
namespace {
const unsigned CD = TEST_CMD_DEPTH, RD = TEST_READ_DEPTH;
const uint64_t APERTURE = uint64_t(1) << 31;
using Line = std::array<uint8_t, 64>;

struct Request {
    bool read = false, write = false, burst = true;
    uint64_t address = 0, data = 0;
    uint8_t be = 0xff;
    bool active() const { return read || write; }
};
Request rd(uint64_t a, uint8_t be = 0xff) {
    Request r; r.read = true; r.address = a; r.be = be;
    r.data = 0x6a09e667f3bcc909ULL ^ a; return r;
}
Request wr(uint64_t a, uint64_t data, uint8_t be = 0xff) {
    Request r; r.write = true; r.address = a; r.data = data; r.be = be;
    return r;
}
struct Cycle {
    Request request;
    bool ready = true, stall = false, quiesce = false;
    bool respond = true, zero = false, response_error = false;
    bool stray = false, init_fail = false, ecc_irq = false;
};
struct Offer {
    bool read = false, write = false, burst = false;
    uint32_t address = 0;
    uint64_t be = 0;
    Line data{};
    bool active() const { return read || write; }
    bool operator==(const Offer &b) const {
        return read == b.read && write == b.write && burst == b.burst &&
               address == b.address && be == b.be && data == b.data;
    }
};
struct Reply { uint64_t address = 0; Line data{}; };
struct Result { bool upstream = false, downstream = false, response = false; };
struct Totals {
    uint64_t cycles = 0, upstream = 0, downstream = 0, reads = 0,
             writes = 0, responses = 0, simultaneous_commands = 0,
             simultaneous_read_credit = 0, zero_latency = 0, stalls = 0,
             cold_reset_commands = 0, cold_reset_reads = 0;
} total;

class Bench {
    Vkernel_ddr_adapter d;
    std::deque<Request> commands, owners;
    std::deque<Reply> replies;
    std::unordered_map<uint64_t, uint8_t> memory;
    bool was_stalled = false, seen_ready = false, expected_fault = false;
    Offer held;
    unsigned expected_code = 0;
    uint64_t first_address = 0, cycle = 0;
    bool first_address_valid = false;

    void check(bool ok, const std::string &msg) const {
        if (!ok) {
            std::ostringstream s;
            s << "cycle " << cycle << " (CMD_DEPTH=" << CD
              << ", READ_DEPTH=" << RD << "): " << msg;
            throw std::runtime_error(s.str());
        }
    }
    Offer offer() const {
        Offer o; o.read = d.d_read; o.write = d.d_write;
        o.address = d.d_address; o.be = d.d_byteenable;
        o.burst = d.d_burstcount;
        for (unsigned i = 0; i < 64; ++i)
            o.data[i] = uint8_t(d.d_writedata[i / 4] >> (8 * (i % 4)));
        return o;
    }
    Offer mapped(const Request &r) const {
        Offer o; o.read = r.read; o.write = r.write; o.burst = r.burst;
        o.address = uint32_t(r.address / 64);
        unsigned offset = unsigned(r.address % 64);
        o.be = uint64_t(r.be) << offset;
        for (unsigned i = 0; i < 8; ++i)
            o.data[offset + i] = uint8_t(r.data >> (8 * i));
        return o;
    }
    Line loadLine(uint64_t address) const {
        Line l{}; uint64_t base = address & ~uint64_t(63);
        for (unsigned i = 0; i < 64; ++i) {
            auto it = memory.find(base + i);
            if (it != memory.end()) l[i] = it->second;
        }
        return l;
    }
    void driveLine(const Line &l) {
        for (unsigned w = 0; w < 16; ++w) {
            uint32_t v = 0;
            for (unsigned b = 0; b < 4; ++b)
                v |= uint32_t(l[4 * w + b]) << (8 * b);
            d.d_readdata[w] = v;
        }
    }
    static uint64_t word(const Line &l, uint64_t address) {
        uint64_t v = 0; unsigned offset = unsigned(address % 64);
        for (unsigned b = 0; b < 8; ++b)
            v |= uint64_t(l[offset + b]) << (8 * b);
        return v;
    }
public:
    Bench() { reset(); }
    ~Bench() { d.final(); }
    void reset() {
        // This operation resets BOTH the adapter and its environment. The
        // kernel drops its request and the backend discards pending responses.
        // It deliberately does not pretend a core-only reset is recoverable.
        total.cold_reset_commands += commands.size();
        total.cold_reset_reads += owners.size();
        commands.clear(); owners.clear(); replies.clear(); memory.clear();
        was_stalled = false; seen_ready = false; expected_fault = false;
        expected_code = 0; first_address = 0; first_address_valid = false;
        d.clk = 0; d.cold_reset_n = 0; d.memory_ready = 0;
        d.backend_init_failed = 0; d.backend_ecc_interrupt = 0;
        d.quiesce_req = 0; d.k_read = 0; d.k_write = 0; d.k_address = 0;
        d.k_writedata = 0; d.k_byteenable = 0; d.k_burstcount = 1;
        d.d_waitrequest = 1; d.d_readdatavalid = 0;
        d.d_readdataerror = 0; driveLine(Line{}); d.eval();
        for (unsigned n = 0; n < 2; ++n) {
            simulation_time += 2;
            d.clk = 1; d.eval(); d.clk = 0; d.eval();
        }
        check(!d.d_read && !d.d_write && !d.k_readdatavalid,
              "traffic escaped cold reset");
        check(d.k_waitrequest && !d.drained, "reset status contract");
        d.cold_reset_n = 1; d.eval();
        check(d.drained && !d.fault, "coordinated reset did not clear ownership");
    }
    void preload(uint64_t a, uint64_t value) {
        for (unsigned b = 0; b < 8; ++b) memory[a + b] = uint8_t(value >> (8 * b));
    }
    bool empty() const { return commands.empty() && owners.empty() && replies.empty(); }
    unsigned pending() const { return unsigned(owners.size()); }
    bool fault() const { return d.fault; }
    unsigned code() const { return d.fault_code; }
    void require(bool x, const std::string &message) const { check(x, message); }

    Result tick(const Cycle &c = Cycle{}) {
        ++cycle; ++total.cycles; simulation_time += 2;
        d.clk = 0; d.cold_reset_n = 1;
        d.memory_ready = c.ready; d.backend_init_failed = c.init_fail;
        d.backend_ecc_interrupt = c.ecc_irq; d.quiesce_req = c.quiesce;
        d.k_read = c.request.read; d.k_write = c.request.write;
        d.k_address = c.request.address; d.k_writedata = c.request.data;
        d.k_byteenable = c.request.be; d.k_burstcount = c.request.burst;
        d.d_waitrequest = c.stall; d.d_readdatavalid = 0;
        d.d_readdataerror = 0; driveLine(Line{}); d.eval();
        Offer before = offer();
        bool down = before.active() && !c.stall;
        bool send = false, owned = false, zero = false;
        Reply response;
        if (c.stray) {
            check(replies.empty() && !(down && before.read),
                  "test attempted stray response while an owner existed");
            send = true; response.data.fill(0xa5);
        } else if (c.respond && !replies.empty()) {
            send = owned = true; response = replies.front();
        } else if (c.respond && c.zero && replies.empty() && down && before.read) {
            check(!commands.empty(), "zero-latency response has no upstream request");
            send = owned = zero = true;
            response.address = commands.front().address;
            response.data = loadLine(response.address);
        }
        d.d_readdatavalid = send; d.d_readdataerror = send && c.response_error;
        driveLine(response.data); d.eval();
        Offer o = offer();
        check(o == before, "DDR offer changed combinationally when response arrived");
        check(!o.read || !o.write, "simultaneous downstream read/write");
        if (was_stalled) check(o == held, "stalled DDR command was withdrawn or changed");
        if (o.active()) {
            check(!commands.empty(), "DDR offered an unaccepted upstream command");
            check(o == mapped(commands.front()), "lane/address/data/BE/order mapping mismatch");
        }
        check(bool(d.drained) == empty(), "drained disagrees with actual interface obligations");
        check(!d.k_writeack, "unused writeack must remain zero");

        unsigned malformed = 0;
        if (c.request.active()) {
            if (c.request.read && c.request.write) malformed |= 1;
            if (!c.request.burst) malformed |= 2;
            if (c.request.address % 8) malformed |= 4;
            if (c.request.address >= APERTURE) malformed |= 8;
        }
        unsigned live = malformed;
        if (c.init_fail || (seen_ready && !c.ready)) live |= 0x10;
        if (c.ecc_irq || (send && c.response_error)) live |= 0x20;
        if (send && !owned) live |= 0x40;
        check(bool(d.quiescing) == (c.quiesce || expected_fault || live != 0),
              "quiescing did not include current fault/admission stop");
        bool up = c.request.active() && !d.k_waitrequest;
        bool capacity = commands.size() - unsigned(down) < CD &&
            (!c.request.read || owners.size() - unsigned(owned) < RD);
        bool mayAccept = c.request.active() && c.ready && !c.quiesce &&
            !expected_fault && live == 0 && capacity;
        check(up == mayAccept, "upstream capacity/admission contract mismatch");
        check(bool(d.k_readdatavalid) == owned, "fabricated, missing, or gated read completion");
        if (owned) {
            check(!owners.empty(), "response did not correspond to accepted kernel read");
            check(owners.front().address == response.address, "read ownership/order mismatch");
            check(d.k_readdata == word(response.data, owners.front().address),
                  "returned word differs from accepted DDR read snapshot");
        }
        if (!expected_fault && live != 0) {
            if (owned && c.response_error) {
                first_address = owners.front().address; first_address_valid = true;
            } else if (malformed) {
                first_address = c.request.address; first_address_valid = true;
            }
        }
        expected_fault = expected_fault || live != 0; expected_code |= live;
        seen_ready = seen_ready || c.ready;

        if (down) {
            Request r = commands.front(); commands.pop_front(); ++total.downstream;
            if (r.read) {
                Reply p; p.address = r.address; p.data = loadLine(r.address);
                replies.push_back(p);
            } else {
                for (unsigned b = 0; b < 8; ++b)
                    if ((r.be >> b) & 1) memory[r.address + b] = uint8_t(r.data >> (8 * b));
            }
        }
        if (owned) {
            check(!replies.empty() && replies.front().address == response.address &&
                  replies.front().data == response.data, "backend response selection mismatch");
            replies.pop_front(); owners.pop_front(); ++total.responses;
            if (zero) ++total.zero_latency;
        }
        if (up) {
            commands.push_back(c.request); ++total.upstream;
            if (c.request.read) { owners.push_back(c.request); ++total.reads; }
            else ++total.writes;
        }
        if (up && down) ++total.simultaneous_commands;
        if (up && c.request.read && owned) ++total.simultaneous_read_credit;
        check(commands.size() <= CD && owners.size() <= RD, "finite capacity exceeded");
        check(replies.size() <= owners.size(), "issued reads exceed ownership");
        was_stalled = o.active() && c.stall; held = o;
        if (was_stalled) ++total.stalls;
        d.clk = 1; d.eval();
        check(bool(d.fault) == expected_fault && d.fault_code == expected_code,
              "sticky diagnostic bits mismatch");
        check(bool(d.fault_address_valid) == first_address_valid &&
              d.fault_address == first_address, "first fault address changed or is wrong");
        d.clk = 0; d.d_readdatavalid = 0; d.d_readdataerror = 0; d.eval();
        check(bool(d.drained) == empty(), "post-edge drained released outstanding work");
        check(!Verilated::gotFinish(), "RTL assertion terminated simulation");
        Result r; r.upstream = up; r.downstream = down; r.response = owned; return r;
    }

    void submit(const Request &request, bool respond = true, bool zero = false) {
        Cycle c; c.request = request; c.respond = respond; c.zero = zero;
        for (unsigned i = 0; i < 10000; ++i) if (tick(c).upstream) return;
        throw std::runtime_error("submit timed out");
    }
    void drain(bool quiesce = true, const Request &heldRequest = Request{}) {
        Cycle c; c.quiesce = quiesce; c.request = heldRequest; c.zero = true;
        for (unsigned i = 0; i < 10000 && !empty(); ++i) tick(c);
        check(empty(), "drain timed out despite ready, accepting backend and responses");
        for (unsigned i = 0; i < 3; ++i) tick(c);
    }
};

void basicAndBytes() {
    Bench b;
    Cycle c; c.ready = false; c.request = rd(0x18);
    for (unsigned i = 0; i < 6; ++i) b.require(!b.tick(c).upstream && !b.fault(), "initial scrub admission");
    c.ready = true; b.require(b.tick(c).upstream, "first ready request not accepted"); b.drain();
    for (unsigned lane = 0; lane < 8; ++lane)
        b.preload(0x100 + 8 * lane, 0x1020304050607080ULL ^ (uint64_t(lane) * 0x1111111111111111ULL));
    for (unsigned mask = 0; mask < 256; ++mask) {
        uint64_t a = 0x100 + 8 * (mask % 8);
        b.submit(wr(a, 0xdeadbeef98765432ULL ^ (uint64_t(mask) << 37), uint8_t(mask)));
        b.submit(rd(a, uint8_t(255 - mask)));
    }
    b.submit(wr(APERTURE - 8, 0x8070605040302010ULL));
    b.submit(rd(APERTURE - 8)); b.drain();
    b.require(!b.fault(), "legal aperture edge faulted");
}

void capacityAndWrap() {
    Bench b;
    Cycle c; c.stall = true; c.respond = false;
    for (unsigned i = 0; i < CD; ++i) {
        c.request = wr(8 * i, 0xcafe0000ULL + i);
        b.require(b.tick(c).upstream, "command FIFO could not fill");
    }
    c.request = wr(0x80, 0x55);
    for (unsigned i = 0; i < 3; ++i) b.require(!b.tick(c).upstream, "full command FIFO accepted without pop");
    c.stall = false;
    Result x = b.tick(c); b.require(x.upstream && x.downstream, "full command push/pop lost throughput");
    b.drain();
    for (unsigned round = 0; round < 7; ++round) {
        for (unsigned i = 0; i < RD; ++i) b.submit(rd(8 * ((i + round) % 8)), false);
        Cycle idle; idle.respond = false;
        for (unsigned i = 0; i < CD + 2; ++i) b.tick(idle);
        b.require(b.pending() == RD, "read ownership did not reach capacity");
        Cycle blocked; blocked.respond = false; blocked.request = rd(0x138 + 64 * round);
        b.require(!b.tick(blocked).upstream, "full read owner queue accepted without completion");
        blocked.respond = true;
        x = b.tick(blocked);
        b.require(x.upstream && x.response, "full read credit pop/push lost throughput");
        b.drain();
    }
}

void zeroLatency() {
    Bench b;
    uint64_t start = total.zero_latency;
    for (unsigned i = 0; i < 32; ++i) {
        uint64_t a = (i % 8) * 8;
        b.preload(a, 0x123456789abcdef0ULL ^ i);
        b.submit(rd(a), false);
        Cycle c; c.zero = true;
        Result r = b.tick(c);
        b.require(r.downstream && r.response, "same-cycle DDR acceptance/response failed");
    }
    b.drain(); b.require(total.zero_latency - start == 32, "zero-latency coverage missing");
}

void randomTraffic() {
    Bench b; std::mt19937_64 rng(0xf9c7bf2d3eab4471ULL ^ (uint64_t(CD) << 32) ^ RD);
    Request active;
    for (unsigned i = 0; i < 12000; ++i) {
        if (!active.active() && (rng() % 5)) {
            uint64_t a = (rng() % 128) * 8;
            if ((rng() & 31) == 0) a = APERTURE - 8;
            active = (rng() & 1) ? rd(a, uint8_t(rng())) : wr(a, rng(), uint8_t(rng()));
        }
        Cycle c; c.request = active; c.stall = rng() % 100 < 39;
        c.respond = rng() % 100 < 63; c.zero = rng() % 100 < 31;
        if (b.tick(c).upstream) active = Request{};
    }
    if (active.active()) b.submit(active);
    b.drain(); b.require(!b.fault(), "legal randomized traffic faulted");
}

void quiescePending() {
    Bench b;
    for (unsigned i = 0; i < RD; ++i) b.submit(rd(8 * (i % 8)), false);
    Cycle c; c.quiesce = true; c.respond = false; c.request = wr(0x200, 0x55);
    for (unsigned i = 0; i < CD + 2; ++i)
        b.require(!b.tick(c).upstream && !b.empty(), "quiesce discarded a pending read");
    b.drain(true, c.request);
    b.require(!b.fault(), "ordinary quiesce latched fault");
    c.quiesce = false; c.respond = true;
    b.require(b.tick(c).upstream, "quiesce release did not resume admission"); b.drain();
}

void readyLossWhileStalled() {
    Bench b;
    b.submit(rd(0x38), false);
    Cycle c; c.stall = true; c.respond = false; c.request = wr(0x180, 0x0123456789abcdefULL, 0xa5);
    if (b.tick(c).upstream) c.request = Request{};
    c.ready = false;
    for (unsigned i = 0; i < 3; ++i) b.require(!b.tick(c).upstream, "ready loss admitted work");
    b.require(b.code() == 0x10, "ready loss not diagnosed");
    c.stall = false;
    b.require(b.tick(c).downstream, "stalled offer was suppressed when readiness fell");
    c.respond = true;
    b.require(b.tick(c).response, "response was suppressed after readiness fault");
    for (unsigned i = 0; i < 2; ++i) b.tick(c);
    c.ready = true;
    while (!b.empty()) b.tick(c);
    for (unsigned i = 0; i < 3; ++i) b.require(!b.tick(c).upstream, "fault silently recovered when ready returned");
}

void faultAndResponses() {
    Bench b;
    unsigned n = std::min<unsigned>(RD, 3);
    for (unsigned i = 0; i < n; ++i) b.submit(rd(0x300 + 8 * i), false);
    Cycle idle; idle.respond = false;
    for (unsigned i = 0; i < CD + 1; ++i) b.tick(idle);
    Cycle c; c.request = wr(0x500, 7); c.response_error = true;
    Result r = b.tick(c);
    b.require(r.response && !r.upstream && b.code() == 0x20, "ECC response did not return and stop success admission");
    c.response_error = false; c.ecc_irq = true;
    while (!b.empty()) b.tick(c);
    b.tick(c); b.require(b.code() == 0x20, "ECC sticky fault lost");
    // All tags were retired from real responses; fault remains after drain.
    b.require(b.empty() && b.fault(), "drain incorrectly cleared a fault");
}

void faultWhileWriteStalled() {
    Bench b;
    b.submit(wr(0x218, 0x3141592653589793ULL, 0x69), false);
    Cycle c; c.stall = true; c.respond = false; c.request = rd(0x218);
    if (b.tick(c).upstream) c.request = Request{};
    c.ecc_irq = true;
    for (unsigned i = 0; i < 3; ++i) b.tick(c);
    b.require(b.code() == 0x20 && !b.empty(), "fault canceled buffered/stalled write");
    c.stall = false; c.respond = true;
    while (!b.empty()) b.tick(c);
    b.require(b.fault(), "write drain incorrectly cleared platform fault");
}

void malformedAndBackendFaults() {
    Request cases[] = {rd(0x40), rd(0x48), rd(0x51), rd(APERTURE), rd((uint64_t(1) << 34) + 0x78)};
    cases[0].write = true; cases[1].burst = false;
    const unsigned expected[] = {1, 2, 4, 8, 8};
    for (unsigned i = 0; i < 5; ++i) {
        Bench b; b.submit(rd(0x98), false);
        Cycle c; c.request = cases[i]; c.respond = false;
        b.require(!b.tick(c).upstream && b.code() == expected[i], "malformed request accepted or wrong fault");
        b.drain(true, cases[i]);
        b.require(b.fault(), "malformed fault cleared after pending response");
    }
    { Bench b; Cycle c; c.ready = false; c.init_fail = true; b.tick(c);
      b.require(b.code() == 0x10, "initialization failure not reported"); }
    { Bench b; b.submit(rd(0), false); Cycle c; c.respond = false; c.ecc_irq = true;
      b.tick(c); b.drain(); b.require(b.code() == 0x20, "ECC interrupt lost while response pending"); }
    { Bench b; Cycle c; c.stray = true; b.tick(c);
      b.require(b.code() == 0x40 && b.empty(), "unowned response fabricated completion");
      c.response_error = true; b.tick(c);
      b.require(b.code() == 0x60, "later ECC fault did not accumulate"); }
    { Bench b; b.submit(rd(0x278), false); Cycle idle; idle.respond = false; b.tick(idle);
      Cycle c; c.request = rd(APERTURE + 1); c.response_error = true;
      b.tick(c); b.require(b.code() == 0x2c, "simultaneous fault bits did not accumulate");
      b.drain(true, c.request); } // Owned ECC response has first-address priority.
}

void coordinatedReset() {
    Bench b;
    b.submit(rd(0x20), false);
    Cycle c; c.respond = false; b.tick(c);
    b.require(!b.empty(), "reset scenario did not create accepted outstanding work");
    b.reset();  // backend and kernel reset together, no old response survives.
    b.submit(wr(0x40, 0xdecafbadfeed1234ULL)); b.submit(rd(0x40)); b.drain();
    b.require(!b.fault(), "coordinated reset left stale ownership");
}

void reservedIsNotIssued() {
    Bench b;
    b.submit(rd(0x168), false); // Owns a tag, but DDR has never accepted it.
    Cycle c; c.stall = true; c.stray = true;
    Result r = b.tick(c);
    b.require(!r.response && !r.downstream && b.pending() == 1 && b.code() == 0x40,
              "reserved-only tag was mistaken for a DDR-issued response owner");
    c.stray = false; c.stall = false; c.respond = false;
    b.require(b.tick(c).downstream, "accepted read did not dispatch after stray-response fault");
    c.respond = true;
    b.require(b.tick(c).response, "real later response lost its reserved owner"); b.drain();

    Bench fresh;
    Cycle first; first.request = rd(0x238); first.stray = true;
    r = fresh.tick(first);
    fresh.require(!r.upstream && !r.response && fresh.empty() && fresh.code() == 0x40,
                  "first upstream request incorrectly authorized an unsolicited DDR response");
}
} // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    try {
        if (!CD || !RD) throw std::runtime_error("positive queue capacities required");
        basicAndBytes(); capacityAndWrap(); zeroLatency(); randomTraffic();
        quiescePending(); readyLossWhileStalled(); faultAndResponses(); faultWhileWriteStalled();
        malformedAndBackendFaults(); coordinatedReset(); reservedIsNotIssued();
        if (!total.simultaneous_commands || !total.simultaneous_read_credit ||
            !total.zero_latency || !total.stalls)
            throw std::runtime_error("required pipeline coverage was not exercised");
        if (total.reads != total.responses + total.cold_reset_reads ||
            total.upstream != total.downstream + total.cold_reset_commands)
            throw std::runtime_error("accepted work was lost outside coordinated cold reset");
        std::cout << "PASS CMD_DEPTH=" << CD << " READ_DEPTH=" << RD
                  << " cycles=" << total.cycles << " upstream=" << total.upstream
                  << " downstream=" << total.downstream << " reads=" << total.reads
                  << " writes=" << total.writes << " responses=" << total.responses
                  << " cmd_push_pop=" << total.simultaneous_commands
                  << " read_push_pop=" << total.simultaneous_read_credit
                  << " zero_latency=" << total.zero_latency
                  << " stalled_cycles=" << total.stalls
                  << " cold_reset_cancelled_reads=" << total.cold_reset_reads << '\n';
        std::cout << "Reset test coordinates kernel/backend/adapter; core-only reset is unsupported.\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "FAIL: " << e.what() << '\n'; return 1;
    }
}
