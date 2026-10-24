#pragma once
#include "Engine/Game/Input/input_pulse.h"
#include <cstdint>
#include <limits>

namespace dingosdk::input_lease_capture {
using Pad = input_pulse::Pad;
struct Key {
    std::uint64_t owner{}, lease_sequence{}, source_epoch{}, context_generation{};
    std::uint32_t user{};
    bool operator==(const Key&) const = default;
};
enum class Phase { idle, waiting_neutral, capturing, releasing, complete };
enum class Reason {
    none, unavailable, invalid_key, busy, exhausted, source_changed, source_stale,
    clock_regressed, authority_lost, context_changed, deadline,
    focus_lost, gameplay_inactive, menu_open, paused, interference,
    cancelled, publication_unconfirmed
};
// Runtime facts, sampled while holding the finalizer/setter publication gate.
// source_authorized means the observation broker accepted this exact key and
// observation tuple, not just that a matching handle was recently active. It
// cannot come from a Lua boolean, a pulse claim, or an actor reservation.
struct Safety {
    bool source_authorized{}, ready{}, focused{}, gameplay{}, menu_closed{}, interference_clear{};
};
struct Input {
    std::uint64_t source_epoch{}, context_generation{}, observation_serial{}, observed_ms{}, now_ms{};
    std::uint32_t user{}, original_result{}, returned_result{};
    Pad raw{}, returned{};
    Safety safety{};
    bool outer_game_poll{}, has_output{}, source_connected{};
};
struct Ticket { std::uint64_t generation{}; };
struct Plan {
    Pad pad{};
    std::uint64_t generation{}, revision{}, observation_serial{};
    bool suppress{}, start{}, release{};
    bool operator==(const Plan&) const = default;
};
struct Receipt {
    Key key{};
    Phase phase{Phase::idle};
    Reason reason{Reason::none};
    std::uint64_t generation{}, revision{}, expires_ms{}, publications{}, neutral_releases{};
    bool debt{}, quarantined{};
};

// Additive portable policy only: this class does not acquire a second actor
// claim, rewrite native memory, create controller identity, or translate packet
// numbers. The native service must serialize setters, revoke, plan, its ONE
// PacketContinuity translation, the output-buffer write, and confirm together.
class Capture {
public:
    static constexpr std::uint64_t maximum_age_ms = 100, maximum_lifetime_ms = 250;
    explicit Capture(std::uint64_t generation = 0, std::uint64_t revision = 0) noexcept {
        receipt_.generation = generation; receipt_.revision = revision;
    }

    bool request(Key key, std::uint64_t expires_ms, const Input& in, bool pulse_busy,
                 Reason& reason) noexcept {
        reason = Reason::none;
        if (receipt_.phase != Phase::idle) return fail(reason, Reason::busy);
        if (!valid(key) || key.lease_sequence <= last_sequence_) return fail(reason, Reason::invalid_key);
        if (pulse_busy) return fail(reason, Reason::busy);
        if (receipt_.generation > maximum - 3 || receipt_.revision > maximum - 3)
            return fail(reason, Reason::exhausted);
        reason = validity(key, in);
        if (reason != Reason::none) return false;
        if (in.now_ms < last_now_) return fail(reason, Reason::clock_regressed);
        if (expires_ms <= in.now_ms || expires_ms - in.now_ms > maximum_lifetime_ms)
            return fail(reason, Reason::deadline);
        const auto generation = receipt_.generation + 1, revision = receipt_.revision + 1;
        receipt_ = {key, Phase::waiting_neutral, Reason::none, generation, revision, expires_ms};
        last_sequence_ = key.lease_sequence;
        admission_serial_ = last_serial_ = in.observation_serial;
        last_observed_ms_ = in.observed_ms;
        last_now_ = in.now_ms;
        pending_ = {};
        return true;
    }

    Ticket ticket() const noexcept { return {receipt_.generation}; }
    const Receipt& state() const noexcept { return receipt_; }
    bool reserved() const noexcept { return receipt_.phase != Phase::idle && receipt_.phase != Phase::complete; }

