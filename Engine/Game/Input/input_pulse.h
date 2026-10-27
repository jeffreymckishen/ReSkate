#pragma once
#include <cmath>
#include <cstdint>
#include <limits>

namespace dingosdk::input_pulse {
struct Pad {
    std::uint16_t buttons{};
    std::uint8_t left_trigger{}, right_trigger{};
    std::int16_t left_x{}, left_y{}, right_x{}, right_y{};
    bool operator==(const Pad&) const = default;
};
// The SDK's one definition of a pad at rest. A controller resting in the hands
// reports small stick and trigger noise, so rest is the XInput SDK's own dead
// zones (XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE,
// XINPUT_GAMEPAD_TRIGGER_THRESHOLD), not exact zero. XInput gives the stick
// values as radii, so a stick rests inside a circle: a square of the same size
// would count a diagonal push at 1.41 times the radius as rest. A trigger above
// the threshold counts as pressed, as XInput says. No button has a dead zone.
inline constexpr std::int32_t left_stick_rest = 7849, right_stick_rest = 8689, trigger_rest = 30;
constexpr bool stick_at_rest(std::int16_t x, std::int16_t y, std::int32_t radius) noexcept {
    const std::int64_t dx = x, dy = y, r = radius;
    return dx * dx + dy * dy <= r * r;
}
constexpr bool trigger_at_rest(std::uint8_t value) noexcept { return value <= trigger_rest; }
constexpr bool neutral(const Pad& pad) noexcept {
    return !pad.buttons && trigger_at_rest(pad.left_trigger) && trigger_at_rest(pad.right_trigger) &&
        stick_at_rest(pad.left_x, pad.left_y, left_stick_rest) && stick_at_rest(pad.right_x, pad.right_y, right_stick_rest);
}
struct Key {
    std::uint64_t owner{}, sequence{}, source_epoch{}, actor_ticket{};
    std::uint32_t source{};
    bool operator==(const Key&) const = default;
};
struct Input {
    Key key{};
    std::uint64_t now_ms{}, source_observed_ms{}, clock_observed_ms{}, serial{};
    double seconds{};
    std::uint32_t original_result{}, original_packet{};
    Pad raw{}, returned{};
    bool has_output{}, outer_game_poll{}, source_fresh{}, actor_current{};
    bool transport_matches{true};
    bool focused{}, gameplay{}, menu_closed{}, interference_clear{};
};
enum class Phase { idle, warming, press, releasing, complete, revoked };
// Facts that failed at the first rejected owned decision, not a causal diagnosis.
// Unrelated routes and stale tickets are bypassed before evaluating these facts.
enum class FailedCheck : std::uint32_t {
    original_result = 1u << 0, output = 1u << 1, source_fresh = 1u << 2,
    transport_result = 1u << 3, interference = 1u << 4, key = 1u << 5,
    raw_equality = 1u << 6, source_clock = 1u << 7, native_clock = 1u << 8,
    native_continuity = 1u << 9, actor = 1u << 10, focus = 1u << 11,
    gameplay = 1u << 12, menu = 1u << 13, native_gap = 1u << 14,
    poll_gap = 1u << 15, deadline = 1u << 16, physical_activity = 1u << 17
};
constexpr std::uint32_t failure_bit(FailedCheck check) noexcept { return static_cast<std::uint32_t>(check); }
inline constexpr std::uint32_t failure_bits = (1u << 18) - 1;
struct Ticket { std::uint64_t generation{}; };
struct Output {
    std::uint32_t result{}, packet{};
    Pad pad{};
    bool press_candidate{}, release_candidate{};
    std::uint64_t revision{}, generation{};
};

// Portable report policy. The private runtime report service is its caller and
// supplies qualified facts and serializes poll, publication and confirmation.
// A planned or published report is not proof that native input consumed it.
class Pulse {
public:
    static constexpr std::uint64_t warmup_ms = 100, maximum_press_ms = 200;
    static constexpr std::uint64_t lifetime_ms = 1000, maximum_gap_ms = 100;
    static constexpr unsigned warmup_samples = 4;

    explicit Pulse(std::uint64_t generation = 0, std::uint64_t revision = 0) noexcept
        : generation_(generation), revision_(revision) {}

    bool request(Key key, std::uint16_t button, std::uint64_t now) noexcept {
        if (phase_ != Phase::idle || !key.owner || !key.sequence || key.sequence <= last_sequence_ ||
            !key.source_epoch || !key.actor_ticket || key.source > 3 || !now || now < last_now_ ||
            !button || (button & (button - 1)) || (button & 0x0c00) ||
            generation_ > maximum - 3 || revision_ > maximum - 6) return false;

        key_ = key;
        button_ = button;
        started_ = last_now_ = now;
        last_poll_ = serial_ = 0;
        seconds_ = 0;
        warm_started_ = press_started_ = 0;
        samples_ = 0;
        debt_ = failed_ = false;
        first_rejection_mask_ = 0;
        rejection_recorded_ = false;
        last_sequence_ = key.sequence;
        phase_ = Phase::warming;
        ++generation_;
        ++revision_;
        return true;
    }

