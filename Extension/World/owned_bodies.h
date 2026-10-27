#pragma once
#include "Engine/Game/World/body_query.h"
#include "Engine/Game/World/sync_probe.h"
#include "Engine/Game/World/motion_refresh_probe.h"
#include "Engine/Game/World/body_reactivation_probe.h"
#include <cstdint>
#include <string>

namespace dingosdk::owned_bodies {
// Client thread only. Tick grants no plugin ownership and never creates bodies;
// a previously requested producer setup may install generic hooks.
void tick(std::uintptr_t base, std::uintptr_t client, bool ready) noexcept;
// Explicit process-lifetime producer preparation, never body creation. Cold
// calls queue only deferred setup and refuse; a later explicit call can report
// a freshly captured local client/clock. No owner, definition or slot is kept.
std::string prepare() noexcept;
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

#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
// Trusted armed runtime only. The verifier has static process lifetime and must
// not call World or native services. Poll only copies; revocation never drops cleanup.
std::string begin_body_reactivation_probe(std::uint64_t owner, const owned_body::Handle&,
    std::uint64_t& sequence, body_reactivation_probe::QualificationCheck);
std::string poll_body_reactivation_probe(std::uint64_t owner, const owned_body::Handle&,
    std::uint64_t sequence, body_reactivation_probe::Result&);
void revoke_body_reactivation_probe(std::uint64_t owner) noexcept;
#endif

// Private native-service bridge. These values never cross the Lua API.
// The source owns a copy of the original measured sample, not a live pose.
// Internal copied diagnostics only. A check names the first existing predicate
// that refused this observation, not an inferred native cause. A failed read
// leaves lanes unknown. Known mask bits 0..3 correspond to the existing XYZW
// value comparison; zero includes either sign of zero. No native identity leaks.
enum class ParkObservationCheck : std::uint8_t {
    not_attempted, passed, output_occupied, owner, client_phase,
    world_lock, retained_identity, fresh_allocation, shape_identity, clock_unavailable,
    clock_serial, clock_time, clock_after_fence, clock_after_park, category_storage,
    collision_storage, dynamic_storage, dynamic_bit, linear_read, linear_zero,
    angular_read, angular_zero, force_read, force_zero, torque_read,
    torque_zero, shape_category_read, shape_category_zero, shape_collision_read, shape_collision_zero,
    shape_current, categories_unchanged, collisions_unchanged, dynamic_unchanged, linear_header,
    linear_values, angular_header, angular_values, force_storage, force_values,
    torque_storage, torque_values, closing_clock, closing_epoch, closing_stamp,
    clock_freshness
};
struct ParkObservationDiagnostic {
    ParkObservationCheck check{ParkObservationCheck::not_attempted};
    std::uint8_t failed_lanes{};
    bool lanes_known{};
    // Only a failed angular_zero comparison supplies this existing-read value.
    // A failed ring read, an earlier refusal or success leaves it unavailable.
    bool angular_fourth_available{};
    float angular_fourth_value{};
    std::uint32_t angular_fourth_bits{};
    bool operator==(const ParkObservationDiagnostic&) const = default;
};
const char* park_observation_check_name(ParkObservationCheck) noexcept;

class SourceBorrow;
class RetirementBasis;
class RetainedParkReceipt;
// Internal historical handoff only. Its result must not gate ordinary terminal ACK.
enum class CompletedAckHandoff { unavailable, closed_ineligible, recorded };
class BodyReleaseHold;
class MeasuredSource;
// What World can say about a sample a plugin presents as proof for a retaining
// service's renewal. current: the slot still holds the measured allocation, the
// sample is the body's latest issued one (from read or a receipt's successor),
// and the body's physics clock was observed under command_lifetime_ms ago.
// Nothing else is claimed: no pose, no actor state, no command authority.
// busy: World's lock or the physics clock feed's lock was held, so nothing was
// decided and the same proof may be presented again.
enum class RenewalProof : std::uint8_t { current, busy, body_unavailable, not_latest, clock_stale };
// Client thread only. The identity selects the exact owner/allocation/world, as
// in try_measure_source. One Try SHARED World lock, the same mode a callback's
// measurement takes, so this never makes a callback's measurement fail, then the
// clock feed's own shared Try. No
// Anchor capture, model query or ring read; latest and the mailbox are unchanged.
// current_serial is the physics step observed, set only for RenewalProof::current.
RenewalProof check_renewal_proof(std::uint64_t owner, const MeasuredSource& identity,
    const owned_body::Epoch& proof, std::uint64_t& current_serial) noexcept;
class MeasuredSource {
public:
    const owned_body::Sample& sample() const noexcept { return sample_; }
    std::uint64_t clock_observed_ms() const noexcept { return clock_observed_ms_; }
    std::uint64_t captured_ms() const noexcept { return captured_ms_; }
    // Internal identity comparison only. It grants no pose, lifetime or write
    // authority and deliberately does not refresh either measurement's age.
    bool same_allocation(const MeasuredSource& other) const noexcept {
        return owner_ && owner_ == other.owner_ && handle_ == other.handle_ &&
            base_ == other.base_ && world_ == other.world_ && state_ == other.state_ &&
            world_generation_ == other.world_generation_ &&
            body_index_ == other.body_index_ && body_generation_ == other.body_generation_;
    }
    // Compare the actual native identities with a separately qualified actor.
    // The two services' SDK world-generation counters are not interchangeable.
    std::uintptr_t native_world() const noexcept { return world_; }
    std::uintptr_t native_state() const noexcept { return state_; }
private:
    friend class SourceBorrow;
    friend bool capture_source(std::uint64_t, const owned_body::Handle&, MeasuredSource&) noexcept;
    friend bool try_measure_source(std::uint64_t, const MeasuredSource&, MeasuredSource&) noexcept;
    friend RenewalProof check_renewal_proof(std::uint64_t, const MeasuredSource&, const owned_body::Epoch&, std::uint64_t&) noexcept;
    friend bool acquire_release_hold(std::uint64_t, const MeasuredSource&, BodyReleaseHold&) noexcept;
    friend bool capture_retirement_basis(std::uint64_t, const MeasuredSource&, RetirementBasis&) noexcept;
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

// Native callback only: the old source selects one exact owner/allocation/world,
// never an old pose. Produces a NEW immutable measurement at the current native
// epoch. Fixed storage, Try-only locks, no model/provider/Lua or native writes.
// The caller must separately own and qualify its actor motion claim.
bool try_measure_source(std::uint64_t owner, const MeasuredSource& identity, MeasuredSource& out) noexcept;

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
    // Stronger sampled endpoint: original sample and age remain unchanged,
    // and exact current native epoch AND pose must still match that sample.
    // This does not pin a native allocation across the next original call.
    const MeasuredSource* current() const noexcept;
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

// Internal SDK dependency pin. It postpones the existing body release while a
// retaining native service may still have original invocations in flight.
// No Lua API, native lifetime pin, motion authority or cleanup proof is granted.
class BodyReleaseHold {
public:
    bool available() const noexcept { return id_ != 0; }
private:
    friend bool acquire_release_hold(std::uint64_t, const MeasuredSource&, BodyReleaseHold&) noexcept;
    friend bool release_requested(std::uint64_t, const BodyReleaseHold&, bool&) noexcept;
    friend bool request_held_release(std::uint64_t, const BodyReleaseHold&) noexcept;
    friend bool release_body_hold(std::uint64_t, BodyReleaseHold&) noexcept;
    std::uint64_t owner_{}, id_{}, world_generation_{};
    owned_body::Handle handle_{};
    std::uintptr_t base_{}, world_{}, state_{};
    std::uint32_t body_index_{}, body_generation_{};
};
// Client only, Try exclusive World lock. Requires the exact current measured
// sample and allocation; acquire before publishing a dependent native writer.
// At most one such retaining service may hold this body. Output must be empty.
bool acquire_release_hold(std::uint64_t owner, const MeasuredSource&, BodyReleaseHold&) noexcept;
// A false return means unavailable/unknown, not that release was not requested.
// Does not recapture native state, call a follow service or renew any lease.
bool release_requested(std::uint64_t owner, const BodyReleaseHold&, bool& out) noexcept;
// Native-safe stop request: one Try exclusive lock, exact SDK token/slot match,
// then only cancel the SDK mailbox and mark release requested. No native reads,
// model/provider query, allocation, setter, park or callback. False is unknown;
// stop local target authority anyway and retry from the retaining client tick.
bool request_held_release(std::uint64_t owner, const BodyReleaseHold&) noexcept;
// Internal trusted retaining service ONLY. Drop after its actual stop/drain and
// post-drain ParkFence capture, or after exact abandonment of an UNPUBLISHED
// admission. World cannot verify that actor duty; there is no public boolean
// proof parameter. This only drops the exact SDK pin: it does not park, satisfy
// a barrier, retire a motion claim or erase a pending body release request.
// A busy/failed return preserves the token for later exact cleanup.
bool release_body_hold(std::uint64_t owner, BodyReleaseHold&) noexcept;

// Cleanup-only observations. These opaque values never authorize body commands,
// renew a measured source or cross the Lua API. The actor service separately
// binds the basis to its actual successful revoke and drained claim.
class RetirementBasis {
public:
    bool available() const noexcept { return owner_ != 0; }
    const owned_body::Epoch& epoch() const noexcept { return epoch_; }
    std::uint64_t captured_ms() const noexcept { return captured_ms_; }
    std::uintptr_t native_world() const noexcept { return world_; }
    std::uintptr_t native_state() const noexcept { return state_; }
private:
    friend bool capture_retirement_basis(std::uint64_t, const MeasuredSource&, RetirementBasis&) noexcept;
    friend bool observe_retained_park(std::uint64_t, const RetirementBasis&, RetainedParkReceipt&) noexcept;
    friend bool observe_retained_park(std::uint64_t, const RetirementBasis&, RetainedParkReceipt&, ParkObservationDiagnostic&) noexcept;
    friend bool matches_retained_park(std::uint64_t, const RetirementBasis&, const RetainedParkReceipt&) noexcept;
    friend bool matches_retained_park_locked(std::uint64_t, const RetirementBasis&, const RetainedParkReceipt&) noexcept;
    friend bool seal_parked_command_cleanup(std::uint64_t, const RetirementBasis&, const RetainedParkReceipt&) noexcept;
    friend CompletedAckHandoff record_completed_follow_ack(std::uint64_t, std::uint64_t, const RetirementBasis&, const RetainedParkReceipt&) noexcept;
    struct Identity {
        std::uintptr_t world{};
        std::uint32_t index{}, generation{};
        bool operator==(const Identity&) const = default;
    };
    std::uint64_t owner_{}, world_generation_{}, captured_ms_{};
    owned_body::Handle handle_{};
    owned_body::Epoch epoch_{};
    std::uintptr_t base_{}, world_{}, state_{};
    Identity body_{};
    std::array<Identity, owned_body::maximum_capsules> shapes_{};
    std::size_t made_{};
};
class RetainedParkReceipt {
public:
    bool available() const noexcept { return parked_ms_ != 0; }
    const owned_body::Epoch& observed_epoch() const noexcept { return observed_epoch_; }
    std::uint64_t observed_ms() const noexcept { return observed_ms_; }
    std::uint64_t parked_ms() const noexcept { return parked_ms_; }
private:
    friend bool observe_retained_park(std::uint64_t, const RetirementBasis&, RetainedParkReceipt&) noexcept;
    friend bool observe_retained_park(std::uint64_t, const RetirementBasis&, RetainedParkReceipt&, ParkObservationDiagnostic&) noexcept;
    friend bool matches_retained_park(std::uint64_t, const RetirementBasis&, const RetainedParkReceipt&) noexcept;
    friend bool matches_retained_park_locked(std::uint64_t, const RetirementBasis&, const RetainedParkReceipt&) noexcept;
    friend bool seal_parked_command_cleanup(std::uint64_t, const RetirementBasis&, const RetainedParkReceipt&) noexcept;
    friend CompletedAckHandoff record_completed_follow_ack(std::uint64_t, std::uint64_t, const RetirementBasis&, const RetainedParkReceipt&) noexcept;
    RetirementBasis basis_{};
    owned_body::Epoch observed_epoch_{};
    std::uint64_t parked_ms_{}, observed_ms_{};
};
// Client only, Try shared SDK lock. Captures a current native clock floor without
// reading/publishing a new pose. Original source age is irrelevant to cleanup;
// its exact owner/body/world identities must still match. Output must be empty.
bool capture_retirement_basis(std::uint64_t, const MeasuredSource&, RetirementBasis&) noexcept;
// After release retained the body, observe zero masks/force/torque/velocities and
// an allocated non-dynamic native body at a later genuine native epoch. Exact
// fixed versus keyframed subtype is not inferred. No destruction/reuse proof.
// Output is issued once and never restamped; an occupied output is preserved.
bool observe_retained_park(std::uint64_t, const RetirementBasis&, RetainedParkReceipt&) noexcept;
// Same observation and short-circuit order; diagnostics add no native reads.
bool observe_retained_park(std::uint64_t, const RetirementBasis&, RetainedParkReceipt&, ParkObservationDiagnostic&) noexcept;
// Checks immutable terminal history against the still-retained SDK identity.
// It does not impose receipt-age limits or provide fresh actor/input authority.
// The retaining actor service must separately qualify the current native context.
bool matches_retained_park(std::uint64_t, const RetirementBasis&, const RetainedParkReceipt&) noexcept;

// Trusted retaining service only, after its exact stop/drain/final-return and
// completed park history. SDK-only receipt metadata; no native reads/writes,
// new successor, receipt ACK, allocation reuse or actor authority is produced.
// Busy or lost proof preserves every mailbox record and the caller's proof.
bool seal_parked_command_cleanup(std::uint64_t, const RetirementBasis&, const RetainedParkReceipt&) noexcept;

// Trusted Follow service only, after its completed stop/drain/park history and
// command cleanup seal, before it discards that history at terminal ACK. Records
// only immutable SDK provenance, without native reads/writes or receipt ACKs.
// Every result is optional bookkeeping and must not gate ordinary Follow ACK.
// recorded is not reuse eligibility: terminal body rows may still need ACK, and
// any future reuse would also require zero body receipt debt and separate proof.
CompletedAckHandoff record_completed_follow_ack(std::uint64_t owner, std::uint64_t sequence,
    const RetirementBasis&, const RetainedParkReceipt&) noexcept;

} // namespace dingosdk::owned_bodies
