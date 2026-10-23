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
}
}
