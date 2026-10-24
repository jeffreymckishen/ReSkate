    // Constructed leaf results for the actual Host binding. No native actor,
    // invocation, hold, drain or park is executed or qualified by this fixture.
    using FollowHandle = dingosdk::body_follow_api::Handle;
    using FollowAttachment = dingosdk::body_follow_api::Attachment;
    using FollowReason = dingosdk::body_follow_api::Reason;
    using FollowReceipt = dingosdk::body_follow_api::Receipt;
    using FollowPhase = dingosdk::body_follow_api::Phase;
    using FollowPending = dingosdk::body_follow_api::Pending;
    struct FollowFixture {
        std::uint64_t owner{};
        owned_body::Handle body{};
        FollowAttachment attachment{};
        FollowReceipt receipt{};
        bool ever_published{};
    } follow_fixture;
    std::uint64_t follow_sequence{9007199254740994ULL};
    unsigned follow_reserves{}, follow_publishes{}, follow_reads{}, follow_stops{}, follow_acks{}, follow_closes{}, follow_host_cleanups{};
    unsigned follow_corruption{};
    bool follow_partial_refusal{}, follow_reserve_refusal{}, follow_zero_handle{}, follow_publish_refusal{};
    bool follow_closed_before_body_cleanup{};
    bool follows(std::uint64_t owner, FollowHandle handle) const {
        return owner && follow_fixture.owner == owner && handle.sequence &&
            follow_fixture.receipt.handle.sequence == handle.sequence;
    }
    bool body_follow_reserve(std::uint64_t owner, const owned_body::Handle& body,
        const FollowAttachment& attachment, FollowHandle& handle, FollowReason& reason) override {
        ++follow_reserves; handle = {}; reason = FollowReason::unavailable;
        if (follow_reserve_refusal) return false;
        if (follow_fixture.owner) { reason = FollowReason::busy; return false; }
        const auto* source = body_of(owner, body);
        if (!source || source->released || source->quarantined || !dingosdk::body_follow_api::valid(attachment)) return false;
        follow_fixture = {}; follow_fixture.owner = owner; follow_fixture.body = body;
        follow_fixture.attachment = attachment;
        auto& receipt = follow_fixture.receipt;
        receipt.handle.sequence = ++follow_sequence; receipt.claim_known = true;
        receipt.reason = reason = follow_partial_refusal ? FollowReason::motion_owned : FollowReason::none;
        receipt.phase = follow_partial_refusal ? FollowPhase::stopping : FollowPhase::reserved;
        handle = follow_zero_handle ? FollowHandle{} : receipt.handle;
        return !follow_partial_refusal;
    }
    bool body_follow_publish(std::uint64_t owner, FollowHandle handle, FollowReason& reason) override {
        ++follow_publishes; reason = FollowReason::unavailable;
        if (!follows(owner, handle) || follow_fixture.receipt.phase != FollowPhase::reserved || follow_publish_refusal) return false;
        follow_fixture.ever_published = true;
        follow_fixture.receipt.phase = FollowPhase::following; reason = FollowReason::none; return true;
    }
    bool body_follow_read(std::uint64_t owner, FollowHandle handle, FollowReceipt& out) override {
        ++follow_reads; out = {};
        if (!follows(owner, handle)) return false;
        out = follow_fixture.receipt;
        switch (follow_corruption) {
        case 1: ++out.handle.sequence; break;
        case 2: out.phase = static_cast<FollowPhase>(255); break;
        case 3: out.reason = static_cast<FollowReason>(255); break;
        case 4: out.park_reason = static_cast<FollowReason>(255); break;
        case 5: out.pending = static_cast<FollowPending>(255); break;
        case 6: out.in_flight = 256; break;
        case 7: out.returned_revision = out.final_revision + 1; break;
        case 8: out.final_native_epoch = 0; break;
        case 9: out.native_retirement_known = true; break;
        case 10: out.phase = FollowPhase::completed; out.park_observed = false; break;
        case 11: out.phase = FollowPhase::completed; out.park_observed = true; out.pending = FollowPending::body_parked; break;
        case 12: out.phase = FollowPhase::completed; out.park_observed = true; out.in_flight = 1; break;
        case 13: out.phase = FollowPhase::completed; out.park_observed = true; --out.returned_revision; break;
        case 14: out.phase = FollowPhase::abandoned; break;
        case 15: out.phase = FollowPhase::reserved; break;
        }
        return true;
    }
    bool body_follow_stop(std::uint64_t owner, FollowHandle handle) override {
        ++follow_stops;
        if (!follows(owner, handle)) return false;
        auto& receipt = follow_fixture.receipt;
        if (dingosdk::body_follow_api::terminal(receipt.phase)) return true;
        receipt.reason = FollowReason::cancelled;
        if (receipt.phase == FollowPhase::reserved) {
            receipt.phase = FollowPhase::abandoned; receipt.claim_known = false;
        } else {
            receipt.phase = FollowPhase::stopping; receipt.pending = FollowPending::body_parked;
        }
        return true;
    }
    bool body_follow_acknowledge(std::uint64_t owner, FollowHandle handle) override {
        ++follow_acks;
        if (!follows(owner, handle)) return false;
        const auto& receipt = follow_fixture.receipt;
        if (!dingosdk::body_follow_api::terminal(receipt.phase) || receipt.pending != FollowPending::none ||
            receipt.in_flight || receipt.native_retirement_known) return false;
        if (receipt.phase == FollowPhase::completed && (!receipt.park_observed ||
            receipt.final_revision != receipt.returned_revision)) return false;
        if (receipt.phase == FollowPhase::abandoned && receipt.final_revision) return false;
        follow_fixture = {}; return true;
    }
    void construct_follow_forwarded() {
        auto& receipt = follow_fixture.receipt;
        receipt.phase = FollowPhase::following;
        receipt.final_revision = receipt.returned_revision = 9007199254740997ULL;
        receipt.final_native_epoch = 9007199254741001ULL;
    }
    void construct_follow_completed() {
        auto& receipt = follow_fixture.receipt;
        receipt.phase = FollowPhase::completed; receipt.pending = FollowPending::none;
        receipt.in_flight = 0; receipt.claim_known = false; receipt.park_observed = true;
        receipt.park_reason = FollowReason::none;
        receipt.returned_revision = receipt.final_revision;
    }
    void construct_follow_abandoned() {
        auto& receipt = follow_fixture.receipt;
        receipt.phase = FollowPhase::abandoned; receipt.pending = FollowPending::none;
        receipt.in_flight = 0; receipt.claim_known = false;
    }
    void close_follow_fixture(std::uint64_t owner) {
        if (follow_fixture.owner != owner) return;
        // Host unload closes once, then Plugin destruction may close again.
        // Keep the first stop-before-body observation across repeated cleanup.
        if (follow_fixture.receipt.orphaned) return;
        ++follow_closes;
        const auto* source = body_of(owner, follow_fixture.body);
        follow_closed_before_body_cleanup = source && !source->released;
        follow_fixture.receipt.orphaned = true;
        if (!dingosdk::body_follow_api::terminal(follow_fixture.receipt.phase)) {
            follow_fixture.receipt.phase = FollowPhase::stopping;
            follow_fixture.receipt.reason = FollowReason::owner_released;
        }
    }
    bool construct_orphan_host_cleanup() {
        if (!follow_fixture.receipt.orphaned) return false;
        if (follow_fixture.ever_published) {
            if (follow_fixture.receipt.phase != FollowPhase::completed) return false;
        } else {
            const auto* source = body_of(follow_fixture.owner,follow_fixture.body);
            if (follow_fixture.receipt.phase != FollowPhase::abandoned || !source || !source->released) return false;
        }
        // Constructed host cleanup uses its retained exact old identity, not
        // a replacement VM, receipt DTO, public proof or owner-transfer API.
        if (!body_follow_acknowledge(follow_fixture.owner,follow_fixture.receipt.handle)) return false;
        ++follow_host_cleanups; return true;
    }
