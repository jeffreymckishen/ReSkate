#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

namespace dingosdk::input_trace {
inline constexpr std::size_t ticket_capacity = 8, record_capacity = 128;
inline constexpr std::uint32_t asset_token_capacity = 64;
inline constexpr std::uint64_t duration_ms = 5000;
struct Handle { std::uint64_t sequence{}; };
enum class Lane : std::uint8_t { interpreter, alternate };
enum class Status : std::uint8_t { active, stopped, expired };
enum class Reason : std::uint8_t { none, invalid_owner, busy, capacity, clock_invalid, sequence_exhausted, unavailable };
constexpr const char* reason_name(Reason reason) noexcept {
    switch (reason) {
    case Reason::none: return "none"; case Reason::invalid_owner: return "invalid_owner";
    case Reason::busy: return "busy"; case Reason::capacity: return "capacity";
    case Reason::clock_invalid: return "clock_invalid"; case Reason::sequence_exhausted: return "sequence_exhausted";
    case Reason::unavailable: return "unavailable";
    }
    return "invalid";
}
constexpr const char* status_name(Status status) noexcept {
    switch (status) {
    case Status::active: return "active"; case Status::stopped: return "stopped"; case Status::expired: return "expired";
    }
    return "invalid";
}
constexpr bool terminal(Status status) noexcept { return status == Status::stopped || status == Status::expired; }
struct Observation {
    std::uint64_t observed_ms{};
    std::uint32_t thread_id{};
    Lane lane{};
    std::uint32_t asset_token{};
    bool condition_known{}, condition{}, local_tuple_known{}, container_matches_local{}, snapshot_stable{};
    std::uint8_t issue{};
};
struct Receipt {
    Handle handle{};
    Status status{Status::active};
    std::uint64_t requested_ms{}, expires_ms{}, seen{}, duplicates{}, dropped{};
    // The private adapter fills these service-wide counters on a copied read.
    // Their difference is not an exact count of observations missed by a ticket.
    std::uint64_t observer_busy_at_start{}, observer_busy_total{};
    std::uint32_t record_count{};
    std::array<Observation, record_capacity> records{};
};
struct Ticket { std::uint64_t owner{}, sequence{}; };
struct Snapshot {
    std::uint64_t began_ms{};
    std::uint32_t count{};
    std::array<Ticket, ticket_capacity> tickets{};
};

// Caller-serialized and allocation-free. Tickets contain VM identity and a
// never-reused sequence, never native addresses. Native pointer qualification
// and equality-token lifetime belong to the private observing adapter.
class Ledger {
public:
    explicit Ledger(std::uint64_t initial_sequence = 0) noexcept : next_(initial_sequence) {}
    bool start(std::uint64_t owner, std::uint64_t now_ms, Handle& handle, Reason& reason) noexcept;
    bool read(std::uint64_t owner, Handle handle, std::uint64_t now_ms, Receipt& receipt) noexcept;
    bool stop(std::uint64_t owner, Handle handle, std::uint64_t now_ms) noexcept;
    bool acknowledge(std::uint64_t owner, Handle handle, std::uint64_t now_ms) noexcept;
    void release_all(std::uint64_t owner) noexcept;
    Snapshot begin(std::uint64_t now_ms) noexcept;
    std::uint32_t finish(const Snapshot& snapshot, const Observation& observation, std::uint64_t now_ms) noexcept;
private:
    struct Entry { std::uint64_t owner{}; Receipt receipt{}; bool occupied{}; };
    std::array<Entry, ticket_capacity> entries_{};
    std::uint64_t next_{}, last_ms_{};
    bool clock_known_{};
    bool advance(std::uint64_t now_ms) noexcept;
    Entry* find(std::uint64_t owner, Handle handle) noexcept;
};
} // namespace dingosdk::input_trace
