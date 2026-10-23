#include "Engine/Game/Skater/native_action_policy.h"
#include <cstdlib>
#include <iostream>
#include <string_view>

namespace a = dingosdk::skater_action;
namespace {
unsigned checks{};
void require(bool value, std::string_view why) {
    ++checks;
    if (!value) { std::cerr << "native action: " << why << '\n'; std::exit(1); }
}
struct Binding { std::uint64_t actor{}, world{}, lifetime{}; };
using Ledger = a::Ledger<Binding>;
const a::State board{true, false, false, false, false, 100};
const a::State walking{true, true, false, true, false, 504};
void receipts() {
    Ledger ledger; a::Handle handle, other; a::Reason reason;
    const Binding binding{8, 11, 3};
    require(ledger.enqueue(7, a::Kind::on_foot, binding, board, 100, handle, reason), "first enqueue");
    auto* entry = ledger.find(7, handle);
    require(entry && entry->receipt.status == a::Status::pending, "queued is not delivered");
    require(!ledger.find(8, handle), "cross VM read denied");
    require(!ledger.cancel(8, handle, 101) && !ledger.acknowledge(8, handle), "cross VM mutation denied");
    require(!ledger.enqueue(8, a::Kind::board, binding, walking, 101, other, reason) && reason == a::Reason::busy,
            "opposite owner cannot overwrite global action");
    require(!ledger.enqueue(0, a::Kind::on_foot, binding, board, 101, other, reason), "invalid owner does not clear request");
    require(!ledger.enqueue(8, static_cast<a::Kind>(9), binding, board, 101, other, reason), "invalid kind does not clear request");
    require(ledger.find(7, handle) == entry && entry->receipt.status == a::Status::pending, "failed requests preserve original");
    require(!ledger.acknowledge(7, handle), "pending acknowledgement denied");
    require(Ledger::claim(*entry, 102), "claim once");
    require(entry->receipt.status == a::Status::pending && entry->receipt.offered_ms == 0, "claim does not falsely offer");
    require(!Ledger::claim(*entry, 103) && !ledger.cancel(7, handle, 103), "claimed action cannot cancel or claim twice");
    Ledger::offered(*entry, 104, 20);
    require(entry->receipt.status == a::Status::offered && entry->receipt.offered_ms == 104, "only actual bit marks offer");
    require(!ledger.cancel(7, handle, 105) && !ledger.acknowledge(7, handle), "offered cannot cancel or acknowledge");
    Ledger::selection(*entry, 504, 504, true, 106);
    require(entry->receipt.status == a::Status::selected && entry->receipt.original_candidate == 504 && entry->receipt.final_candidate == 504,
            "selector candidates are not committed state");
    Ledger::observe(*entry, walking, 107, 20);
    require(entry->receipt.status == a::Status::selected && !entry->receipt.committed_known, "same observation cannot complete");
    auto ragdoll = walking; ragdoll.ragdoll = true;
    Ledger::observe(*entry, ragdoll, 108, 21);
    require(entry->receipt.status == a::Status::selected && entry->receipt.ragdoll, "504 ragdoll cannot complete");
    auto unknown = walking; unknown.ragdoll_known = false;
    Ledger::observe(*entry, unknown, 109, 22);
    require(entry->receipt.status == a::Status::selected, "unknown ragdoll cannot complete");
    auto airborne = walking; airborne.in_air = true;
    Ledger::observe(*entry, airborne, 110, 23);
    require(entry->receipt.status == a::Status::selected, "airborne504 cannot complete");
    unknown = walking; unknown.in_air_known = false;
    Ledger::observe(*entry, unknown, 111, 24);
    require(entry->receipt.status == a::Status::selected, "unknown air cannot complete");
    Ledger::observe(*entry, walking, 112, 25);
    require(entry->receipt.status == a::Status::completed && entry->receipt.committed_state == 504, "later grounded nonragdoll504 completes");
    Ledger::finish(*entry, a::Status::rejected, a::Reason::actor_changed, 113);
    require(entry->receipt.status == a::Status::completed, "terminal status remains retained");
    require(ledger.acknowledge(7, handle) && !ledger.find(7, handle), "owner acknowledges terminal receipt");
    require(!ledger.acknowledge(7, handle), "duplicate acknowledgement denied");

    require(ledger.enqueue(7, a::Kind::board, binding, walking, 120, handle, reason), "reverse enqueue");
    entry = ledger.find(7, handle); require(Ledger::claim(*entry, 121), "reverse claim");
    Ledger::offered(*entry, 121, 30); Ledger::selection(*entry, 200, 200, true, 122);
    require(entry->receipt.status == a::Status::selected, "normal native mount candidate200 admitted");
    auto mounting = board; mounting.value = 200;
    Ledger::observe(*entry, mounting, 123, 31);
    require(entry->receipt.status == a::Status::selected, "native200 is not grounded completion");
    Ledger::observe(*entry, board, 124, 32);
    require(entry->receipt.status == a::Status::completed, "mount completes only at later100");
    require(ledger.acknowledge(7, handle), "reverse acknowledged");
}
void failures_and_lifetime() {
    for (const auto reason : {a::Reason::context_changed, a::Reason::native_lifetime_changed,
         a::Reason::world_changed, a::Reason::focus_changed, a::Reason::motion_owned,
         a::Reason::protection_conflict, a::Reason::request_bits_conflict, a::Reason::request_write_failed}) {
        Ledger ledger; a::Handle handle; a::Reason why;
        require(ledger.enqueue(4, a::Kind::on_foot, {}, board, 10, handle, why), "failure setup");
        auto* e = ledger.find(4, handle); require(Ledger::claim(*e, 11), "failure claim");
        e->claimed = false; Ledger::finish(*e, a::Status::rejected, reason, 12);
        require(e->receipt.reason == reason && e->receipt.offered_ms == 0, "pre-offer failure typed and unoffered");
        Ledger::observe(*e, walking, 13, 99);
        require(e->receipt.status == a::Status::rejected, "rejected action never becomes completed");
    }
    for (unsigned scenario = 0; scenario < 3; ++scenario) {
        Ledger ledger; a::Handle handle; a::Reason why;
        require(ledger.enqueue(4, a::Kind::on_foot, {}, board, 10, handle, why), "selector setup");
        auto* e = ledger.find(4, handle); require(Ledger::claim(*e, 11), "selector claim");
        Ledger::offered(*e, 11, 5);
        Ledger::selection(*e, scenario == 1 ? 100U : 504U, scenario == 2 ? 100U : (scenario == 1 ? 100U : 504U), scenario != 0, 12);
        require(e->receipt.status == a::Status::rejected && e->receipt.reason ==
            (scenario == 0 ? a::Reason::request_restore_failed : scenario == 1 ? a::Reason::native_refused : a::Reason::selector_overridden),
            "restore, refusal and override remain separate");
    }
    require(a::lifetime_fence(3, 3, 9, 9) == a::Reason::none, "same lifecycle fence");
    require(a::lifetime_fence(3, 4, 9, 9) == a::Reason::native_lifetime_changed, "same-address reuse changes lifetime");
    require(a::lifetime_fence(3, 3, 9, 10) == a::Reason::world_changed, "world generation changed");
    Ledger ledger; a::Handle handle, next; a::Reason why;
    require(ledger.enqueue(4, a::Kind::on_foot, {}, board, 10, handle, why), "unload setup");
    auto* e = ledger.find(4, handle); require(Ledger::claim(*e, 11), "unload claim");
    ledger.release(4, 12);
    require(!ledger.find(4, handle) && ledger.active() == e, "unloaded in-flight owner hidden but keeps arbitration");
    require(!ledger.enqueue(5, a::Kind::on_foot, {}, board, 13, next, why), "unload cannot free native in-flight claim");
    Ledger::selection(*e, 504, 504, true, 14);
    require(!ledger.active() && ledger.enqueue(5, a::Kind::on_foot, {}, board, 15, next, why), "native return retires abandoned claim");
    ledger.release(5, 16); require(!ledger.active() && !ledger.find(5, next), "pending owner release clears only that owner");
}
void budgets_and_expiry() {
    Ledger ledger; a::Reason why; std::array<a::Handle, a::receipt_slots> handles{};
    for (auto& h : handles) {
        require(ledger.enqueue(1, a::Kind::board, {}, board, 10, h, why), "already-target terminal retained");
        const auto& receipt = ledger.find(1, h)->receipt;
        require(receipt.status == a::Status::already_target && receipt.committed_known && receipt.committed_state == 100 &&
            !receipt.original_known && !receipt.final_known && receipt.offered_ms == 0, "already target retains actual snapshot without selector offer");
    }
    a::Handle extra;
    require(!ledger.enqueue(1, a::Kind::board, {}, board, 11, extra, why) && why == a::Reason::receipt_capacity,
            "full receipt ring applies backpressure instead of overwriting");
    require(ledger.acknowledge(1, handles[0]), "free oldest explicit receipt");
    require(ledger.enqueue(1, a::Kind::board, {}, board, 12, extra, why) && extra.sequence > handles.back().sequence,
            "reused slot gets fresh monotonic handle");
    require(!ledger.find(1, handles[0]), "stale handle cannot alias reused slot");
    ledger.release(1, 13);
    require(ledger.enqueue(2, a::Kind::on_foot, {}, board, 100, extra, why), "expiry setup");
    auto* e = ledger.find(2, extra); Ledger::expire(*e, 349);
    require(e->receipt.status == a::Status::pending, "not early expiry");
    Ledger::expire(*e, 350);
    require(e->receipt.status == a::Status::expired && !Ledger::claim(*e, 351), "unused request expires exactly250ms with no retry");
    require(ledger.acknowledge(2, extra), "expired acknowledgement");
    require(ledger.enqueue(2, a::Kind::board, {}, walking, 400, extra, why), "commit expiry setup");
    e = ledger.find(2, extra); require(Ledger::claim(*e, 401), "commit expiry claim");
    Ledger::offered(*e, 402, 1); Ledger::selection(*e, 200, 200, true, 403);
    Ledger::observe(*e, board, 4402, 2);
    require(e->receipt.status == a::Status::expired, "late actual target does not turn expiry into success");
}
void quarantine() {
    Ledger ledger; a::Handle handle, other; a::Reason reason;
    require(ledger.enqueue(1, a::Kind::on_foot, {8, 11, 3}, board, 10, handle, reason), "quarantine setup");
    auto* e = ledger.find(1, handle); require(Ledger::claim(*e, 11), "quarantine claim");
    Ledger::offered(*e, 12, 1); Ledger::selection(*e, 504, 504, false, 13);
    require(e->receipt.status == a::Status::rejected && e->receipt.reason == a::Reason::request_restore_failed &&
        e->receipt.quarantined && !e->receipt.flag_restored && ledger.active() == e, "unrestored bit holds terminal quarantine");
    require(!ledger.acknowledge(1, handle) && !ledger.cancel(1, handle, 14), "quarantine cannot be acknowledged or cancelled");
    require(!ledger.enqueue(2, a::Kind::board, {}, walking, 14, other, reason) && reason == a::Reason::busy,
        "quarantine blocks different VM action");
    Ledger::expire(*e, 99999); Ledger::observe(*e, walking, 99999, 99);
    require(e->receipt.quarantined && e->receipt.status == a::Status::rejected, "timeout and actual target cannot clear uncertain bit");
    Ledger::retire_quarantine(*e);
    require(!e->receipt.quarantined && !e->receipt.flag_restored && e->receipt.status == a::Status::rejected &&
        e->receipt.reason == a::Reason::request_restore_failed, "safe-clear proof releases guard without claiming restoration or completion");
    require(ledger.acknowledge(1, handle), "resolved terminal quarantine can be acknowledged");
    require(ledger.enqueue(1, a::Kind::on_foot, {}, board, 20, handle, reason), "abandoned quarantine setup");
    e = ledger.find(1, handle); require(Ledger::claim(*e, 21), "abandoned quarantine claim");
    Ledger::offered(*e, 22, 2); ledger.release(1, 23);
    Ledger::selection(*e, 504, 504, false, 24);
    require(ledger.active() == e && !ledger.find(1, handle) && e->receipt.quarantined, "VM unload cannot release uncertain native bit");
    Ledger::retire_quarantine(*e);
    require(!ledger.active() && !e->occupied, "retirement proof finally frees abandoned quarantine");
}
void bits_and_publication() {
    for (const auto bit : {0x80U, 0x100U, 0x180U}) {
        unsigned calls{}; std::uint32_t word = 0x4000U | bit;
        auto compare = [&](std::uint32_t exchange, std::uint32_t expected, std::uint32_t& observed) noexcept {
            ++calls; observed = word; if (word == expected) word = exchange; return true;
        };
        const auto result = a::offer_bits(0x100U, 0x180U, compare);
        require(!result.inserted && result.reason == a::Reason::request_bits_conflict && calls == 1 && word == (0x4000U | bit),
                "same/opposite preexisting native request is not a new SDK offer");
    }
    for (unsigned mode = 0; mode < 4; ++mode) {
        unsigned calls{}; std::uint32_t word = 0x4000U;
        auto compare = [&](std::uint32_t exchange, std::uint32_t expected, std::uint32_t& observed) noexcept {
            ++calls;
            if ((mode == 1 && calls == 1) || (mode == 2 && calls == 2)) return false;
            if (mode == 3 && calls == 2) word |= 0x2000U;
            observed = word; if (word == expected) word = exchange; return true;
        };
        const auto result = a::offer_bits(0x100U, 0x180U, compare);
        require(calls <= 2, "no atomic retry loop");
        require(result.inserted == (mode == 0), "only unchanged readable word gets offered");
        if (mode == 0) require(word == 0x4100U && result.before == 0x4000U, "unrelated flags preserved");
        else require((word & 0x180U) == 0, "failure never inserts request");
    }
    a::MotionClaim claim;
    require(claim.publication_allowed() && claim.begin_admission(), "initial empty provider may publish or reserve");
    require(!claim.publication_allowed() && !claim.begin_admission(), "reservation blocks provider and second requester");
    claim.retire_if_idle(); require(!claim.publication_allowed(), "observer cleanup cannot release in-progress admission");
    claim.publish(true); require(!claim.publication_allowed(), "published pending/selected action blocks motion publication");
    claim.retire_if_idle(); require(claim.publication_allowed(), "terminal retirement releases provider");
    require(claim.begin_admission(), "new admission after terminal"); claim.publish(false);
    require(claim.publication_allowed(), "failed admission releases reservation");
}
}
int main() {
    receipts(); failures_and_lifetime(); budgets_and_expiry(); quarantine(); bits_and_publication();
    std::cout << "native action policy passed: " << checks << " checks\n";
}
