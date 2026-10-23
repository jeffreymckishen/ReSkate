#pragma once
#include "Engine/Game/Input/native_input_trace.h"
#include <cstdint>

namespace dingosdk::native_input_trace {
// Client-phase entry points. Loading/ticking alone does not install the hook;
// the first permitted request checks the exact image/call lanes and installs it.
bool request(std::uint64_t owner, input_trace::Handle& handle, input_trace::Reason& reason) noexcept;
bool read(std::uint64_t owner, input_trace::Handle handle, input_trace::Receipt& receipt) noexcept;
bool stop(std::uint64_t owner, input_trace::Handle handle) noexcept;
bool acknowledge(std::uint64_t owner, input_trace::Handle handle) noexcept;
void release_all(std::uint64_t owner) noexcept;
void tick(std::uintptr_t base, std::uintptr_t client, bool ready) noexcept;

// Observation issue codes describe a failed sampled relation, never a native
// gameplay failure. Asset tokens are per-trace pointer-equality labels only;
// no native reference is retained and pointer reuse can alias a prior token.
enum class Issue : std::uint8_t {
    none, service_unavailable, epoch_unavailable, local_owner_unavailable,
    local_tuple_unavailable, borrowed_unavailable, condition_invalid,
    snapshot_changed, asset_unavailable, token_capacity
};
}
