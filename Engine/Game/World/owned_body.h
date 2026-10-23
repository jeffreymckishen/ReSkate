#pragma once
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>

// Values crossing the client/physics boundary. No native address is part of this contract.
namespace dingosdk::owned_body {
using Vec = std::array<float, 3>;
using Quaternion = std::array<float, 4>; // Hamilton XYZW
inline constexpr std::size_t maximum_capsules = 8, retained_capacity = 8;
inline constexpr double native_seconds = 1.0 / 60.0;
inline constexpr std::uint64_t command_lifetime_ms = 100;
inline constexpr float maximum_force = 40000, maximum_torque = 4000, maximum_impulse = 600;

struct Capsule { Vec a{}, b{}; float radius{}; };
struct Definition {
    std::array<Capsule, maximum_capsules> capsules{};
    std::size_t count{};
    float mass{};
    Vec inertia{}, position{};
    Quaternion rotation{};
};
// SDK-generated identifiers. The Lua binding wraps these in locked userdata.
struct Handle { std::uint64_t generation{}; std::uint32_t slot{}; bool operator==(const Handle&) const = default; };
struct Epoch {
    std::uint64_t world{}, body{}, serial{};
    double time{};
    float seconds{};
    bool operator==(const Epoch&) const = default;
};
struct Sample {
    Epoch epoch{};
    Vec position{}, velocity{}, angular_velocity{}, inertia{};
    Quaternion rotation{};
    float mass{};
};
struct Command {
    Epoch epoch{};
    Vec force{}, torque{}, impulse{};
    std::uint32_t impulse_id{};
};
enum class Outcome { none, queued, applied, partial, rejected, expired };
inline const char* name(Outcome value) noexcept {
    switch (value) {
    case Outcome::none: return "none";
    case Outcome::queued: return "queued";
    case Outcome::applied: return "applied";
    case Outcome::partial: return "partial";
    case Outcome::rejected: return "rejected";
    case Outcome::expired: return "expired";
    }
    return "rejected";
}
struct Receipt {
    Outcome outcome{};
    std::uint64_t sequence{};
    Epoch requested{};
    Epoch produced{};
    bool force_attempted{}, torque_attempted{}, retained{}, quarantined{}, successor_available{};
    Sample successor{};
};
// A constructor may have mutated the world before its out handle or return value
// becomes verifiable. Parking the confirmed subset cannot erase that uncertainty.
struct AllocationProgress {
    bool body_confirmed{};
    std::size_t shapes_attempted{}, shapes_confirmed{};
    bool quarantine(bool confirmed_subset_parked) const noexcept {
        return !confirmed_subset_parked || !body_confirmed || shapes_attempted != shapes_confirmed;
    }
};
inline bool finite(const Vec& value, float bound) noexcept {
    for (float v : value) if (!std::isfinite(v) || std::abs(v) > bound) return false;
    return true;
}
inline double length(const Vec& value) noexcept {
    double sum{}; for (float v : value) sum += static_cast<double>(v) * v;
    return std::sqrt(sum);
}
inline bool calibrated(float seconds) noexcept {
    return std::isfinite(seconds) && std::abs(static_cast<double>(seconds) - native_seconds) <= 1e-7;
}
inline bool valid(const Definition& value) noexcept {
    if (!value.count || value.count > maximum_capsules || !std::isfinite(value.mass) ||
        value.mass < 1 || value.mass > 1000 || !finite(value.inertia, 10000) || !finite(value.position, 100000)) return false;
    for (float v : value.inertia) if (v < .01f) return false;
    double norm{};
    for (float v : value.rotation) { if (!std::isfinite(v)) return false; norm += static_cast<double>(v) * v; }
    if (std::abs(norm - 1) > .0001) return false;
    for (std::size_t i = 0; i < value.count; ++i) {
        const auto& c = value.capsules[i];
        if (!finite(c.a, 10) || !finite(c.b, 10) || !std::isfinite(c.radius) || c.radius < .01f || c.radius > 2) return false;
    }
    return true;
}
inline bool valid(const Command& value) noexcept {
    if (!value.epoch.world || !value.epoch.body || !value.epoch.serial || value.epoch.serial == std::numeric_limits<std::uint64_t>::max() ||
        !std::isfinite(value.epoch.time) || value.epoch.time < 0 || !std::isfinite(value.epoch.time + value.epoch.seconds) ||
        !calibrated(value.epoch.seconds) || !finite(value.force, maximum_force) || !finite(value.torque, maximum_torque) ||
        !finite(value.impulse, maximum_impulse) || length(value.force) > maximum_force || length(value.torque) > maximum_torque ||
        length(value.impulse) > maximum_impulse || (length(value.impulse) > 0 && !value.impulse_id)) return false;
    Vec combined = value.force;
    for (std::size_t i = 0; i < 3; ++i) combined[i] += value.impulse[i] / value.epoch.seconds;
    return finite(combined, maximum_force) && length(combined) <= maximum_force;
}

// External synchronization owns this fixed mailbox. Consumption precedes the first native
// setter: even an uncertain/partial setter can never replay an impulse or command serial.
struct Mailbox {
    Command command{};
    Receipt receipt{};
    std::uint64_t deadline{}, last_serial{}, last_submitted{}, sequence{};
    std::uint32_t last_impulse{};
    bool pending{}, failed{}, acknowledged = true;

