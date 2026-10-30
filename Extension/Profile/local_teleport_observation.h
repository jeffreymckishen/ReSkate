#pragma once
#include <array>
#include <cstdint>
#include "Extension/Skater/no_bail.h"
#include "Engine/Game/Skater/teleport_observation.h"

namespace dingosdk {
enum class LocalTeleportObservation : std::uint8_t;
namespace teleport_observation { struct Result; }
namespace profile_runtime {
// The existing native hook is process-lived once its fingerprinted install succeeds.
bool local_teleport_equipment_available(std::uintptr_t base) noexcept;
// One synchronous dispatch, never a persistent equipment preference. The hook
// consumes this only for the same local target, transition and fresh owner.
struct LocalTeleportEquipmentRequest : teleport_observation::EquipmentRequest {
    std::uintptr_t base{}, client{};
    NoBailSkater owner;
    bool options_applied{};
};
inline thread_local LocalTeleportEquipmentRequest* local_teleport_equipment_request{};
inline bool same_teleport_owner(const NoBailSkater& a, const NoBailSkater& b) noexcept {
    return a.base == b.base && a.entity == b.entity && a.core == b.core &&
        a.context == b.context && a.rig == b.rig;
}
// Private transient view for one fresh actor-controls qualification. Never
// expose this native manager identity in Lua or retain it as an actor key.
bool observe_local_skater_teleport(bool& pending, LocalTeleportObservation& observation,
    teleport_observation::Result& result) noexcept;
// Call only after follow reservation excludes new SDK motion writers. This
// Try-only query includes both queued position and placed-object teleports.
bool follow_teleport_duties_idle() noexcept;
}
}
