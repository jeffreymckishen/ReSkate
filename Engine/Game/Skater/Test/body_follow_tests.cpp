#include "Engine/Game/Skater/body_follow.h"
#include "Engine/Game/Skater/body_follow_transform.h"
#include <array>
#include <bit>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <type_traits>

namespace f = dingosdk::body_follow;
namespace c = dingosdk::actor_control;
namespace t = dingosdk::body_follow_transform;
namespace {
unsigned checks{};
void require(bool condition, const char* why) {
    ++checks;
    if (!condition) { std::cerr << "body follow: " << why << '\n'; std::exit(1); }
}
struct Fixture {
    static constexpr std::uint64_t owner = 7;
    c::Arbiter arbiter;
    f::Session session{arbiter};
    f::Actor actor{11, 12, 13};
    f::Body body{21, 22, 13};
    f::Handle handle;
    f::Qualification qualification() const { return {actor, body, true, true, true}; }
    f::Sample measured(std::uint64_t wall = 100, std::uint64_t serial = 1, double time = 1) const {
        return {body, serial, wall, time};
    }
    void reserve(std::uint64_t wall = 100) {
        f::Reason reason{};
        require(session.reserve(owner, actor, body, wall, handle, reason) && reason == f::Reason::none,
            "qualified candidate reserves a generation before native admission");
    }
    void start() {
        reserve();
        require(session.activate(owner, handle, measured(), qualification(), 100), "qualified measured sample activates follow");
    }
    f::Receipt read() const {
        f::Receipt result;
        require(session.read(owner, handle, result), "receipt belongs to exact owner/session");
        return result;
    }
    f::Witness witness(std::uint64_t observed, c::Barrier barrier = c::Barrier::native_consumed) const {
        return {read().release, barrier, observed, true};
    }
    void clean(std::uint64_t wall) {
        const auto native = witness(wall, c::Barrier::native_consumed);
        const auto parked = witness(wall, c::Barrier::body_parked);
        require(session.prove(owner, handle, c::Barrier::native_consumed, native, wall), "independent native cleanup fact accepted");
        require(session.prove(owner, handle, c::Barrier::body_parked, parked, wall), "independent body cleanup fact accepted");
    }
};

// Refuse one bounded ownership transition, forwarding everything else to ONE
// real arbiter. Every accepted Call still belongs to that concrete arbiter.
struct RefuseOneRevoke {
    c::Arbiter actual;
    unsigned revoke_calls{}, refusals{};
    bool refuse_next{true};
    bool reserve(std::uint64_t owner, c::Domain domain, c::Ticket& ticket) { return actual.reserve(owner, domain, ticket); }
    bool publish(std::uint64_t owner, c::Ticket ticket) { return actual.publish(owner, ticket); }
    bool abandon(std::uint64_t owner, c::Ticket ticket) { return actual.abandon(owner, ticket); }
    bool enter(std::uint64_t owner, c::Ticket ticket, c::Call& call) { return actual.enter(owner, ticket, call); }
    bool revoke(std::uint64_t owner, c::Ticket ticket, c::Barrier required) {
        ++revoke_calls;
        if (refuse_next) { refuse_next = false; ++refusals; return false; }
        return actual.revoke(owner, ticket, required);
    }
    bool satisfy(std::uint64_t owner, c::Ticket ticket, c::Barrier proof) { return actual.satisfy(owner, ticket, proof); }
    bool retire(std::uint64_t owner, c::Ticket ticket) { return actual.retire(owner, ticket); }
    c::Snapshot snapshot() const { return actual.snapshot(); }
};
template<class Session>
f::Receipt read(Session& session, f::Handle handle) {
    f::Receipt receipt;
    require(session.read(Fixture::owner, handle, receipt), "exact retained session receipt is available");
    return receipt;
}

void admission_and_competing_domains() {
    Fixture x; f::Handle handle{99, {99}}; f::Reason reason{};
    require(!x.session.reserve(0, x.actor, x.body, 100, handle, reason) && !handle.sequence &&
        reason == f::Reason::invalid_owner, "zero owner clears output without reserving");
    auto other_body = x.body; ++other_body.world;
    require(!x.session.reserve(7, x.actor, other_body, 100, handle, reason) && reason == f::Reason::invalid_identity,
        "cross-world actor/body cannot reserve");
    auto actor = x.actor; actor.lifetime = 0;
    require(!x.session.reserve(7, actor, x.body, 100, handle, reason), "unknown actor lifetime is not guessed");
    require(!x.session.reserve(7, x.actor, x.body, 0, handle, reason), "zero wall clock cannot qualify a lease");
    c::Ticket equipment;
    require(x.arbiter.reserve(99, c::Domain::equipment, equipment), "equipment takes same actual arbiter");
    require(!x.session.reserve(7, x.actor, x.body, 100, handle, reason) && reason == f::Reason::busy,
        "follow cannot bypass equipment admission");
    require(x.arbiter.abandon(99, equipment), "equipment admission abandons its own generation");
    x.reserve();
    require(!x.arbiter.reserve(99, c::Domain::equipment, equipment), "follow admission already excludes competing writer");
    require(!x.session.activate(8, x.handle, x.measured(), x.qualification(), 100), "other VM cannot activate reserved candidate");
    require(x.read().status == f::Status::admitting, "foreign activation leaves original admission intact");
    auto changed = x.qualification(); ++changed.actor.lifetime;
    require(!x.session.activate(7, x.handle, x.measured(), changed, 100), "changed lifetime rejects before activation");
    const auto rejected = x.read();
    require(rejected.status == f::Status::rejected && rejected.claim_released && x.arbiter.publication_allowed(),
        "unpublished rejection abandons claim without inventing body/native cleanup");
    x.session.tick(9000); x.session.unload(7, 9001);
    require(x.read() == rejected, "terminal admission receipt stays immutable");
    require(!x.session.acknowledge(8, x.handle) && x.session.acknowledge(7, x.handle), "only owner removes retained receipt");
    const auto old = x.handle; x.reserve(10000);
    require(x.handle.sequence > old.sequence && x.handle.ticket.generation > old.ticket.generation,
        "acknowledgement never reuses session or arbiter generation");
    require(!x.session.release(7, old, 10001), "old handle cannot revoke next admission");
    require(x.session.release(7, x.handle, 10001), "unpublished release abandons only own admission");
}

void qualification_and_sample_failures() {
    for (unsigned lane = 0; lane < 9; ++lane) {
        Fixture x; x.reserve(); auto sample = x.measured(); auto qualified = x.qualification();
        switch (lane) {
        case 0: qualified.actor_current = false; break;
        case 1: qualified.body_current = false; break;
        case 2: qualified.writers_clear = false; break;
        case 3: ++sample.body.generation; break;
        case 4: sample.serial = 0; break;
        case 5: sample.time = std::numeric_limits<double>::quiet_NaN(); break;
        case 6: sample.time = std::numeric_limits<double>::infinity(); break;
        case 7: sample.observed_ms = 101; break;
        case 8: sample.observed_ms = 1; break;
        }
        const auto now = lane == 8 ? 102u : 100u;
        require(!x.session.activate(7, x.handle, sample, qualified, now), "unknown, foreign, nonfinite or stale measured input refuses");
        require(x.read().status == f::Status::rejected && x.arbiter.publication_allowed(), "failed activation owns no native writers");
    }
    Fixture delayed; delayed.reserve();
    require(!delayed.session.activate(7, delayed.handle, delayed.measured(300), delayed.qualification(), 300) &&
        delayed.read().reason == f::Reason::lease_expired, "late activation cannot resurrect expired admission");
}

void publication_is_measured_monotonic_and_generation_bound() {
    Fixture x; x.start(); const auto original = x.read().publication;
    require(x.session.publish(7, x.handle, x.measured(), x.qualification(), 150), "exact duplicate is idempotent");
    require(x.read().publication == original, "old sample cannot refresh lease or increment revision");
    const auto next = x.measured(180, 2, 1.016);
    require(x.session.publish(7, x.handle, next, x.qualification(), 180), "new measured epoch renews bounded lease");
    const auto publication = x.read().publication;
    require(publication.sample == next && publication.revision == original.revision + 1 && publication.expires_ms == 380,
        "receipt retains referenced body epoch without relabeling it as a later native step");
    require(!x.session.current(7, x.handle, original, x.qualification(), 180), "superseded publication cannot authorize another write");
    auto foreign = publication; ++foreign.handle.ticket.generation;
    require(!x.session.current(7, x.handle, foreign, x.qualification(), 180), "same sample from foreign session is not current");
    require(x.session.current(7, x.handle, publication, x.qualification(), 180), "current exact publication remains usable");
    auto changed_copy = x.read(); ++changed_copy.publication.sample.body.identity;
    require(changed_copy.publication.sample.body.identity != x.read().publication.sample.body.identity &&
        x.read().publication == publication, "returned snapshot mutation cannot replace retained source identity");
    f::Receipt ignored;
    require(!x.session.read(8, x.handle, ignored) && !x.session.publish(8, x.handle, next, x.qualification(), 180),
        "wrong VM cannot read or renew another control");
    auto forged = next; forged.observed_ms = 181;
    require(!x.session.publish(7, x.handle, forged, x.qualification(), 181) && x.read().reason == f::Reason::sample_regressed,
        "same serial/time with a refreshed wall stamp is not a new measured sample");
    require(x.read().status == f::Status::revoking && !x.arbiter.publication_allowed(), "bad source renewal revokes without releasing cleanup debt");
}

void lease_and_identity_loss_stop_new_writers() {
    for (unsigned lane = 0; lane < 5; ++lane) {
        Fixture x; x.start(); auto qualified = x.qualification();
        switch (lane) {
        case 0: ++qualified.actor.identity; break;
        case 1: ++qualified.body.generation; break;
        case 2: ++qualified.body.world; break;
        case 3: qualified.actor_current = false; break;
        case 4: qualified.writers_clear = false; break;
        }
        c::Call call; f::Publication selected;
        require(!x.session.enter(7, x.handle, qualified, 110, call, selected) && !call.active(), "unqualified current source never enters writer");
        require(x.read().status == f::Status::revoking && x.read().pending == f::Session::release_barriers,
            "identity or competing-writer failure retains both cleanup obligations");
    }
    Fixture stale; stale.start(); stale.session.tick(201);
    require(stale.read().reason == f::Reason::stale_sample && stale.read().status == f::Status::revoking,
        "old measured epoch stops assertions independently of the publication TTL");
    Fixture expired; expired.start();
    require(!expired.session.publish(7, expired.handle, expired.measured(300, 2, 2), expired.qualification(), 300) &&
        expired.read().reason == f::Reason::lease_expired, "fresh measurement cannot resurrect expired published lease");
    Fixture backwards; backwards.start(); c::Call call; f::Publication selected;
    require(!backwards.session.enter(7, backwards.handle, backwards.qualification(), 99, call, selected) &&
        backwards.read().reason == f::Reason::clock_invalid, "wall regression revokes rather than extending authority");
}

void original_return_is_not_either_cleanup_proof() {
    Fixture x; x.start(); c::Call call; f::Publication publication;
    require(x.session.enter(7, x.handle, x.qualification(), 110, call, publication), "accepted writer owns actual shared Call cookie");
    require(!x.session.enter(7, x.handle, x.qualification(), 110, call, publication) && x.read().in_flight == 1,
        "same callback cannot enter twice or inflate actual count");
    require(x.session.release(7, x.handle, 120), "release revokes future callback admission");
    const auto before_return = x.witness(121);
    require(!x.session.prove(7, x.handle, c::Barrier::native_consumed, before_return, 121), "even qualified cleanup is rejected while a writer can still publish");
    require(x.arbiter.leave(call), "original native scope returns");
    x.session.tick(122);
    require(x.read().drained_ms == 122 && x.read().pending == f::Session::release_barriers && !x.read().claim_released,
        "observed original return only drains callbacks, never native/body barriers");
    require(!x.session.prove(7, x.handle, c::Barrier::native_consumed, before_return, 122),
        "pre-drain rejected fact cannot be cached and replayed after original return");
    c::Call late; f::Publication selected; c::Ticket equipment;
    require(!x.session.enter(7, x.handle, x.qualification(), 123, late, selected), "no new writer can enter revoked generation");
    require(!x.arbiter.reserve(8, c::Domain::equipment, equipment), "equipment waits through both cleanup barriers");
    auto proof = x.witness(123);
    require(!x.session.prove(8, x.handle, c::Barrier::native_consumed, proof, 123), "wrong owner cannot supply cleanup");
    auto wrong = x.witness(123, c::Barrier::body_parked); ++wrong.release.body.generation;
    require(!x.session.prove(7, x.handle, c::Barrier::body_parked, wrong, 123), "another body generation cannot park this dependency");
    wrong = proof; ++wrong.release.actor.lifetime;
    require(!x.session.prove(7, x.handle, c::Barrier::native_consumed, wrong, 123), "another actor lifetime cannot retire old writes");
    wrong = proof; wrong.qualified = false;
    require(!x.session.prove(7, x.handle, c::Barrier::native_consumed, wrong, 123), "unknown cleanup is never success");
    require(!x.session.prove(7, x.handle, f::Session::release_barriers, proof, 123), "one undifferentiated witness cannot satisfy both facts");
    require(x.session.prove(7, x.handle, c::Barrier::native_consumed, proof, 123), "qualified native consumption releases only native barrier");
    require(!x.read().claim_released && x.read().pending == c::Barrier::body_parked, "body parking remains independently pending");
    require(!x.session.prove(7, x.handle, c::Barrier::body_parked, proof, 123) && !x.read().claim_released,
        "qualified native consumption witness cannot be relabeled as body parking");
    proof = x.witness(124, c::Barrier::body_parked);
    require(x.session.prove(7, x.handle, c::Barrier::body_parked, proof, 124), "qualified same-generation parking completes remaining barrier");
    const auto final = x.read();
    require(final.status == f::Status::released && final.claim_released && final.native_consumed_ms == 123 &&
        final.body_parked_ms == 124 && x.arbiter.publication_allowed(), "terminal receipt records both explicit proof stamps");
    x.session.tick(10000); x.session.unload(7, 10001);
    require(!x.session.release(7, x.handle, 10002) && !x.session.prove(7, x.handle, c::Barrier::native_consumed, proof, 10002),
        "terminal completion cannot accept new cleanup or revocation");
    require(x.read() == final, "terminal receipt remains exact historical evidence");
}

void quarantine_and_unload_retain_obligations() {
    Fixture x; x.start();
    require(x.session.cleanup_unknown(7, x.handle, 110), "unverifiable cleanup explicitly quarantines control");
    x.session.tick(10000);
    require(x.read().status == f::Status::quarantined && x.read().pending == f::Session::release_barriers &&
        !x.session.acknowledge(7, x.handle) && !x.arbiter.publication_allowed(), "timeout and terminal-looking cleanup cannot invent release");
    x.clean(10001);
    require(x.read().status == f::Status::released && x.read().reason == f::Reason::cleanup_unavailable,
        "later real proof can release while preserving original cleanup failure");
    Fixture pending; pending.reserve(); pending.session.unload(7, 101);
    require(pending.read().status == f::Status::rejected && pending.read().orphaned && pending.read().claim_released,
        "unload before activation abandons only the unpublished claim");
    Fixture live; live.start(); c::Call call; f::Publication publication;
    require(live.session.enter(7, live.handle, live.qualification(), 105, call, publication), "native call accepted before unload");
    live.session.unload(8, 106);
    require(live.read().status == f::Status::active && !live.read().orphaned, "another VM cannot unload current control");
    live.session.unload(7, 110); live.session.tick(10000);
    require(live.read().orphaned && live.read().status == f::Status::revoking && !live.read().claim_released,
        "VM disappearance retains in-flight actor/body duty without another VM adopting it");
    require(live.arbiter.leave(call), "native scope can return after VM destruction");
    live.session.tick(10001); live.clean(10002);
    require(live.read().orphaned && live.read().reason == f::Reason::owner_released && live.read().claim_released,
        "orphan retires only after independent post-drain facts, not actor-loss shortcuts");
}

void arbiter_bits_alone_are_not_a_policy_cleanup_witness() {
    Fixture x; x.start();
    require(x.session.release(7, x.handle, 110), "follow release establishes separate proof ledger");
    require(x.arbiter.satisfy(7, x.handle.ticket, f::Session::release_barriers), "lower ownership gate alone can clear its bits");
    x.session.tick(111);
    require(!x.read().claim_released && x.read().status == f::Status::revoking &&
        !x.read().native_consumed_ms && !x.read().body_parked_ms && !x.arbiter.publication_allowed(),
        "externally cleared arbiter bits do not fabricate the policy's two qualified facts");
    x.clean(112);
    require(x.read().claim_released, "actual two qualified witnesses can still complete cleanup");
}

void mismatched_ownership_is_not_a_zero_callback_observation() {
    Fixture x; x.reserve();
    require(x.arbiter.abandon(7, x.handle.ticket), "simulate identity service withdrawing the original admission");
    c::Ticket foreign;
    require(x.arbiter.reserve(9, c::Domain::equipment, foreign), "different owner takes a newer underlying ticket");
    f::Receipt receipt;
    require(!x.session.read(7, x.handle, receipt), "nonmatching gate cannot be reported as known zero native calls");
    require(!x.session.release(7, x.handle, 101), "stale follow cannot release the newer underlying claim");
    require(x.arbiter.owns(9, foreign, c::Domain::equipment) && x.arbiter.abandon(9, foreign),
        "only actual owner can retire the newer generation");
}

void shared_gate_revocation_stops_a_saved_publication() {
    Fixture x; x.start(); const auto publication = x.read().publication;
    require(x.arbiter.revoke(7, x.handle.ticket, f::Session::release_barriers), "shared identity service revokes actual gate");
    require(!x.session.current(7, x.handle, publication, x.qualification(), 110),
        "cached active status cannot authorize a write after actual gate revocation");
    require(x.read().status == f::Status::revoking && x.read().pending == f::Session::release_barriers,
        "external shared revocation joins conservative policy cleanup without claiming consumption");
    x.clean(111);
}

void bounded_counts_and_exhaustion() {
    Fixture x; x.start(); std::array<c::Call, c::Arbiter::maximum_in_flight> calls;
    for (auto& call : calls) {
        f::Publication publication;
        require(x.session.enter(7, x.handle, x.qualification(), 100, call, publication), "bounded native callback slot enters");
    }
    c::Call extra; f::Publication publication;
    require(!x.session.enter(7, x.handle, x.qualification(), 100, extra, publication) && x.read().in_flight == calls.size(),
        "native callback count cannot wrap into generation");
    require(x.session.release(7, x.handle, 110), "saturated generation still revokes");
    for (auto& call : calls) require(x.arbiter.leave(call), "each native callback leaves exact generation");
    x.session.tick(111); x.clean(112);
    c::Arbiter gate;
    f::Session exhausted(gate, std::numeric_limits<std::uint64_t>::max()); f::Handle last, none; f::Reason reason{};
    require(exhausted.reserve(7, x.actor, x.body, 100, last, reason) && exhausted.release(7, last, 101) &&
        exhausted.acknowledge(7, last), "last representable session can retire unpublished");
    require(!exhausted.reserve(7, x.actor, x.body, 102, none, reason) && !none.sequence &&
        reason == f::Reason::sequence_exhausted && gate.publication_allowed(), "session identifiers exhaust without reuse");
    f::Session revision(gate, 1, std::numeric_limits<std::uint64_t>::max());
    require(revision.reserve(7, x.actor, x.body, 100, last, reason) && revision.activate(7, last, x.measured(), x.qualification(), 100),
        "last representable publication revision can activate");
    require(!revision.publish(7, last, x.measured(101, 2, 2), x.qualification(), 101), "publication revisions never wrap");
    f::Receipt receipt;
    require(revision.read(7, last, receipt) && receipt.reason == f::Reason::revision_exhausted &&
        receipt.status == f::Status::revoking, "revision exhaustion keeps required cleanup");
    Fixture overflow;
    require(!overflow.session.reserve(7, overflow.actor, overflow.body, std::numeric_limits<std::uint64_t>::max(), none, reason) &&
        reason == f::Reason::clock_invalid && overflow.arbiter.publication_allowed(), "lease deadline addition is overflow bounded");
}

void cleanup_time_does_not_require_another_lease() {
    constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    const auto last_lease = maximum - f::Session::lease_ms;
    Fixture x; x.reserve(last_lease);
    require(x.session.activate(7, x.handle, x.measured(last_lease), x.qualification(), last_lease),
        "last nonoverflowing lease creation can activate");
    require(x.read().publication.expires_ms == maximum && x.session.release(7, x.handle, last_lease),
        "last safe lease still revokes through the real arbiter");
    const auto native = x.witness(last_lease + 1);
    const auto parked = x.witness(last_lease + 2, c::Barrier::body_parked);
    require(x.session.prove(7, x.handle, c::Barrier::native_consumed, native, last_lease + 1),
        "cleanup proof may advance beyond lease-addition headroom");
    require(x.session.prove(7, x.handle, c::Barrier::body_parked, parked, last_lease + 2),
        "independent later parking proof retires the last safe lease");
    const auto final = x.read();
    require(final.claim_released && final.status == f::Status::released && x.arbiter.publication_allowed(),
        "clock headroom cannot permanently trap a fully proven final lease");
    x.session.tick(maximum);
    require(x.read() == final, "terminal last-lease receipt remains immutable at the clock limit");

    Fixture current; current.reserve(last_lease);
    const auto measured = current.measured(last_lease);
    require(current.session.activate(7, current.handle, measured, current.qualification(), last_lease),
        "near-limit current-use case activates");
    const auto publication = current.read().publication;
    require(current.session.current(7, current.handle, publication, current.qualification(), last_lease + 1) &&
        current.session.publish(7, current.handle, measured, current.qualification(), last_lease + 1) &&
        current.read().publication == publication, "fresh current use and an idempotent sample require no deadline addition");
    require(current.session.release(7, current.handle, last_lease + 2), "near-limit current use can still stop");
    current.clean(last_lease + 3);

    Fixture reservation; f::Handle none{99, {99}}; f::Reason reason{};
    require(!reservation.session.reserve(7, reservation.actor, reservation.body, last_lease + 1, none, reason) &&
        !none.sequence && reason == f::Reason::clock_invalid && reservation.arbiter.publication_allowed(),
        "new reservation still refuses overflowing lease headroom and clears output");
    Fixture activation; activation.reserve(last_lease);
    require(!activation.session.activate(7, activation.handle, activation.measured(last_lease + 1),
        activation.qualification(), last_lease + 1) && activation.read().reason == f::Reason::clock_invalid &&
        activation.read().claim_released && activation.arbiter.publication_allowed(),
        "activation rechecks headroom even after a safe earlier reservation");
    Fixture renewal; renewal.reserve(last_lease - 1);
    require(renewal.session.activate(7, renewal.handle, renewal.measured(last_lease - 1),
        renewal.qualification(), last_lease - 1), "renewal case activates below final headroom");
    const auto original = renewal.read().publication;
    require(!renewal.session.publish(7, renewal.handle, renewal.measured(last_lease + 1, 2, 2),
        renewal.qualification(), last_lease + 1) && renewal.read().reason == f::Reason::clock_invalid &&
        renewal.read().publication == original && renewal.read().status == f::Status::revoking,
        "new measured publication cannot overflow its lease or mutate the final accepted sample");
    renewal.clean(last_lease + 2);
}

void refused_revoke_stays_stopped_and_retries_only_its_claim() {
    for (unsigned route = 0; route < 3; ++route) {
        Fixture facts; RefuseOneRevoke gate; f::BasicSession<RefuseOneRevoke> session(gate);
        f::Handle handle; f::Reason reason{};
        require(session.reserve(7, facts.actor, facts.body, 100, handle, reason) &&
            session.activate(7, handle, facts.measured(), facts.qualification(), 100), "fault case activates against the actual shared arbiter");
        const auto publication = read(session, handle).publication;
        c::Call call; f::Publication selected;
        require(session.enter(7, handle, facts.qualification(), 105, call, selected), "real native Call is in flight before failed revocation");
        require(!session.release(7, handle, 110) && gate.refusals == 1 && gate.revoke_calls == 1,
            "deterministic transition seam exercises exactly one refused actual-revoke result");
        auto pending = read(session, handle);
        require(pending.status == f::Status::quarantined && pending.reason == f::Reason::cleanup_unavailable &&
            pending.publication == publication && pending.release == f::Release{} && !pending.claim_released &&
            gate.actual.snapshot().phase == c::Phase::published, "failed actual revoke preserves final publication but establishes no release fence");
        c::Call late;
        require(!session.enter(7, handle, facts.qualification(), 111, late, selected) && !late.active() &&
            !session.current(7, handle, publication, facts.qualification(), 111), "local follow writes remain stopped while actual claim is still published");
        const f::Witness prepaid{{}, c::Barrier::native_consumed, 111, true};
        require(!session.prove(7, handle, c::Barrier::native_consumed, prepaid, 111), "missing actual revocation cannot accept a prepaid default release witness");
        if (route == 0) session.tick(112);
        else if (route == 1) require(session.release(7, handle, 112), "explicit release retries only retained revocation");
        else session.unload(7, 112);
        pending = read(session, handle);
        require(gate.revoke_calls == 2 && gate.refusals == 1 && gate.actual.snapshot().phase == c::Phase::revoking &&
            pending.release.handle == handle && pending.release.actor == facts.actor && pending.release.body == facts.body &&
            pending.release.revision == publication.revision && pending.release.revoked_ms == 112 &&
            pending.publication == publication && pending.reason == f::Reason::cleanup_unavailable && pending.orphaned == (route == 2),
            "tick/release/unload retries same concrete claim and seals one later immutable release identity");
        const auto release = pending.release;
        const f::Witness early{release, c::Barrier::native_consumed, 113, true};
        require(!session.prove(7, handle, c::Barrier::native_consumed, early, 113), "successful retry still cannot accept proof before real Call drains");
        require(gate.actual.leave(call), "Call returns through its actual arbiter rather than a fake provider");
        session.tick(114);
        require(read(session, handle).drained_ms == 114 && !session.prove(7, handle, c::Barrier::native_consumed, early, 114),
            "pre-drain fact remains refused after revocation retry and original return");
        require(session.release(7, handle, 114) && read(session, handle).release == release &&
            read(session, handle).publication == publication && gate.revoke_calls == 2,
            "repeated cleanup never reseals release, reopens local writes or rebases the sample");
        require(session.prove(7, handle, c::Barrier::native_consumed, {release, c::Barrier::native_consumed, 115, true}, 115) &&
            !read(session, handle).claim_released, "first later real witness clears only its independent barrier");
        require(session.prove(7, handle, c::Barrier::body_parked, {release, c::Barrier::body_parked, 116, true}, 116),
            "second post-drain witness can finally retire the retried claim");
        const auto final = read(session, handle);
        session.tick(10000); session.unload(7, 10001);
        require(final.status == f::Status::released && final.claim_released && read(session, handle) == final &&
            gate.actual.publication_allowed(), "retried terminal proof is historical and immutable");
    }
}

void revocation_retry_preserves_failed_reason_and_joins_existing_stop() {
    Fixture facts; RefuseOneRevoke gate; f::BasicSession<RefuseOneRevoke> session(gate);
    f::Handle handle; f::Reason reason{};
    require(session.reserve(7, facts.actor, facts.body, 100, handle, reason) &&
        session.activate(7, handle, facts.measured(), facts.qualification(), 100), "reason case activates");
    const auto original = read(session, handle).publication;
    auto invalid = facts.measured(110, 0, 2);
    require(!session.publish(7, handle, invalid, facts.qualification(), 110) && gate.refusals == 1 &&
        read(session, handle).reason == f::Reason::invalid_sample, "failed revoke preserves the original measured-sample failure reason");
    require(gate.actual.revoke(7, handle.ticket, f::Session::release_barriers), "shared identity service independently stops the same actual ticket");
    require(!session.prove(7, handle, c::Barrier::native_consumed, {{}, c::Barrier::native_consumed, 111, true}, 111) &&
        !session.prove(7, handle, c::Barrier::body_parked, {{}, c::Barrier::body_parked, 112, true}, 112),
        "externally stopped claim still cannot accept default release witnesses before model fence exists");
    require(!read(session, handle).native_consumed_ms && !read(session, handle).body_parked_ms &&
        read(session, handle).release == f::Release{}, "failed pre-fence proof attempts record no cleanup facts");
    session.tick(113);
    const auto stopped = read(session, handle);
    require(stopped.release.revoked_ms == 113 && stopped.publication == original &&
        stopped.reason == f::Reason::invalid_sample && gate.revoke_calls == 2, "retry can join exact already-revoking claim without adopting a new publication");
    session.tick(114);
    require(read(session, handle).release == stopped.release && gate.revoke_calls == 2,
        "already established release is never replaced on a later tick");
    require(session.prove(7, handle, c::Barrier::body_parked, {stopped.release, c::Barrier::body_parked, 115, true}, 115) &&
        session.prove(7, handle, c::Barrier::native_consumed, {stopped.release, c::Barrier::native_consumed, 115, true}, 115),
        "independent proof kinds may arrive in either order after the real drain fence");
    require(read(session, handle).claim_released && read(session, handle).reason == f::Reason::invalid_sample,
        "successful eventual cleanup retains the original failure");
}

void quarantine_never_borrows_foreign_or_unpublished_claims() {
    Fixture facts; RefuseOneRevoke gate; f::BasicSession<RefuseOneRevoke> session(gate);
    f::Handle handle; f::Reason reason{};
    require(session.reserve(7, facts.actor, facts.body, 100, handle, reason) &&
        session.activate(7, handle, facts.measured(), facts.qualification(), 100) && !session.release(7, handle, 110),
        "foreign case reaches the real published-claim failure edge");
    // Simulate independent ownership withdrawal. Clearing lower arbiter bits
    // supplies no body-follow proof and cannot make this model terminal.
    require(gate.actual.revoke(7, handle.ticket, f::Session::release_barriers) &&
        gate.actual.satisfy(7, handle.ticket, f::Session::release_barriers) && gate.actual.retire(7, handle.ticket),
        "external ownership service removes the original underlying generation");
    c::Ticket foreign;
    require(gate.actual.reserve(9, c::Domain::equipment, foreign) && gate.actual.publish(9, foreign),
        "another owner publishes a newer actual claim");
    session.tick(111);
    require(!session.release(7, handle, 112) && !session.release(9, handle, 112), "old policy or foreign VM cannot adopt newer ownership");
    session.unload(7, 113);
    f::Receipt ignored;
    require(gate.revoke_calls == 1 && gate.actual.owns(9, foreign, c::Domain::equipment) &&
        !session.read(7, handle, ignored) && !session.acknowledge(7, handle), "quarantine retry touches no foreign ticket and invents no zero-call/release observation");

    RefuseOneRevoke unpublished_gate; f::BasicSession<RefuseOneRevoke> unpublished(unpublished_gate);
    require(unpublished.reserve(7, facts.actor, facts.body, 100, handle, reason) &&
        unpublished_gate.actual.publish(7, handle.ticket), "simulate actual publication without a model-approved measured sample");
    require(!unpublished.activate(7, handle, facts.measured(), facts.qualification(), 100),
        "unexpected underlying phase cannot activate empty model publication");
    require(read(unpublished, handle).status == f::Status::quarantined, "unpublished mismatch is retained as unknown cleanup");
    unpublished.tick(101);
    require(!unpublished.release(7, handle, 102), "no model publication means no valid revocation retry identity");
    unpublished.unload(7, 103);
    require(unpublished_gate.revoke_calls == 0 && unpublished_gate.actual.snapshot().phase == c::Phase::published &&
        read(unpublished, handle).release == f::Release{} && !read(unpublished, handle).claim_released,
        "even a matching underlying ticket is never adopted without the retained model publication");
}
// These are our constructed values, not captured native target data.
constexpr std::array<std::uint8_t, 12> transform_xyz_lanes{0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14};
constexpr std::array<std::uint8_t, 4> transform_fourth_lanes{3, 7, 11, 15};
constexpr std::array<std::uint32_t, 3> transform_invalid_xyz{0x7FC12345U, 0x7F800000U, 0xFF800000U};
constexpr std::array<std::uint32_t, 4> transform_fourth_patterns{0x7FC01234U, 0x7F800000U, 0xFF800000U, 0xFFC05678U};
constexpr std::array<float, 16> transform_supplied{1, 0, 0, 17, 0, 1, 0, 19, 0, 0, 1, 23, 5, 6, 7, 29};
using TransformBits = std::array<std::uint32_t, 16>;

void supplied_xyz_finiteness() {
    require(t::first_nonfinite_xyz(transform_supplied) == t::no_failed_lane, "finite supplied XYZ has no failed lane");
    auto isolated = transform_supplied;
    isolated[15] = std::bit_cast<float>(transform_invalid_xyz[0]);
    require(t::first_nonfinite_xyz(isolated) == t::no_failed_lane, "isolated lane-15 NaN is outside the XYZ scan");
    for (const auto lane : transform_xyz_lanes)
        for (const auto invalid : transform_invalid_xyz) {
            auto value = transform_supplied;
            for (std::size_t index = 0; index < transform_fourth_lanes.size(); ++index)
                value[transform_fourth_lanes[index]] = std::bit_cast<float>(transform_fourth_patterns[index]);
            value[lane] = std::bit_cast<float>(invalid);
            const auto before = std::bit_cast<TransformBits>(value);
            require(t::first_nonfinite_xyz(value) == lane, "each nonfinite XYZ class reports its actual first lane despite earlier fourth words");
            require(std::bit_cast<TransformBits>(value) == before, "supplied XYZ scan never changes source bits");
        }
    auto ordered = transform_supplied;
    ordered[2] = std::bit_cast<float>(transform_invalid_xyz[1]);
    ordered[3] = std::bit_cast<float>(transform_invalid_xyz[0]);
    ordered[4] = std::bit_cast<float>(transform_invalid_xyz[2]);
    require(t::first_nonfinite_xyz(ordered) == 2, "first XYZ failure precedes both a fourth word and the next row");
    ordered[2] = transform_supplied[2];
    require(t::first_nonfinite_xyz(ordered) == 4, "a nonfinite fourth word cannot hide the next XYZ failure");
    ordered[4] = transform_supplied[4];
    require(t::first_nonfinite_xyz(ordered) == t::no_failed_lane, "remaining fourth-word NaN does not refuse valid XYZ");
}

void target_preserves_fourth_words() {
    dingosdk::owned_body::Sample sample;
    sample.position = {20, 30, 40};
    const auto q = std::sqrt(.5f);
    sample.rotation = {0, q, 0, q};
    const dingosdk::owned_body::Vec offset{1, 2, 3};
    const dingosdk::owned_body::Quaternion root{q, 0, 0, q};
    // Body yaw +90 maps the COM-relative offset to (3,2,-1). Composing
    // root roll +90 maps basis X to -Z, Y to X, and Z to -Y.
    const std::array<float, 12> expected{0, 0, -1, 1, 0, 0, 0, -1, 0, 23, 32, 39};
    const std::array<std::uint32_t, 4> finite_markers{0x80000000U, 0x3F800000U, 0xC0600000U, 0x00000000U};
    for (std::size_t variant = 0; variant < 6; ++variant) {
        auto target = transform_supplied;
        if (variant == 0) target[15] = std::bit_cast<float>(transform_invalid_xyz[0]);
        else for (std::size_t index = 0; index < transform_fourth_lanes.size(); ++index) {
            const auto bits = variant == 5 ? finite_markers[index] :
                transform_fourth_patterns[(index + variant - 1) % transform_fourth_patterns.size()];
            target[transform_fourth_lanes[index]] = std::bit_cast<float>(bits);
        }
        const auto before = std::bit_cast<TransformBits>(target);
        require(t::first_nonfinite_xyz(target) == t::no_failed_lane, "all constructed fourth-word variants admit finite XYZ");
        require(t::transform(sample, offset, root, target), "actual pure target builder accepts the full-orientation COM oracle");
        for (std::size_t index = 0; index < transform_xyz_lanes.size(); ++index) {
            const auto value = target[transform_xyz_lanes[index]];
            require(std::isfinite(value) && std::abs(value - expected[index]) < .00002f,
                "all twelve output XYZ values match the independent geometric oracle");
        }
        const auto after = std::bit_cast<TransformBits>(target);
        for (const auto lane : transform_fourth_lanes)
            require(after[lane] == before[lane], "target building preserves every fourth word bit for bit, including NaN payloads and signed zero");
    }
}

void lead_attachment_bounds() {
    namespace api = dingosdk::body_follow_api;
    api::Attachment attachment;
    require(attachment.lead.steps == 0 && !attachment.lead.angular && api::valid(attachment),
        "an omitted lead keeps the existing valid attachment default");
    for (std::uint8_t steps = 0; steps <= 3; ++steps)
        for (const bool angular : {false, true}) {
            attachment.lead = {steps, angular};
            require(api::valid_lead(attachment.lead) && api::valid(attachment),
                "every bounded lead step and angular selector is a valid attachment");
        }
    for (const std::uint8_t steps : {std::uint8_t{4}, std::uint8_t{255}}) {
        attachment.lead = {steps, true};
        require(!api::valid_lead(attachment.lead) && !api::valid(attachment),
            "an internal out-of-range step cannot enter an attachment");
    }
}

void disabled_lead_preserves_target_bits() {
    dingosdk::owned_body::Sample sample;
    const auto q = std::sqrt(.5f);
    const dingosdk::owned_body::Vec offset{1, 2, 3};
    const dingosdk::owned_body::Quaternion root{q, 0, 0, q};
    sample.position = {-0.0f, 30, 40};
    sample.rotation = {0, q, 0, q};
    // Motion is deliberately unusable. Zero steps must not inspect it or
    // canonicalize the original transform's signed zeros and padding payloads.
    sample.velocity = {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(), -101};
    sample.angular_velocity = {-std::numeric_limits<float>::infinity(), 101, std::numeric_limits<float>::quiet_NaN()};
    sample.epoch.seconds = std::numeric_limits<float>::quiet_NaN();
    for (const bool angular : {false, true}) {
        auto original = transform_supplied;
        for (std::size_t i = 0; i < transform_fourth_lanes.size(); ++i)
            original[transform_fourth_lanes[i]] = std::bit_cast<float>(transform_fourth_patterns[i]);
        original[3] = -0.0f;
        auto led = original;
        bool skipped = true;
        require(t::transform(sample, offset, root, original), "the original builder ignores unused motion");
        require(t::transform_led(sample, offset, root, {0, angular}, led, skipped) && !skipped,
            "zero steps bypass invalid motion without recording a skipped prediction");
        require(std::bit_cast<TransformBits>(led) == std::bit_cast<TransformBits>(original),
            "zero steps preserve all sixteen original transform words bit for bit");
    }
}

void measured_lead_translation() {
    dingosdk::owned_body::Sample sample;
    sample.position = {10, 20, 30};
    sample.rotation = {0, 0, 0, 1};
    sample.velocity = {3, -6, 9};
    sample.epoch.seconds = static_cast<float>(dingosdk::owned_body::native_seconds);
    const dingosdk::owned_body::Vec offset{1, 2, 3};
    const dingosdk::owned_body::Quaternion root{0, 0, 0, 1};
    for (std::uint8_t steps = 1; steps <= 3; ++steps) {
        auto target = transform_supplied;
        bool skipped = true;
        require(t::transform_led(sample, offset, root, {steps, false}, target, skipped) && !skipped,
            "constant measured velocity produces a bounded positional lead");
        const double seconds = static_cast<double>(steps) * sample.epoch.seconds;
        for (unsigned axis = 0; axis < 3; ++axis) {
            const double expected = sample.position[axis] + offset[axis] + sample.velocity[axis] * seconds;
            require(std::abs(target[12 + axis] - expected) < .00001,
                "each lead component uses the selected number of measured steps");
        }
        for (const auto lane : transform_fourth_lanes)
            require(std::bit_cast<std::uint32_t>(target[lane]) == std::bit_cast<std::uint32_t>(transform_supplied[lane]),
                "positive lead preserves the supplied fourth words");
    }
    // This is still a calibrated sample, but measurably differs from the
    // nominal constant. The target must use its own seconds, not a new read.
    sample.position = {};
    sample.velocity = {100, 0, 0};
    sample.epoch.seconds += .00000005f;
    auto target = transform_supplied;
    bool skipped = true;
    require(dingosdk::owned_body::calibrated(sample.epoch.seconds), "the constructed alternate step remains calibrated");
    require(t::transform_led(sample, {}, root, {3, false}, target, skipped) && !skipped,
        "the exact linear speed boundary is accepted");
    const auto expected = static_cast<float>(100.0 * 3.0 * sample.epoch.seconds);
    const auto nominal = static_cast<float>(100.0 * 3.0 * static_cast<float>(dingosdk::owned_body::native_seconds));
    require(target[12] == expected && target[12] != nominal,
        "lead time comes from this sample's epoch seconds rather than the nominal step");
}

void angular_lead_uses_rotated_offset() {
    dingosdk::owned_body::Sample sample;
    const auto q = std::sqrt(.5f);
    sample.position = {20, 30, 40};
    sample.rotation = {0, q, 0, q};
    sample.velocity = {3, 0, 9};
    sample.angular_velocity = {0, 2, 0};
    sample.epoch.seconds = static_cast<float>(dingosdk::owned_body::native_seconds);
    const dingosdk::owned_body::Vec offset{1, 2, 3};
    const dingosdk::owned_body::Quaternion root{q, 0, 0, q};
    // Body yaw rotates offset to (3,2,-1). World omega (0,2,0) cross that
    // offset is (-2,0,-6), so point velocity is (1,0,3), independent of root.
    for (const bool angular : {false, true}) {
        auto original = transform_supplied;
        auto target = original;
        bool skipped = true;
        require(t::transform(sample, offset, root, original), "the angular oracle has an admitted original target");
        require(t::transform_led(sample, offset, root, {2, angular}, target, skipped) && !skipped,
            "a bounded angular selector uses the same measured sample");
        const std::array<double, 3> velocity = angular ? std::array<double, 3>{1, 0, 3} : std::array<double, 3>{3, 0, 9};
        const std::array<double, 3> position{23, 32, 39};
        for (unsigned axis = 0; axis < 3; ++axis)
            require(std::abs(target[12 + axis] - (position[axis] + velocity[axis] * 2 * sample.epoch.seconds)) < .00002,
                "omega cross rotated COM offset has the expected sign and world-space axes");
        const auto original_bits = std::bit_cast<TransformBits>(original);
        const auto target_bits = std::bit_cast<TransformBits>(target);
        for (std::size_t lane = 0; lane < 12; ++lane)
            require(target_bits[lane] == original_bits[lane], "lead leaves the root basis and its padding exact");
        require(target_bits[15] == original_bits[15], "lead leaves the translation padding exact");
    }
    sample.velocity = {};
    sample.angular_velocity = {0, 0, 100};
    sample.rotation = {0, 0, 0, 1};
    auto target = transform_supplied;
    bool skipped = true;
    require(t::transform_led(sample, {1, 0, 0}, {0, 0, 0, 1}, {1, true}, target, skipped) && !skipped,
        "the exact angular and resulting point-speed boundaries are accepted");
    require(std::abs(target[13] - (30.0 + 100.0 * sample.epoch.seconds)) < .00001,
        "boundary spin moves the offset point in the positive cross-product direction");
}

void invalid_lead_falls_back_atomically() {
    namespace body = dingosdk::owned_body;
    body::Sample sample;
    sample.position = {10, 20, 30};
    sample.rotation = {0, 0, 0, 1};
    sample.velocity = {3, 0, 0};
    sample.epoch.seconds = static_cast<float>(body::native_seconds);
    const body::Quaternion root{0, 0, 0, 1};
    const auto fallback = [&](const body::Sample& changed, const body::Vec& offset,
        const dingosdk::body_follow_api::Lead& lead) {
        auto original = transform_supplied;
        for (std::size_t i = 0; i < transform_fourth_lanes.size(); ++i)
            original[transform_fourth_lanes[i]] = std::bit_cast<float>(transform_fourth_patterns[i]);
        auto target = original;
        bool skipped = false;
        require(t::transform(changed, offset, root, original), "fallback case has a valid unled transform");
        require(t::transform_led(changed, offset, root, lead, target, skipped) && skipped,
            "invalid prediction falls back without rejecting a valid base transform");
        require(std::bit_cast<TransformBits>(target) == std::bit_cast<TransformBits>(original),
            "fallback commits no partial translation or padding change");
        require(t::first_nonfinite_xyz(target) == t::no_failed_lane, "fallback never publishes nonfinite XYZ");
    };
    for (const auto bad : transform_invalid_xyz)
        for (std::size_t axis = 0; axis < 3; ++axis) {
            auto changed = sample;
            changed.velocity[axis] = std::bit_cast<float>(bad);
            fallback(changed, {}, {2, false});
            changed = sample;
            changed.angular_velocity[axis] = std::bit_cast<float>(bad);
            fallback(changed, {1, 0, 0}, {2, true});
        }
    for (const body::Vec velocity : {body::Vec{100.01f, 0, 0}, body::Vec{-100.01f, 0, 0}, body::Vec{80, 80, 0}}) {
        auto changed = sample;
        changed.velocity = velocity;
        fallback(changed, {}, {2, false});
        changed = sample;
        changed.angular_velocity = velocity;
        fallback(changed, {}, {2, true});
    }
    for (const float seconds : {0.0f, -1.0f / 60.0f, 1.0f / 30.0f,
        std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity()}) {
        auto changed = sample;
        changed.epoch.seconds = seconds;
        fallback(changed, {}, {2, false});
    }
    fallback(sample, {}, {4, false});
    // Individually admitted linear and angular motion can still exceed the
    // point-speed bound when combined at the chosen offset.
    auto changed = sample;
    changed.velocity = {90, 0, 0};
    changed.angular_velocity = {0, 0, 20};
    fallback(changed, {0, -1, 0}, {2, true});
    changed = sample;
    changed.position = {10, 100000, 30};
    changed.velocity = {20, 1, 20};
    fallback(changed, {}, {2, false});
    changed.position = {10, 20, -100000};
    changed.velocity = {20, 1, -1};
    fallback(changed, {}, {2, false});

    // Disabled angular motion is genuinely unused, rather than needlessly
    // causing a fallback because an unrelated spin component is unavailable.
    changed = sample;
    changed.angular_velocity = {std::numeric_limits<float>::quiet_NaN(), 101, std::numeric_limits<float>::infinity()};
    auto target = transform_supplied;
    bool skipped = true;
    require(t::transform_led(changed, {}, root, {2, false}, target, skipped) && !skipped,
        "linear-only lead ignores unusable angular velocity");
    require(std::abs(target[12] - (10.0 + 6.0 * changed.epoch.seconds)) < .00001,
        "linear-only lead still applies the current linear motion");
}

void invalid_base_cannot_become_led() {
    dingosdk::owned_body::Sample sample;
    sample.position = {10, 20, 30};
    sample.rotation = {0, 0, 0, 1};
    sample.velocity = {3, 0, 0};
    sample.epoch.seconds = static_cast<float>(dingosdk::owned_body::native_seconds);
    for (unsigned fault = 0; fault < 4; ++fault)
        for (const std::uint8_t steps : {std::uint8_t{0}, std::uint8_t{2}}) {
            auto changed = sample;
            dingosdk::owned_body::Vec offset{};
            dingosdk::owned_body::Quaternion root{0, 0, 0, 1};
            if (fault == 0) changed.position[0] = std::numeric_limits<float>::quiet_NaN();
            else if (fault == 1) changed.rotation[3] = 0;
            else if (fault == 2) offset[1] = 10.01f;
            else root[0] = std::numeric_limits<float>::infinity();
            auto target = transform_supplied;
            bool skipped = true;
            require(!t::transform_led(changed, offset, root, {steps, true}, target, skipped) && !skipped,
                "an invalid base stays refused regardless of whether prediction is enabled");
            require(std::bit_cast<TransformBits>(target) == std::bit_cast<TransformBits>(transform_supplied),
                "base refusal leaves the supplied target untouched");
        }
}
static_assert(!std::is_copy_constructible_v<f::Session> && !std::is_move_constructible_v<f::Session>);
static_assert(std::is_same_v<f::Session, f::BasicSession<c::Arbiter>>);
}
int main() {
    admission_and_competing_domains();
    qualification_and_sample_failures();
    publication_is_measured_monotonic_and_generation_bound();
    lease_and_identity_loss_stop_new_writers();
    original_return_is_not_either_cleanup_proof();
    quarantine_and_unload_retain_obligations();
    arbiter_bits_alone_are_not_a_policy_cleanup_witness();
    mismatched_ownership_is_not_a_zero_callback_observation();
    shared_gate_revocation_stops_a_saved_publication();
    bounded_counts_and_exhaustion();
    cleanup_time_does_not_require_another_lease();
    refused_revoke_stays_stopped_and_retries_only_its_claim();
    revocation_retry_preserves_failed_reason_and_joins_existing_stop();
    quarantine_never_borrows_foreign_or_unpublished_claims();
    supplied_xyz_finiteness();
    target_preserves_fourth_words();
    lead_attachment_bounds();
    disabled_lead_preserves_target_bits();
    measured_lead_translation();
    angular_lead_uses_rotated_offset();
    invalid_lead_falls_back_atomically();
    invalid_base_cannot_become_led();
    std::cout << "body_follow checks=" << checks << " native_actions=0\n";
}
