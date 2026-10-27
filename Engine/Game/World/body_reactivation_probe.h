#pragma once
#include "owned_body.h"
#include <array>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <utility>

namespace dingosdk::body_reactivation_probe {
// Copied facts from one diagnostic cycle. No value grants body reuse, a new
// native lifetime, Follow authority or proof of contact/broadphase retirement.
inline constexpr std::uint64_t run_lifetime_ms = 2000, cleanup_lifetime_ms = 3000;
inline constexpr std::size_t record_capacity = 16;
inline constexpr std::uint8_t maximum_cycles = 1;
inline constexpr std::uint32_t qualified_categories = 0, qualified_collisions = 0x101;
using QualificationCheck = bool (*)(std::uint64_t owner) noexcept;
enum class Status : std::uint8_t { pending, observed, expired, invalidated };
enum class Phase : std::uint8_t { initial_park, await_initial_park, activation, await_dynamic, repark, await_repark, terminal };
enum class Cleanup : std::uint8_t { pending, confirmed, unconfirmed };
enum class Check : std::uint8_t {
    none, qualification, client_phase, world_lock, identity, allocation, dependency,
    mailbox, clock, run_deadline, cleanup_deadline, owner_closed, initial_park,
    transform, categories, collisions, motion, wake, observation, repark, cancelled
};
enum class Stage : std::uint8_t {
    initial_park, initial_park_observed, transform, categories, collisions,
    motion, wake, dynamic_observed, repark, repark_observed
};
struct Observation {
    bool available{}, dynamic{};
    std::uint8_t shape_count{};
    owned_body::Sample sample{};
    std::array<std::uint32_t, owned_body::maximum_capsules> categories{}, collisions{};
    std::array<float, 4> force{}, torque{};
    float angular_fourth{};
};
struct Record {
    Stage stage{Stage::initial_park};
    bool passed{};
    // Copied pre-admission Follow park floor, never a new probe park command.
    // Only initial_park may carry this flag, with no attached observation.
    bool historical_park_basis{};
    owned_body::Epoch epoch{};
    Observation observation{};
};
struct Result {
    Status status{Status::pending};
    Phase phase{Phase::initial_park};
    Cleanup cleanup{Cleanup::pending};
    Check first_failure{Check::none};
    Phase failure_phase{Phase::initial_park};
    bool cleanup_owed{}, native_retirement_known{}, failure_shape_known{};
    std::uint8_t failure_shape{};
    std::uint8_t cycle_count{}; // admitted plan, not a count of successful native cycles
    owned_body::Vec target_position{};
    owned_body::Quaternion target_rotation{};
    double elapsed_ms{};
    std::uint32_t record_count{};
    std::array<Record, record_capacity> records{};
};
static_assert(sizeof(Result) <= 8192);
// Paths are canonicalized by the trusted facade before reaching this pure model.
// Runtime code serializes access; no caller can arm a previously unarmed snapshot.
struct LaunchArmValues {
    bool opted_in{}, isolation_current{};
    std::filesystem::path profile_root{}, plugin_root{};
    std::string plugin_id{}, run_id{};
    bool operator==(const LaunchArmValues&) const = default;
};
class FrozenArm {
public:
    explicit FrozenArm(LaunchArmValues values = {}) : values_(std::move(values)), armed_(valid(values_)) {}
    bool revalidate(const LaunchArmValues& current) noexcept {
        if (!armed_ || revoked_) return false;
        if (current != values_) { revoked_ = true; return false; }
        return true;
    }
    bool begin(const LaunchArmValues& current, std::uint64_t owner, std::string_view plugin_id,
        const std::filesystem::path& plugin_root) noexcept {
        if (!revalidate(current) || !owner || consumed_ || plugin_id != values_.plugin_id || plugin_root != values_.plugin_root) return false;
        consumed_ = true; owner_ = owner; return true;
    }
    bool current(const LaunchArmValues& values, std::uint64_t owner) noexcept {
        return revalidate(values) && consumed_ && owner && owner == owner_;
    }
    void close(std::uint64_t owner) noexcept { if (owner && owner == owner_) revoked_ = true; }
    void revoke() noexcept { revoked_ = true; }
    bool consumed() const noexcept { return consumed_; }
    bool revoked() const noexcept { return revoked_; }
    std::uint64_t bound_owner() const noexcept { return owner_; }
    const LaunchArmValues& values() const noexcept { return values_; }
private:
    static bool token(std::string_view value) noexcept {
        if (value.empty() || value.size() > 128) return false;
        for (const unsigned char c : value) if (c < 0x21 || c > 0x7e) return false;
        return true;
    }
    static bool valid(const LaunchArmValues& value) noexcept {
        return value.opted_in && value.isolation_current && value.profile_root.is_absolute() && value.plugin_root.is_absolute() &&
            value.profile_root.native().size() <= 180 && value.plugin_root.native().size() <= 1024 &&
            token(value.plugin_id) && token(value.run_id);
    }
    LaunchArmValues values_;
    bool armed_{}, consumed_{}, revoked_{};
    std::uint64_t owner_{};
};
} // namespace dingosdk::body_reactivation_probe
