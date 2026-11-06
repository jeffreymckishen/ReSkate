#include "score_hud.h"
#include "trick_feed.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Abi/native_data.h"
#include "Engine/Game/Build/addresses.h"
#include "Engine/Game/Build/20260929/engine.h"
#include "Engine/Game/Build/20260929/hud_corner.h"
#include "Engine/Game/Build/20260929/reference_lists.h"
#include "Engine/Game/Build/20260929/score_hud.h"
#include "Extension/UI/NativeMenu/native_menu_data.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <format>
#include <map>
#include <string>
#include <utility>

namespace dingosdk::tricks {
namespace {
namespace menu_data = multiplayer::menu_data;
namespace corner = addr::hud_corner;
namespace score = addr::score_hud;
using Address = std::uintptr_t;
using Clock = std::chrono::steady_clock;

// ScoringHUDViewModel's fields read each tick (the build header's score_hud.h). A label is read by
// its Text member (LabelViewModel), found by hash at bind rather than taken to be its first 8 bytes.
struct Watched {
    const char* name;
    std::uint32_t hash;
    bool label;
};
enum : std::size_t { line_score, multiplier, action_active, sequence_header, sequence_descriptor, sequence_state, line_timer };
constexpr std::array<Watched, 7> watched{{
    {"LineScore", score::line_score, false},
    {"Multiplier", score::multiplier, false},
    {"ActionActive", score::action_active, false},
    {"SequenceHeader", score::sequence_header, true},
    {"SequenceDescriptor", score::sequence_descriptor, true},
    {"SequenceState", corner::sequence_state, false},
    {"LineTimer", score::line_timer, false},
}};
constexpr std::size_t value_bytes = 16; // read per field

struct Bound {
    bool present{};
    std::uint16_t offset{};
    unsigned size{}, kind{};
    std::array<unsigned char, value_bytes> now{};
    bool read{};
};
// Where the trick list's rows are, found at bind: the Items array's pointer from the root, the size of
// one item, and each item's data handle (Content's data Ref's handle) from the item.
struct ListLayout {
    bool ok{};
    std::uint16_t items{};
    unsigned stride{};
    std::uint16_t data_handle{};
};
// A row model's labels (their Text) and icon, found from the first row's type.
struct RowLayout {
    Address type{};
    std::uint16_t name{}, landing{}, stance{}, damage{}, icon{};
    Address refused{}; // a type found not to be the row model, not looked at again
};
struct Hud {
    Clock::time_point next_look;
    Address manager{};
    menu_data::Value model;
    std::array<Bound, watched.size()> fields{};
    ListLayout list;
    RowLayout row;
    std::vector<TrickRow> rows; // as last read, newest first
    std::map<Address, bool> icons; // a row icon's asset, and whether it is the slam icon
    bool feeding{};
    bool warned{}, rows_warned{};
};
Hud hud; // client thread

// A score field's value: the game's widget logic keeps scores as floats (kind 19, as LineTimer
// and Multiplier). A field known to be one is read as one, so a timer counting down through tiny
// values does not read as the integer of its bits; for another kind, an integer reading is taken
// if the float one is not sensible.
float score_of(const Bound& field) {
    if (!field.present || !field.read || field.size != 4) return 0;
    float f{};
    std::int32_t i{};
    std::memcpy(&f, field.now.data(), 4);
    std::memcpy(&i, field.now.data(), 4);
    if (field.kind == 19) return std::isfinite(f) ? f : 0;
    if (std::isfinite(f) && (f == 0 || (std::abs(f) > 1e-3f && std::abs(f) < 1e9f))) return f;
    return static_cast<float>(i);
}
bool flag_of(const Bound& field) { return field.present && field.read && field.now[0] != 0; }
// Text at a pointer to its characters. Printable text only, so a value that is something else reads
// as none.
std::string text_at(Address at) {
    char text[96]{};
    const auto length = memory::peek_cstring(at, text, sizeof text);
    if (length <= 0) return {};
    for (std::ptrdiff_t i = 0; i < length; ++i)
        if (static_cast<unsigned char>(text[i]) < 0x20) return {};
    return std::string(text, static_cast<std::size_t>(length));
}
std::string text_of(const Bound& field) {
    if (!field.present || !field.read || field.size < 8) return {};
    Address at{};
    std::memcpy(&at, field.now.data(), sizeof at);
    return text_at(at);
}
// The text of the label whose Text pointer sits at `at`.
std::string label_at(Address at) {
    Address text{};
    return memory::peek(at, text) ? text_at(text) : std::string{};
}
std::uint32_t enum_of(const Bound& field) {
    if (!field.present || !field.read || field.size < 4) return 0;
    std::uint32_t value{};
    std::memcpy(&value, field.now.data(), 4);
    return value;
}
std::uint32_t schema_of(Address type) { return menu_data::read<std::uint32_t>(menu_data::read<Address>(type)); }
// The offset in `owner` of the Text of its label field `hash`.
std::uint16_t label_text(const menu_data::Context& context, Address owner, std::uint32_t hash) {
    const auto label = context.member(owner, hash);
    menu_data::require(menu_data::kind(label.type) == 2 && schema_of(label.type) == score::label_schema, "a label is not a LabelViewModel");
    const auto text = context.member(label.type, score::label_text);
    menu_data::require(menu_data::kind(text.type) == 7 && menu_data::size(text.type) == 8, "a label's Text is not text");
    return static_cast<std::uint16_t>(label.offset + text.offset);
}

// Runs `use(context)` on the game's UI model registry under its model lock (as Hall of Meat's
// HUD code does). False while there is no registry.
template <class Use> bool with_ui_models(Address base, Use&& use) {
    if (!base) return false;
    const auto ui = menu_data::read<Address>(base + addr::engine::ui_manager);
    const auto manager = ui ? menu_data::read<Address>(ui + 0x140) : 0;
    if (!manager) return false;
    const menu_data::Context context(base, manager);
    game::ModelWriteLock lock(manager);
    use(context);
    return true;
}

// The trick list's layout in `model`, checked against what the native list reads; not ok (and said
// why in `layout`) when a piece is not this build's, and then only the rows go unread.
ListLayout bind_list(const menu_data::Context& context, const menu_data::Value& model, std::string& layout) {
    try {
        const auto list = context.member(model.type, score::trick_list);
        const auto items = context.member(list.type, corner::stack_items);
        menu_data::require(menu_data::kind(items.type) == 4, "its Items are not an array");
        // Its items are stack items, as the d-pad's stack holds (hud_corner.cpp reads those the same way).
        const auto item_type = context.type(menu_data::stack_item);
        const auto content = context.member(item_type, corner::item_content);
        const auto data = context.member(content.type, score::content_data);
        const auto handle = context.member(data.type, score::ref_handle);
        menu_data::require(menu_data::size(handle.type) == 8, "an item's data handle is not 8 bytes");
        const auto value = context.path(model, {score::trick_list, corner::stack_items});
        unsigned count{}, stride{};
        (void)context.array(value, 64, count, stride);
        menu_data::require(stride == menu_data::stack_item.size, "its items are not stack items");
        ListLayout result{true, static_cast<std::uint16_t>(list.offset + items.offset), stride,
                          static_cast<std::uint16_t>(content.offset + data.offset + handle.offset)};
        // Each tick peeks the list where these offsets say; the native read must find it there too.
        menu_data::require(menu_data::read<Address>(context.address(value)) == menu_data::read<Address>(context.address(model) + result.items),
                           "its Items are not where their offsets say");
        layout += std::format(" TrickList@+0x{:x}:{}b/item data@+0x{:x}", result.items, result.stride, result.data_handle);
        return result;
    } catch (const std::exception& error) {
        layout += std::format(" TrickList:unread ({})", error.what());
        return {};
    }
}

bool bind_model(Hud& h, const menu_data::Context& context) {
    if (h.manager != context.manager) { // a new registry: its types and assets too
        h.manager = context.manager;
        h.model = {};
        h.row = {};
        h.icons.clear();
    }
    if (h.model.handle && context.type_of(h.model.handle) == h.model.type) return true;
    h.model = {};
    h.rows.clear();
    const auto now = Clock::now();
    if (now < h.next_look) return false;
    h.next_look = now + std::chrono::seconds(1);
    const auto roots = context.roots({corner::score_view_schema});
    if (roots.empty()) return false;
    const auto model = roots.front().model;
    std::string layout;
    bool any = false;
    for (std::size_t n = 0; n < watched.size(); ++n) {
        auto& field = h.fields[n];
        field = {};
        try {
            if (watched[n].label) {
                field.offset = label_text(context, model.type, watched[n].hash);
                field.size = 8;
                field.kind = 7;
            } else {
                const auto member = context.member(model.type, watched[n].hash);
                field.offset = member.offset;
                field.size = menu_data::size(member.type);
                field.kind = menu_data::kind(member.type);
            }
            field.present = any = true;
            layout += std::format(" {}@+0x{:x}:{}b/k{}", watched[n].name, field.offset, field.size, field.kind);
        } catch (const std::exception&) {
            layout += std::format(" {}:missing", watched[n].name);
        }
    }
    if (!any) return false;
    h.model = model;
    h.list = bind_list(context, model, layout);
    h.rows_warned = false;
    logging::write(logging::Level::info, logging::Channel::skater, "Score HUD model found:" + layout);
    return true;
}

// A row model's layout, from the type of a row in the list: the row type the game makes for its
// TrickHistoryStackItem rows, each label's Text and the icon.
bool bind_row(Hud& h, const menu_data::Context& context, Address type) {
    if (h.row.type == type) return true;
    if (h.row.refused == type) return false;
    RowLayout row{type};
    try {
        menu_data::require(menu_data::kind(type) == 2 && schema_of(type) == score::trick_row_schema && menu_data::size(type) == score::trick_row_size,
                           "not the row model");
        row.name = label_text(context, type, score::row_name);
        row.landing = label_text(context, type, score::row_landing);
        row.stance = label_text(context, type, score::row_stance);
        row.damage = label_text(context, type, score::row_damage);
        const auto icon = context.member(type, score::row_icon);
        menu_data::require(menu_data::size(icon.type) == 8, "a row's icon is not an asset");
        row.icon = icon.offset;
    } catch (const std::exception&) {
        h.row.refused = type;
        return false;
    }
    h.row = row;
    logging::log(logging::Level::info, logging::Channel::skater, "Score HUD trick rows: name@+0x{:x} landing@+0x{:x} stance@+0x{:x} damage@+0x{:x} icon@+0x{:x}",
                 row.name, row.landing, row.stance, row.damage, row.icon);
    return true;
}

// Whether a row's icon is the game's slam icon, by its asset's name (once per asset).
bool is_slam_icon(Hud& h, Address asset) {
    if (!asset) return false;
    if (const auto known = h.icons.find(asset); known != h.icons.end()) return known->second;
    if (h.icons.size() >= 16) h.icons.clear(); // (assets of an earlier level)
    Address name{};
    const bool slam = memory::peek(asset + addr::reference_lists::asset_name, name) && text_at(name) == score::slam_icon;
    h.icons.emplace(asset, slam);
    return slam;
}
// A row's name, or all its labels and icon, read from its model (of the bound row type).
void read_row(Hud& h, const menu_data::Context& context, TrickRow& row, bool all) {
    const auto at = context.address({row.handle, h.row.type});
    row.name = label_at(at + h.row.name);
    if (!all) return;
    row.landing = label_at(at + h.row.landing);
    row.stance = label_at(at + h.row.stance);
    row.damage = label_at(at + h.row.damage);
    Address icon{};
    row.slam = !row.damage.empty() || (memory::peek(at + h.row.icon, icon) && is_slam_icon(h, icon));
}
// The trick list's rows, newest first, into `rows`, and the entries of rows new since the last read
// into `fresh`. False when the list cannot be read this tick. Costs a peek for the list and one per
// row; a row's model is looked up when it is new, while its name is still empty, and for the newest
// row (whose landing and damage come later) each tick.
bool read_rows(Hud& h, const menu_data::Context& context, Address root, std::vector<TrickRow>& rows, std::vector<std::uint64_t>& fresh) {
    if (!h.list.ok) return false;
    Address items{};
    if (!memory::peek(root + h.list.items, items)) return false;
    std::uint32_t count{};
    // The dword before an array is its count; its top bit is a flag (as Context::array reads it).
    if (items && !memory::peek(items - 4, count)) return false;
    count = items ? count & 0x7fffffffu : 0;
    if (count > score::most_trick_rows) {
        if (!std::exchange(h.rows_warned, true))
            logging::log(logging::Level::warning, logging::Channel::skater,
                "Score HUD: its trick list holds {} rows, more than the {} it keeps on this build, so its rows are not read while it does.", count,
                score::most_trick_rows);
        return false;
    }
    for (std::uint32_t i = 0; i < count; ++i) {
        std::uint64_t handle{};
        if (!memory::peek(items + std::size_t{i} * h.list.stride + h.list.data_handle, handle) || !handle) return false;
        const auto was = std::find_if(h.rows.begin(), h.rows.end(), [&](const TrickRow& row) { return row.handle == handle; });
        TrickRow row = was != h.rows.end() ? *was : TrickRow{handle};
        const bool fresh_row = was == h.rows.end();
        if (fresh_row) {
            const auto type = context.type_of(handle);
            if (!type || !bind_row(h, context, type)) {
                if (!std::exchange(h.rows_warned, true))
                    logging::log(logging::Level::warning, logging::Channel::skater,
                        "Score HUD: a trick list row is not the row model this build makes, so its rows are not read.");
                return false;
            }
        }
        if (fresh_row || i == 0 || row.name.empty()) read_row(h, context, row, fresh_row || i == 0);
        if (fresh_row) fresh.push_back(handle >> 16);
        rows.push_back(std::move(row));
    }
    return true;
}
}

std::optional<ScoreHud> read_score_hud(std::uintptr_t image_base) noexcept {
    auto& h = hud;
    bool ok = false;
    ScoreHud result;
    std::vector<std::uint64_t> fresh;
    try {
        with_ui_models(image_base, [&](const menu_data::Context& context) {
            if (!bind_model(h, context)) return;
            const auto at = context.address(h.model);
            for (auto& field : h.fields)
                field.read = field.present && memory::peek_bytes(at + field.offset, field.now.data(), std::min<unsigned>(field.size, value_bytes));
            ok = true;
            // The rows go unread on their own: the values above still make the tricks.
            try {
                result.rows_read = read_rows(h, context, at, result.rows, fresh);
            } catch (const std::exception& error) {
                result.rows_read = false;
                if (!std::exchange(h.rows_warned, true))
                    logging::log(logging::Level::warning, logging::Channel::skater, "Score HUD: its trick list cannot be read: {}", error.what());
            }
            if (result.rows_read) h.rows = result.rows;
            else {
                result.rows.clear();
                fresh.clear();
            }
        });
        h.warned = false;
    } catch (const std::exception& error) {
        h.model = {};
        if (!std::exchange(h.warned, true))
            logging::log(logging::Level::warning, logging::Channel::skater, "The score HUD cannot be read: {}", error.what());
    } catch (...) {
        h.model = {};
    }
    if (!ok) return std::nullopt;
    // The trick feed lets a name out only from a row the game's own list was seen to hold (outside the
    // model lock: the feed takes its own). Rows already there when it is turned on are told then.
    const bool feeding = feed::wanted();
    if (feeding && !h.feeding) {
        fresh.clear();
        for (const auto& row : h.rows) fresh.push_back(row.handle >> 16);
    }
    h.feeding = feeding;
    if (feeding && !fresh.empty()) feed::know(fresh);
    const auto& f = h.fields;
    result.action = flag_of(f[action_active]);
    result.line_score = score_of(f[line_score]);
    result.multiplier = score_of(f[multiplier]);
    result.header = text_of(f[sequence_header]);
    result.descriptor = text_of(f[sequence_descriptor]);
    result.sequence_state = enum_of(f[sequence_state]);
    result.line_timer = score_of(f[line_timer]);
    return result;
}

bool names_manual(const ScoreHud& now) {
    const auto says = [](std::string text) {
        for (auto& c : text) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c + 32 : c);
        return text.find("manual") != std::string::npos;
    };
    return now.action && (says(now.header) || says(now.descriptor));
}
}
