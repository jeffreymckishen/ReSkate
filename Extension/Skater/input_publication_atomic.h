#pragma once
#include "input_publication_gate.h"
#include <atomic>

namespace dingosdk::native_input_pulse {
// Existing UI writers keep their short atomic operations. A changed capture or
// readiness fact is published with revocation before a report can commit.
// Callers must not hold PublicationScope; token-taking native setters use set.
template<class T, PublicationChange Change = PublicationChange::interference>
class PublicationAtomic {
public:
    constexpr PublicationAtomic() noexcept = default;
    constexpr explicit PublicationAtomic(T value) noexcept : value_(value) {}
    PublicationAtomic(const PublicationAtomic&) = delete;
    PublicationAtomic& operator=(const PublicationAtomic&) = delete;

    T load(std::memory_order order = std::memory_order_seq_cst) const noexcept {
        return value_.load(order);
    }
    operator T() const noexcept { return load(); }
    T operator=(T value) noexcept { store(value); return value; }
    void store(T value, std::memory_order order = std::memory_order_seq_cst) noexcept {
        PublicationScope scope;
        (void)set(scope, value, order);
    }
    T exchange(T value, std::memory_order order = std::memory_order_seq_cst) noexcept {
        PublicationScope scope;
        return set(scope, value, order);
    }
    // An invalid token never changes the underlying flag. Native callers must
    // keep the token through this update and their other coordinated writes.
    T set(const PublicationScope& scope, T value,
        std::memory_order order = std::memory_order_seq_cst) noexcept {
        if (!scope.owns()) return load();
        const auto previous = value_.exchange(value, order);
        if (previous != value) publication_changed(scope, Change);
        return previous;
    }
private:
    std::atomic<T> value_{};
};
}
