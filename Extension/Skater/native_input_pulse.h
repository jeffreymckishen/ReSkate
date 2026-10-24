#pragma once
#include "Engine/Game/Input/game_input_pulse.h"
#include "Engine/Game/Input/input_pulse.h"
#include "Engine/Game/Input/input_lease.h"
#include "Engine/Game/Input/input_lease_capture_policy.h"
#include "input_publication_gate.h"
#include "Engine/Game/Skater/actor_control_policy.h"
#include <Windows.h>
#include <Xinput.h>

namespace dingosdk::native_input_pulse {
bool request(std::uint64_t owner, std::uint32_t user, std::uint16_t button,
    game_input_pulse::Handle& handle, game_input_pulse::Reason& reason) noexcept;
bool read(std::uint64_t owner, game_input_pulse::Handle handle, game_input_pulse::Receipt& receipt) noexcept;
bool cancel(std::uint64_t owner, game_input_pulse::Handle handle) noexcept;
bool acknowledge(std::uint64_t owner, game_input_pulse::Handle handle) noexcept;
void release_all(std::uint64_t owner) noexcept;
void tick(std::uintptr_t base, std::uintptr_t client, bool ready) noexcept;

// Passive selected-source observations. These calls never reserve the actor,
// suppress native controls, or confirm native input consumption.
bool lease_request(std::uint64_t owner, std::uint32_t user,
    input_lease::Handle& handle, input_lease::Reason& reason) noexcept;
bool lease_read(std::uint64_t owner, input_lease::Handle handle,
    input_lease::Snapshot& snapshot, input_lease::Reason& reason) noexcept;
bool lease_renew(std::uint64_t owner, input_lease::Handle handle,
    const input_lease::Snapshot& snapshot, input_lease::Reason& reason) noexcept;
bool lease_release(std::uint64_t owner, input_lease::Handle handle, input_lease::Reason& reason) noexcept;
bool lease_state(std::uint64_t owner, input_lease::Handle handle,
    input_lease::Receipt& receipt, input_lease::Reason& reason) noexcept;
bool lease_acknowledge(std::uint64_t owner, input_lease::Handle handle, input_lease::Reason& reason) noexcept;
void lease_release_all(std::uint64_t owner) noexcept;

// Private native composition only. No public plugin capture API is exposed by
// this candidate. A snapshot must be an exact issued broker observation.
bool capture_request(std::uint64_t owner, input_lease::Handle handle,
    const input_lease::Snapshot& snapshot, input_lease_capture::Reason& reason) noexcept;
bool capture_state(std::uint64_t owner, input_lease::Handle handle,
    input_lease_capture::Receipt& receipt) noexcept;
bool capture_release(std::uint64_t owner, input_lease::Handle handle) noexcept;
bool capture_acknowledge(std::uint64_t owner, input_lease::Handle handle) noexcept;

// One stack cookie per outer wrapper invocation. The actor Call drains before
// a later client-phase claim retirement; it is not an input-consumption receipt.
struct Poll {
    ~Poll();
    std::uint64_t sequence{};
    input_lease::Handle lease_handle{};
    input_pulse::Ticket ticket{};
    actor_control::Call call;
    actor_observation::Trace enter_observation;
    input_lease_capture::Key capture_key{};
    input_lease_capture::Ticket capture_ticket{};
    game_input_pulse::ActorObservation staged_actor;
    std::uint64_t staged_serial{}, staged_clock_ms{};
    double staged_seconds{};
    bool staged_actor_current{}, staged_clock_known{}, prepared{};
    std::uint32_t source_user{4};
    bool source_call_active{};
};
void begin(bool outer, std::uint32_t user, Poll& poll) noexcept;
// Actor/protection locks are taken only here, outside PublicationScope.
void prepare_finish(Poll& poll) noexcept;
DWORD finish_staged(Poll& poll, const PublicationScope& scope, bool outer, std::uint32_t user,
    DWORD original_result, std::uint64_t original_ms, DWORD raw_packet, const XINPUT_GAMEPAD& raw,
    DWORD returned_result, const XINPUT_STATE& candidate, std::uint64_t staged_revision,
    XINPUT_STATE* output, bool interference_clear, bool original_output_known) noexcept;
void finish(Poll& poll, bool outer, std::uint32_t user, DWORD original_result,
    std::uint64_t original_ms, DWORD raw_packet, const XINPUT_GAMEPAD& raw,
    DWORD returned_result, XINPUT_STATE* output, bool interference_clear) noexcept;
// Existing opted-in private helpers operate on the live buffer before this
// competitor adapter. It preserves their pad and never confirms owned capture
// or pulse neutral release from another owner's report.
void finish_private(Poll& poll, bool outer, std::uint32_t user, DWORD original_result,
    std::uint64_t original_ms, DWORD raw_packet, const XINPUT_GAMEPAD& raw,
    DWORD returned_result, XINPUT_STATE* output, bool original_output_known) noexcept;
}