    bool submit(const Command& value, const Epoch& observed, std::uint64_t now) noexcept {
        if (failed || pending || !acknowledged || !valid(value) || value.epoch != observed || value.epoch.serial <= last_submitted ||
            (value.impulse_id && value.impulse_id <= last_impulse)) return false;
        command = value; deadline = now + command_lifetime_ms; pending = true; acknowledged = false; last_submitted = value.epoch.serial;
        receipt = {}; receipt.outcome = Outcome::queued; receipt.sequence = ++sequence; receipt.requested = value.epoch;
        return true;
    }
    bool consume(const Epoch& current, std::uint64_t now, Command& out) noexcept {
        if (!pending) return false;
        Epoch target = command.epoch; ++target.serial; target.time += target.seconds;
        if (now >= deadline || current.serial > target.serial) {
            pending = false; receipt.outcome = Outcome::expired; return false;
        }
        // The client computed from observed predecessor N. Earlier callbacks in N
        // cannot consume it; only the independently observed listener epoch N+1 may.
        if (current == command.epoch) return false;
        if (current != target) { pending = false; receipt.outcome = Outcome::rejected; return false; }
        out = command; pending = false; last_serial = command.epoch.serial;
        receipt.produced = current;
        if (command.impulse_id) last_impulse = command.impulse_id;
        return true;
    }
    void finish(bool force_attempted, bool torque_attempted, bool complete) noexcept {
        receipt.force_attempted = force_attempted; receipt.torque_attempted = torque_attempted;
        receipt.outcome = complete ? Outcome::applied : force_attempted || torque_attempted ? Outcome::partial : Outcome::rejected;
        failed = !complete;
    }
    void cancel() noexcept {
        if (pending) { pending = false; receipt.outcome = Outcome::rejected; }
    }
    bool observe_successor(const Sample& value) noexcept {
        const auto& produced = receipt.produced;
        if (receipt.outcome != Outcome::applied || value.epoch.world != produced.world || value.epoch.body != produced.body ||
            value.epoch.serial <= produced.serial || !std::isfinite(value.epoch.time) || value.epoch.time <= produced.time ||
            !calibrated(value.epoch.seconds)) return false;
        receipt.successor = value; receipt.successor_available = true; return true;
    }
    bool acknowledge(std::uint64_t value) noexcept {
        if (!value || receipt.sequence != value || pending || receipt.outcome == Outcome::none ||
            receipt.outcome == Outcome::queued || acknowledged ||
            (receipt.outcome == Outcome::applied && !receipt.successor_available)) return false;
        acknowledged = true; return true;
    }
};
} // namespace dingosdk::owned_body
