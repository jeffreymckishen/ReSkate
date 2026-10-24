#pragma once
#include "Engine/Game/World/body_query.h"
#include "Engine/Game/World/sync_probe.h"
#include "Engine/Game/World/motion_refresh_probe.h"
#include <cstdint>
#include <string>

namespace dingosdk::owned_bodies {
// Client thread only. Tick grants no plugin ownership and never creates bodies;
// a previously requested producer setup may install generic hooks.
void tick(std::uintptr_t base, std::uintptr_t client, bool ready) noexcept;
// Cold create requests only process-lifetime producer setup on a later eligible
// tick and refuses before allocation. No definition/body request is queued;
// callers must make a separate explicit create after readiness is available.
std::string create(std::uint64_t owner, const owned_body::Definition&, owned_body::Handle&) noexcept;
std::string read(std::uint64_t owner, const owned_body::Handle&, owned_body::Sample&) noexcept;
body_query::Result probe_batch(std::uint64_t owner, const owned_body::Handle&, const body_query::Request&, unsigned allowance) noexcept;
std::string submit(std::uint64_t owner, const owned_body::Handle&, const owned_body::Command&, std::uint64_t& sequence) noexcept;
std::string receipt(std::uint64_t owner, const owned_body::Handle&, std::uint64_t sequence, owned_body::Receipt&) noexcept;
std::string acknowledge(std::uint64_t owner, const owned_body::Handle&, std::uint64_t sequence) noexcept;
std::string release(std::uint64_t owner, const owned_body::Handle&) noexcept;
void release_all(std::uint64_t owner) noexcept;

// Client-thread bounded diagnostic over the existing native synchronizer.
// Sequence stays behind opaque plugin userdata, paired with exact owner/body.
// It never modifies a target, acquires a follow claim or satisfies a barrier.
std::string begin_sync_probe(std::uint64_t owner, const owned_body::Handle&, std::uint64_t& sequence);
std::string poll_sync_probe(std::uint64_t owner, const owned_body::Handle&, std::uint64_t sequence, body_sync_probe::Result&);

// Actor-scoped diagnostic; no owned body, input lease or native command.
// A cold begin requests only deferred clock/listener preparation and refuses;
// callers must explicitly begin again after the existing mover is available.
std::string begin_motion_refresh_probe(std::uint64_t owner, std::uint64_t& sequence);
std::string poll_motion_refresh_probe(std::uint64_t owner, std::uint64_t sequence, motion_refresh_probe::Result&);
// Idempotent owner close, including owners with no body slots. Removes pending
// and terminal results; late callbacks cannot publish into another generation.
void cancel_motion_refresh_probes(std::uint64_t owner) noexcept;

// Private native-service bridge. These values never cross the Lua API.
// The source owns a copy of the original measured sample, not a live pose.
class SourceBorrow;
class MeasuredSource {
public:
    const owned_body::Sample& sample() const noexcept { return sample_; }
    std::uint64_t clock_observed_ms() const noexcept { return clock_observed_ms_; }
    std::uint64_t captured_ms() const noexcept { return captured_ms_; }
    // Compare the actual native identities with a separately qualified actor.
    // The two services' SDK world-generation counters are not interchangeable.
    std::uintptr_t native_world() const noexcept { return world_; }
    std::uintptr_t native_state() const noexcept { return state_; }
private:
    friend class SourceBorrow;
    friend bool capture_source(std::uint64_t, const owned_body::Handle&, MeasuredSource&) noexcept;
    friend bool try_borrow_source(std::uint64_t, const MeasuredSource&, SourceBorrow&) noexcept;
    std::uint64_t owner_{}, world_generation_{}, clock_observed_ms_{}, captured_ms_{};
    owned_body::Handle handle_{};
    owned_body::Sample sample_{};
    std::uintptr_t base_{}, world_{}, state_{};
    std::uint32_t body_index_{}, body_generation_{};
};
// Client only. Uses observe(), not sample(): latest and the command mailbox
// remain unchanged. Failure publishes no source.
bool capture_source(std::uint64_t owner, const owned_body::Handle&, MeasuredSource&) noexcept;

// Stack scope on the acquiring thread only; never keep this object across an
// original native call or an SDK call that can acquire the body-service lock.
// This serializes SDK slot changes. It DOES NOT pin a native allocation, keep a
// world alive, acquire an actor claim or establish a native consumer boundary.
class SourceBorrow {
public:
    SourceBorrow() noexcept = default;
    ~SourceBorrow();
    SourceBorrow(const SourceBorrow&) = delete;
    SourceBorrow& operator=(const SourceBorrow&) = delete;
    // Repeats the endpoint checks and returns the original sample unchanged.
    // A non-null result is sampled identity evidence, not an atomic native lease.
    const MeasuredSource* get() const noexcept;
private:
    friend bool try_borrow_source(std::uint64_t, const MeasuredSource&, SourceBorrow&) noexcept;
    MeasuredSource source_{};
    std::uint32_t thread_{};
    bool held_{};
};
// Native callback path: one Try shared acquisition, fixed storage, no model,
// provider or profile query, allocation, Lua, logging, hooks or native writes.
// Pass an empty output. Refusal preserves an already-held output borrow;
// it never implicitly releases one. No retry is performed.
bool try_borrow_source(std::uint64_t owner, const MeasuredSource&, SourceBorrow&) noexcept;

} // namespace dingosdk::owned_bodies
