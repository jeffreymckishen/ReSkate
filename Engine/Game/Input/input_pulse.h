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
struct Key {
    std::uint64_t owner{}, sequence{}, source_epoch{}, actor_ticket{};
    std::uint32_t source{};
    bool operator==(const Key&) const = default;
};
struct Input {
    Key key{};
    std::uint64_t now_ms{}, clock_observed_ms{}, serial{};
    double seconds{};
    std::uint32_t original_result{}, original_packet{};
    Pad raw{}, returned{};
    bool has_output{}, outer_game_poll{}, source_fresh{}, actor_current{};
    bool focused{}, gameplay{}, menu_closed{}, interference_clear{};
};
enum class Phase { idle, warming, press, releasing, complete, revoked };
struct Ticket { std::uint64_t generation{}; };
struct Output {
    std::uint32_t result{}, packet{};
    Pad pad{};
    bool press_candidate{}, release_candidate{};
    std::uint64_t revision{}, generation{};
};

// Portable report policy, currently unconnected to runtime input. The caller
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
        failed_ = true;
        phase_ = debt_ ? Phase::releasing : Phase::revoked;
        ++generation_;
        ++revision_;
        return true;
    }

    Output poll(Ticket ticket, const Input& in) noexcept {
        Output out{in.original_result, in.original_packet, in.returned, false, false, revision_, generation_};
        if (ticket.generation != generation_ || phase_ == Phase::idle || terminal()) return out;
        if (!in.outer_game_poll || in.key.source != key_.source) return out;

        const bool clock = in.now_ms >= last_now_ && in.serial && std::isfinite(in.seconds) && in.seconds >= 0 &&
            in.clock_observed_ms && in.clock_observed_ms <= in.now_ms &&
            in.now_ms - in.clock_observed_ms <= maximum_gap_ms &&
            (!serial_ || (in.serial >= serial_ && in.seconds >= seconds_ &&
                (in.serial != serial_ || in.seconds == seconds_) &&
                (in.serial == serial_ || in.seconds > seconds_)));
        const bool raw_path = in.original_result == 0 && in.has_output && in.outer_game_poll &&
            in.source_fresh && in.actor_current && in.key == key_ && in.returned == in.raw;
        const bool ready = raw_path && clock && in.focused && in.gameplay && in.menu_closed && in.interference_clear &&
            (!serial_ || in.seconds - seconds_ <= 0.25) &&
            (!last_poll_ || in.now_ms - last_poll_ <= maximum_gap_ms) && in.now_ms - started_ < lifetime_ms;
        if (!ready && phase_ != Phase::releasing) (void)revoke(key_);

        if (raw_path && clock) {
            const bool advanced = in.serial != serial_;
            serial_ = in.serial;
            seconds_ = in.seconds;
            last_now_ = last_poll_ = in.now_ms;
            if (phase_ == Phase::warming) {
                if (in.raw != Pad{}) {
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
                if (in.raw != Pad{}) {
                    // Preserve physical input rather than creating a chord or clearing a press.
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
            if (phase_ == Phase::releasing && in.raw == Pad{}) out.release_candidate = debt_;
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

private:
    bool terminal() const noexcept { return phase_ == Phase::complete || phase_ == Phase::revoked; }
    static constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    Key key_{};
    std::uint16_t button_{};
    Phase phase_{Phase::idle};
    std::uint64_t generation_{}, revision_{}, last_sequence_{}, started_{}, last_now_{}, last_poll_{}, serial_{};
    std::uint64_t warm_started_{}, press_started_{};
    double seconds_{};
    unsigned samples_{};
    bool debt_{}, failed_{};
};

// One persistent per-slot domain across every outer wrapper, never per request.
// Modulo-32-bit wrap preserves adjacent-change distinction, not global uniqueness.
class PacketContinuity {
public:
    std::uint32_t translate(std::uint64_t epoch, std::uint64_t revision, std::uint32_t original,
                            const Pad& raw, const Pad& final, bool activate) noexcept {
        if (!active_) {
            if (activate) {
                packet_ = seen_ ? packet_ + 1 : original + 1;
                active_ = true;
            } else packet_ = original;
        } else if (epoch != epoch_ || revision != revision_ || original != original_ || raw != raw_ || final != final_) {
            ++packet_;
        }
        seen_ = true;
        epoch_ = epoch;
        revision_ = revision;
        original_ = original;
        raw_ = raw;
        final_ = final;
        return packet_;
    }

private:
    bool active_{}, seen_{};
    std::uint32_t packet_{}, original_{};
    std::uint64_t epoch_{}, revision_{};
    Pad raw_{}, final_{};
};
}