    Ticket ticket() const noexcept { return {generation_}; }

    bool revoke(Key key) noexcept {
        if (key != key_ || phase_ == Phase::idle || terminal()) return false;
        // Idempotence bounds one request to three generation and six revision advances.
        if (failed_) return true;
        remember_rejection(0); // External cancellation/revocation has no invented failed facts.
        failed_ = true;
        phase_ = debt_ ? Phase::releasing : Phase::revoked;
        ++generation_;
        ++revision_;
        return true;
    }

    // Only a trusted caller can classify the precise temporary observation
    // refusal. This does not make the missing actor or native clock known.
    // Failed attempts leave both policy state and the caller's output untouched.
    bool defer_warmup(Ticket ticket, const Input& in, Output& passthrough) noexcept {
        if (ticket.generation != generation_ || phase_ != Phase::warming || failed_ || debt_ || rejection_recorded_ ||
            in.key != key_ || !in.outer_game_poll || in.original_result != 0 || !in.has_output ||
            !in.source_fresh || !in.transport_matches || !in.interference_clear || in.returned != in.raw || !neutral(in.raw) ||
            !in.focused || !in.gameplay || !in.menu_closed || in.actor_current ||
            in.serial != 0 || in.clock_observed_ms != 0 || in.seconds != 0 ||
            in.now_ms < last_now_ || !in.source_observed_ms || in.source_observed_ms > in.now_ms ||
            in.now_ms - in.source_observed_ms > maximum_gap_ms ||
            (last_poll_ && in.now_ms - last_poll_ > maximum_gap_ms) || in.now_ms - started_ >= lifetime_ms) return false;

        // Keep the immutable request and native high-water marks. A later full
        // observation still has to advance them and build an entirely new dwell.
        warm_started_ = 0;
        samples_ = 0;
        last_now_ = last_poll_ = in.now_ms;
        passthrough = {in.original_result, in.original_packet, in.returned, false, false, revision_, generation_};
        return true;
    }

    Output poll(Ticket ticket, const Input& in) noexcept {
        Output out{in.original_result, in.original_packet, in.returned, false, false, revision_, generation_};
        if (ticket.generation != generation_ || phase_ == Phase::idle || terminal()) return out;
        if (!in.outer_game_poll || in.key.source != key_.source) return out;

        const bool source_clock = in.now_ms >= last_now_ && in.source_observed_ms &&
            in.source_observed_ms <= in.now_ms && in.now_ms - in.source_observed_ms <= maximum_gap_ms;
        const bool native_clock = in.now_ms >= last_now_ && in.serial && std::isfinite(in.seconds) && in.seconds >= 0 &&
            in.clock_observed_ms && in.clock_observed_ms <= in.now_ms &&
            in.now_ms - in.clock_observed_ms <= maximum_gap_ms;
        const bool continuity = !serial_ || (in.serial >= serial_ && in.seconds >= seconds_ &&
                (in.serial != serial_ || in.seconds == seconds_) &&
                (in.serial == serial_ || in.seconds > seconds_));
        const bool clock = native_clock && continuity;
        const bool raw_path = in.original_result == 0 && in.has_output && in.outer_game_poll &&
            in.source_fresh && in.interference_clear && in.key == key_ && in.returned == in.raw && in.transport_matches;
        const bool native_gap = !serial_ || in.seconds - seconds_ <= 0.25;
        const bool poll_gap = !last_poll_ || in.now_ms - last_poll_ <= maximum_gap_ms;
        const bool deadline = in.now_ms - started_ < lifetime_ms;
        const bool ready = raw_path && source_clock && clock && in.actor_current &&
            in.focused && in.gameplay && in.menu_closed && in.interference_clear &&
            native_gap && poll_gap && deadline;
        if (!ready && phase_ != Phase::releasing) {
            std::uint32_t mask{};
            const auto add = [&](bool passed, FailedCheck check) { if (!passed) mask |= failure_bit(check); };
            add(in.original_result == 0, FailedCheck::original_result); add(in.has_output, FailedCheck::output);
            add(in.source_fresh, FailedCheck::source_fresh); add(in.transport_matches, FailedCheck::transport_result);
            add(in.interference_clear, FailedCheck::interference); add(in.key == key_, FailedCheck::key);
            add(in.returned == in.raw, FailedCheck::raw_equality); add(source_clock, FailedCheck::source_clock);
            add(native_clock, FailedCheck::native_clock);
            // Continuity and native-gap comparisons need a usable native sample.
            // An absent/nonfinite clock reports native_clock rather than made-up drift.
            add(!native_clock || continuity, FailedCheck::native_continuity);
            add(!native_clock || native_gap, FailedCheck::native_gap);
            add(in.actor_current, FailedCheck::actor); add(in.focused, FailedCheck::focus);
            add(in.gameplay, FailedCheck::gameplay); add(in.menu_closed, FailedCheck::menu);
            add(poll_gap, FailedCheck::poll_gap); add(deadline, FailedCheck::deadline);
            remember_rejection(mask);
            (void)revoke(key_);
        }

        if (raw_path && source_clock) {
            const bool advanced = in.serial != serial_;
            last_now_ = last_poll_ = in.now_ms;
            if (clock && in.actor_current) {
                serial_ = in.serial;
                seconds_ = in.seconds;
            }
            // Neutral is the rest rule above, not exact zero, so a controller
            // resting in the hands warms, presses and releases; its noise passes
            // through untouched beside the pressed button.
            if (phase_ == Phase::warming) {
                if (!neutral(in.raw)) {
                    warm_started_ = 0;
                    samples_ = 0;
                } else {
                    if (!samples_) warm_started_ = in.now_ms;
                    if (advanced && samples_ < warmup_samples) ++samples_;
                    if (advanced && samples_ >= warmup_samples && in.now_ms - warm_started_ >= warmup_ms) {
                        phase_ = Phase::press;
                        press_started_ = in.now_ms;
                        ++revision_;
                    }
                }
            }
            if (phase_ == Phase::press) {
                if (!neutral(in.raw)) {
                    // Preserve physical input rather than creating a chord or clearing a press.
                    remember_rejection(failure_bit(FailedCheck::physical_activity));
                    (void)revoke(key_);
                } else if (in.now_ms - press_started_ >= maximum_press_ms) {
                    phase_ = Phase::releasing;
                    ++revision_;
                } else {
                    out.pad.buttons = static_cast<std::uint16_t>(out.pad.buttons | button_);
                    out.press_candidate = true;
                    debt_ = true;
                }
            }
            // Returning the original neutral report removes our overlay. It
            // neither touches an old actor nor needs that actor's step clock.
            if (phase_ == Phase::releasing && neutral(in.raw)) out.release_candidate = debt_;
        }
        out.revision = revision_;
        out.generation = generation_;
        return out;
    }

