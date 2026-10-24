#pragma once
#include <cstdint>

namespace dingosdk {
enum class LocalTeleportObservation : std::uint8_t;
namespace teleport_observation { struct Result; }
namespace profile_runtime {
// Private transient view for one fresh actor-controls qualification. Never
// expose this native manager identity in Lua or retain it as an actor key.
bool observe_local_skater_teleport(bool& pending, LocalTeleportObservation& observation,
    teleport_observation::Result& result) noexcept;
// Call only after follow reservation excludes new SDK motion writers. This
// Try-only query includes both queued position and placed-object teleports.
bool follow_teleport_duties_idle() noexcept;
}
}
