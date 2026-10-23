#pragma once
#include "Engine/Game/World/owned_body.h"
#include <cstdint>
#include <string>

namespace dingosdk::owned_bodies {
// Client thread only. Calling tick grants no plugin ownership and creates no hooks or bodies.
void tick(std::uintptr_t base, std::uintptr_t client, bool ready) noexcept;
std::string create(std::uint64_t owner, const owned_body::Definition&, owned_body::Handle&) noexcept;
std::string read(std::uint64_t owner, const owned_body::Handle&, owned_body::Sample&) noexcept;
std::string submit(std::uint64_t owner, const owned_body::Handle&, const owned_body::Command&) noexcept;
std::string receipt(std::uint64_t owner, const owned_body::Handle&, owned_body::Receipt&) noexcept;
std::string acknowledge(std::uint64_t owner, const owned_body::Handle&, std::uint64_t sequence) noexcept;
std::string release(std::uint64_t owner, const owned_body::Handle&) noexcept;
void release_all(std::uint64_t owner) noexcept;
} // namespace dingosdk::owned_bodies