    // Confirm output-buffer publication under the same gate. This cannot prove
    // the wrapper's later return or native consumption. Uncertain writes retain debt.
    bool confirm(const Output& out, bool published) noexcept {
        if (out.generation != generation_ || out.revision != revision_ || terminal() || phase_ == Phase::idle) return false;
        if (!published) {
            if (out.press_candidate) (void)revoke(key_);
            return false;
        }
        if (out.release_candidate && phase_ == Phase::releasing && debt_) {
            debt_ = false;
            phase_ = failed_ ? Phase::revoked : Phase::complete;
            ++revision_;
        }
        return true;
    }

    bool acknowledge(Key key) noexcept {
        if (key != key_ || !terminal() || debt_) return false;
        phase_ = Phase::idle;
        ++generation_;
        ++revision_;
        return true;
    }

    Phase phase() const noexcept { return phase_; }
    bool release_debt() const noexcept { return debt_; }
    std::uint64_t revision() const noexcept { return revision_; }
    std::uint32_t first_rejection_mask() const noexcept { return first_rejection_mask_; }

private:
    void remember_rejection(std::uint32_t mask) noexcept {
        if (!rejection_recorded_) { first_rejection_mask_ = mask; rejection_recorded_ = true; }
    }
    bool terminal() const noexcept { return phase_ == Phase::complete || phase_ == Phase::revoked; }
    static constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    Key key_{};
    std::uint16_t button_{};
    Phase phase_{Phase::idle};
    std::uint64_t generation_{}, revision_{}, last_sequence_{}, started_{}, last_now_{}, last_poll_{}, serial_{};
    std::uint64_t warm_started_{}, press_started_{};
    double seconds_{};
    unsigned samples_{};
    std::uint32_t first_rejection_mask_{};
    bool debt_{}, failed_{}, rejection_recorded_{};
};

// One persistent per-slot domain across every outer wrapper, never per request.
// Modulo-32-bit wrap preserves adjacent-change distinction, not global uniqueness.
class PacketContinuity {
public:
    std::uint32_t translate(std::uint64_t epoch, std::uint64_t revision, std::uint32_t original,
                            const Pad& raw, const Pad& final, bool activate) noexcept {
        return translate(epoch, revision, original, original, raw, final, activate);
    }

    std::uint32_t translate(std::uint64_t epoch, std::uint64_t revision, std::uint32_t original,
                            std::uint32_t returned, const Pad& raw, const Pad& final, bool activate) noexcept {
        if (!active_) {
            if (activate) {
                packet_ = seen_ ? packet_ + 1 : returned + 1;
                active_ = true;
            } else packet_ = returned;
        } else if (epoch != epoch_ || revision != revision_ || original != original_ || returned != returned_ ||
                   raw != raw_ || final != final_) {
            ++packet_;
        }
        seen_ = true;
        epoch_ = epoch;
        revision_ = revision;
        original_ = original;
        returned_ = returned;
        raw_ = raw;
        final_ = final;
        return packet_;
    }

private:
    bool active_{}, seen_{};
    std::uint32_t packet_{}, original_{}, returned_{};
    std::uint64_t epoch_{}, revision_{};
    Pad raw_{}, final_{};
};
}
