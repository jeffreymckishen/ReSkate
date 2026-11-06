#include "trick_feed.h"
#include "trick_feed_gate.h"
#include "Extension/UI/own_ui_writes.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Build/addresses.h"
#include "Engine/Game/Build/20260929/engine.h"
#include <Windows.h>
#include <array>
#include <atomic>
#include <format>
#include <mutex>
#include <set>
#include <string_view>

// SmokeyDawg58's reading of the trick list's writes, with the asking moved here.
namespace dingosdk::tricks::feed {
namespace {
constexpr std::uint32_t trick_name_member = 0x0002, trick_side_member = 0x009c, trick_landing_member = 0x0034;
constexpr std::uint32_t trick_body_spin_member = 0x00bc, trick_board_spin_member = 0x00ac, trick_stance_member = 0x004e;
constexpr std::uint32_t trick_late_member = 0x007c, trick_darkflip_member = 0x010d, trick_darkcatch_member = 0x00fd;
struct Feed {
    std::atomic<bool> on{};
    std::mutex mutex;
    std::vector<Note> notes;
    std::set<std::string> owners;
    EntryGate<Note> gate; // which models' writes are the trick list's rows' (trick_feed_gate.h)
    LeftOutLog left_out_log;
};
Feed& feed() {
    static auto* value = new Feed;
    return *value;
}
// The SDK's own models (own): read by tap on the game's threads, so atomics rather than a lock.
std::array<std::atomic<std::uint64_t>, most_owned> owned_entries{};
bool owned(std::uint64_t entry) noexcept {
    for (const auto& slot : owned_entries)
        if (entry && slot.load(std::memory_order_acquire) == entry) return true;
    return false;
}
// Readable text at `address`: ASCII, or UTF-16 with every other byte zero; empty when not.
std::string text_at(std::uintptr_t address) noexcept {
    std::array<unsigned char, 96> raw{};
    if (!memory::read_bytes(address, raw.data(), raw.size())) return {};
    const auto printable = [](unsigned char c) { return c >= 0x20 && c < 0x7f; };
    std::string text;
    for (std::size_t i = 0; i < raw.size() && raw[i]; ++i) {
        if (!printable(raw[i])) return {};
        text += static_cast<char>(raw[i]);
    }
    if (text.size() >= 3) return text;
    text.clear();
    for (std::size_t i = 0; i + 1 < raw.size() && (raw[i] || raw[i + 1]); i += 2) {
        if (raw[i + 1] || !printable(raw[i])) return {};
        text += static_cast<char>(raw[i]);
    }
    return text.size() >= 3 ? text : std::string{};
}
// A trick list text that reads as a name: letters with digits, spaces and a little punctuation. A
// pointer read as text ("P#a=") does not.
bool readable_name(std::string_view text) noexcept {
    bool letter = false;
    for (const char c : text) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) letter = true;
        else if (!(c >= '0' && c <= '9') && c != ' ' && c != '-' && c != '\'' && c != '.' && c != '&' && c != '/' && c != '!' && c != '_')
            return false;
    }
    return letter;
}
// Queues what the gate let out, and says what it left out: each model and text once.
void pass_on(Feed& f, std::vector<Note>& out, std::vector<Note>& said) {
    for (auto& note : out)
        if (f.notes.size() < 256) f.notes.push_back(std::move(note));
    for (auto& note : f.gate.take_left_out())
        if (f.left_out_log.say(note.entry, note.text)) said.push_back(std::move(note));
}
void say_left_out(const std::vector<Note>& said) {
    for (const auto& note : said)
        logging::log(logging::Level::info, logging::Channel::plugins,
            "Trick feed: left out \"{}\" from model entry 0x{:x}: the score HUD's trick list was not seen to hold that model.", note.text,
            note.entry);
}
} // namespace

void ask(const std::string& owner, bool on) {
    auto& f = feed();
    std::lock_guard lock(f.mutex);
    if (on) f.owners.insert(owner);
    else f.owners.erase(owner);
    f.on.store(!f.owners.empty(), std::memory_order_release);
    if (f.owners.empty()) {
        f.notes.clear();
        f.gate.clear();
        f.left_out_log.clear();
    }
}
bool wanted() noexcept { return feed().on.load(std::memory_order_acquire); }
std::vector<Note> take() {
    auto& f = feed();
    std::lock_guard lock(f.mutex);
    return std::exchange(f.notes, {});
}

