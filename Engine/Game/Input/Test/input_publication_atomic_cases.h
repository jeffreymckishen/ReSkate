#pragma once
#include "Extension/Skater/input_publication_atomic.h"
#include <atomic>
#include <cstdint>
#include <type_traits>

namespace dingosdk::input_publication_atomic_test {
namespace native = native_input_pulse;

// The including actual-service fixture owns all native providers and cleanup.
// arm() establishes a fresh observed lease, capture, and real neutral publication
// debt. conclude(changed) checks the resulting actual broker/capture authority,
// then completes neutral handoff and acknowledgement before the next case.
template<class Check, class Arm, class Conclude>
void run_publication_atomic_cases(Check&& check, Arm&& arm, Conclude&& conclude) {
    static_assert(!std::is_copy_constructible_v<native::PublicationAtomic<bool>>);
    static_assert(!std::is_copy_assignable_v<native::PublicationAtomic<bool>>);
    static_assert(std::is_convertible_v<const native::PublicationAtomic<bool>&, bool>);

    const auto revision = [&]() {
        check(!native::publication_held(), "atomic case enters without a held publication gate");
        std::uint64_t result{};
        {
            native::PublicationScope scope;
            check(scope.owns() && native::publication_held(), "atomic case uses actual native publication token");
            result = native::publication_revision(scope);
            check(result != 0, "actual native publication revision remains usable");
        }
        check(!native::publication_held(), "short publication scope releases before fixture operations");
        return result;
    };

    // Construction is deliberately silent, including nonzero pointer/readiness
    // defaults. A read of an existing flag is never a publication event.
    {
        arm();
        const auto before = revision();
        native::PublicationAtomic<bool> default_flag;
        native::PublicationAtomic<bool> enabled{true};
        int client{};
        native::PublicationAtomic<const void*, native::PublicationChange::context> context{&client};
        check(!default_flag && enabled && enabled.load(std::memory_order_acquire),
            "default construction and implicit bool retain original atomic read behavior");
        check(context.load() == &client, "pointer initialization preserves exact context value");
        check(revision() == before, "construction and reads do not notify or change publication revision");
        conclude(false);
    }
    {
        arm();
        native::PublicationAtomic<bool> flag{false};
        const auto before = revision();
        flag.store(true, std::memory_order_release);
        check(flag.load(std::memory_order_acquire), "changed store publishes requested flag value");
        check(revision() > before, "changed store advances actual publication authority");
        conclude(true);
    }
    {
        arm();
        native::PublicationAtomic<bool> flag{false};
        const auto before = revision();
        flag.store(false, std::memory_order_release);
        check(!flag && revision() == before, "no-op store preserves value and publication revision");
        conclude(false);
    }
    {
        arm();
        native::PublicationAtomic<bool> flag{false};
        const auto before = revision();
        check(!flag.exchange(true, std::memory_order_acq_rel) && flag,
            "changed exchange returns previous value and publishes replacement");
        check(revision() > before, "changed exchange advances publication authority");
        conclude(true);
    }
    {
        arm();
        native::PublicationAtomic<bool> flag{true};
        const auto before = revision();
        check(flag.exchange(true, std::memory_order_acq_rel) && flag,
            "no-op exchange returns actual prior value");
        check(revision() == before, "no-op exchange leaves publication revision intact");
        conclude(false);
    }
    {
        arm();
        native::PublicationAtomic<bool> flag{false};
        const auto before = revision();
        const bool assigned = (flag = true);
        check(assigned && flag, "assignment returns assigned value and retains implicit bool use");
        check(revision() > before, "changed assignment advances publication authority");
        conclude(true);
    }
    {
        arm();
        native::PublicationAtomic<bool> flag{false};
        const auto before = revision();
        const bool assigned = (flag = false);
        check(!assigned && !flag && revision() == before,
            "no-op assignment does not revoke authority or change revision");
        conclude(false);
    }
    {
        arm();
        native::PublicationAtomic<bool> flag{false};
        const auto before = revision();
        {
            native::PublicationScope scope;
            check(scope.owns(), "token-taking update receives an owned native gate");
            check(!flag.set(scope, true, std::memory_order_release) && flag,
                "owned-token set returns previous flag and publishes new value");
            check(scope.owns() && native::publication_revision(scope) > before,
                "token-taking set keeps original gate owned through authority revocation");
        }
        check(!native::publication_held(), "token-taking update releases before fixture verification");
        conclude(true);
    }
    {
        arm();
        native::PublicationAtomic<bool> flag{true};
        const auto before = revision();
        {
            native::PublicationScope scope;
            check(flag.set(scope, true, std::memory_order_relaxed) && flag,
                "no-op token-taking update returns previous value");
            check(native::publication_revision(scope) == before,
                "no-op token-taking update does not revoke or advance revision");
        }
        conclude(false);
    }
    {
        arm();
        native::PublicationAtomic<bool> flag{false};
        const auto before = revision();
        {
            native::PublicationScope disabled(false);
            check(!disabled.owns() && !native::publication_held() && native::publication_revision(disabled) == 0,
                "disabled token carries no gate or revision authority");
            check(!flag.set(disabled, true) && !flag,
                "invalid-token set leaves underlying flag unchanged and returns prior value");
        }
        check(revision() == before, "invalid-token atomic set leaves publication authority unchanged");
        conclude(false);
    }
    {
        arm();
        int old_client{}, new_client{};
        native::PublicationAtomic<const void*, native::PublicationChange::context> client{&old_client};
        const auto before = revision();
        const void* assigned = (client = &new_client);
        check(assigned == &new_client && client.load() == &new_client,
            "pointer context assignment retains exact replacement identity");
        check(revision() > before, "changed pointer context invalidates publication authority");
        conclude(true);
    }
    {
        arm();
        int client{};
        native::PublicationAtomic<const void*, native::PublicationChange::context> context{&client};
        const auto before = revision();
        check(context.exchange(&client) == &client && context.load() == &client,
            "no-op pointer exchange preserves actual context identity");
        check(revision() == before, "unchanged pointer context does not invalidate authority");
        conclude(false);
    }
    {
        arm();
        native::PublicationAtomic<bool, native::PublicationChange::paused> paused{false};
        const auto before = revision();
        paused.store(true);
        check(paused && revision() > before, "changed pause flag publishes through actual native gate");
        conclude(true);
    }
}
}
