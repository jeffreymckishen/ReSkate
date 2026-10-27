#pragma once
#include "actor_control.h"
#include "native_motion_entry.h"
#include "Engine/Game/Skater/body_follow_api.h"
#include "Extension/World/owned_bodies.h"
#include <array>
#include <cstdint>

namespace dingosdk::body_follow_native {
using CleanupPolicy = body_follow_api::CleanupPolicy;
using Lifetime = body_follow_api::Lifetime;
enum class MotionPolicy : std::uint8_t { native_lifetime, callback_entry };
constexpr bool valid_motion_policy(MotionPolicy policy) noexcept {
    return policy == MotionPolicy::native_lifetime || policy == MotionPolicy::callback_entry;
}
// Internal first-fault context. Plain copied data only; no native identities,
// allocation, logging or additional game reads are needed to record a stage.
enum class DiagnosticStage : std::uint8_t {
    not_attempted, prepare_guard, enter, inspect_first, first_identity, first_admission,
    supplied_copy, supplied_finite, measure, measured_allocation, borrow, borrow_current,
    borrow_join, transform, borrow_recheck, inspect_closing, closing_identity, closing_admission,
    final_source, final_published, current_guard, inspect_current, current_identity,
    current_admission, current_source, current_published, fence_guard, fence_actor, fence_basis,
    fence_world, fence_state, fence_closing_actor, fence_drained, park_history, park_guard,
    park_actor, park_observe, park_closing_actor, park_drained, park_match, complete_drained,
    complete_history, complete_actor, complete_closing_drained, complete_retire
};
struct Diagnostic {
    DiagnosticStage stage{DiagnosticStage::not_attempted}, actor_stage{DiagnosticStage::not_attempted};
    std::uint8_t supplied_failed_lane{16}; // Unknown unless an existing finite check failed.
    // Last actor operation actually evaluated by this provider call. A later
    // non-actor stage does not turn a qualified inspection into a failed one.
    actor_control_native::Observation actor;
    actor_control_native::InspectionFacts facts;
    owned_bodies::ParkObservationDiagnostic world_park;
};
const char* diagnostic_stage_name(DiagnosticStage) noexcept;
// Caller serializes Binding access. Internal only: no address, Actor or
// MeasuredSource is exposed to Luau.
// The retaining service must outlive every Call and must retain any unresolved
// Binding across VM unload. This is not a public reservation API.
struct Binding {
    std::uint64_t owner{}, sequence{};
    actor_control_native::Actor actor{};
    // Initial measurement selects a persistent exact body/allocation/world.
    // Native motion never treats its original pose or wall age as current.
    owned_bodies::MeasuredSource source{};
    actor_control_native::Admission admission{};
    // Selected once at reserve by the owning service; no effect on target admission.
    CleanupPolicy cleanup{CleanupPolicy::actor_lifetime};
    // Eligible start remains unchanged. Callback continuation has no State claim.
    MotionPolicy motion_policy{MotionPolicy::native_lifetime};
    bool reserved{}, published{}, stopped{};
};
// Out must be empty. A false result may still have reserved=true if bounded
// abandonment failed; the caller must retain it and retry cleanup, not discard.
bool reserve_binding(std::uint64_t owner, std::uint64_t sequence,
    const owned_bodies::MeasuredSource&, actor_control_native::Admission,
    Binding& out, actor_control_native::Reason& reason) noexcept;
// Separate opt-in step. The first harmless native diagnostic can reserve/join
// and abandon without publishing any target or incurring follow cleanup duty.
// Publishing is not permitted by the proposal's activation scope yet.
bool publish_binding(Binding&, actor_control_native::Reason& reason) noexcept;
// MeasuredSource stores native ring COM position and principal-body rotation.
// Attachment names a point relative to that COM in that principal-body basis,
// and the root-local basis expressed in that body basis, Hamilton XYZW.
// Lua owns attachment/mode policy; the SDK has no bike geometry or yaw policy.
struct Attachment {
    owned_body::Vec offset_from_com{};
    owned_body::Quaternion root_in_body{0, 0, 0, 1};
    CleanupPolicy cleanup{CleanupPolicy::actor_lifetime};
    MotionPolicy motion_policy{MotionPolicy::native_lifetime};
    // Read by the retaining Service only; target preparation never sees a lease.
    Lifetime lifetime{Lifetime::fixed};
    body_follow_api::Lead lead{};
};
// The runtime and the constructed Service tests use the same conversion, so a
// new copied field cannot silently disappear at the plugin/native boundary.
inline bool attachment_from_api(const body_follow_api::Attachment& value, Attachment& out) noexcept {
    out = {};
    if (!body_follow_api::valid(value)) return false;
    out.offset_from_com = value.offset_from_com;
    out.root_in_body = value.root_in_body;
    out.cleanup = value.cleanup;
    out.motion_policy = value.motion_policy == body_follow_api::MotionPolicy::callback_entry ?
        MotionPolicy::callback_entry : MotionPolicy::native_lifetime;
    out.lifetime = value.lifetime;
    out.lead = value.lead;
    return true;
}
// A NEW current-epoch measured source supplies both translation and full basis.
// Exact supplied padding words are retained. No body borrow spans original.
// Call remains alive through the future exact original invocation.
struct PreparedTarget {
    actor_control::Call call;
    actor_control_native::Actor actor{};
    owned_bodies::MeasuredSource source{};
    owned_body::Sample sample{};
    std::uint64_t owner{}, sequence{};
    actor_control_native::FollowEntryObservation entry;
    alignas(16) std::array<float, 16> value{};
    const NativeMotionEntry* scope{};
    bool ready{}, lead_skipped{};
    PreparedTarget() noexcept = default;
    PreparedTarget(const PreparedTarget&) = delete;
    PreparedTarget& operator=(const PreparedTarget&) = delete;
};
bool prepare_target(const Binding&, std::uintptr_t rig, std::uintptr_t context,
    const std::array<float, 16>* supplied, const Attachment&,
    PreparedTarget&, actor_control_native::Reason& reason) noexcept;
bool prepare_target(const Binding&, std::uintptr_t rig, std::uintptr_t context,
    const std::array<float, 16>* supplied, const Attachment&,
    PreparedTarget&, actor_control_native::Reason&, Diagnostic&) noexcept;
bool prepare_target(const Binding&, const NativeMotionEntry&, const Attachment&,
    PreparedTarget&, actor_control_native::Reason&, Diagnostic&) noexcept;
// The future wrapper must call immediately before its forwarding edge. A
// prepared copy never remains authority after stop, replacement or source loss.
// This final sampled check does not create native lifetime/consumption proof.
bool current_target(const Binding&, PreparedTarget&, actor_control_native::Reason&) noexcept;
bool current_target(const Binding&, PreparedTarget&, actor_control_native::Reason&, Diagnostic&) noexcept;
bool current_target(const Binding&, const NativeMotionEntry&, PreparedTarget&,
    actor_control_native::Reason&, Diagnostic&) noexcept;
// Before publication this only abandons its exact admission. Afterwards it
// revokes with the required body-park barrier. Drain remains an Arbiter duty.
bool stop(Binding&) noexcept;
// Captured only from the actual revoked follow claim after every accepted Call
// drains, before its dependent owned body is released. No caller supplies a
// qualified boolean, numeric drain token or synthetic clock floor.
class ParkFence {
public:
    bool available() const noexcept { return owner_ != 0; }
private:
    friend bool capture_park_fence(const Binding&, ParkFence&, actor_control_native::Reason&) noexcept;
    friend bool capture_park_fence(const Binding&, ParkFence&, actor_control_native::Reason&, Diagnostic&) noexcept;
    friend bool observe_park(const Binding&, const ParkFence&, owned_bodies::RetainedParkReceipt&,
        actor_control_native::Reason&) noexcept;
    friend bool observe_park(const Binding&, const ParkFence&, owned_bodies::RetainedParkReceipt&,
        actor_control_native::Reason&, Diagnostic&) noexcept;
    friend bool park_history_matches(const Binding&, const ParkFence&, const owned_bodies::RetainedParkReceipt&) noexcept;
    friend bool complete_stop(Binding&, const ParkFence&, const owned_bodies::RetainedParkReceipt&) noexcept;
    friend bool complete_stop(Binding&, const ParkFence&, const owned_bodies::RetainedParkReceipt&, Diagnostic&) noexcept;
    friend bool completed_history_matches(const Binding&, const ParkFence&, const owned_bodies::RetainedParkReceipt&) noexcept;
    friend bool seal_command_cleanup(const Binding&, const ParkFence&, const owned_bodies::RetainedParkReceipt&) noexcept;
    std::uint64_t owner_{}, sequence_{};
    actor_control_native::Actor actor_{};
    CleanupPolicy cleanup_{CleanupPolicy::actor_lifetime};
    owned_bodies::RetirementBasis basis_{};
};
bool capture_park_fence(const Binding&, ParkFence&, actor_control_native::Reason&) noexcept;
bool capture_park_fence(const Binding&, ParkFence&, actor_control_native::Reason&, Diagnostic&) noexcept;
// This observes only the retained body's park duty; it never satisfies a shared
// barrier or retires a claim. Native-consumer retirement remains independent.
bool observe_park(const Binding&, const ParkFence&, owned_bodies::RetainedParkReceipt&,
    actor_control_native::Reason&) noexcept;
bool observe_park(const Binding&, const ParkFence&, owned_bodies::RetainedParkReceipt&,
    actor_control_native::Reason&, Diagnostic&) noexcept;
// Immutable terminal history can remain valid after follow retirement. No age
// refresh or repeat park is required. This is NOT current actor/input authority;
// a recovery/action service must qualify that independently before any effect.
bool park_history_matches(const Binding&, const ParkFence&, const owned_bodies::RetainedParkReceipt&) noexcept;
// SDK-completed receipt identity only: the same stored opaque objects were
// validated before actual retirement. No new World/actor freshness is required
// merely to ACK history after a level change; this grants no action authority.
bool completed_history_matches(const Binding&, const ParkFence&,
    const owned_bodies::RetainedParkReceipt&) noexcept;
// Retire only actual stopped/drained SDK ownership after matching positive
// park. The caller also excludes any invoking edge or abnormal original return.
// Success is SDK completion; native pose-history retirement remains unknown.
// Trusted completed Service calls only, after its final original return.
// Metadata-only cleanup closure; original force outcome/successor stay unchanged.
bool seal_command_cleanup(const Binding&, const ParkFence&, const owned_bodies::RetainedParkReceipt&) noexcept;
bool complete_stop(Binding&, const ParkFence&, const owned_bodies::RetainedParkReceipt&) noexcept;
bool complete_stop(Binding&, const ParkFence&, const owned_bodies::RetainedParkReceipt&, Diagnostic&) noexcept;
} // namespace dingosdk::body_follow_native
