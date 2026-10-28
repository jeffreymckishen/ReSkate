#include "scripted_pad.h"
#include "Extension/Skater/input_publication_gate.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>

namespace dingosdk::overlay {
namespace {
struct State {
    std::mutex mutex;
    std::vector<PadStep> steps;
    std::size_t current{};
    std::uint32_t ticks{};
    std::chrono::steady_clock::time_point last_tick, done_at;
    bool active{};
    DWORD packet{};
    // A stick held (hold_stick).
    int stick{};
    SHORT value{};
    std::chrono::steady_clock::time_point held_until{};
};
State &state() { static auto *value = new State; return *value; }
constexpr std::chrono::milliseconds linger{2000}, no_ticks{250}, tick_length{17};
// One game tick of the script. The caller holds the publication gate, then s.mutex.
bool advance(State &s, std::chrono::steady_clock::time_point now) {
    const auto previous = s.current;
    ++s.ticks;
    s.last_tick = now;
    while (s.current + 1 < s.steps.size() && s.steps[s.current + 1].tick <= s.ticks) {
        ++s.current;
        if (s.current + 1 == s.steps.size()) s.done_at = now;
    }
    return s.current != previous;
}

bool scripted_pad_locked(State &s, const native_input_pulse::PublicationScope& publication,
    XINPUT_STATE &output) noexcept {
    const auto now = std::chrono::steady_clock::now();
    if (!s.active) {
        if (now >= s.held_until) {
            if (s.held_until != std::chrono::steady_clock::time_point{}) {
                s.held_until = {};
                native_input_pulse::publication_changed(publication);
            }
            return false;
        }
        output.Gamepad = XINPUT_GAMEPAD{};
        SHORT* axes[] = {&output.Gamepad.sThumbLX, &output.Gamepad.sThumbLY, &output.Gamepad.sThumbRX, &output.Gamepad.sThumbRY};
        *axes[s.stick] = s.value;
        output.dwPacketNumber = ++s.packet;
        return true;
    }
    // With no game ticks, time alone moves the script on.
    bool changed{};
    while (s.current + 1 < s.steps.size() && now - s.last_tick > no_ticks)
        changed = advance(s, s.last_tick + tick_length) || changed;
    const bool done = s.current + 1 == s.steps.size();
    if (done && now - s.done_at > linger) {
        s.active = false;
        native_input_pulse::publication_changed(publication);
        return false;
    }
    if (changed) native_input_pulse::publication_changed(publication);
    output.Gamepad = done ? XINPUT_GAMEPAD{} : s.steps[s.current].pad;
    // The script packet is output metadata, not a change of capture authority.
    output.dwPacketNumber = ++s.packet;
    return true;
}
} // namespace

void play_pad(std::vector<PadStep> steps) {
    native_input_pulse::PublicationScope publication;
    if (!publication.owns()) return;
    auto &s = state();
    std::lock_guard lock(s.mutex);
    const bool changed = s.active || !steps.empty();
    s.steps = std::move(steps);
    s.current = 0;
    s.ticks = 0;
    s.last_tick = s.done_at = std::chrono::steady_clock::now();
    s.active = !s.steps.empty();
    if (changed) native_input_pulse::publication_changed(publication);
}
void pad_tick() noexcept {
    native_input_pulse::PublicationScope publication;
    if (!publication.owns()) return;
    auto &s = state();
    std::lock_guard lock(s.mutex);
    if (s.active && advance(s, std::chrono::steady_clock::now()))
        native_input_pulse::publication_changed(publication);
}
void hold_stick(int stick, float value, unsigned milliseconds) noexcept {
    native_input_pulse::PublicationScope publication;
    if (!publication.owns()) return;
    auto &s = state();
    std::lock_guard lock(s.mutex);
    const auto now = std::chrono::steady_clock::now();
    const auto next_stick = stick < 0 || stick > 3 ? 2 : stick;
    const auto next_value = static_cast<SHORT>(std::lround(std::clamp(value, -1.0f, 1.0f) * 32767.0f));
    const auto next_until = value == 0 ? std::chrono::steady_clock::time_point{}
                                     : now + std::chrono::milliseconds(milliseconds);
    const bool changed = (s.held_until != std::chrono::steady_clock::time_point{} ||
        next_until != std::chrono::steady_clock::time_point{}) &&
        (s.stick != next_stick || s.value != next_value || s.held_until != next_until);
    s.stick = next_stick;
    s.value = next_value;
    s.held_until = next_until;
    if (changed) native_input_pulse::publication_changed(publication);
}
bool held_stick(int& stick, SHORT& value) noexcept {
    native_input_pulse::PublicationScope publication;
    if (!publication.owns()) return false;
    auto& s = state();
    std::lock_guard lock(s.mutex);
    const auto now = std::chrono::steady_clock::now();
    // Native-only readers may never poll XInput to retire a completed script.
    if (s.active && s.current + 1 == s.steps.size() && now - s.done_at > linger) {
        s.active = false;
        native_input_pulse::publication_changed(publication);
    }
    if (s.active) return false;
    if (now >= s.held_until) {
        if (s.held_until != std::chrono::steady_clock::time_point{}) {
            s.held_until = {};
            native_input_pulse::publication_changed(publication);
        }
        return false;
    }
    stick = s.stick;
    value = s.value;
    return true;
}
bool scripted_pad(DWORD user, XINPUT_STATE &output) noexcept {
    if (user != 0) return false;
    native_input_pulse::PublicationScope publication;
    if (!publication.owns()) return false;
    auto &s = state();
    std::lock_guard lock(s.mutex);
    return scripted_pad_locked(s, publication, output);
}
bool scripted_pad(DWORD user, XINPUT_STATE &output, std::uint64_t& staged_revision) noexcept {
    if (user != 0) return false;
    native_input_pulse::PublicationScope publication;
    if (!publication.owns() || native_input_pulse::publication_revision(publication) != staged_revision) return false;
    auto &s = state();
    std::lock_guard lock(s.mutex);
    if (!scripted_pad_locked(s, publication, output)) return false;
    // Only this script's own transitions may advance the caller's stage. A foreign
    // publication before this scope is refused above; later ones fail finalization.
    staged_revision = native_input_pulse::publication_revision(publication);
    return true;
}
bool scripted_pad_active() noexcept {
    // Admission/finalization already holds the outer gate. An unguarded call
    // must not report that the source is clear or invert the native lock order.
    if (!native_input_pulse::publication_held()) return true;
    auto &s = state();
    std::lock_guard lock(s.mutex);
    const auto now = std::chrono::steady_clock::now();
    if (!s.active) return now < s.held_until;
    const bool done = s.current + 1 == s.steps.size();
    return !done || now - s.done_at <= linger;
}
} // namespace dingosdk::overlay
