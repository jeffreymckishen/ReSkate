#pragma once
#include "body_hit_identity.h"
#include "body_query.h"
#include "Engine/Game/Build/20260929/rigid_bodies.h"
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>

// An optional, read-only diagnostic beside an already qualified nearest hit: the
// hit shape's InCategories DWORD as read now, through World+28 and state+FE8.
// It is read-time evidence only. It does not identify an actor, a floor, terrain,
// static geometry, support or collision-time filtering, and it grants nothing.
// Missing means unavailable; zero is a known empty mask.
namespace dingosdk::body_shape_categories {
using NativeHandle = body_hit_identity::NativeHandle;
// Private to the native adapter. Only the copied DWORD can leave, and only
// through Sidecars::publish after the batch's closing fence.
struct Witness {
    std::uintptr_t world{}, state{};
    NativeHandle shape{}, body{};
    std::uintptr_t categories{};
    std::uint32_t value{};
};
// unavailable drops only this optional value. identity_changed means the hit
// itself no longer qualifies, so the caller refuses its whole batch.
enum class Capture : std::uint8_t { available, unavailable, identity_changed };

// The pinned getter reads World+28, then state+FE8, then DWORD[shape.index].
// Its bytes are compared, never called. A mismatch disables this field only.
template<class Read>
bool layout_qualified(std::uintptr_t base, Read&& read) {
    namespace r = addr::rigid_bodies;
    decltype(r::shape_in_categories.bytes) actual{};
    constexpr auto last = std::numeric_limits<std::uintptr_t>::max() - (sizeof(actual) - 1);
    if (!base || base > last - r::shape_in_categories.rva) return false;
    return read(base + r::shape_in_categories.rva, actual) && actual == r::shape_in_categories.bytes;
}

// qualified(shape, body) is the caller's check that this ORIGINAL actual hit
// still qualifies: current World/state, epoch, shape allocation and generation,
// and its shape-to-body association. It runs before and after the reads, which
// cannot detect reuse on their own. The element is the hit's own shape index,
// never the mapped body or a batch ordinal, so child shapes of one body differ.
template<class Read, class Qualified>
Capture capture(std::uintptr_t world, std::uintptr_t state, const NativeHandle& shape, const NativeHandle& body,
    Witness& out, Read&& read, Qualified&& qualified) {
    namespace r = addr::rigid_bodies;
    out = {};
    constexpr auto last = std::numeric_limits<std::uintptr_t>::max() - (sizeof(std::uintptr_t) - 1);
    // Complete field arithmetic precedes the callback and every read; element()
    // refuses a null array and an element span that would overflow.
    if (!world || !state || state > last - r::shape_categories || shape.world != world || body.world != world ||
        shape.index == 0xffffffffU || body.index == 0xffffffffU) return Capture::unavailable;
    if (!qualified(shape, body)) return Capture::identity_changed;
    std::uintptr_t categories{}, again{};
    std::uint32_t value{}, repeated{};
    const bool readable = read(state + r::shape_categories, categories) &&
        body_hit_identity::element(read, categories, shape.index, value) &&
        read(state + r::shape_categories, again) && again == categories &&
        body_hit_identity::element(read, categories, shape.index, repeated) && repeated == value;
    // Requalify even after a failed read: an identity change outranks a missing value.
    if (!qualified(shape, body)) return Capture::identity_changed;
    if (!readable) return Capture::unavailable;
    out = {world, state, shape, body, categories, value};
    return Capture::available;
}
// The closing inspection repeats the whole capture for the same original hit.
// A different array or value is category-only drift and drops the value.
template<class Read, class Qualified>
Capture current(const Witness& value, Read&& read, Qualified&& qualified) {
    Witness again;
    const auto result = body_shape_categories::capture(value.world, value.state, value.shape, value.body, again, read, qualified);
    if (result != Capture::available) return result;
    return again.categories == value.categories && again.value == value.value ? Capture::available : Capture::unavailable;
}

// One optional value per requested ray, bound to the query ordinal: execute calls
// its query once per ray, in order. It is never keyed by body, so child shapes of
// one body, or two rays on one shape, keep their own witnesses.
template<std::size_t Capacity> class Sidecars {
public:
    // False only when the hit's identity changed, and that is sticky for the
    // batch. Unreadable or drifting category data just leaves this ray absent.
    template<class Read, class Qualified>
    bool capture(std::size_t ordinal, std::uintptr_t world, std::uintptr_t state, const NativeHandle& shape,
        const NativeHandle& body, Read&& read, Qualified&& qualified) {
        if (identity_lost_) return false;
        if (ordinal >= Capacity) return true;
        present_[ordinal] = false;
        Witness witness;
        const auto result = body_shape_categories::capture(world, state, shape, body, witness, read, qualified);
        if (result == Capture::identity_changed) { identity_lost_ = true; return false; }
        if (result == Capture::available) { witnesses_[ordinal] = witness; present_[ordinal] = true; }
        return true;
    }
    // Run inside the batch fence. A category-only loss or change removes that
    // value for the rest of the batch; an identity loss refuses the batch.
    template<class Read, class Qualified>
    bool current(Read&& read, Qualified&& qualified) {
        if (identity_lost_) return false;
        for (std::size_t i = 0; i < Capacity; ++i) {
            if (!present_[i]) continue;
            const auto result = body_shape_categories::current(witnesses_[i], read, qualified);
            if (result == Capture::identity_changed) { identity_lost_ = true; return false; }
            if (result != Capture::available) present_[i] = false;
        }
        return true;
    }
    bool identity_lost() const noexcept { return identity_lost_; }
    bool available(std::size_t ordinal) const noexcept { return ordinal < Capacity && present_[ordinal]; }
    // Pass the result execute returned. Nothing is copied into a refused batch,
    // a row that is not a hit, or a request that did not opt in.
    void publish(const body_query::Request& request, body_query::Result& out) const noexcept {
        if (!out.available || !request.include_shape_categories || identity_lost_) return;
        for (std::size_t i = 0; i < out.count && i < out.rays.size() && i < Capacity; ++i) {
            auto& hit = out.rays[i];
            if (hit.status != body_query::Status::hit || !present_[i]) continue;
            hit.in_categories = witnesses_[i].value; hit.in_categories_available = true;
        }
    }
private:
    std::array<Witness, Capacity> witnesses_{};
    std::array<bool, Capacity> present_{};
    bool identity_lost_{};
};
} // namespace dingosdk::body_shape_categories
