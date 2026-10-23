#pragma once
#include "actor_control_policy.h"
#include <cmath>
#include <cstdint>
#include <limits>

namespace dingosdk::body_follow {
// The adapter issues these opaque tokens only after qualifying its complete
// native identity. They are not pointers, native handles or lifetime detectors.
struct Actor {
    std::uint64_t identity{}, lifetime{}, world{};
    bool operator==(const Actor&) const = default;
};
struct Body {
    std::uint64_t identity{}, generation{}, world{};
    bool operator==(const Body&) const = default;
};
struct Handle {
    std::uint64_t sequence{};
    actor_control::Ticket ticket{};
    bool operator==(const Handle&) const = default;
};
// Identifies an immutable, independently qualified measured sample. The native
// adapter retains the actual pose/velocity; this policy performs no mapping.
struct Sample {
    Body body{};
    std::uint64_t serial{}, observed_ms{};
    double time{};
    bool operator==(const Sample&) const = default;
};
struct Qualification {
    Actor actor{};
    Body body{};
    bool actor_current{}, body_current{}, writers_clear{};
};
struct Publication {
    Handle handle{};
    Sample sample{};
    std::uint64_t revision{}, expires_ms{};
    bool operator==(const Publication&) const = default;
};
struct Release {
    Handle handle{};
    Actor actor{};
    Body body{};
    std::uint64_t revision{}, revoked_ms{};
    bool operator==(const Release&) const = default;
};
// qualified attests a real external proof of the ONE supplied barrier. A later
// wall stamp only rejects prepaid facts; it does not prove native consumption.
struct Witness {
    Release release{};
    actor_control::Barrier barrier{actor_control::Barrier::none};
    std::uint64_t observed_ms{};
    bool qualified{};
};
enum class Status { none, admitting, active, revoking, quarantined, rejected, released };
enum class Reason {
    none, invalid_owner, invalid_identity, busy, invalid_sample, stale_sample,
    sample_regressed, clock_invalid, qualification_lost, competing_writer,
    lease_expired, owner_released, cleanup_unavailable, sequence_exhausted,
    revision_exhausted
};
constexpr bool terminal(Status status) noexcept { return status == Status::rejected || status == Status::released; }
struct Receipt {
    Handle handle{};
    Actor actor{};
    Body body{};
    Status status{Status::none};
    Reason reason{Reason::none};
    Publication publication{};
    Release release{};
    std::uint64_t requested_ms{}, observed_ms{}, drained_ms{}, native_consumed_ms{}, body_parked_ms{};
    unsigned in_flight{};
    actor_control::Barrier pending{actor_control::Barrier::none};
    bool orphaned{}, claim_released{}, in_flight_known{};
    bool operator==(const Receipt&) const = default;
};

// Caller serialization protects this model. The supplied process-wide arbiter
// must outlive it and every Call. Only this session mutates its own ticket.
// One retained terminal receipt blocks another reservation until acknowledged.
template<class Gate>
class BasicSession {
public:
    static constexpr std::uint64_t lease_ms = 200, maximum_sample_age_ms = 100;
    static constexpr auto release_barriers = actor_control::Barrier::native_consumed | actor_control::Barrier::body_parked;
    // Seeds permit bounded exhaustion tests. Sequences never repeat; revisions
    // restart only with a new handle and never wrap within that session.
    explicit BasicSession(Gate& arbiter, std::uint64_t first_sequence = 1,
        std::uint64_t first_revision = 1) noexcept
        : arbiter_(arbiter), next_sequence_(first_sequence), first_revision_(first_revision) {}
    BasicSession(const BasicSession&) = delete;
    BasicSession& operator=(const BasicSession&) = delete;

