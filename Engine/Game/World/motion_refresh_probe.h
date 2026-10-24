#pragma once
#include <array>
#include <cstdint>

namespace dingosdk::motion_refresh_probe {
// Copied read-only diagnostics. No native address, body allocation, motion
// claim, stock-origin assertion, published-revision ACK or retirement proof.
inline constexpr std::uint32_t lifetime_ms = 1000;
inline constexpr std::uint32_t callback_limit = 128;
enum class Status : std::uint8_t { pending, observed, expired, invalidated };
struct Epoch {
    std::uint64_t world_generation{}, lifetime_epoch{}, actor_epoch{}, serial{};
    double time{};
    float seconds{};
    bool operator==(const Epoch&) const = default;
};
using Matrix = std::array<float, 16>;
struct Endpoints {
    Matrix root{}, inverse{};
    // The three covered packet-source caches, in the admitted native order.
    std::array<Matrix, 3> caches{};
    std::array<Matrix, 4> packets{};
    std::array<std::uint32_t, 4> flags{};
    bool operator==(const Endpoints&) const = default;
};
struct Record {
    bool present{};
    // This means only that the existing mover relay received the same values.
    // It says nothing about upstream stock source or other writers.
    bool unchanged_forwarding{};
    std::uint8_t flag{};
    std::array<float, 4> input{};
    Epoch before_epoch{}, after_epoch{};
    Endpoints before{}, after{};
};
// Bounded callback counters are independent generation-qualified lower bounds.
// Contention/closure can omit counts; zero never proves universal absence.
struct Routing {
    std::uint32_t entries{}, matching{}, other{}, rejected{}, dropped{};
    bool limit_reached{};
};
struct Result {
    Status status{Status::pending};
    Epoch armed_epoch{}, confirmed_epoch{};
    bool client_revalidated{};
    double elapsed_ms{};
    Record record{};
    Routing routing{};
};
static_assert(sizeof(Result) <= 4096);
} // namespace dingosdk::motion_refresh_probe
