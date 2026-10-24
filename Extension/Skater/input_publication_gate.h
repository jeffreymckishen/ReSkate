#pragma once
#include <cstdint>

namespace dingosdk::native_input_pulse {
enum class PublicationChange { interference, paused, context };

// Nonrecursive native publication gate. Never surround an original XInput call,
// external filter callback, Luau callback, UI draw or window/cursor operation.
// Token-taking helpers do not acquire it again. The lock order is this gate,
// then the service state lock or a specifically audited native-state mutex.
class PublicationScope {
public:
    explicit PublicationScope(bool enabled = true) noexcept;
    ~PublicationScope();
    PublicationScope(const PublicationScope&) = delete;
    PublicationScope& operator=(const PublicationScope&) = delete;
    PublicationScope(PublicationScope&&) = delete;
    PublicationScope& operator=(PublicationScope&&) = delete;
    bool owns() const noexcept;
private:
    bool acquired_{};
    std::uint32_t thread_{};
};

bool publication_held() noexcept;
// Zero means an invalid token or exhausted/invalid gate. Revisions do not wrap.
std::uint64_t publication_revision(const PublicationScope& scope) noexcept;
// Mutate only your own capture state, then call this for an actual change while
// retaining the token. It invalidates readable source authority and revokes own
// capture before another report can publish; report debt remains reserved.
void publication_changed(const PublicationScope& scope,
    PublicationChange change = PublicationChange::interference) noexcept;
}