    // The broker calls this with its verified new deadline after an exact issued
    // snapshot renewal. This internal operation does not accept a public epoch.
    bool renew(Key key, std::uint64_t expires_ms, const Input& in) noexcept {
        if (key != receipt_.key || (receipt_.phase != Phase::waiting_neutral && receipt_.phase != Phase::capturing)) return false;
        const auto reason = validity(key, in);
        if (reason != Reason::none || in.now_ms < last_now_ || in.now_ms >= receipt_.expires_ms) {
            revoke(reason != Reason::none ? reason : in.now_ms < last_now_ ? Reason::clock_regressed : Reason::deadline);
            return false;
        }
        last_now_ = in.now_ms;
        if (expires_ms <= in.now_ms || expires_ms - in.now_ms > maximum_lifetime_ms || expires_ms < receipt_.expires_ms)
            return false;
        receipt_.expires_ms = expires_ms;
        return true;
    }

    bool release(Key key) noexcept {
        if (key != receipt_.key || !reserved()) return false;
        revoke(Reason::cancelled);
        return true;
    }

    // The native finalizer also has a bounded stale-stage neutral fallback.
    // Record that attempted owned write BEFORE revoking waiting authority; a
    // setter may already have made a waiting request complete without debt.
    // Retained keys cannot be acknowledged while their outer polls remain live.
    bool retain_neutralization(Key key) noexcept {
        if (key != receipt_.key || receipt_.phase == Phase::idle) return false;
        receipt_.debt = true;
        if (receipt_.phase != Phase::releasing) {
            receipt_.phase = Phase::releasing;
            receipt_.reason = Reason::interference;
            bump(receipt_.generation); bump(receipt_.revision);
        }
        pending_ = {};
        return true;
    }
    void neutralization_result(Key key, bool published) noexcept {
        if (key != receipt_.key || !receipt_.debt) return;
        if (published) bump(receipt_.publications);
        else receipt_.reason = Reason::publication_unconfirmed;
    }
    // A delayed same-key report can maintain already owed neutral suppression
    // without becoming a new observation or a neutral-release witness.
    void continuation_result(Key key, bool published) noexcept {
        if (key != receipt_.key || !receipt_.debt ||
            (receipt_.phase != Phase::capturing && receipt_.phase != Phase::releasing)) return;
        if (published) bump(receipt_.publications);
        else {
            revoke(Reason::publication_unconfirmed);
            receipt_.reason = Reason::publication_unconfirmed;
        }
    }

    // Capture setters and owner stop/pause call this under the same gate before
    // allowing another owned report. It neither reads nor clears their flags.
    void revoke(Reason reason) noexcept {
        if (receipt_.phase == Phase::idle || receipt_.phase == Phase::complete || receipt_.phase == Phase::releasing) return;
        receipt_.reason = reason;
        receipt_.phase = receipt_.debt ? Phase::releasing : Phase::complete;
        bump(receipt_.generation); bump(receipt_.revision);
        pending_ = {};
    }