    bool reserve(std::uint64_t owner, Actor actor, Body body, std::uint64_t now,
        Handle& out, Reason& reason) noexcept {
        out = {}; reason = Reason::none;
        if (!owner) { reason = Reason::invalid_owner; return false; }
        if (!valid(actor) || !valid(body) || actor.world != body.world) { reason = Reason::invalid_identity; return false; }
        if (occupied_) { reason = Reason::busy; return false; }
        if (!lease_wall(now)) { reason = Reason::clock_invalid; return false; }
        if (!next_sequence_) { reason = Reason::sequence_exhausted; return false; }
        if (!first_revision_) { reason = Reason::revision_exhausted; return false; }
        actor_control::Ticket ticket;
        if (!arbiter_.reserve(owner, actor_control::Domain::follow, ticket)) { reason = Reason::busy; return false; }
        receipt_ = {}; owner_ = owner; occupied_ = true;
        receipt_.handle = {next_sequence_, ticket};
        next_sequence_ = next_sequence_ == maximum ? 0 : next_sequence_ + 1;
        receipt_.actor = actor; receipt_.body = body;
        receipt_.requested_ms = receipt_.observed_ms = now;
        receipt_.status = Status::admitting; out = receipt_.handle;
        return true;
    }
    bool activate(std::uint64_t owner, Handle handle, const Sample& sample,
        const Qualification& qualified, std::uint64_t now) noexcept {
        if (!owns(owner, handle) || receipt_.status != Status::admitting) return false;
        const auto issue = check(sample, qualified, now);
        if (issue != Reason::none) { reject(issue); return false; }
        if (!lease_wall(now)) { reject(Reason::clock_invalid); return false; }
        if (now - receipt_.requested_ms >= lease_ms) { reject(Reason::lease_expired); return false; }
        if (!arbiter_.publish(owner_, handle.ticket)) { quarantine(Reason::cleanup_unavailable); return false; }
        receipt_.publication = {handle, sample, first_revision_, now + lease_ms};
        receipt_.status = Status::active;
        return true;
    }
    bool publish(std::uint64_t owner, Handle handle, const Sample& sample,
        const Qualification& qualified, std::uint64_t now) noexcept {
        if (!owns(owner, handle) || receipt_.status != Status::active) return false;
        const auto issue = check(sample, qualified, now);
        if (issue != Reason::none) { revoke(issue); return false; }
        if (now >= receipt_.publication.expires_ms) { revoke(Reason::lease_expired); return false; }
        const auto& previous = receipt_.publication.sample;
        if (sample == previous) return true; // Idempotent; never renew an old epoch's lease.
        if (sample.serial <= previous.serial || sample.time <= previous.time || sample.observed_ms < previous.observed_ms) {
            revoke(Reason::sample_regressed); return false;
        }
        if (!lease_wall(now)) { revoke(Reason::clock_invalid); return false; }
        if (receipt_.publication.revision == maximum) { revoke(Reason::revision_exhausted); return false; }
        receipt_.publication = {handle, sample, receipt_.publication.revision + 1, now + lease_ms};
        return true;
    }
    bool enter(std::uint64_t owner, Handle handle, const Qualification& qualified, std::uint64_t now,
        actor_control::Call& call, Publication& publication) noexcept {
        publication = {};
        if (!owns(owner, handle) || receipt_.status != Status::active) return false;
        const auto issue = current(qualified, now);
        if (issue != Reason::none) { revoke(issue); return false; }
        if (!arbiter_.enter(owner_, handle.ticket, call)) return false;
        publication = receipt_.publication;
        return true;
    }
    // Recheck immediately before each accepted write/forwarding edge while the
    // adapter serializes publication. This does not lock native memory.
    bool current(std::uint64_t owner, Handle handle, const Publication& publication,
        const Qualification& qualified, std::uint64_t now) noexcept {
        if (!owns(owner, handle) || receipt_.status != Status::active) return false;
        const auto issue = current(qualified, now);
        if (issue != Reason::none) { revoke(issue); return false; }
        return publication == receipt_.publication;
    }
    bool release(std::uint64_t owner, Handle handle, std::uint64_t now) noexcept {
        if (!owns(owner, handle) || terminal(receipt_.status)) return false;
        const bool valid_wall = advance(now);
        if (receipt_.status == Status::admitting) return reject(valid_wall ? Reason::none : Reason::clock_invalid);
        return revoke(valid_wall ? Reason::none : Reason::clock_invalid);
    }
    void unload(std::uint64_t owner, std::uint64_t now) noexcept {
        if (!occupied_ || owner != owner_ || terminal(receipt_.status)) return;
        receipt_.orphaned = true;
        (void)advance(now);
        if (receipt_.status == Status::admitting) (void)reject(Reason::owner_released);
        else (void)revoke(Reason::owner_released);
    }
    bool cleanup_unknown(std::uint64_t owner, Handle handle, std::uint64_t now) noexcept {
        if (!owns(owner, handle) || terminal(receipt_.status) || receipt_.status == Status::admitting) return false;
        (void)advance(now);
        if (!revoke(Reason::cleanup_unavailable)) return false;
        quarantine(Reason::cleanup_unavailable); return true;
    }
    bool prove(std::uint64_t owner, Handle handle, actor_control::Barrier barrier,
        const Witness& witness, std::uint64_t now) noexcept {
        if (!owns(owner, handle) || !revoking() || !has_release() || !advance(now) ||
            (barrier != actor_control::Barrier::native_consumed && barrier != actor_control::Barrier::body_parked) ||
            !witness.qualified || witness.barrier != barrier || witness.release != receipt_.release ||
            witness.observed_ms <= receipt_.release.revoked_ms || witness.observed_ms > now) return false;
        const auto state = arbiter_.snapshot();
        // A writer still in flight could publish after a readback. Neither
        // barrier is accepted until every accepted native scope has returned.
        if (!matching(state) || state.in_flight) return false;
        observe_drain(state);
        if (witness.observed_ms <= receipt_.drained_ms || !arbiter_.satisfy(owner_, handle.ticket, barrier)) return false;
        auto& recorded = barrier == actor_control::Barrier::native_consumed ? receipt_.native_consumed_ms : receipt_.body_parked_ms;
        if (!recorded) recorded = witness.observed_ms;
        finish(); return true;
    }
    void tick(std::uint64_t now) noexcept {
        if (!occupied_ || terminal(receipt_.status)) return;
        if (!advance(now)) {
            if (receipt_.status == Status::admitting) (void)reject(Reason::clock_invalid);
            else (void)revoke(Reason::clock_invalid);
            return;
        }
        if (receipt_.status == Status::admitting && now - receipt_.requested_ms >= lease_ms) (void)reject(Reason::lease_expired);
        else if (receipt_.status == Status::active) {
            if (now >= receipt_.publication.expires_ms) (void)revoke(Reason::lease_expired);
            else if (now - receipt_.publication.sample.observed_ms > maximum_sample_age_ms) (void)revoke(Reason::stale_sample);
        }
        if (revoking()) {
            if (!has_release()) (void)revoke(Reason::none);
            finish();
        }
    }
    bool read(std::uint64_t owner, Handle handle, Receipt& out) const noexcept {
        if (!owns(owner, handle)) return false;
        if (!terminal(receipt_.status)) {
            const auto state = arbiter_.snapshot();
            if (!matching(state)) return false;
            out = receipt_; out.in_flight = state.in_flight; out.in_flight_known = true; out.pending = state.pending;
        } else {
            out = receipt_;
        }
        return true;
    }
    bool acknowledge(std::uint64_t owner, Handle handle) noexcept {
        if (!owns(owner, handle) || !terminal(receipt_.status) || !receipt_.claim_released) return false;
        occupied_ = false; owner_ = 0; receipt_ = {}; return true;
    }

private:
    static constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    static bool valid(Actor actor) noexcept { return actor.identity && actor.lifetime && actor.world; }
    static bool valid(Body body) noexcept { return body.identity && body.generation && body.world; }
    static bool lease_wall(std::uint64_t now) noexcept { return now && now <= maximum - lease_ms; }
    bool owns(std::uint64_t owner, Handle handle) const noexcept {
        return occupied_ && owner && owner == owner_ && handle.sequence && handle == receipt_.handle;
    }
    bool matching(const actor_control::Snapshot& state) const noexcept {
        return state.available && state.owner == owner_ && state.ticket == receipt_.handle.ticket &&
            state.domain == actor_control::Domain::follow;
    }
    bool revoking() const noexcept { return receipt_.status == Status::revoking || receipt_.status == Status::quarantined; }
    bool has_release() const noexcept {
        return receipt_.release.handle == receipt_.handle && receipt_.release.revision != 0;
    }
    bool has_publication() const noexcept {
        return receipt_.publication.handle == receipt_.handle && receipt_.publication.revision != 0 &&
            receipt_.publication.expires_ms != 0 && receipt_.publication.sample.serial != 0 &&
            receipt_.publication.sample.body == receipt_.body;
    }
    bool advance(std::uint64_t now) noexcept {
        // Only lease creation adds lease_ms. Cleanup and current-use checks
        // still accept later monotonic timestamps near the clock's limit.
        if (!now || now < receipt_.observed_ms) return false;
        receipt_.observed_ms = now; return true;
    }
    Reason check(const Sample& sample, const Qualification& qualified, std::uint64_t now) noexcept {
        if (!advance(now)) return Reason::clock_invalid;
        const auto state = arbiter_.snapshot();
        const auto phase = receipt_.status == Status::admitting ? actor_control::Phase::admitting : actor_control::Phase::published;
        if (!matching(state) || state.phase != phase) return Reason::qualification_lost;
        if (!qualified.actor_current || !qualified.body_current || qualified.actor != receipt_.actor || qualified.body != receipt_.body)
            return Reason::qualification_lost;
        if (!qualified.writers_clear) return Reason::competing_writer;
        if (sample.body != receipt_.body || !sample.serial || !sample.observed_ms || !std::isfinite(sample.time) || sample.time < 0)
            return Reason::invalid_sample;
        if (sample.observed_ms > now || now - sample.observed_ms > maximum_sample_age_ms) return Reason::stale_sample;
        return Reason::none;
    }
    Reason current(const Qualification& qualified, std::uint64_t now) noexcept {
        const auto issue = check(receipt_.publication.sample, qualified, now);
        if (issue != Reason::none) return issue;
        if (now >= receipt_.publication.expires_ms) return Reason::lease_expired;
        return Reason::none;
    }
    void quarantine(Reason reason) noexcept {
        receipt_.status = Status::quarantined;
        if (receipt_.reason == Reason::none) receipt_.reason = reason;
    }
    bool reject(Reason reason) noexcept {
        if (!arbiter_.abandon(owner_, receipt_.handle.ticket)) { quarantine(Reason::cleanup_unavailable); return false; }
        receipt_.status = Status::rejected; receipt_.reason = reason; receipt_.claim_released = receipt_.in_flight_known = true;
        return true;
    }
    bool revoke(Reason reason) noexcept {
        if (revoking() && has_release()) return true;
        if (receipt_.status != Status::active && !revoking()) {
            quarantine(Reason::cleanup_unavailable); return false;
        }
        if (receipt_.reason == Reason::none) receipt_.reason = reason;
        const auto state = arbiter_.snapshot();
        // A bounded failed revocation stops local writes immediately. A later
        // cleanup attempt may retry only this exact retained published claim;
        // no admission, foreign generation or empty publication is adopted.
        if (!has_publication() || !matching(state) ||
            (state.phase != actor_control::Phase::published && state.phase != actor_control::Phase::revoking) ||
            !arbiter_.revoke(owner_, receipt_.handle.ticket, release_barriers)) {
            quarantine(Reason::cleanup_unavailable); return false;
        }
        const auto stopped = arbiter_.snapshot();
        if (!matching(stopped) || stopped.phase != actor_control::Phase::revoking || stopped.required != release_barriers) {
            quarantine(Reason::cleanup_unavailable); return false;
        }
        if (receipt_.status != Status::quarantined) receipt_.status = Status::revoking;
        // Establish this fence once, after actual shared revocation succeeds.
        // Later cleanup cannot replace the final publication or this identity.
        receipt_.release = {receipt_.handle, receipt_.actor, receipt_.body, receipt_.publication.revision, receipt_.observed_ms};
        observe_drain(stopped);
        return true;
    }
    void finish() noexcept {
        const auto state = arbiter_.snapshot();
        observe_drain(state);
        if (!receipt_.native_consumed_ms || !receipt_.body_parked_ms || !matching(state) ||
            state.phase != actor_control::Phase::revoking || state.in_flight ||
            state.pending != actor_control::Barrier::none || !arbiter_.retire(owner_, receipt_.handle.ticket)) return;
        receipt_.status = Status::released; receipt_.claim_released = receipt_.in_flight_known = true;
        receipt_.in_flight = 0; receipt_.pending = actor_control::Barrier::none;
    }
    void observe_drain(const actor_control::Snapshot& state) noexcept {
        if (!receipt_.drained_ms && matching(state) && state.phase == actor_control::Phase::revoking && !state.in_flight)
            receipt_.drained_ms = receipt_.observed_ms;
    }
    Gate& arbiter_;
    Receipt receipt_{};
    std::uint64_t owner_{}, next_sequence_{}, first_revision_{};
    bool occupied_{};
};
// Production always uses the process-wide concrete arbiter. Tests can forward
// through it while refusing one bounded transition, without fabricating proofs.
using Session = BasicSession<actor_control::Arbiter>;
} // namespace dingosdk::body_follow