void tap(std::uintptr_t, std::uint64_t handle, std::uintptr_t type, const void* value, std::uint8_t flag) noexcept {
    auto& f = feed();
    if (!f.on.load(std::memory_order_acquire) || ui::writing_own_ui) return;
    const auto member = static_cast<std::uint32_t>(handle & 0xffff);
    if (member != trick_name_member && member != trick_side_member && member != trick_landing_member && member != trick_body_spin_member &&
        member != trick_board_spin_member && member != trick_stance_member && member != trick_late_member && member != trick_darkflip_member &&
        member != trick_darkcatch_member)
        return;
    if (owned(handle >> 16)) return; // a model of the SDK's own, such as a plugin's score line row
    static const auto string_type = reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr)) + addr::engine::string_type; // the UI model's string type
    if (member == trick_name_member && type != string_type) return;
    try {
        std::uint64_t first{};
        if (!memory::peek_bytes(reinterpret_cast<std::uintptr_t>(value), &first, sizeof first)) return;
        auto text = text_at(static_cast<std::uintptr_t>(first));
        // A name skate. gives as a short code rather than text (one grind wrote 0x42532030): the code
        // itself, the same on every player's game, so it can still be set and copied. A pointer whose
        // text could not be read is not one: it differs from game to game. Some names sit one pointer
        // further in (dark flips): a value that does not read as a name is followed once more.
        if (member == trick_name_member && !text.empty() && !readable_name(text)) {
            std::uint64_t inner{};
            text = memory::read(static_cast<std::uintptr_t>(first), inner) ? text_at(static_cast<std::uintptr_t>(inner)) : std::string();
            if (!readable_name(text)) return;
        }
        if (text.empty() && member == trick_name_member && first && first < 0x100000000ull) text = std::format("Trick #{:x}", first);
        if (text.empty()) return;
        char kind = 'n';
        if (member == trick_side_member) {
            if (!text.starts_with("ID_TRICK_")) return;
            kind = 's';
        } else if (member == trick_landing_member) {
            if (!text.starts_with("ID_TRICK_LANDING")) return;
            kind = 'l';
        } else if (member == trick_body_spin_member) {
            if (text.find_first_not_of("0123456789") != std::string::npos) return;
            kind = 'b';
        } else if (member == trick_board_spin_member) {
            // The board's spin ("360") or how many times it flipped ("Double", "Triple").
            if (text.starts_with("ID_") || text.size() > 16) return;
            kind = 'r';
        } else if (member == trick_stance_member) {
            if (!text.starts_with("ID_STANCE_")) return;
            kind = 'k';
        } else if (member == trick_late_member || member == trick_darkflip_member || member == trick_darkcatch_member) {
            if (member == trick_late_member ? text != "Late" : !text.starts_with("ID_TRICK_DARK")) return;
            text = member == trick_late_member ? "Late" : member == trick_darkflip_member ? "Darkflip" : "Dark Catch";
            kind = 'm';
        }
        // Whose write it is: a side, landing, stance or modifier (each checked against the game's own
        // ids above) goes out as it is; a name or a spin only from a row model the score HUD reader
        // saw in the game's trick list. The entry is the model's own handle (the write's handle less
        // its field's 16 bits). Every row write seen came with registry flag 0, the registry the
        // reader reads; a write to the other is never a known row's (key 0).
        const auto entry = handle >> 16;
        const bool sure = kind == 's' || kind == 'l' || kind == 'k' || kind == 'm';
        std::vector<Note> out, said;
        {
            std::lock_guard lock(f.mutex);
            f.gate.add({entry, kind, std::move(text)}, flag == 0 ? entry : 0, sure, GetTickCount64(), out);
            pass_on(f, out, said);
        }
        say_left_out(said);
    } catch (...) {}
}

void own(const std::vector<std::uint64_t>& entries) noexcept {
    for (std::size_t slot = 0; slot < owned_entries.size(); ++slot)
        owned_entries[slot].store(slot < entries.size() ? entries[slot] : 0, std::memory_order_release);
}

void know(const std::vector<std::uint64_t>& entries) noexcept {
    auto& f = feed();
    if (entries.empty() || !f.on.load(std::memory_order_acquire)) return;
    try {
        std::vector<Note> out, said;
        {
            std::lock_guard lock(f.mutex);
            const auto now = GetTickCount64();
            for (const auto entry : entries)
                if (entry) f.gate.know(entry, now, out);
            pass_on(f, out, said);
        }
        say_left_out(said);
    } catch (...) {}
}
} // namespace dingosdk::tricks::feed
