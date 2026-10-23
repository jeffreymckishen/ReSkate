#include "native_input_trace.h"
#include <limits>

namespace dingosdk::input_trace {
namespace {
void increment(std::uint64_t& count) noexcept { if (count != std::numeric_limits<std::uint64_t>::max()) ++count; }
bool same_value(const Observation& a, const Observation& b) noexcept {
    return a.asset_token == b.asset_token && a.lane == b.lane && a.condition_known == b.condition_known &&
        a.condition == b.condition && a.local_tuple_known == b.local_tuple_known &&
        a.container_matches_local == b.container_matches_local && a.snapshot_stable == b.snapshot_stable && a.issue == b.issue;
}
}
bool Ledger::advance(std::uint64_t now) noexcept {
    if (clock_known_ && now < last_ms_) return false;
    clock_known_ = true; last_ms_ = now;
    for (auto& entry : entries_) if (entry.occupied && entry.receipt.status == Status::active && now >= entry.receipt.expires_ms)
        entry.receipt.status = Status::expired;
    return true;
}
Ledger::Entry* Ledger::find(std::uint64_t owner, Handle handle) noexcept {
    if (!owner || !handle.sequence) return nullptr;
    for (auto& entry : entries_) if (entry.occupied && entry.owner == owner && entry.receipt.handle.sequence == handle.sequence) return &entry;
    return nullptr;
}
bool Ledger::start(std::uint64_t owner, std::uint64_t now, Handle& handle, Reason& reason) noexcept {
    handle = {}; reason = Reason::none;
    if (!owner) { reason = Reason::invalid_owner; return false; }
    if (now > std::numeric_limits<std::uint64_t>::max() - duration_ms || !advance(now)) {
        reason = Reason::clock_invalid; return false;
    }
    for (const auto& entry : entries_) if (entry.occupied && entry.owner == owner && entry.receipt.status == Status::active) {
        reason = Reason::busy; return false;
    }
    if (next_ == std::numeric_limits<std::uint64_t>::max()) { reason = Reason::sequence_exhausted; return false; }
    Entry* available{};
    for (auto& entry : entries_) if (!entry.occupied) { available = &entry; break; }
    if (!available) { reason = Reason::capacity; return false; }
    *available = {}; available->owner = owner; available->occupied = true;
    available->receipt.handle.sequence = ++next_; available->receipt.requested_ms = now;
    available->receipt.expires_ms = now + duration_ms; handle = available->receipt.handle;
    return true;
}
bool Ledger::read(std::uint64_t owner, Handle handle, std::uint64_t now, Receipt& receipt) noexcept {
    receipt = {};
    if (!advance(now)) return false;
    const auto* entry = find(owner, handle);
    if (!entry) return false;
    receipt = entry->receipt; return true;
}
bool Ledger::stop(std::uint64_t owner, Handle handle, std::uint64_t now) noexcept {
    if (!advance(now)) return false;
    auto* entry = find(owner, handle);
    if (!entry || entry->receipt.status != Status::active) return false;
    entry->receipt.status = Status::stopped; return true;
}
bool Ledger::acknowledge(std::uint64_t owner, Handle handle, std::uint64_t now) noexcept {
    if (!advance(now)) return false;
    auto* entry = find(owner, handle);
    if (!entry || !terminal(entry->receipt.status)) return false;
    *entry = {}; return true;
}
void Ledger::release_all(std::uint64_t owner) noexcept {
    if (!owner) return;
    for (auto& entry : entries_) if (entry.occupied && entry.owner == owner) entry = {};
}
Snapshot Ledger::begin(std::uint64_t now) noexcept {
    Snapshot snapshot; snapshot.began_ms = now;
    if (!advance(now)) return snapshot;
    for (const auto& entry : entries_) if (entry.occupied && entry.receipt.status == Status::active)
        snapshot.tickets[snapshot.count++] = {entry.owner, entry.receipt.handle.sequence};
    return snapshot;
}
std::uint32_t Ledger::finish(const Snapshot& snapshot, const Observation& observation, std::uint64_t now) noexcept {
    if (snapshot.count > ticket_capacity) return 0;
    const bool clock = advance(now) && now >= snapshot.began_ms;
    const bool valid = clock && observation.observed_ms >= snapshot.began_ms && observation.observed_ms <= now &&
        (observation.lane == Lane::interpreter || observation.lane == Lane::alternate);
    std::uint32_t appended{};
    for (std::uint32_t i = 0; i < snapshot.count; ++i) {
        const auto ticket = snapshot.tickets[i];
        bool repeated{};
        for (std::uint32_t j = 0; j < i; ++j) if (snapshot.tickets[j].owner == ticket.owner && snapshot.tickets[j].sequence == ticket.sequence) repeated = true;
        if (repeated) continue;
        auto* entry = find(ticket.owner, {ticket.sequence});
        if (!entry) continue;
        auto& receipt = entry->receipt;
        if (receipt.status != Status::active) continue; // Terminal receipts are historical, frozen records.
        increment(receipt.seen);
        if (!valid) { increment(receipt.dropped); continue; }
        const Observation* previous{};
        for (std::uint32_t j = receipt.record_count; j > 0; --j) {
            const auto& candidate = receipt.records[j - 1];
            if (candidate.asset_token == observation.asset_token && candidate.lane == observation.lane) { previous = &candidate; break; }
        }
        if (previous && same_value(*previous, observation)) { increment(receipt.duplicates); continue; }
        if (receipt.record_count == record_capacity) { increment(receipt.dropped); continue; }
        receipt.records[receipt.record_count++] = observation; ++appended;
    }
    return appended;
}
} // namespace dingosdk::input_trace