    Plan plan(Ticket ticket, const Input& in) noexcept {
        Plan pass{in.returned};
        if (!reserved() || !in.outer_game_poll || in.user != receipt_.key.user || ticket.generation != receipt_.generation)
            return pass;
        pending_ = {};
        const auto& key = receipt_.key;
        const bool same_source = in.source_connected && in.source_epoch == key.source_epoch && in.source_epoch;
        receipt_.quarantined = receipt_.debt && !same_source;
        if (!same_source) { revoke(Reason::source_changed); return pass; }
        if (!in.has_output || in.original_result != 0 || in.returned_result != in.original_result) {
            revoke(Reason::interference); return pass;
        }
        if (!in.now_ms || in.now_ms < last_now_) { revoke(Reason::clock_regressed); return pass; }
        last_now_ = in.now_ms;
        if (!in.observation_serial || in.observation_serial <= last_serial_ || !in.observed_ms || in.observed_ms < last_observed_ms_ ||
            in.observed_ms > in.now_ms || in.now_ms - in.observed_ms > maximum_age_ms) {
            revoke(Reason::source_stale); return pass;
        }
        last_serial_ = in.observation_serial;
        last_observed_ms_ = in.observed_ms;
        if (receipt_.phase != Phase::releasing) {
            const auto reason = safety_reason(in.safety);
            if (reason != Reason::none) revoke(reason);
            else if (in.context_generation != key.context_generation) revoke(Reason::context_changed);
            else if (in.now_ms >= receipt_.expires_ms) revoke(Reason::deadline);
        }
        if (receipt_.phase == Phase::complete) return pass;
        // An independently owned filter/report wins. Keep our debt and source
        // reservation, and wait for a clean same-source handoff opportunity.
        if (!in.safety.interference_clear || in.returned != in.raw) {
            revoke(Reason::interference); return pass;
        }
        if (receipt_.phase == Phase::waiting_neutral &&
            (in.observation_serial <= admission_serial_ || in.raw != Pad{})) return pass;
        pending_ = {{}, receipt_.generation, receipt_.revision, in.observation_serial, true,
                    receipt_.phase == Phase::waiting_neutral,
                    receipt_.phase == Phase::releasing && in.raw == Pad{}};
        return pending_;
    }

    // A failed/uncertain attempted write may have partially changed the buffer.
    // It therefore retains debt even for the first attempted neutral capture.
    // Confirm is publication evidence, never a wrapper-return/consumption proof.
    bool confirm(const Plan& plan, bool published) noexcept {
        if (!plan.suppress || plan != pending_ || plan.generation != receipt_.generation ||
            plan.revision != receipt_.revision || !reserved()) return false;
        pending_ = {};
        if (!published) {
            receipt_.debt = true;
            revoke(Reason::publication_unconfirmed);
            return false;
        }
        if (receipt_.publications != maximum) ++receipt_.publications;
        if (plan.release) {
            receipt_.debt = false;
            receipt_.phase = Phase::complete;
            bump(receipt_.neutral_releases);
            bump(receipt_.generation); bump(receipt_.revision);
        } else {
            receipt_.debt = true;
            if (plan.start) receipt_.phase = Phase::capturing;
        }
        return true;
    }

    bool acknowledge(Key key) noexcept {
        if (key != receipt_.key || receipt_.phase != Phase::complete || receipt_.debt) return false;
        const auto generation = receipt_.generation, revision = receipt_.revision;
        receipt_ = {}; receipt_.generation = generation; receipt_.revision = revision;
        pending_ = {};
        return true;
    }

private:
    static constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    static void bump(std::uint64_t& value) noexcept { if (value != maximum) ++value; }
    static bool fail(Reason& out, Reason reason) noexcept { out = reason; return false; }
    static bool valid(Key key) noexcept {
        return key.owner && key.lease_sequence && key.source_epoch && key.context_generation && key.user < 4;
    }
    static Reason safety_reason(const Safety& safety) noexcept {
        if (!safety.source_authorized || !safety.ready) return Reason::authority_lost;
        if (!safety.focused) return Reason::focus_lost;
        if (!safety.gameplay) return Reason::gameplay_inactive;
        if (!safety.menu_closed) return Reason::menu_open;
        if (!safety.interference_clear) return Reason::interference;
        return Reason::none;
    }
    static Reason validity(Key key, const Input& in) noexcept {
        if (!in.outer_game_poll || in.user != key.user || !in.source_connected || in.source_epoch != key.source_epoch)
            return Reason::source_changed;
        if (!in.has_output || in.original_result != 0 || in.returned_result != in.original_result || in.raw != in.returned)
            return Reason::interference;
        if (!in.now_ms || !in.observation_serial || !in.observed_ms || in.observed_ms > in.now_ms ||
            in.now_ms - in.observed_ms > maximum_age_ms) return Reason::source_stale;
        if (in.context_generation != key.context_generation) return Reason::context_changed;
        return safety_reason(in.safety);
    }
    Receipt receipt_{};
    Plan pending_{};
    std::uint64_t last_sequence_{}, admission_serial_{}, last_serial_{}, last_observed_ms_{}, last_now_{};
};
}
