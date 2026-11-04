// Build the BMX bike's private native model pack from ReSkate Studio's FPV Drone template, and
// check that a built pack has names of its own (--check-own-names).
// Only the chosen output folder is written. The source game and template stay intact.
//
// The pack keeps nothing of the drone's. The template's own assets (its 15 textures, its mesh,
// blueprint, shader depot and variation database) are taken out of the manifest, and its archive
// is not copied: the pack's archive holds only what the new manifest names. What the bike borrows
// from the drone is the layout of those assets, written again under the identities in own:: (one
// table of every new name, GUID, resource id and key). What stays of the template is its copy of
// the game's root bundle, and its two shader tables, which are rebuilt from the game's own with
// the bike material's rows added.
//
// --keep-template-names=<database,block-hashes,section-names,partition-guid> keeps the template's
// value for any of those four, for a game trial that has to find which of them the game minds.
#include "Engine/Vfs/game_archives.h"
#include "Engine/Vfs/game_bundles.h"
#include "Engine/Resource/cas_codec.h"
#include "Engine/Resource/ebx_document.h"
#include "Engine/Resource/ebx_writer.h"
#include "Engine/Resource/mesh_set.h"
#include "Engine/Resource/shader_lookup.h"
#include "Engine/Resource/toc.h"
#include "Engine/Resource/texture.h"
#include <Windows.h>
#include <bcrypt.h>
#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <unordered_map>

namespace fb = dingosdk::frostbite;
namespace ebx = fb::ebx;
namespace vfs = dingosdk::vfs;
namespace db = dingosdk::native_db;
namespace fs = std::filesystem;
using Bytes = std::vector<std::byte>;
void require(bool condition, const char* reason) { if (!condition) throw std::runtime_error(reason); }
void require(bool condition, const std::string& reason) { if (!condition) throw std::runtime_error(reason); }
Bytes read(const fs::path& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    const auto size = file.tellg();
    require(size >= 0 && size < 64*1024*1024, "Input is missing or exceeds builder bound");
    Bytes bytes(static_cast<std::size_t>(size)); file.seekg(0);
    require(static_cast<bool>(file.read(reinterpret_cast<char*>(bytes.data()), size)), "Cannot read input");
    return bytes;
}
void write(const fs::path& path, std::span<const std::byte> bytes) {
    fs::create_directories(path.parent_path()); std::ofstream file(path, std::ios::binary);
    file.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    require(static_cast<bool>(file), "Cannot write pack artifact");
}
fb::Sha1 sha(std::span<const std::byte> bytes) {
    fb::Sha1 value;
    require(bytes.size() <= std::numeric_limits<ULONG>::max(), "Hash bound");
    const auto status = BCryptHash(BCRYPT_SHA1_ALG_HANDLE, nullptr, 0,
        reinterpret_cast<PUCHAR>(const_cast<std::byte*>(bytes.data())), static_cast<ULONG>(bytes.size()),
        reinterpret_cast<PUCHAR>(value.bytes.data()), static_cast<ULONG>(value.bytes.size()));
    require(status >= 0, "Native SHA1 failed"); return value;
}
fb::Sha1 sha(std::string_view text) { return sha({reinterpret_cast<const std::byte*>(text.data()), text.size()}); }
fb::Guid guid(std::string_view key) {
    const auto hashed = sha("ReSkateBMXNative20261017/" + std::string(key));
    fb::Guid value; std::copy_n(hashed.bytes.begin(), 16, value.bytes.begin()); return value;
}
std::uint64_t id(std::string_view key) {
    const auto hashed = sha("ReSkateBMXNative20261017/" + std::string(key));
    std::uint64_t value{}; std::memcpy(&value, hashed.bytes.data(), sizeof(value)); return value;
}
// The hash the game names an asset by: djb2-xor of its lower-case name, as the merge computes it
// (Engine/Vfs/mod_merge_textures.cpp) to find a texture's chunk record.
std::uint64_t owner_hash(std::string_view name) {
    std::uint64_t value = 5381;
    for (const unsigned char c : name) value = value*33 ^ static_cast<unsigned char>(std::tolower(c));
    return value;
}
// Its low 32 bits: a mesh's NameHash, a LOD's and a mesh section's name hash.
std::uint32_t name_hash32(std::string_view name) { return static_cast<std::uint32_t>(owner_hash(name)); }
bool lower_case(std::string_view name) {
    return std::none_of(name.begin(), name.end(), [](unsigned char c) { return std::isupper(c) != 0; });
}
std::string hex(std::uint64_t value) {
    constexpr char digits[] = "0123456789abcdef"; std::string text = "0x";
    for (int shift = 60; shift >= 0; shift -= 4) text.push_back(digits[(value >> shift) & 15]);
    return text;
}
// The streamer reads a chunk as compressed blocks only when bit 0 of its GUID's last byte is set
// (mod_merge_textures.cpp); every texture chunk ReSkate Studio writes has it.
bool compressed_chunk(const fb::Guid& chunk) { return (std::to_integer<unsigned>(chunk.bytes[15]) & 1u) != 0; }
fb::Guid compressed(fb::Guid chunk) { chunk.bytes[15] |= std::byte{1}; return chunk; }
ebx::Value clone(const ebx::Value& from) {
    ebx::Value result = from;
    if (const auto* object = std::get_if<std::shared_ptr<ebx::Object>>(&from.data); object && *object) {
        auto next = std::make_shared<ebx::Object>(**object);
        for (auto& field : next->fields) field.value = clone(field.value);
        result.data = std::move(next);
    } else if (const auto* array = std::get_if<ebx::Value::Array>(&from.data)) {
        ebx::Value::Array next; for (const auto& item : *array) next.push_back(clone(item)); result.data = std::move(next);
    }
    return result;
}
ebx::FieldValue& field(ebx::Object& object, std::string_view name) {
    const auto found = std::find_if(object.fields.begin(), object.fields.end(), [&](const auto& item) { return item.name == name; });
    require(found != object.fields.end(), "Template field is missing"); return *found;
}
const ebx::FieldValue& field(const ebx::Object& object, std::string_view name) {
    const auto* found = object.find(name); require(found != nullptr, "Template field is missing"); return *found;
}
std::string type_name(const ebx::Document& document, const ebx::InstanceRecord& instance) {
    return instance.descriptor >= 0 && static_cast<std::size_t>(instance.descriptor) < document.types.size()
        ? document.types[static_cast<std::size_t>(instance.descriptor)].name : std::string{};
}
void remap_external(ebx::Value& value, std::int32_t offset) {
    if (auto* pointer = std::get_if<ebx::PointerReference>(&value.data); pointer && pointer->kind == ebx::PointerKind::external)
        pointer->index += offset;
    else if (auto* object = std::get_if<std::shared_ptr<ebx::Object>>(&value.data); object && *object)
        for (auto& item : (*object)->fields) remap_external(item.value, offset);
    else if (auto* array = std::get_if<ebx::Value::Array>(&value.data))
        for (auto& item : *array) remap_external(item, offset);
}
void bounds(ebx::Value& value, const std::array<float, 6>& box) {
    auto& array = std::get<ebx::Value::Array>(value.data); require(array.size() == 1, "Unexpected part bounds");
    auto& object = *std::get<std::shared_ptr<ebx::Object>>(array[0].data);
    for (unsigned end = 0; end < 2; ++end) {
        auto& point = *std::get<std::shared_ptr<ebx::Object>>(field(object, end ? "max" : "min").value.data);
        unsigned axis{}; for (const auto* name : {"x", "y", "z"}) field(point, name).value.data = double(box[end*3+axis++]);
    }
}
template<class T> void put(Bytes& bytes, std::size_t at, T value) {
    static_assert(std::is_integral_v<T>);
    require(at <= bytes.size() && sizeof(T) <= bytes.size()-at, "Header write bound");
    std::memcpy(bytes.data()+at, &value, sizeof(value));
}
template<class T> T get(std::span<const std::byte> bytes, std::size_t at) {
    static_assert(std::is_integral_v<T>);
    require(at <= bytes.size() && sizeof(T) <= bytes.size()-at, "Payload read bound");
    T value{}; std::memcpy(&value, bytes.data()+at, sizeof(value)); return value;
}
fb::Guid get_guid(std::span<const std::byte> bytes, std::size_t at) {
    require(at <= bytes.size() && 16 <= bytes.size()-at, "GUID read bound");
    fb::Guid value; std::memcpy(value.bytes.data(), bytes.data()+at, 16); return value;
}
void put_guid(Bytes& bytes, std::size_t at, const fb::Guid& value) {
    require(at <= bytes.size() && 16 <= bytes.size()-at, "GUID write bound");
    std::memcpy(bytes.data()+at, value.bytes.data(), 16);
}
// A NUL-terminated string in a resource, and its length.
std::string string_at(std::span<const std::byte> bytes, std::size_t at) {
    require(at < bytes.size(), "String is outside its resource");
    const auto end = std::find(bytes.begin()+static_cast<std::ptrdiff_t>(at), bytes.end(), std::byte{});
    require(end != bytes.end(), "String has no terminator");
    return {reinterpret_cast<const char*>(bytes.data()+at), static_cast<std::size_t>(end-(bytes.begin()+static_cast<std::ptrdiff_t>(at)))};
}
// Replaces the string at `at` in place: the new one must fit where the old one was.
void rewrite_string(Bytes& bytes, std::size_t at, std::string_view text, const char* reason) {
    const auto old = string_at(bytes, at);
    require(text.size() <= old.size(), reason);
    std::fill_n(bytes.begin()+static_cast<std::ptrdiff_t>(at), old.size(), std::byte{});
    std::memcpy(bytes.data()+at, text.data(), text.size());
}
void erase_string(Bytes& bytes, std::size_t at) {
    const auto old = string_at(bytes, at);
    std::fill_n(bytes.begin()+static_cast<std::ptrdiff_t>(at), old.size(), std::byte{});
}
std::vector<std::size_t> find_all(std::span<const std::byte> haystack, std::span<const std::byte> needle) {
    std::vector<std::size_t> found;
    if (needle.empty() || needle.size() > haystack.size()) return found;
    for (auto at = haystack.begin();;) {
        at = std::search(at, haystack.end(), needle.begin(), needle.end());
        if (at == haystack.end()) return found;
        found.push_back(static_cast<std::size_t>(at-haystack.begin())); ++at;
    }
}
std::span<const std::byte> as_bytes(const fb::Guid& value) { return value.bytes; }
std::span<const std::byte> as_bytes(std::string_view text) { return {reinterpret_cast<const std::byte*>(text.data()), text.size()}; }

struct TextureInput {
    std::uint32_t width{},height{},format{},count{};
    std::array<std::uint32_t,15> sizes{};
    Bytes pixels;
};
TextureInput texture_input(const fs::path& root, std::string_view name) {
    const auto info=read(root/(std::string(name)+".info"));
    require(info.size()==80, "Native texture input descriptor length");
    fb::BinaryReader in(info);
    require(in.fixed_string(4)=="BMXT", "Native texture input descriptor magic");
    TextureInput t;t.width=in.u32();t.height=in.u32();t.format=in.u32();t.count=in.u32();
    require(t.width>0 && t.width<=4096 && t.height>0 && t.height<=4096 &&
        t.count>0 && t.count<=15 && (t.format==55 || t.format==63), "Texture dimensions or format outside private contract");
    auto width=t.width,height=t.height;std::uint64_t total{};
    for(unsigned mip=0;mip<15;++mip) {
        t.sizes[mip]=in.u32();
        const auto expected=mip<t.count?std::max(1u,(width+3)/4)*std::max(1u,(height+3)/4)*(t.format==55?8u:16u):0u;
        require(t.sizes[mip]==expected, "Texture mip byte count mismatch");total+=t.sizes[mip];
        width=std::max(1u,width/2);height=std::max(1u,height/2);
    }
    t.pixels=read(root/(std::string(name)+".pixels"));require(total==t.pixels.size(), "Texture pixel payload mismatch");
    return t;
}
void texture_dimensions(ebx::Document& document, const TextureInput& input) {
    require(document.rootType=="TextureAsset" && document.instances.size()==1, "Unexpected donor texture document");
    auto& object=*document.instances[0].object;
    // These fields are signed s16/u16 in the donor. Preserve the parsed variant
    // representation so EBX serialization does not silently change field type.
    const auto assign=[](ebx::Value& value,std::uint32_t number) {
        if(std::holds_alternative<std::uint64_t>(value.data))value.data=std::uint64_t(number);
        else {require(std::holds_alternative<std::int64_t>(value.data), "Unexpected texture dimension scalar");value.data=std::int64_t(number);}
    };
    assign(field(object,"AuthoredWidth").value,input.width);assign(field(object,"AuthoredHeight").value,input.height);
    auto& crop=*std::get<std::shared_ptr<ebx::Object>>(field(object,"CropInfo").value.data);
    assign(field(crop,"X").value,0);assign(field(crop,"Y").value,0);
    assign(field(crop,"Z").value,input.width);assign(field(crop,"W").value,input.height);
}

constexpr auto toc_path = "Win32/levels/game/dingolevel_root/dingolevel_root.toc";
// The template's own assets, by the names ReSkate Studio gave them.
constexpr std::string_view drone_mesh_name = "reskate/drone/fpv_drone_mesh";
constexpr std::string_view drone_blueprint_name = "reskate/drone/fpv_drone";
constexpr std::string_view drone_texture_prefix = "reskate/drone/fpv_drone/textures/";
constexpr std::string_view drone_depot_prefix = "reskate/drone/fpv_drone_win32_shaderstate/shaderblockdepot_";
// Studio's pack names its variation database as a stock root database would be named; the stock
// root has none.
constexpr std::string_view slot_database_name = "levels/game/dingolevel_root/dingolevel_root/meshvariationdb_win32";
constexpr std::string_view program_table_name = "levels/game/dingolevel_root/dingolevel_root_win32_shaderstate_db";
constexpr std::string_view texture_table_name = "levels/game/dingolevel_root/dingolevel_root_win32_shaderstate_streamabletexturesetlookuptable";
constexpr std::uint32_t depot_type = 0x73312045;
constexpr std::uint32_t mesh_set_type = 0x49b156d4;
// The texture parameter the depot's blocks bind a TextureAsset with: its type, then 5 bytes, then
// the texture's instance GUID and its file GUID (found on the template's 15 bindings).
constexpr std::array<std::byte, 4> texture_parameter{std::byte{0x30}, std::byte{0xfc}, std::byte{0xc5}, std::byte{0x14}};
constexpr std::size_t binding_instance = 9, binding_file = 25;
// The city's LOD group the template mesh imports, which the pack carries beside its meshes.
constexpr auto lod_name = "common/utilities/lodgroups/worldobject/medium/worldobject_mediumvista_2lod";
constexpr std::array<unsigned char, 20> lod_sha1{0x16,0x6f,0x68,0xb7,0x13,0xc7,0x92,0x60,0xa4,0x7f,
    0x6a,0x3a,0x9e,0x62,0xc1,0x08,0x74,0x2a,0x46,0xfc};
// The frame mask the bike is drawn with: the one texel (one BC1 block) of the template's
// frame_2_mask, the same value as all five of the drone's masks. The pack writes it from here.
constexpr std::array<std::byte, 8> frame_mask_texel{std::byte{0xa0}, std::byte{0x03}, std::byte{0x9f}, std::byte{0x03},
    std::byte{0x55}, std::byte{0x55}, std::byte{0x55}, std::byte{0x55}};
// The material sections the drone's material keys (and the depot's blocks) belong to; the sixth
// section of each mesh is the stock TerrainMesh preset, keyed by its stock key.
constexpr unsigned material_sections = 5;
// The supplied bike's parts: frame, fork, two wheels, cranks, handlebars and two pedals.
constexpr std::size_t bike_parts = 8;

// Every name, GUID, resource id and key the pack gives its own assets. Each one is the SHA1 of a
// fixed key (guid(), id()), so two builds give the same bytes.
namespace own {
constexpr std::array<std::string_view, 3> texture_slots{"basecolor", "normal", "mask"};
struct Texture { std::string slot, name; fb::Guid file, instance, chunk; std::uint64_t rid{}; };
Texture texture(std::string_view slot) {
    const std::string key = "texture/" + std::string(slot);
    Texture result{std::string(slot), "reskate/bmx/textures/bike_" + std::string(slot), guid(key+"/ebx"), guid(key+"/asset"),
        compressed(guid(key+"/chunk")), id(key+"/resource") | std::uint64_t{1}};
    require(lower_case(result.name), "Own texture name is not lower case");
    return result;
}
std::uint64_t section_key(unsigned section) { return id("material/section" + std::to_string(section)); }
std::uint64_t block_hash(unsigned section) { return id("material/section" + std::to_string(section) + "/block"); }
// Mixed case like the Studio material names they replace; only their hashes are lower case.
std::string section_name(unsigned section) { return "ReSkate_BMX_Bike_M_rs" + std::to_string(section); }
std::string depot_name() {
    const auto name = "reskate/bmx/bike_win32_shaderstate/shaderblockdepot_" +
        std::to_string(id("material/depot/name") & 0x7FFF'FFFF'FFFF'FFFFull);
    require(lower_case(name), "Own depot name is not lower case"); return name;
}
std::uint64_t depot_rid() { return id("material/depot") | std::uint64_t{1}; }
constexpr std::string_view database_name = "reskate/bmx/meshvariationdb_win32";
fb::Guid database_file() { return guid("meshvariationdb"); }
// The database's exported instances, by their place in it: its root, RadiosityMaterials and
// MeshMaterialVariations.
fb::Guid database_instance(std::size_t index) { return guid("meshvariationdb/instance" + std::to_string(index)); }
struct Part {
    std::string part, name, mesh_name, lod_name;
    fb::Guid mesh_file, mesh_root, blueprint_file, blueprint_root, blueprint_model, chunk;
    std::array<fb::Guid, 5> materials{};
    std::uint64_t rid{};
};
Part part(std::string_view part_name) {
    const std::string key(part_name);
    Part result;
    result.part = key; result.name = "reskate/bmx/" + key; result.mesh_name = result.name + "_mesh";
    result.lod_name = result.mesh_name + "_lod0";
    result.mesh_file = guid(key+"/mesh"); result.mesh_root = guid(key+"/mesh_root");
    result.blueprint_file = guid(key+"/blueprint"); result.blueprint_root = guid(key+"/blueprint_root");
    result.blueprint_model = guid(key+"/blueprint_model"); result.chunk = guid(key+"/chunk");
    for (unsigned i = 0; i < 5; ++i) result.materials[i] = guid(key+"/material"+std::to_string(i+1));
    // Native ResourceRef stores an immediate resource ID with bit0 set. Even values can be
    // interpreted as live/refcounted pointers while the loader replaces the reference.
    result.rid = id(key+"/resource") | std::uint64_t{1};
    require(lower_case(result.name) && lower_case(result.lod_name), "Own part name is not lower case");
    return result;
}
}

struct KeepNames { bool database{}, block_hashes{}, section_names{}, partition_guid{}; };
KeepNames keep_names(std::string_view list) {
    KeepNames keep;
    while (!list.empty()) {
        const auto comma = list.find(',');
        const auto item = list.substr(0, comma);
        if (item == "database") keep.database = true;
        else if (item == "block-hashes") keep.block_hashes = true;
        else if (item == "section-names") keep.section_names = true;
        else if (item == "partition-guid") keep.partition_guid = true;
        else require(item == "none" || item.empty(), "--keep-template-names takes database, block-hashes, section-names, partition-guid");
        list = comma == std::string_view::npos ? std::string_view{} : list.substr(comma+1);
    }
    return keep;
}

// A pack folder (the template, or a built pack): its layout, its one superbundle TOC and bundle.
struct Pack {
    fs::path root, game;
    vfs::Layout layout;
    std::optional<vfs::GameArchives> archives;
    fb::TocDocument toc;
    fb::BundleRegion region;
    fb::BinaryBundle bundle;
    Pack(const fs::path& at, const fs::path& game_root) : root(at), game(game_root) {
        layout = vfs::read_layout(root / "layout.toc"); archives.emplace(root, layout.root);
        toc = fb::read_toc(read(root / toc_path)); require(toc.bundles.size() == 1, "Expected one pack bundle");
        region = fb::read_bundle_region(toc.bundles[0].region); require(!region.files.empty(), "Pack manifest missing");
        const auto& first = region.files[0];
        bundle = archives->read_manifest(root, first.location, first.offset, first.size, game);
        require(region.files.size() == 1+bundle.ebx.size()+bundle.resources.size()+bundle.chunks.size(), "Pack asset ordering");
    }
    Pack(const Pack&) = delete;
    Pack& operator=(const Pack&) = delete;
    [[nodiscard]] std::size_t first(fb::AssetKind kind) const {
        return 1 + (kind == fb::AssetKind::ebx ? 0 : kind == fb::AssetKind::resource ? bundle.ebx.size()
            : bundle.ebx.size() + bundle.resources.size());
    }
    [[nodiscard]] const fb::BundleFileInfo& file(fb::AssetKind kind, std::size_t index) const { return region.files.at(first(kind)+index); }
    [[nodiscard]] Bytes stored(const fb::BundleFileInfo& file) const { return archives->read(root, file.location, file.offset, file.size); }
    [[nodiscard]] Bytes payload(fb::AssetKind kind, std::size_t index) const {
        const auto& at = file(kind, index); require(at.location.patch, "Expected a payload the pack stores itself");
        return fb::decode_cas(stored(at), {game});
    }
    [[nodiscard]] std::optional<std::size_t> find(fb::AssetKind kind, std::string_view name) const {
        const auto& list = kind == fb::AssetKind::ebx ? bundle.ebx : bundle.resources;
        const auto at = std::find_if(list.begin(), list.end(), [&](const auto& item) { return item.name == name; });
        if (at == list.end()) return std::nullopt;
        return static_cast<std::size_t>(at-list.begin());
    }
    [[nodiscard]] std::optional<std::size_t> find_chunk(const fb::Guid& chunk) const {
        const auto at = std::find_if(bundle.chunks.begin(), bundle.chunks.end(), [&](const auto& item) { return item.guid == chunk; });
        if (at == bundle.chunks.end()) return std::nullopt;
        return static_cast<std::size_t>(at-bundle.chunks.begin());
    }
};

// The game's root bundle (dingolevel_root), its TOC's chunks and its two shader tables: what the
// pack's stock entries must equal, and what the new names must not collide with.
struct GameRoot {
    fs::path game;
    vfs::Layout layout;
    std::optional<vfs::GameArchives> archives;
    fb::TocDocument toc;
    vfs::GameBundle bundle;
    std::set<fb::Guid> toc_chunks, chunks;
    std::set<std::string, std::less<>> names;
    std::set<std::uint64_t> rids;
    std::map<std::string, std::size_t, std::less<>> ebx, resources;
    Bytes program, texture;
    std::vector<std::byte> program_meta;
    explicit GameRoot(const fs::path& game_root) : game(game_root) {
        const vfs::GameData data(game);
        toc = data.read_toc(toc_path);
        require(toc.bundles.size() == 1, "The game's root superbundle has more than one bundle");
        auto read_bundle = data.read_bundle(toc, toc.bundles[0].name);
        require(read_bundle.has_value(), "The game's root bundle is missing");
        bundle = std::move(*read_bundle);
        // A merge reads tens of thousands of payloads; so may --check-own-names (stock EBX GUIDs).
        layout = vfs::read_layout(game / "Data" / "layout.toc"); archives.emplace(game / "Data", layout.root); archives->keep_open();
        for (const auto& chunk : toc.chunks) toc_chunks.insert(chunk.guid);
        for (const auto& chunk : bundle.manifest.chunks) chunks.insert(chunk.guid);
        for (std::size_t i = 0; i < bundle.manifest.ebx.size(); ++i) { names.insert(bundle.manifest.ebx[i].name); ebx.emplace(bundle.manifest.ebx[i].name, i); }
        for (std::size_t i = 0; i < bundle.manifest.resources.size(); ++i) {
            const auto& resource = bundle.manifest.resources[i];
            names.insert(resource.name); rids.insert(resource.resourceId); resources.emplace(resource.name, i);
        }
        const auto program_at = resources.find(program_table_name), texture_at = resources.find(texture_table_name);
        require(program_at != resources.end() && texture_at != resources.end(), "The game's root shader tables are missing");
        program = payload(fb::AssetKind::resource, program_at->second);
        program_meta = bundle.manifest.resources[program_at->second].resourceMeta;
        texture = payload(fb::AssetKind::resource, texture_at->second);
    }
    [[nodiscard]] Bytes payload(fb::AssetKind kind, std::size_t index) const {
        const auto* at = bundle.payload(kind, index); require(at != nullptr, "Stock payload is missing");
        return fb::decode_cas(archives->read(archives->root(), at->location, at->offset, at->size), {game});
    }
};

// Program lookup rows: key, then the indices of the stock programs it aliases (shader_lookup.cpp).
using ProgramRows = std::vector<std::pair<std::uint64_t, std::vector<std::uint32_t>>>;
std::size_t program_lookup_offset(std::span<const std::byte> resource, std::span<const std::byte> meta) {
    require(meta.size() == 16, "Program lookup metadata is not 16 bytes");
    const auto offset = std::size_t{get<std::uint32_t>(meta, 0)} + get<std::uint32_t>(meta, 4);
    require(offset <= resource.size() && get<std::uint32_t>(meta, 8) == resource.size()-offset, "Program lookup size");
    return offset;
}
ProgramRows program_rows(std::span<const std::byte> resource, std::span<const std::byte> meta) {
    auto at = program_lookup_offset(resource, meta);
    const auto count = get<std::uint32_t>(resource, at); at += 4;
    ProgramRows rows;
    for (std::uint32_t row = 0; row < count; ++row) {
        const auto key = get<std::uint64_t>(resource, at); const auto values = get<std::uint32_t>(resource, at+8); at += 12;
        require(values > 0 && values <= 4096, "Program lookup row is invalid");
        std::vector<std::uint32_t> indices;
        for (std::uint32_t value = 0; value < values; ++value, at += 4) indices.push_back(get<std::uint32_t>(resource, at));
        rows.emplace_back(key, std::move(indices));
    }
    require(at == resource.size(), "Program lookup has trailing data");
    return rows;
}
using TextureRows = std::vector<std::pair<std::uint64_t, std::uint64_t>>;
TextureRows texture_rows(std::span<const std::byte> resource) {
    require(resource.size() % 16 == 0, "Texture lookup layout");
    TextureRows rows;
    for (std::size_t at = 0; at < resource.size(); at += 16) rows.emplace_back(get<std::uint64_t>(resource, at), get<std::uint64_t>(resource, at+8));
    return rows;
}

// A mesh set resource's layout, as the template's is (prepare_free_native_parts.py reads it the
// same way). Pointers are stored as the byte position minus 16.
constexpr std::size_t pointer_bias = 16, section_stride = 384;
constexpr std::size_t mesh_full_name = 104, mesh_short_name = 112, mesh_name_hash = 120;
constexpr std::size_t lod_long_at = 140, lod_medium_at = 148, lod_short_at = 156, lod_hash_at = 164;
constexpr std::size_t section_name_pointer = 8, section_key = 312, section_name_hash = 324;
// After a section's bounds: the hash of its LOD's name, as at lod+164. The template's sections
// 0-3 hold it; section 4 and the stock TerrainMesh section hold 0.
constexpr std::size_t section_lod_hash = 372;
std::size_t pointer_at(std::span<const std::byte> bytes, std::size_t at) {
    const auto value = get<std::uint64_t>(bytes, at);
    require(value < bytes.size() - pointer_bias, "Resource pointer is outside its resource");
    return static_cast<std::size_t>(value) + pointer_bias;
}
struct MeshLayout {
    std::size_t lod{}, sections{}, count{};
    explicit MeshLayout(std::span<const std::byte> resource) {
        lod = pointer_at(resource, 48); sections = pointer_at(resource, lod+12); count = get<std::uint32_t>(resource, lod+8);
        require(count == material_sections+1 && sections + count*section_stride <= resource.size(), "Unexpected mesh section table");
    }
    [[nodiscard]] std::size_t section(std::size_t index) const { return sections + index*section_stride; }
};
std::string after_last_slash(std::string_view name) {
    const auto at = name.rfind('/'); return std::string(at == std::string_view::npos ? name : name.substr(at+1));
}

// What the template holds of its own: the entries it stores itself and does not share a name
// with the game's root, read before anything is removed.
struct DroneTexture { std::string name; std::size_t ebx{}, resource{}, chunk{}; fb::Guid file, instance, chunk_guid; std::uint64_t rid{}; };
struct DroneTemplate {
    std::vector<std::size_t> ebx, resources, chunks;
    std::size_t program_table{}, texture_table{};
    std::size_t mesh{}, blueprint{}, database{}, mesh_resource{}, depot{};
    std::vector<DroneTexture> textures;
    Bytes mesh_document, blueprint_document, database_document, mesh_resource_bytes, depot_bytes;
    std::array<std::uint64_t, material_sections> keys{}, block_hashes{};
    std::array<std::string, material_sections> section_names;
    std::string mesh_lod_name;
    std::uint64_t depot_number{};
    fb::Guid mesh_file, partition;
    [[nodiscard]] const DroneTexture& texture(std::string_view name) const {
        const auto at = std::find_if(textures.begin(), textures.end(), [&](const auto& item) { return item.name == name; });
        require(at != textures.end(), "Template texture is missing"); return *at;
    }
    [[nodiscard]] const DroneTexture* binding(const fb::Guid& instance, const fb::Guid& file) const {
        const auto at = std::find_if(textures.begin(), textures.end(), [&](const auto& item) { return item.instance == instance && item.file == file; });
        return at == textures.end() ? nullptr : &*at;
    }
};
// The depot: a u64 pointer to its entry table ({key, record} per material section, in section
// order), records {block, hash, size}, then the blocks; its relocations come after the data.
struct DepotLayout {
    std::size_t entries{}, count{}, relocations{}, relocation_bytes{};
    DepotLayout(std::span<const std::byte> depot, std::span<const std::byte> meta) {
        require(meta.size() == 16, "Depot metadata is not 16 bytes");
        relocations = get<std::uint32_t>(meta, 0); relocation_bytes = get<std::uint32_t>(meta, 4); count = get<std::uint32_t>(meta, 12);
        require(relocations + relocation_bytes <= depot.size() && count == material_sections, "Unexpected depot layout");
        entries = static_cast<std::size_t>(get<std::uint64_t>(depot, 0));
        require(entries + count*16 <= relocations, "Depot entry table is outside its data");
    }
    [[nodiscard]] std::size_t key(std::size_t section) const { return entries + section*16; }
    [[nodiscard]] std::size_t record(std::span<const std::byte> depot, std::size_t section) const {
        const auto at = static_cast<std::size_t>(get<std::uint64_t>(depot, entries + section*16 + 8));
        require(at + 24 <= relocations, "Depot record is outside its data"); return at;
    }
};
std::vector<std::size_t> texture_parameters(std::span<const std::byte> depot) { return find_all(depot, texture_parameter); }

DroneTemplate read_drone_template(const Pack& tpl) {
    DroneTemplate drone;
    const auto& t = tpl.bundle;
    std::size_t databases{}, depots{}, tables{};
    for (std::size_t i = 0; i < t.ebx.size(); ++i) {
        if (!tpl.file(fb::AssetKind::ebx, i).location.patch) continue;
        const auto& name = t.ebx[i].name;
        drone.ebx.push_back(i);
        if (name == drone_mesh_name) drone.mesh = i;
        else if (name == drone_blueprint_name) drone.blueprint = i;
        else if (name == slot_database_name) { drone.database = i; ++databases; }
        else require(name.starts_with(drone_texture_prefix), "Unexpected template asset " + name);
    }
    for (std::size_t i = 0; i < t.resources.size(); ++i) {
        if (!tpl.file(fb::AssetKind::resource, i).location.patch) continue;
        const auto& resource = t.resources[i];
        if (resource.name == program_table_name) { drone.program_table = i; ++tables; continue; }
        if (resource.name == texture_table_name) { drone.texture_table = i; ++tables; continue; }
        drone.resources.push_back(i);
        if (resource.name == drone_mesh_name) drone.mesh_resource = i;
        else if (resource.resourceType == depot_type && resource.name.starts_with(drone_depot_prefix)) {
            drone.depot = i; ++depots;
            drone.depot_number = std::stoull(resource.name.substr(drone_depot_prefix.size()));
        } else require(resource.name.starts_with(drone_texture_prefix) && resource.resourceType == fb::texture_resource_type,
            "Unexpected template resource " + resource.name);
    }
    for (std::size_t i = 0; i < t.chunks.size(); ++i)
        if (tpl.file(fb::AssetKind::chunk, i).location.patch) drone.chunks.push_back(i);
    // 15 textures, the mesh, the blueprint and the database; 15 headers, the mesh and the depot,
    // besides the two shader tables; 15 texture chunks and the mesh's geometry.
    require(drone.ebx.size() == 18 && drone.resources.size() == 17 && drone.chunks.size() == 16 &&
        databases == 1 && depots == 1 && tables == 2 && t.ebx[drone.mesh].name == drone_mesh_name &&
        t.ebx[drone.blueprint].name == drone_blueprint_name && t.resources[drone.mesh_resource].name == drone_mesh_name,
        "The template's own entries are not the FPV Drone pack's");
    for (const auto i : drone.ebx) {
        const auto& name = t.ebx[i].name;
        if (!name.starts_with(drone_texture_prefix)) continue;
        DroneTexture texture; texture.name = name; texture.ebx = i;
        const auto resource = tpl.find(fb::AssetKind::resource, name);
        require(resource.has_value(), "Template texture has no header"); texture.resource = *resource;
        const auto document = ebx::read_document(tpl.payload(fb::AssetKind::ebx, i));
        require(document.rootType == "TextureAsset" && document.instances.size() == 1 && document.instances[0].exported, "Unexpected template texture");
        texture.file = document.fileGuid; texture.instance = document.instances[0].instanceGuid;
        texture.rid = t.resources[*resource].resourceId;
        const auto header = tpl.payload(fb::AssetKind::resource, *resource);
        texture.chunk_guid = fb::read_texture_header(header, t.resources[*resource].resourceMeta).chunk;
        const auto chunk = tpl.find_chunk(texture.chunk_guid);
        require(chunk.has_value() && std::ranges::find(drone.chunks, *chunk) != drone.chunks.end(), "Template texture chunk is not the template's");
        texture.chunk = *chunk;
        drone.textures.push_back(std::move(texture));
    }
    require(drone.textures.size() == 15, "Expected the template's 15 textures");
    drone.mesh_document = tpl.payload(fb::AssetKind::ebx, drone.mesh);
    drone.blueprint_document = tpl.payload(fb::AssetKind::ebx, drone.blueprint);
    drone.database_document = tpl.payload(fb::AssetKind::ebx, drone.database);
    drone.mesh_resource_bytes = tpl.payload(fb::AssetKind::resource, drone.mesh_resource);
    drone.depot_bytes = tpl.payload(fb::AssetKind::resource, drone.depot);
    const auto mesh = ebx::read_document(drone.mesh_document);
    drone.mesh_file = mesh.fileGuid;
    drone.partition = std::get<fb::Guid>(field(*mesh.instances[0].object, "OriginalPartitionGuid").value.data);
    const auto& resource = drone.mesh_resource_bytes;
    const MeshLayout layout(resource);
    for (unsigned section = 0; section < material_sections; ++section) {
        const auto at = layout.section(section);
        drone.keys[section] = get<std::uint64_t>(resource, at+section_key);
        drone.section_names[section] = string_at(resource, pointer_at(resource, at+section_name_pointer));
        require(get<std::uint32_t>(resource, at+section_name_hash) == name_hash32(drone.section_names[section]),
            "Template section name hash is not the lower-case name's");
    }
    drone.mesh_lod_name = string_at(resource, pointer_at(resource, layout.lod+lod_medium_at));
    require(drone.mesh_lod_name == std::string(drone_mesh_name) + "_lod0" &&
        string_at(resource, pointer_at(resource, layout.lod+lod_long_at)) == "Mesh:" + drone.mesh_lod_name &&
        string_at(resource, pointer_at(resource, layout.lod+lod_short_at)) == after_last_slash(drone.mesh_lod_name) &&
        get<std::uint32_t>(resource, layout.lod+lod_hash_at) == name_hash32(drone.mesh_lod_name), "Template LOD names differ");
    const DepotLayout depot(drone.depot_bytes, t.resources[drone.depot].resourceMeta);
    for (unsigned section = 0; section < material_sections; ++section) {
        require(get<std::uint64_t>(drone.depot_bytes, depot.key(section)) == drone.keys[section], "Template depot keys are not its sections'");
        drone.block_hashes[section] = get<std::uint64_t>(drone.depot_bytes, depot.record(drone.depot_bytes, section)+8);
    }
    return drone;
}

struct Built { std::size_t ebx{}, resources{}, chunks{}; };

// A streamed texture's bundle chunk is the resident end of the chain its TOC chunk lists, in the
// same bytes (as Studio writes one, and as the merge narrows one). Every other payload has bytes
// of its own.
bool end_of_toc_chunk(const fb::BundleFileInfo& file, const fb::Guid& chunk, const std::vector<fb::TocChunk>& toc) {
    return std::ranges::any_of(toc, [&](const auto& item) {
        return item.guid == chunk && !item.removed && item.location == file.location && file.offset > item.offset &&
            std::uint64_t{file.offset} + file.size == std::uint64_t{item.offset} + item.size;
    });
}

int build(const fs::path& root, const fs::path& parts, const fs::path& output, const fs::path& game,
          const std::optional<fs::path>& textures, const KeepNames& keep) {
    require(root != output && !fs::exists(output), "Output must be a new separate directory");
    std::vector<std::string> part_names{"frame","fork","rear_wheel","front_wheel","cranks","handlebars"};
    if(fs::exists(parts/"part-list.txt")) {
        auto expected=part_names;expected.push_back("left_pedal");expected.push_back("right_pedal");
        std::ifstream list(parts/"part-list.txt");std::vector<std::string> actual;std::string line;
        while(std::getline(list,line)) {if(!line.empty() && line.back()=='\r')line.pop_back();actual.push_back(line);}
        require(actual==expected, "Unexpected private articulated part list");part_names=std::move(actual);
    }
    require(!textures || part_names.size()==8, "Supplied-model textures require the eight-part geometry contract");
    const Pack tpl(root, game);
    const auto& t = tpl.bundle;
    const auto& manifest_file = tpl.region.files[0];
    // Everything the template stores itself is in the archive its manifest is in. The pack's
    // archive at that path is written afresh, holding only what the new manifest names.
    require(manifest_file.location.patch, "Template manifest is not the template's own");
    for (const auto& file : tpl.region.files) require(!file.location.patch || file.location == manifest_file.location, "Template payloads span archives");
    for (const auto& chunk : tpl.toc.chunks) require(!chunk.location.patch || chunk.location == manifest_file.location, "Template chunks span archives");
    const auto drone = read_drone_template(tpl);
    const GameRoot stock(game);
    require(stock.toc.bundles[0].name == tpl.toc.bundles[0].name, "Template bundle is not the game's root bundle");

    // What stays: the template's copy of the game's root bundle. Each entry must be the game's
    // own, by name (or GUID), content and place; the two shader tables are rebuilt below.
    const std::set<std::size_t> drop_ebx(drone.ebx.begin(), drone.ebx.end()), drop_resources(drone.resources.begin(), drone.resources.end()),
        drop_chunks(drone.chunks.begin(), drone.chunks.end());
    fb::BinaryBundle bundle;
    std::vector<fb::BundleFileInfo> ef, rf, cf;
    const auto same_place = [](const fb::BundleFileInfo& left, const fb::BundleFileInfo* right) {
        return right && left.location == right->location && left.offset == right->offset && left.size == right->size;
    };
    for (std::size_t i = 0; i < t.ebx.size(); ++i) {
        if (drop_ebx.contains(i)) continue;
        const auto at = stock.ebx.find(t.ebx[i].name);
        require(at != stock.ebx.end() && stock.bundle.manifest.ebx[at->second].sha1 == t.ebx[i].sha1 &&
            same_place(tpl.file(fb::AssetKind::ebx, i), stock.bundle.payload(fb::AssetKind::ebx, at->second)),
            "Template EBX is not the game's: " + t.ebx[i].name);
        bundle.ebx.push_back(t.ebx[i]); ef.push_back(tpl.file(fb::AssetKind::ebx, i));
    }
    std::size_t program_at{}, texture_at{};
    for (std::size_t i = 0; i < t.resources.size(); ++i) {
        if (drop_resources.contains(i)) continue;
        const auto& resource = t.resources[i];
        const auto at = stock.resources.find(resource.name);
        require(at != stock.resources.end(), "Template resource is not the game's: " + resource.name);
        const auto& game_row = stock.bundle.manifest.resources[at->second];
        require(game_row.resourceId == resource.resourceId && game_row.resourceType == resource.resourceType, "Template resource identity differs: " + resource.name);
        if (i == drone.program_table) program_at = bundle.resources.size();
        else if (i == drone.texture_table) texture_at = bundle.resources.size();
        else require(game_row.sha1 == resource.sha1 && game_row.resourceMeta == resource.resourceMeta &&
            same_place(tpl.file(fb::AssetKind::resource, i), stock.bundle.payload(fb::AssetKind::resource, at->second)),
            "Template resource is not the game's: " + resource.name);
        bundle.resources.push_back(resource); rf.push_back(tpl.file(fb::AssetKind::resource, i));
    }
    auto metadata = db::read({reinterpret_cast<const unsigned char*>(t.chunkMetadata.data()), t.chunkMetadata.size()},
        "Private native pack chunk metadata", nullptr, {.unique_fields=false, .max_entries=t.chunkMetadata.size()});
    require(metadata.children.size() == t.chunks.size(), "Chunk metadata count");
    const auto template_rows = metadata.children;
    metadata.children.clear();
    std::set<fb::Guid> dropped_chunks;
    for (std::size_t i = 0; i < t.chunks.size(); ++i) {
        if (drop_chunks.contains(i)) { dropped_chunks.insert(t.chunks[i].guid); continue; }
        std::size_t index{};
        const auto* game_chunk = stock.bundle.find_chunk(t.chunks[i].guid, &index);
        require(game_chunk && game_chunk->sha1 == t.chunks[i].sha1 &&
            same_place(tpl.file(fb::AssetKind::chunk, i), stock.bundle.payload(fb::AssetKind::chunk, index)),
            "Template chunk is not the game's: " + t.chunks[i].guid.string());
        bundle.chunks.push_back(t.chunks[i]); cf.push_back(tpl.file(fb::AssetKind::chunk, i));
        // A chunk's record is at the chunk's own place in the list (mod_merge_combine.cpp).
        metadata.children.push_back(template_rows[i]);
    }
    require(bundle.ebx.size() == stock.bundle.manifest.ebx.size() && bundle.resources.size() == stock.bundle.manifest.resources.size() &&
        bundle.chunks.size() == stock.bundle.manifest.chunks.size(), "What stays of the template is not the game's root bundle");
    auto toc = tpl.toc;
    const auto toc_before = toc.chunks.size();
    std::erase_if(toc.chunks, [&](const auto& chunk) { return dropped_chunks.contains(chunk.guid); });
    require(toc_before - toc.chunks.size() == drop_chunks.size(), "Template TOC chunks are not its own chunks");
    const auto stock_ebx = bundle.ebx.size(), stock_resources = bundle.resources.size(), stock_chunks = bundle.chunks.size();
    // Before any new name is used: none may be the game's.
    const auto unused_name = [&](const std::string& name) { require(!stock.names.contains(name), "Own name collides with the game's: " + name); };
    const auto unused_chunk = [&](const fb::Guid& chunk) {
        require(!stock.chunks.contains(chunk) && !stock.toc_chunks.contains(chunk) &&
            std::none_of(bundle.chunks.begin(), bundle.chunks.end(), [&](const auto& item) { return item.guid == chunk; }), "Own chunk GUID collides: " + chunk.string());
    };
    const auto unused_rid = [&](std::uint64_t rid) {
        require(!stock.rids.contains(rid) && std::none_of(bundle.resources.begin(), bundle.resources.end(), [&](const auto& item) { return item.resourceId == rid; }),
            "Own resource id collides: " + hex(rid));
    };

    fs::create_directories(output);
    for (const auto* name : {"layout.toc", "initfs_win32", ".reskate-studio-patch"}) fs::copy_file(root/name, output/name);
    const auto archive_path = fs::path("Win32") / tpl.archives->directory(manifest_file.location.installChunk) / vfs::archive_file(manifest_file.location.archive);
    fs::create_directories((output/archive_path).parent_path());
    std::ofstream cas(output/archive_path, std::ios::binary | std::ios::trunc);
    require(static_cast<bool>(cas), "Cannot create the pack's archive");
    struct StoredPayload { fb::BundleFileInfo file; fb::Sha1 digest; bool encoded{}; };
    std::vector<StoredPayload> written_payloads;
    std::uint64_t cas_size{};
    const auto append_stored = [&](std::span<const std::byte> stored, fb::Sha1 digest, bool encoded) {
        require(cas_size + stored.size() < std::numeric_limits<std::uint32_t>::max(), "CAS size bound");
        cas.write(reinterpret_cast<const char*>(stored.data()), static_cast<std::streamsize>(stored.size()));
        require(static_cast<bool>(cas), "CAS append failed");
        const fb::BundleFileInfo file{manifest_file.location, static_cast<std::uint32_t>(cas_size), static_cast<std::uint32_t>(stored.size())};
        cas_size += stored.size();
        written_payloads.push_back({file, digest, encoded});
        return file;
    };
    const auto append = [&](std::span<const std::byte> bytes, bool encode=true) {
        // Use the same native Kraken path as the mod merger.
        const auto stored = encode ? fb::encode_cas(bytes, {game}) : Bytes(bytes.begin(), bytes.end());
        return append_stored(stored,sha(bytes),encode);
    };

    // The shader tables: the game's own, with the bike material's five rows. Each row K_i is
    // the drone's row D_i (the same stock programs and texture set) under the bike's key; Studio's
    // tables are the game's with the D rows, which the bike no longer has.
    std::array<std::uint64_t, material_sections> keys{};
    for (unsigned section = 0; section < material_sections; ++section) keys[section] = own::section_key(section);
    {
        const fb::shader::Table stock_program{stock.program, stock.program_meta};
        const auto template_program = tpl.payload(fb::AssetKind::resource, drone.program_table);
        const auto& template_meta = t.resources[drone.program_table].resourceMeta;
        require(fb::shader::same_program_graph({template_program, template_meta}, stock_program), "Template program table is not on the game's graph");
        const auto stock_rows = program_rows(stock.program, stock.program_meta);
        const std::map<std::uint64_t, std::vector<std::uint32_t>> stock_map(stock_rows.begin(), stock_rows.end());
        std::map<std::uint64_t, std::vector<std::uint32_t>> added;
        for (const auto& [key, values] : program_rows(template_program, template_meta)) {
            const auto at = stock_map.find(key);
            if (at == stock_map.end()) added.emplace(key, values);
            else require(at->second == values, "Template changes a stock program row");
        }
        require(added.size() == material_sections, "Template program table adds other rows than the drone's");
        Bytes edit(stock.program.begin(), stock.program.begin()+static_cast<std::ptrdiff_t>(program_lookup_offset(stock.program, stock.program_meta)));
        const auto lookup = edit.size();
        const auto push = [&](auto value) { const auto at = edit.size(); edit.resize(at+sizeof(value)); std::memcpy(edit.data()+at, &value, sizeof(value)); };
        push(static_cast<std::uint32_t>(material_sections));
        for (unsigned section = 0; section < material_sections; ++section) {
            const auto row = added.find(drone.keys[section]);
            require(row != added.end(), "Template program table lacks a drone row");
            require(!stock_map.contains(keys[section]), "Own material key collides with a stock program row");
            push(keys[section]); push(static_cast<std::uint32_t>(row->second.size()));
            for (const auto value : row->second) push(value);
        }
        auto edit_meta = stock.program_meta;
        const auto edit_lookup = static_cast<std::uint32_t>(edit.size()-lookup); std::memcpy(edit_meta.data()+8, &edit_lookup, 4);
        const fb::shader::Table edits[]{{edit, edit_meta}};
        const auto merged = fb::shader::merge_program_lookup(stock_program, edits);
        const fb::shader::Table result{merged.resource, merged.resourceMeta};
        require(merged.added == material_sections && !merged.conflicts && !merged.outside && !merged.removed &&
            fb::shader::same_program_graph(result, stock_program) && fb::shader::only_stock_aliases(result, stock_program) &&
            merged.resource.size() == template_program.size() && merged.resourceMeta == template_meta,
            "Program table with the bike's rows differs from the game's plus five rows");
        for (const auto& [key, values] : program_rows(merged.resource, merged.resourceMeta)) {
            (void)values;
            require(std::ranges::find(drone.keys, key) == drone.keys.end(), "Program table keeps a drone row");
        }
        auto& row = bundle.resources[program_at];
        row.sha1 = sha(merged.resource); row.originalSize = merged.resource.size(); row.resourceMeta = merged.resourceMeta;
        rf[program_at] = append(merged.resource);
        std::cout << "program table: the game's " << stock_rows.size() << " rows plus " << merged.added << ", lookup "
            << get<std::uint32_t>(stock.program_meta, 8) << " -> " << get<std::uint32_t>(merged.resourceMeta, 8) << " bytes\n";
    }
    {
        const auto stock_rows = texture_rows(stock.texture);
        const std::map<std::uint64_t, std::uint64_t> stock_map(stock_rows.begin(), stock_rows.end());
        std::map<std::uint64_t, std::uint64_t> added;
        for (const auto& [key, value] : texture_rows(tpl.payload(fb::AssetKind::resource, drone.texture_table))) {
            const auto at = stock_map.find(key);
            if (at == stock_map.end()) added.emplace(key, value);
            else require(at->second == value, "Template changes a stock texture row");
        }
        require(added.size() == material_sections, "Template texture table adds other rows than the drone's");
        Bytes edit;
        for (unsigned section = 0; section < material_sections; ++section) {
            const auto row = added.find(drone.keys[section]);
            require(row != added.end(), "Template texture table lacks a drone row");
            require(!stock_map.contains(keys[section]), "Own material key collides with a stock texture row");
            const auto at = edit.size(); edit.resize(at+16);
            std::memcpy(edit.data()+at, &keys[section], 8); std::memcpy(edit.data()+at+8, &row->second, 8);
        }
        const auto& texture_row = bundle.resources[texture_at];
        const fb::shader::Table edits[]{{edit, texture_row.resourceMeta}};
        const auto merged = fb::shader::merge_texture_lookup({stock.texture, texture_row.resourceMeta}, edits);
        const auto rows = texture_rows(merged.resource);
        require(merged.added == material_sections && !merged.conflicts && merged.resource.size() == stock.texture.size() + 16*material_sections &&
            std::ranges::is_sorted(rows, [](const auto& left, const auto& right) { return left.first < right.first; }) &&
            std::none_of(rows.begin(), rows.end(), [&](const auto& item) { return std::ranges::find(drone.keys, item.first) != drone.keys.end(); }),
            "Texture table with the bike's rows differs from the game's plus five rows");
        auto& row = bundle.resources[texture_at];
        row.sha1 = sha(merged.resource); row.originalSize = merged.resource.size();
        rf[texture_at] = append(merged.resource);
    }

    // The bike's three textures, each from the template's frame_2 texture of its slot: its EBX,
    // header, manifest rows and chunk record, under the bike's own names. Basecolour and normal
    // take the supplied pixels; the mask is the frame mask value above.
    std::map<std::string, own::Texture, std::less<>> own_textures;
    for (const auto slot : own::texture_slots) {
        const auto own = own::texture(slot);
        const auto& donor = drone.texture(std::string(drone_texture_prefix) + "frame_2_" + std::string(slot));
        unused_name(own.name); unused_chunk(own.chunk); unused_rid(own.rid);
        auto document = ebx::read_document(tpl.payload(fb::AssetKind::ebx, donor.ebx));
        auto resource = t.resources[donor.resource]; auto header = tpl.payload(fb::AssetKind::resource, donor.resource);
        auto chunk = t.chunks[donor.chunk];
        const auto original = fb::read_texture_header(header, resource.resourceMeta);
        require(header.size() == 180 && resource.resourceMeta.size() >= 4, "Unexpected extended texture header");
        fb::BinaryReader version(resource.resourceMeta);
        const auto texture_version = version.u32();
        std::cout << donor.name << " header version=" << texture_version << " type=" << original.type << " format=" << original.format
            << " dimensions=" << original.width << 'x' << original.height << '\n';
        require(texture_version >= 12 && texture_version <= 13 && original.type == 0 &&
            header[32] == header[31] && header[33] == header[30], "Supported texture header contract changed");
        std::uint64_t old_owner{}; std::memcpy(&old_owner, header.data()+120, 8);
        require(old_owner == owner_hash(donor.name), "Donor texture owner hash differs");
        require(compressed_chunk(original.chunk), "Donor texture chunk is not read as compressed blocks");
        require(std::get<ebx::ResourceReference>(field(*document.instances[0].object, "Resource").value.data).id == resource.resourceId,
            "Compiled texture binding resource differs from its header");
        Bytes pixels, encoded;
        // What the TOC lists: the stored chain, of which `encoded` (what the bundle lists) is the
        // tail from `tail_at`. Only a donor's streamed chain has a tail of its own.
        Bytes chain; std::uint32_t tail_at{};
        std::optional<TextureInput> input;
        // No supplied model (the six-part reference path): colour and normal keep the donor's
        // pixels, header, mip chain and chunk record whole, under the bike's names.
        const bool donor_pixels = !textures && slot != "mask";
        if (slot == "mask") {
            // One mip of one BC1 block, as the donor's: the pixels change nothing else.
            pixels.assign(frame_mask_texel.begin(), frame_mask_texel.end());
            require(original.mip_count == 1 && original.first_mip == 0 && original.chunk_size == pixels.size() &&
                original.mip_sizes[0] == pixels.size() && tpl.payload(fb::AssetKind::chunk, donor.chunk) == pixels,
                "The template's frame mask is not the value the builder writes");
            encoded = fb::encode_cas(pixels, {game});
        } else if (textures) {
            const bool colour = slot == "basecolor";
            input = texture_input(*textures, colour ? "albedo" : "normal");
            require(input->format == (colour ? 55u : 63u) && original.format == input->format, "Colour/normal texture format mismatch");
            pixels = input->pixels;
            // Each mip ends on a CAS block boundary. The first two words identify
            // COMPRESSED stream ends, not decoded pixel offsets (Frosty Utils.cs).
            std::array<std::uint32_t,2> mip_ends{}; std::size_t pixel_offset{};
            for (unsigned mip = 0; mip < input->count; ++mip) {
                const auto block = fb::encode_cas(std::span<const std::byte>(input->pixels).subspan(pixel_offset, input->sizes[mip]), {game});
                encoded.insert(encoded.end(), block.begin(), block.end()); pixel_offset += input->sizes[mip];
                if (mip < 2 && input->count > 1) mip_ends[mip] = static_cast<std::uint32_t>(encoded.size());
            }
            require(fb::decode_cas(encoded, {game}) == input->pixels, "Texture mip CAS round trip failed");
            put(header,0,mip_ends[0]); put(header,4,mip_ends[1]);
            put(header,20,static_cast<std::uint16_t>(input->count==1?original.flags&~1u:original.flags));
            put(header,22,static_cast<std::uint16_t>(input->width)); put(header,24,static_cast<std::uint16_t>(input->height));
            put(header,30,static_cast<std::uint8_t>(input->count)); put(header,31,std::uint8_t{0});
            // All 15 retained donor headers duplicate first/count here. Preserve
            // all six unexplained bytes34..39; this extended-header duplication remains
            // an observed contract, to be checked again by the native loader.
            put(header,32,std::uint8_t{0}); put(header,33,static_cast<std::uint8_t>(input->count));
            for (unsigned mip = 0; mip < 15; ++mip) put(header,56+mip*4,input->sizes[mip]);
            put(header,116,static_cast<std::uint32_t>(input->pixels.size()));
            texture_dimensions(document, *input);
        } else {
            // Stored as the donor stored them, so its compressed mip ends stay true. A streamed
            // donor (frame_2_normal: first mip 1) lists its whole chain in the TOC and, in the
            // bundle, only the resident mips, the end of the same bytes; both are kept so.
            const auto& listed = tpl.file(fb::AssetKind::chunk, donor.chunk);
            const auto toc_chunk = std::ranges::find_if(tpl.toc.chunks, [&](const auto& item) { return item.guid == donor.chunk_guid; });
            require(toc_chunk != tpl.toc.chunks.end() && !toc_chunk->removed && toc_chunk->location == listed.location &&
                listed.offset >= toc_chunk->offset && std::uint64_t{listed.offset} + listed.size == std::uint64_t{toc_chunk->offset} + toc_chunk->size,
                "Donor texture's bundle chunk is not the end of its TOC chunk");
            chain = tpl.archives->read(tpl.root, toc_chunk->location, toc_chunk->offset, toc_chunk->size);
            tail_at = listed.offset - toc_chunk->offset;
            require(fb::decode_cas(chain, {game}).size() == original.chunk_size, "Donor texture's TOC chunk is not its whole mip chain");
            pixels = tpl.payload(fb::AssetKind::chunk, donor.chunk);
            encoded.assign(chain.begin()+tail_at, chain.end());
        }
        if (chain.empty()) chain = encoded;
        std::copy(own.chunk.bytes.begin(), own.chunk.bytes.end(), header.begin()+40);
        put(header,120,owner_hash(own.name));
        const auto checked = fb::read_texture_header(header, resource.resourceMeta);
        require(checked.chunk == own.chunk && checked.first_mip == (donor_pixels ? original.first_mip : 0) &&
            checked.chunk_size == (donor_pixels ? original.chunk_size : pixels.size()) &&
            (!input || (checked.width == input->width && checked.height == input->height && checked.mip_count == input->count)),
            "Generated texture header mismatch");
        document.fileGuid = own.file; document.instances[0].instanceGuid = own.instance;
        field(*document.instances[0].object, "Name").value.data = own.name;
        field(*document.instances[0].object, "Resource").value.data = ebx::ResourceReference{own.rid};
        const auto bytes = ebx::write_document(document);
        require(ebx::read_document(bytes).fileGuid == document.fileGuid, "Texture EBX round trip failed");
        auto asset = t.ebx[donor.ebx]; asset.name = own.name; asset.sha1 = sha(bytes); asset.originalSize = bytes.size();
        bundle.ebx.push_back(asset); ef.push_back(append(bytes));
        resource.name = own.name; resource.resourceId = own.rid; resource.sha1 = sha(header); resource.originalSize = header.size();
        bundle.resources.push_back(resource); rf.push_back(append(header));
        chunk.guid = own.chunk; chunk.name = own.chunk.string();
        // A donor chain keeps the donor's row (Studio's digest is not the decoded payload's).
        if (!donor_pixels) {
            chunk.sha1 = sha(pixels); chunk.originalSize = pixels.size();
            chunk.logicalOffset = 0; chunk.logicalSize = static_cast<std::uint32_t>(pixels.size());
        }
        const auto whole = append_stored(chain, tail_at ? sha(fb::decode_cas(chain, {game})) : sha(pixels), true);
        const fb::BundleFileInfo placement{whole.location, whole.offset + tail_at, whole.size - tail_at};
        if (tail_at) written_payloads.push_back({placement, sha(pixels), true});
        require(fb::decode_cas(encoded, {game}) == pixels, "Texture chunk CAS round trip failed");
        bundle.chunks.push_back(chunk); cf.push_back(placement);
        toc.chunks.push_back({own.chunk, whole.location, whole.offset, whole.size, false});
        // Its record, the donor's with the bike's name hash; a chain the builder wrote is
        // resident from mip 0.
        auto row = template_rows[donor.chunk];
        auto* owner = row.field("h64"); require(owner && owner->payload().size() == 8, "Texture chunk metadata has no owner hash");
        owner->bytes = {}; owner->owned.assign(8, 0); const auto hash = owner_hash(own.name); std::memcpy(owner->owned.data(), &hash, 8);
        auto* meta = row.field("meta"); require(meta != nullptr, "Texture chunk metadata missing meta object");
        auto* mip = meta->field("firstMip"); require(mip != nullptr && mip->payload().size() == 4, "Texture first mip metadata missing");
        if (!donor_pixels) { mip->bytes = {}; mip->owned.assign(4, 0); }
        metadata.children.push_back(std::move(row));
        write(output/"texture-audit"/(std::string(slot)+".header"), header);
        write(output/"texture-audit"/(std::string(slot)+".pixels"), pixels);
        std::cout << own.name << " chunk=" << own.chunk.string() << " bytes=" << pixels.size() << '\n';
        own_textures.emplace(std::string(slot), own);
    }

    // The database's place in the manifest, after the textures; it is written once every part's
    // entry is in it.
    const auto database_at = bundle.ebx.size();
    {
        auto asset = t.ebx[drone.database];
        asset.name = keep.database ? std::string(slot_database_name) : std::string(own::database_name);
        if (!keep.database) unused_name(asset.name);
        bundle.ebx.push_back(asset); ef.push_back({});
    }

    // The depot: the template's, block for block, under the bike's name, keyed by the bike's
    // material keys, its texture parameters bound to the bike's textures of the same slot.
    {
        auto depot = drone.depot_bytes;
        auto resource = t.resources[drone.depot];
        const DepotLayout layout(depot, resource.resourceMeta);
        for (unsigned section = 0; section < material_sections; ++section) {
            put(depot, layout.key(section), keys[section]);
            // Pack A: the block's hash is the bike's own. Whether the game checks it against the
            // content or uses it to share blocks is not known (the bisect keeps the drone's).
            if (!keep.block_hashes) put(depot, layout.record(depot, section)+8, own::block_hash(section));
        }
        const auto parameters = texture_parameters(drone.depot_bytes);
        require(parameters.size() == drone.textures.size(), "Template depot binds another number of textures");
        for (const auto at : parameters) {
            const auto* bound = drone.binding(get_guid(depot, at+binding_instance), get_guid(depot, at+binding_file));
            require(bound != nullptr, "Template depot binds a texture that is not the template's");
            const auto slot = bound->name.substr(bound->name.rfind('_')+1);
            const auto& own = own_textures.at(slot);
            put_guid(depot, at+binding_instance, own.instance); put_guid(depot, at+binding_file, own.file);
        }
        for (const auto& texture : drone.textures)
            require(find_all(depot, as_bytes(texture.instance)).empty() && find_all(depot, as_bytes(texture.file)).empty(), "Depot keeps a drone texture binding");
        require(depot.size() == drone.depot_bytes.size() &&
            std::equal(depot.begin()+static_cast<std::ptrdiff_t>(layout.relocations), depot.end(),
                drone.depot_bytes.begin()+static_cast<std::ptrdiff_t>(layout.relocations)), "Depot layout changed");
        resource.name = own::depot_name(); resource.resourceId = own::depot_rid();
        unused_name(resource.name); unused_rid(resource.resourceId);
        resource.sha1 = sha(depot); resource.originalSize = depot.size();
        bundle.resources.push_back(resource); rf.push_back(append(depot));
        std::cout << resource.name << " bytes=" << depot.size() << " bindings=" << parameters.size() << '\n';
    }

    // The donor imports this group from the city bundle. Root-domain meshes
    // cannot resolve an asset loaded only in a child level domain. Preserve
    // the original authored dependency, but load it beside these meshes.
    const vfs::GameData game_data(game);
    const auto city_toc = game_data.read_toc("Win32/levels/game/bam_levelroot/bam_levelroot.toc");
    const auto city = game_data.read_bundle(city_toc, "win32/levels/game/bam_levelroot/bam_levelroot");
    require(city.has_value(), "Supported city bundle with donor LOD group is absent");
    std::size_t lod_index{};
    const auto* lod_asset = city->find(fb::AssetKind::ebx, lod_name, &lod_index);
    require(lod_asset != nullptr, "Donor LOD group is absent");
    const auto* lod_payload = city->payload(fb::AssetKind::ebx, lod_index);
    require(lod_payload != nullptr, "Donor LOD group has no payload");
    const auto lod_bytes = game_data.read(*lod_payload);
    const auto lod = ebx::read_document(lod_bytes);
    const auto donor_mesh = ebx::read_document(drone.mesh_document);
    require(lod_bytes.size() == 2240 && lod.rootType == "MeshLodGroup" && lod.imports.empty() &&
        lod.instances.size() == 1, "Donor LOD shape differs");
    require(!donor_mesh.imports.empty() &&
        lod.fileGuid == donor_mesh.imports[0].fileGuid && lod.instances[0].instanceGuid == donor_mesh.imports[0].classGuid &&
        lod.fileGuid.string() == "7a5d035c-d46c-4cc2-8417-9839b66383d5", "Donor LOD import pair differs");
    // Validate the decoded source bytes against the independently extracted
    // supported-build dependency, rather than assuming the manifest digest
    // describes the decoded representation.
    const auto lod_digest = sha(lod_bytes);
    require(std::memcmp(lod_digest.bytes.data(), lod_sha1.data(), lod_sha1.size()) == 0,
        "Donor LOD decoded source SHA1 differs");
    require(std::none_of(bundle.ebx.begin(), bundle.ebx.end(), [&](const auto& item) { return item.name == lod_name; }),
        "Template already contains the donor LOD group");
    bundle.ebx.push_back(*lod_asset); ef.push_back(append(lod_bytes));

    // The variation database: the template's, with an entry for each part and none for the drone.
    auto variations = ebx::read_document(drone.database_document);
    require(variations.rootType == "MeshVariationDatabase", "Unexpected template variation database");
    auto& database_root = *variations.instances[0].object;
    auto& entries = std::get<ebx::Value::Array>(field(database_root, "Entries").value.data);
    require(entries.size() == 1, "Expected one private template mesh variation");
    const auto prototype_entry = clone(entries[0]);
    entries.clear();
    const auto prototype_imports = variations.imports;
    require(prototype_imports.size() == 1+5 && std::ranges::all_of(prototype_imports, [&](const auto& item) { return item.fileGuid == drone.mesh_file; }),
        "The template database imports other than the drone mesh's root and materials");
    variations.imports.clear();
    if (!keep.database) {
        variations.fileGuid = own::database_file();
        field(database_root, "Name").value.data = std::string(own::database_name);
        // Its instances' GUIDs are Studio's: none is in any of the game's variation databases, so
        // with the FPV Drone mod on they would be the drone database's too. Each gets the bike's
        // own; the entries point at them by index, and nothing imports them.
        std::set<fb::Guid> old_instances;
        for (std::size_t i = 0; i < variations.instances.size(); ++i) {
            auto& instance = variations.instances[i];
            if (!instance.exported) continue;
            old_instances.insert(instance.instanceGuid);
            instance.instanceGuid = own::database_instance(i);
            require(!old_instances.contains(instance.instanceGuid), "Own database instance GUID collides with the template's");
        }
    } else require(std::get<std::string>(field(database_root, "Name").value.data) == slot_database_name, "Template database name differs");
    // Its RadiosityMaterials carry the mesh sections' names: renamed with them or not at all.
    {
        const auto& prototype = *std::get<std::shared_ptr<ebx::Object>>(prototype_entry.data);
        const auto& radiosity = std::get<ebx::Value::Array>(field(prototype, "RadiosityMaterials").value.data);
        require(radiosity.size() == material_sections, "Unexpected template radiosity materials");
        for (unsigned section = 0; section < material_sections; ++section) {
            const auto& pointer = std::get<ebx::PointerReference>(radiosity[section].data);
            require(pointer.kind == ebx::PointerKind::internal && pointer.index >= 0 &&
                static_cast<std::size_t>(pointer.index) < variations.instances.size(), "Template radiosity material is not in its database");
            auto& instance = variations.instances[static_cast<std::size_t>(pointer.index)];
            require(type_name(variations, instance) == "RadiosityMaterial", "Template radiosity material type");
            auto& name = field(*instance.object, "Name").value.data;
            require(std::get<std::string>(name) == drone.section_names[section], "Template radiosity material is not its section's");
            if (!keep.section_names) name = own::section_name(section);
        }
    }

    for (const auto& part : part_names) {
        const auto own = own::part(part);
        auto mesh = ebx::read_document(drone.mesh_document), blueprint = ebx::read_document(drone.blueprint_document);
        unused_name(own.name); unused_name(own.mesh_name); unused_chunk(own.chunk); unused_rid(own.rid);
        // Every instance the mesh exports gets the part's own GUID, and each import naming one of
        // them (the blueprint's, the database's) is remapped through this.
        std::map<fb::Guid, fb::Guid> renamed;
        require(mesh.instances.size() == 6 && type_name(mesh, mesh.instances[0]) == "RigidMeshAsset" &&
            std::ranges::all_of(mesh.instances, [](const auto& item) { return item.exported; }), "Unexpected template mesh instances");
        renamed.emplace(mesh.instances[0].instanceGuid, own.mesh_root);
        for (std::size_t material = 1; material < mesh.instances.size(); ++material) {
            require(type_name(mesh, mesh.instances[material]) == "MeshMaterial", "Unexpected template mesh material");
            renamed.emplace(mesh.instances[material].instanceGuid, own.materials[material-1]);
        }
        for (auto& instance : mesh.instances) instance.instanceGuid = renamed.at(instance.instanceGuid);
        const auto old_mesh_file = mesh.fileGuid;
        mesh.fileGuid = own.mesh_file;
        auto& mesh_root = *mesh.instances[0].object;
        field(mesh_root, "Name").value.data = own.mesh_name;
        field(mesh_root, "MeshSetResource").value.data = ebx::ResourceReference{own.rid};
        const auto hash = name_hash32(own.mesh_name);
        field(mesh_root, "NameHash").value.data = std::uint64_t(hash);
        auto& partition = field(mesh_root, "OriginalPartitionGuid").value.data;
        require(std::get<fb::Guid>(partition) == drone.partition, "Template partition GUID differs");
        // Pack A: the mesh's own file GUID. Nothing in the SDK reads it; whether the game does is
        // not known (the bisect keeps the template's).
        if (!keep.partition_guid) partition = own.mesh_file;

        auto mesh_resource = read(parts/(std::string(part)+".mesh"));
        require(mesh_resource.size() == drone.mesh_resource_bytes.size(), "Part mesh is not the template mesh's layout");
        const MeshLayout layout(mesh_resource);
        std::memcpy(mesh_resource.data()+mesh_name_hash, &hash, sizeof(hash));
        // Native setup resolves MeshAsset by this embedded full name. Reusing
        // the donor name binds the new resource to the donor's asset settings.
        const auto full_name_at = pointer_at(mesh_resource, mesh_full_name), old_short_at = pointer_at(mesh_resource, mesh_short_name);
        require(string_at(mesh_resource, full_name_at) == drone_mesh_name && string_at(mesh_resource, old_short_at) == after_last_slash(drone_mesh_name) &&
            old_short_at > full_name_at + drone_mesh_name.size(), "Part mesh names are not the template's");
        rewrite_string(mesh_resource, full_name_at, own.mesh_name, "New mesh name exceeds the donor string slot");
        // The short name now points into the full one; the template's own short name, which
        // nothing points to any more, is cleared.
        put(mesh_resource, mesh_short_name, static_cast<std::uint64_t>(full_name_at - pointer_bias + std::string_view("reskate/bmx/").size()));
        erase_string(mesh_resource, old_short_at);
        // The LOD's three names: the long one is written where the template's long one was, and
        // the other two point into it (front_wheel_mesh_lod0 would not fit the short slot).
        const auto long_at = pointer_at(mesh_resource, layout.lod+lod_long_at);
        const auto lod_at = pointer_at(mesh_resource, layout.lod+lod_medium_at), short_at = pointer_at(mesh_resource, layout.lod+lod_short_at);
        require(string_at(mesh_resource, lod_at) == drone.mesh_lod_name && get<std::uint32_t>(mesh_resource, layout.lod+lod_hash_at) == name_hash32(drone.mesh_lod_name),
            "Part mesh LOD is not the template's");
        rewrite_string(mesh_resource, long_at, "Mesh:" + own.lod_name, "New LOD name exceeds the donor string slot");
        erase_string(mesh_resource, lod_at); erase_string(mesh_resource, short_at);
        put(mesh_resource, layout.lod+lod_medium_at, static_cast<std::uint64_t>(long_at - pointer_bias + 5));
        put(mesh_resource, layout.lod+lod_short_at, static_cast<std::uint64_t>(long_at - pointer_bias + 5 + std::string_view("reskate/bmx/").size()));
        put(mesh_resource, layout.lod+lod_hash_at, name_hash32(own.lod_name));
        for (std::size_t section = 0; section < layout.count; ++section) {
            const auto at = layout.section(section)+section_lod_hash;
            const auto value = get<std::uint32_t>(mesh_resource, at);
            require(value == 0 || value == name_hash32(drone.mesh_lod_name), "Part mesh section LOD hash is not the template's");
            if (value) put(mesh_resource, at, name_hash32(own.lod_name));
        }
        require(string_at(mesh_resource, pointer_at(mesh_resource, layout.lod+lod_medium_at)) == own.lod_name &&
            string_at(mesh_resource, pointer_at(mesh_resource, layout.lod+lod_short_at)) == after_last_slash(own.lod_name) &&
            string_at(mesh_resource, pointer_at(mesh_resource, mesh_short_name)) == after_last_slash(own.mesh_name), "Mesh name pointers do not read back");
        // The material sections: the bike's material keys and, in pack A, its own section names.
        for (unsigned section = 0; section < material_sections; ++section) {
            const auto at = layout.section(section);
            require(get<std::uint64_t>(mesh_resource, at+section_key) == drone.keys[section], "Part mesh section key is not the template's");
            put(mesh_resource, at+section_key, keys[section]);
            const auto name_at = pointer_at(mesh_resource, at+section_name_pointer);
            require(string_at(mesh_resource, name_at) == drone.section_names[section], "Part mesh section name is not the template's");
            if (keep.section_names) continue;
            const auto name = own::section_name(section);
            rewrite_string(mesh_resource, name_at, name, "New section name exceeds the donor string slot");
            put(mesh_resource, at+section_name_hash, name_hash32(name));
        }
        const auto geometry = read(parts/(std::string(part)+".geom"));
        require(fb::check_mesh_lod(mesh_resource, 0, geometry).empty(), "Generated geometry is outside its declarations");
        require(fb::any_mesh_lod_geometry(mesh_resource, 0).chunk == own.chunk, "Geometry chunk GUID mismatch");
        std::array<float,6> box{}; std::memcpy(box.data(), mesh_resource.data()+16, 12); std::memcpy(box.data()+3, mesh_resource.data()+32, 12);

        blueprint.fileGuid = own.blueprint_file; blueprint.instances[0].instanceGuid = own.blueprint_root;
        require(blueprint.instances.size() >= 2 && blueprint.instances[1].exported && type_name(blueprint, blueprint.instances[1]) == "StaticModelEntityData",
            "Unexpected template blueprint instances");
        blueprint.instances[1].instanceGuid = own.blueprint_model;
        field(*blueprint.instances[0].object, "Name").value.data = own.name;
        require(blueprint.imports.size() == 1 && blueprint.imports[0].fileGuid == old_mesh_file, "Template mesh import mismatch");
        blueprint.imports[0] = {mesh.fileGuid, renamed.at(blueprint.imports[0].classGuid)};
        bounds(field(*blueprint.instances[1].object, "PartBoundingBoxes").value, box);

        auto variation = clone(prototype_entry);
        remap_external(variation, static_cast<std::int32_t>(variations.imports.size()));
        for (const auto& imported : prototype_imports) {
            const auto instance = renamed.find(imported.classGuid);
            require(instance != renamed.end(), "Template database imports an instance the mesh does not export");
            variations.imports.push_back({mesh.fileGuid, instance->second});
        }
        entries.push_back(std::move(variation));
        for (const auto& [document, name, row] : {std::tuple{&mesh, own.mesh_name, &t.ebx[drone.mesh]}, std::tuple{&blueprint, own.name, &t.ebx[drone.blueprint]}}) {
            const auto bytes = ebx::write_document(*document);
            require(ebx::read_document(bytes).fileGuid == document->fileGuid, "EBX round trip failed");
            auto asset = *row; asset.name = name; asset.sha1 = sha(bytes); asset.originalSize = bytes.size();
            bundle.ebx.push_back(asset); ef.push_back(append(bytes));
        }
        auto resource = t.resources[drone.mesh_resource]; resource.name = own.mesh_name; resource.resourceId = own.rid;
        resource.sha1 = sha(mesh_resource); resource.originalSize = mesh_resource.size(); bundle.resources.push_back(resource); rf.push_back(append(mesh_resource));
        fb::BundleAsset chunk; chunk.kind = fb::AssetKind::chunk; chunk.guid = own.chunk; chunk.name = own.chunk.string();
        chunk.sha1 = sha(geometry); chunk.originalSize = geometry.size(); chunk.logicalSize = static_cast<std::uint32_t>(geometry.size());
        const auto placement = append(geometry); bundle.chunks.push_back(chunk); cf.push_back(placement);
        toc.chunks.push_back({own.chunk, placement.location, placement.offset, placement.size, false});
        db::Node row, hash_node, meta; row.type=2; row.terminated=true; hash_node.type=9; hash_node.named=true; hash_node.name="h64";
        const auto owner = owner_hash(own.mesh_name); for (unsigned i=0;i<8;++i) hash_node.owned.push_back(static_cast<unsigned char>(owner>>(i*8)));
        meta.type=2; meta.named=true; meta.name="meta"; meta.terminated=true;
        row.children.push_back(std::move(hash_node)); row.children.push_back(std::move(meta)); metadata.children.push_back(std::move(row));
        std::cout << own.name << " native mesh bytes=" << mesh_resource.size() << " geometry=" << geometry.size() << " chunk=" << own.chunk.string() << '\n';
    }
    const auto db_bytes = ebx::write_document(variations);
    {
        const auto written = ebx::read_document(db_bytes);
        require(written.fileGuid == variations.fileGuid && written.imports.size() == 6*part_names.size(), "Variation database round trip failed");
    }
    bundle.ebx[database_at].sha1 = sha(db_bytes); bundle.ebx[database_at].originalSize = db_bytes.size(); ef[database_at] = append(db_bytes);
    const auto meta_bytes = db::write(metadata);
    bundle.chunkMetadata.assign(reinterpret_cast<const std::byte*>(meta_bytes.data()), reinterpret_cast<const std::byte*>(meta_bytes.data()+meta_bytes.size()));
    require(metadata.children.size() == bundle.chunks.size(), "Chunk metadata count");
    // The additions: 3 textures, the database, the LOD group and a mesh and blueprint per part;
    // 3 texture headers, the depot and a mesh per part; 3 texture chunks and a geometry per part.
    const Built added{bundle.ebx.size()-stock_ebx, bundle.resources.size()-stock_resources, bundle.chunks.size()-stock_chunks};
    require(added.ebx == 5+2*part_names.size() && added.resources == 4+part_names.size() && added.chunks == 3+part_names.size() &&
        toc.chunks.size() == added.chunks, "The pack's additions are not the bike's");
    const auto manifest = fb::write_binary_bundle(bundle); const auto first = append(manifest, false);
    std::vector<fb::BundleFileInfo> files{first}; files.insert(files.end(),ef.begin(),ef.end()); files.insert(files.end(),rf.begin(),rf.end()); files.insert(files.end(),cf.begin(),cf.end());
    toc.bundles[0].region = fb::write_bundle_region(files);
    const auto packed_toc = fb::write_patch_toc(toc.bundles,toc.chunks,toc.flags); fb::verify_toc(fb::read_toc(packed_toc));
    write(output/toc_path, packed_toc); cas.close();
    require(static_cast<bool>(cas) && fs::file_size(output/archive_path) == cas_size, "Pack archive size differs from its payloads");
    // Validate the bytes through the exact archive locations recorded in the
    // emitted pack, rather than only validating the in-memory inputs.
    const vfs::GameArchives emitted_archives(output, tpl.layout.root);
    for (const auto& item : written_payloads) {
        const auto stored = emitted_archives.read(output, item.file.location, item.file.offset, item.file.size);
        const auto decoded = item.encoded ? fb::decode_cas(stored, {game}) : stored;
        require(sha(decoded) == item.digest, "Emitted CAS payload differs at its recorded offset");
    }
    const auto emitted_bundle = emitted_archives.read_manifest(output, first.location, first.offset, first.size, game);
    require(emitted_bundle.ebx.size() == bundle.ebx.size() && emitted_bundle.resources.size() == bundle.resources.size() &&
        emitted_bundle.chunks.size() == bundle.chunks.size(), "Emitted manifest asset counts differ");
    // Every byte of the archive is one payload the pack names.
    {
        std::set<std::pair<std::uint32_t, std::uint32_t>> ranges;
        const auto chunks_at = 1 + ef.size() + rf.size();
        for (std::size_t i = 0; i < files.size(); ++i) {
            if (!files[i].location.patch) continue;
            if (i >= chunks_at && end_of_toc_chunk(files[i], bundle.chunks[i-chunks_at].guid, toc.chunks)) continue;
            ranges.emplace(files[i].offset, files[i].size);
        }
        for (const auto& chunk : toc.chunks) if (chunk.location.patch) ranges.emplace(chunk.offset, chunk.size);
        std::uint64_t next{};
        for (const auto& [offset, size] : ranges) { require(offset == next, "Pack archive has bytes no payload names"); next += size; }
        require(next == cas_size, "Pack archive has bytes no payload names");
    }
    std::ofstream credits(output/"BMX-NATIVE.txt");
    credits << "Private local BMX prototype pack; not a redistribution pack.\n"
        "Every asset it adds has a name of its own (reskate/bmx/...); none of the FPV Drone template's assets is in it.\n"
        "Native structure: the mesh, material, blueprint and texture layouts, the shader depot's blocks and the variation\n"
        "database's material variations (which refer to the game's own) follow ReSkate Studio's FPV Drone pack\n"
        "(\"FPV Drone\" by PinaPipe, CC BY 4.0).\n"
        "https://sketchfab.com/3d-models/fpv-drone-92152c31ec9a4a87b2a0478bd114d293\nhttps://creativecommons.org/licenses/by/4.0/\n"
        "The bike's frame mask is the drone's mask value (one texel).\n"
        << part_names.size() << " articulated render parts, no borrowed collision volumes.\n";
    if (keep.database || keep.block_hashes || keep.section_names || keep.partition_guid)
        credits << "Bisect build: keeps the template's" << (keep.database ? " database name" : "") << (keep.block_hashes ? " block hashes" : "")
            << (keep.section_names ? " section names" : "") << (keep.partition_guid ? " partition GUID" : "") << ".\n";
    if (textures) credits << "Geometry/colour: user-supplied Downloads/bmx-free/source/BMX_sf.fbx; kept private.\nSource normals retained, flat tangent normal.\n";
    else credits << "Colour and normal: the drone's frame textures' pixels, under the bike's own texture names.\n";
    std::cout << "Created " << output.string() << " with " << part_names.size() << " native bike blueprints; added "
        << added.ebx << " EBX, " << added.resources << " resources (and the 2 shader tables), " << added.chunks << " chunks.\n";
    return 0;
}

// --check-own-names: whether a pack has names of its own and keeps nothing of the template's.
// Each check prints PASS or FAIL with what failed, or that it is not checked here (C11 needs two
// builds); the exit code is 0 only when none fails.
class Checks {
public:
    void fail(const std::string& check, std::string what) { failures_[check].push_back(std::move(what)); seen_.insert(check); }
    void pass(const std::string& check) { seen_.insert(check); }
    void note(const std::string& check, std::string what) { notes_[check].push_back(std::move(what)); seen_.insert(check); }
    // A check this mode cannot run: it is named, neither passed nor failed.
    void skip(const std::string& check, std::string why) { skipped_[check] = std::move(why); }
    int report() const {
        std::vector<std::string> failed;
        for (const auto& check : order_) {
            if (const auto skipped = skipped_.find(check); skipped != skipped_.end() && !seen_.contains(check)) {
                std::cout << check << " not checked here: " << skipped->second << '\n'; continue;
            }
            if (!seen_.contains(check)) continue;
            const auto at = failures_.find(check);
            std::cout << check << ' ' << (at == failures_.end() ? "PASS" : "FAIL (" + std::to_string(at->second.size()) + ")") << '\n';
            if (const auto notes = notes_.find(check); notes != notes_.end()) for (const auto& line : notes->second) std::cout << "    note: " << line << '\n';
            if (at == failures_.end()) continue;
            failed.push_back(check);
            for (const auto& line : at->second) std::cout << "    " << line << '\n';
        }
        std::cout << (failed.empty() ? std::string("own names: PASS") : "own names: FAIL in");
        for (const auto& check : failed) std::cout << ' ' << check;
        std::cout << '\n';
        return failed.empty() ? 0 : 1;
    }
private:
    std::vector<std::string> order_{"C1","C2","C3","C4","C5","C6","C7","C8","C9","C10","C11"};
    std::map<std::string, std::vector<std::string>> failures_, notes_;
    std::map<std::string, std::string> skipped_;
    std::set<std::string> seen_;
};

// The template's own identities, searched for as exact bytes (2.15: "drone" alone would find
// the game's advance/prototypes/dronedatastruct).
struct Needle { std::string label; Bytes bytes; bool aligned32{}; };
std::vector<Needle> drone_identities(const Pack& tpl, const DroneTemplate& drone) {
    std::vector<Needle> needles;
    std::set<Bytes> seen;
    const auto add = [&](std::string label, std::span<const std::byte> bytes, bool aligned32 = false) {
        Bytes value(bytes.begin(), bytes.end());
        if (seen.insert(value).second) needles.push_back({std::move(label), std::move(value), aligned32});
    };
    const auto add_u64 = [&](std::string label, std::uint64_t value) { add(std::move(label), {reinterpret_cast<const std::byte*>(&value), 8}); };
    const auto add_u32 = [&](std::string label, std::uint32_t value) { add(std::move(label), {reinterpret_cast<const std::byte*>(&value), 4}, true); };
    add("string reskate/drone/", as_bytes("reskate/drone/")); add("string fpv_drone", as_bytes("fpv_drone"));
    add("depot number " + std::to_string(drone.depot_number), as_bytes(std::to_string(drone.depot_number)));
    add_u64("depot number", drone.depot_number);
    std::set<std::string> names;
    for (const auto i : drone.ebx) names.insert(tpl.bundle.ebx[i].name);
    for (const auto i : drone.resources) names.insert(tpl.bundle.resources[i].name);
    for (const auto& name : names) {
        add("name " + name, as_bytes(name)); add_u64("owner hash of " + name, owner_hash(name)); add_u32("name hash of " + name, name_hash32(name));
    }
    add_u32("LOD name hash of " + drone.mesh_lod_name, name_hash32(drone.mesh_lod_name));
    for (unsigned section = 0; section < material_sections; ++section) {
        add("section name " + drone.section_names[section], as_bytes(drone.section_names[section]));
        add_u32("section name hash of " + drone.section_names[section], name_hash32(drone.section_names[section]));
        add_u64("drone material key " + hex(drone.keys[section]), drone.keys[section]);
        add_u64("drone block hash " + hex(drone.block_hashes[section]), drone.block_hashes[section]);
    }
    for (const auto i : drone.resources) add_u64("rid of " + tpl.bundle.resources[i].name, tpl.bundle.resources[i].resourceId);
    for (const auto i : drone.chunks) add("chunk " + tpl.bundle.chunks[i].guid.string(), as_bytes(tpl.bundle.chunks[i].guid));
    add("partition GUID " + drone.partition.string(), as_bytes(drone.partition));
    for (const auto i : drone.ebx) {
        const auto& name = tpl.bundle.ebx[i].name;
        const auto document = ebx::read_document(tpl.payload(fb::AssetKind::ebx, i));
        add("file GUID of " + name + " " + document.fileGuid.string(), as_bytes(document.fileGuid));
        // The database's too (its root, RadiosityMaterials and MeshMaterialVariations): their GUIDs
        // are Studio's, in none of the game's variation databases.
        for (const auto& instance : document.instances)
            if (instance.exported) add("instance GUID in " + name + " " + instance.instanceGuid.string(), as_bytes(instance.instanceGuid));
    }
    return needles;
}

int check_own_names(const fs::path& pack_root, const fs::path& template_root, const fs::path& game) {
    const Pack pack(pack_root, game), tpl(template_root, game);
    const auto drone = read_drone_template(tpl);
    const GameRoot stock(game);
    Checks checks;
    const auto& b = pack.bundle;
    std::array<std::uint64_t, material_sections> keys{};
    for (unsigned section = 0; section < material_sections; ++section) keys[section] = own::section_key(section);
    std::cout << "pack " << pack_root.string() << "\ntemplate " << template_root.string() << "\ngame " << game.string() << '\n';

    // The pack's own payloads, decoded once. A payload whose name is the game's and whose bytes
    // are the game's (or the city's LOD group) is stock: no identity search runs on it.
    struct Payload { fb::AssetKind kind; std::size_t index; std::string label; Bytes bytes; bool stock_copy{}; };
    std::vector<Payload> payloads;
    std::map<std::string, ebx::Document, std::less<>> documents;
    for (const auto kind : {fb::AssetKind::ebx, fb::AssetKind::resource, fb::AssetKind::chunk}) {
        const auto& list = kind == fb::AssetKind::ebx ? b.ebx : kind == fb::AssetKind::resource ? b.resources : b.chunks;
        for (std::size_t i = 0; i < list.size(); ++i) {
            if (!pack.file(kind, i).location.patch) continue;
            Payload payload{kind, i, (kind == fb::AssetKind::ebx ? "ebx " : kind == fb::AssetKind::resource ? "res " : "chunk ") + list[i].name,
                pack.payload(kind, i)};
            const auto digest = sha(payload.bytes);
            if (kind == fb::AssetKind::ebx) {
                const auto at = stock.ebx.find(list[i].name);
                payload.stock_copy = (at != stock.ebx.end() && stock.bundle.manifest.ebx[at->second].sha1 == digest) ||
                    (list[i].name == lod_name && std::memcmp(digest.bytes.data(), lod_sha1.data(), lod_sha1.size()) == 0);
                documents.emplace(list[i].name, ebx::read_document(payload.bytes));
            } else if (kind == fb::AssetKind::resource) {
                const auto at = stock.resources.find(list[i].name);
                payload.stock_copy = at != stock.resources.end() && stock.bundle.manifest.resources[at->second].sha1 == digest;
            }
            payloads.push_back(std::move(payload));
        }
    }
    const auto resource_named = [&](std::string_view name) -> const Payload* {
        const auto at = std::find_if(payloads.begin(), payloads.end(), [&](const auto& item) { return item.kind == fb::AssetKind::resource && b.resources[item.index].name == name; });
        return at == payloads.end() ? nullptr : &*at;
    };
    const auto resource_by_rid = [&](std::uint64_t rid) -> const Payload* {
        const auto at = std::find_if(payloads.begin(), payloads.end(), [&](const auto& item) { return item.kind == fb::AssetKind::resource && b.resources[item.index].resourceId == rid; });
        return at == payloads.end() ? nullptr : &*at;
    };
    const auto program = resource_named(program_table_name), texture = resource_named(texture_table_name);

    // C1. The template's own identities, anywhere in what the pack stores or lists.
    {
        const auto needles = drone_identities(tpl, drone);
        std::unordered_map<std::uint32_t, std::vector<std::size_t>> by_prefix;
        for (std::size_t i = 0; i < needles.size(); ++i) {
            std::uint32_t prefix{}; std::memcpy(&prefix, needles[i].bytes.data(), 4); by_prefix[prefix].push_back(i);
        }
        std::map<std::pair<std::string, std::string>, std::pair<std::size_t, std::size_t>> hits;   // (where, what) -> (count, first)
        const auto search = [&](const std::string& where, std::span<const std::byte> bytes, bool with32) {
            for (std::size_t at = 0; at + 4 <= bytes.size(); ++at) {
                std::uint32_t prefix{}; std::memcpy(&prefix, bytes.data()+at, 4);
                const auto found = by_prefix.find(prefix);
                if (found == by_prefix.end()) continue;
                for (const auto i : found->second) {
                    const auto& needle = needles[i];
                    if (needle.aligned32 && (!with32 || at % 4)) continue;
                    if (needle.bytes.size() > bytes.size()-at || std::memcmp(bytes.data()+at, needle.bytes.data(), needle.bytes.size())) continue;
                    auto& hit = hits[{where, needle.label}]; if (!hit.first++) hit.second = at;
                }
            }
        };
        const auto first_manifest = pack.stored(pack.region.files[0]);
        search("manifest", first_manifest, false);
        search("toc", read(pack_root / toc_path), false);
        for (const auto* name : {"layout.toc", ".reskate-studio-patch", "BMX-NATIVE.txt"})
            if (fs::exists(pack_root / name)) search(name, read(pack_root / name), false);
        std::size_t searched{}, skipped{};
        for (const auto& payload : payloads) {
            if (payload.stock_copy) { ++skipped; continue; }
            ++searched;
            if (&payload == program || &payload == texture) {
                // Only the rows the game's table does not have.
                Bytes rows;
                if (&payload == program) {
                    const auto stock_rows = program_rows(stock.program, stock.program_meta);
                    const std::map<std::uint64_t, std::vector<std::uint32_t>> stock_map(stock_rows.begin(), stock_rows.end());
                    for (const auto& [key, values] : program_rows(payload.bytes, b.resources[payload.index].resourceMeta)) {
                        if (const auto at = stock_map.find(key); at != stock_map.end() && at->second == values) continue;
                        const auto at = rows.size(); rows.resize(at+12+4*values.size());
                        std::memcpy(rows.data()+at, &key, 8); const auto count = static_cast<std::uint32_t>(values.size()); std::memcpy(rows.data()+at+8, &count, 4);
                        std::memcpy(rows.data()+at+12, values.data(), 4*values.size());
                    }
                } else {
                    const auto stock_rows = texture_rows(stock.texture);
                    const std::map<std::uint64_t, std::uint64_t> stock_map(stock_rows.begin(), stock_rows.end());
                    for (const auto& [key, value] : texture_rows(payload.bytes)) {
                        if (const auto at = stock_map.find(key); at != stock_map.end() && at->second == value) continue;
                        const auto at = rows.size(); rows.resize(at+16); std::memcpy(rows.data()+at, &key, 8); std::memcpy(rows.data()+at+8, &value, 8);
                    }
                }
                search(payload.label + " (rows the game's lacks)", rows, false);
                continue;
            }
            search(payload.label, payload.bytes, payload.kind != fb::AssetKind::chunk);
        }
        for (const auto& [where, hit] : hits)
            checks.fail("C1", where.first + ": " + where.second + (hit.first > 1 ? " (" + std::to_string(hit.first) + " times, first" : " (") + " at " + std::to_string(hit.second) + ")");
        // The TOC stores a chunk's GUID byte-reversed (toc.cpp), where the search above cannot see
        // it: its chunks are compared as read.
        std::set<fb::Guid> drone_chunks;
        for (const auto i : drone.chunks) drone_chunks.insert(tpl.bundle.chunks[i].guid);
        for (const auto& chunk : pack.toc.chunks)
            if (drone_chunks.contains(chunk.guid)) checks.fail("C1", "toc: chunk " + chunk.guid.string());
        checks.note("C1", std::to_string(needles.size()) + " identities of the template; " + std::to_string(searched) + " payloads searched, " +
            std::to_string(skipped) + " left out as the game's own bytes, plus the manifest, TOC and pack files");
        checks.pass("C1");
    }

    // C2. Texture chunks: read as compressed blocks, not the game's, and whole in the TOC.
    {
        std::size_t textures{};
        for (const auto& payload : payloads) {
            if (payload.kind != fb::AssetKind::resource || b.resources[payload.index].resourceType != fb::texture_resource_type) continue;
            ++textures;
            const auto header = fb::read_texture_header(payload.bytes, b.resources[payload.index].resourceMeta);
            if (!compressed_chunk(header.chunk)) checks.fail("C2", payload.label + ": chunk " + header.chunk.string() + " lacks the compressed-blocks bit");
            if (stock.chunks.contains(header.chunk) || stock.toc_chunks.contains(header.chunk))
                checks.fail("C2", payload.label + ": chunk " + header.chunk.string() + " is the game's");
            if (!pack.find_chunk(header.chunk)) checks.fail("C2", payload.label + ": chunk " + header.chunk.string() + " is not in the pack");
            // The TOC lists the whole chain, also of a texture whose bundle holds only its end.
            const auto listed = std::ranges::find_if(pack.toc.chunks, [&](const auto& item) { return item.guid == header.chunk && !item.removed; });
            if (listed == pack.toc.chunks.end() || !listed->location.patch) { checks.fail("C2", payload.label + ": chunk " + header.chunk.string() + " is not in the pack's TOC"); continue; }
            const auto chain = fb::decode_cas(pack.archives->read(pack.root, listed->location, listed->offset, listed->size), {game}).size();
            if (chain != header.chunk_size)
                checks.fail("C2", payload.label + ": its TOC chunk holds " + std::to_string(chain) + " bytes, its header's chain " + std::to_string(header.chunk_size));
        }
        const auto unforced = guid("texture/mask/chunk");
        checks.note("C2", std::to_string(textures) + " texture headers; self-test: the unforced mask GUID " + unforced.string() +
            (compressed_chunk(unforced) ? " would pass (the test is broken)" : " is refused"));
        if (compressed_chunk(unforced)) checks.fail("C2", "self-test: the unforced mask GUID passes");
        checks.pass("C2");
    }

    // C3. Each mesh's OriginalPartitionGuid is its own file GUID.
    std::vector<std::string> meshes;
    for (const auto& [name, document] : documents) {
        if (document.rootType != "RigidMeshAsset" || !pack.file(fb::AssetKind::ebx, *pack.find(fb::AssetKind::ebx, name)).location.patch) continue;
        meshes.push_back(name);
        const auto partition = std::get<fb::Guid>(field(*document.instances[0].object, "OriginalPartitionGuid").value.data);
        if (partition != document.fileGuid) checks.fail("C3", name + ": OriginalPartitionGuid " + partition.string() + " is not its file GUID " + document.fileGuid.string());
    }
    checks.note("C3", std::to_string(meshes.size()) + " meshes"); checks.pass("C3");

    // C4. The shader tables: the game's, plus exactly the bike's five rows, in key order.
    {
        const auto drone_key = [&](std::uint64_t key) { return std::ranges::find(drone.keys, key) != drone.keys.end(); };
        const auto own_key = [&](std::uint64_t key) { return std::ranges::find(keys, key) != keys.end(); };
        const auto template_program = program_rows(tpl.payload(fb::AssetKind::resource, drone.program_table), tpl.bundle.resources[drone.program_table].resourceMeta);
        const std::map<std::uint64_t, std::vector<std::uint32_t>> template_map(template_program.begin(), template_program.end());
        if (!program) checks.fail("C4", "the pack has no program table of its own");
        else {
            const auto& meta = b.resources[program->index].resourceMeta;
            const fb::shader::Table table{program->bytes, meta}, game_table{stock.program, stock.program_meta};
            if (!fb::shader::same_program_graph(table, game_table)) checks.fail("C4", "program table: not on the game's program graph");
            if (!fb::shader::only_stock_aliases(table, game_table)) checks.fail("C4", "program table: rows that are not stock aliases");
            const auto rows = program_rows(program->bytes, meta), stock_rows = program_rows(stock.program, stock.program_meta);
            const std::map<std::uint64_t, std::vector<std::uint32_t>> stock_map(stock_rows.begin(), stock_rows.end()), row_map(rows.begin(), rows.end());
            if (!std::ranges::is_sorted(rows, [](const auto& l, const auto& r) { return l.first < r.first; })) checks.fail("C4", "program table: rows not in key order");
            for (const auto& [key, values] : stock_rows) if (const auto at = row_map.find(key); at == row_map.end() || at->second != values) checks.fail("C4", "program table: stock row " + hex(key) + " changed or missing");
            std::size_t extra_bytes{};
            for (const auto& [key, values] : rows) {
                if (stock_map.contains(key)) continue;
                extra_bytes += 12 + 4*values.size();
                if (drone_key(key)) checks.fail("C4", "program table: drone row " + hex(key));
                else if (!own_key(key)) checks.fail("C4", "program table: row " + hex(key) + " is neither the game's nor the bike's");
            }
            for (unsigned section = 0; section < material_sections; ++section) {
                const auto at = row_map.find(keys[section]);
                if (at == row_map.end()) { checks.fail("C4", "program table: no row for the bike's key " + hex(keys[section])); continue; }
                if (at->second != template_map.at(drone.keys[section])) checks.fail("C4", "program table: the bike's row " + hex(keys[section]) + " is not the drone row's programs");
            }
            if (get<std::uint32_t>(meta, 8) != get<std::uint32_t>(stock.program_meta, 8) + extra_bytes || extra_bytes != 140)
                checks.fail("C4", "program table: lookupSize " + std::to_string(get<std::uint32_t>(meta, 8)) + ", the game's " + std::to_string(get<std::uint32_t>(stock.program_meta, 8)) + " + 140 expected");
        }
        const auto template_texture = texture_rows(tpl.payload(fb::AssetKind::resource, drone.texture_table));
        const std::map<std::uint64_t, std::uint64_t> template_tex(template_texture.begin(), template_texture.end());
        if (!texture) checks.fail("C4", "the pack has no texture table of its own");
        else {
            const auto rows = texture_rows(texture->bytes), stock_rows = texture_rows(stock.texture);
            const std::map<std::uint64_t, std::uint64_t> stock_map(stock_rows.begin(), stock_rows.end()), row_map(rows.begin(), rows.end());
            if (!std::ranges::is_sorted(rows, [](const auto& l, const auto& r) { return l.first < r.first; })) checks.fail("C4", "texture table: rows not in unsigned key order");
            if (texture->bytes.size() != stock.texture.size() + 80) checks.fail("C4", "texture table: " + std::to_string(texture->bytes.size()) + " bytes, the game's + 80 expected");
            for (const auto& [key, value] : stock_rows) if (const auto at = row_map.find(key); at == row_map.end() || at->second != value) checks.fail("C4", "texture table: stock row " + hex(key) + " changed or missing");
            for (const auto& [key, value] : rows) {
                (void)value;
                if (stock_map.contains(key)) continue;
                if (drone_key(key)) checks.fail("C4", "texture table: drone row " + hex(key));
                else if (!own_key(key)) checks.fail("C4", "texture table: row " + hex(key) + " is neither the game's nor the bike's");
            }
            for (unsigned section = 0; section < material_sections; ++section) {
                const auto at = row_map.find(keys[section]);
                if (at == row_map.end()) checks.fail("C4", "texture table: no row for the bike's key " + hex(keys[section]));
                else if (at->second != template_tex.at(drone.keys[section])) checks.fail("C4", "texture table: the bike's row " + hex(keys[section]) + " is not the drone row's texture set");
            }
        }
        checks.pass("C4");
    }

    // The pack's three textures, by name: what the depot must bind.
    std::map<std::string, std::pair<fb::Guid, fb::Guid>> own_bindings;   // slot -> (instance, file)
    for (const auto slot : own::texture_slots) {
        const auto own = own::texture(slot);
        if (const auto at = documents.find(own.name); at != documents.end() && !at->second.instances.empty())
            own_bindings[std::string(slot)] = {at->second.instances[0].instanceGuid, at->second.fileGuid};
    }
    // C5. The depot: the bike's name, keys, textures and block hashes, the template's layout.
    {
        std::size_t depots{};
        for (const auto& payload : payloads) {
            if (payload.kind != fb::AssetKind::resource || b.resources[payload.index].resourceType != depot_type) continue;
            ++depots;
            const auto& row = b.resources[payload.index];
            if (row.name != own::depot_name()) checks.fail("C5", "depot named " + row.name);
            if (row.resourceId != own::depot_rid()) checks.fail("C5", "depot rid " + hex(row.resourceId) + " is not the bike's");
            const auto& depot = payload.bytes;
            if (depot.size() != drone.depot_bytes.size() || row.resourceMeta != tpl.bundle.resources[drone.depot].resourceMeta) {
                checks.fail("C5", "depot size or metadata is not the template's layout"); continue;
            }
            const DepotLayout layout(depot, row.resourceMeta);
            if (!std::equal(depot.begin()+static_cast<std::ptrdiff_t>(layout.relocations), depot.end(), drone.depot_bytes.begin()+static_cast<std::ptrdiff_t>(layout.relocations)))
                checks.fail("C5", "depot relocations differ from the template's");
            for (unsigned section = 0; section < material_sections; ++section) {
                const auto key = get<std::uint64_t>(depot, layout.key(section));
                if (key != keys[section]) checks.fail("C5", "depot entry " + std::to_string(section) + " keyed " + hex(key) + ", not the bike's " + hex(keys[section]));
                const auto hash = get<std::uint64_t>(depot, layout.record(depot, section)+8);
                if (hash == drone.block_hashes[section]) checks.fail("C5", "depot block " + std::to_string(section) + " keeps the drone's hash " + hex(hash));
                else if (hash != own::block_hash(section)) checks.fail("C5", "depot block " + std::to_string(section) + " hash " + hex(hash) + " is not the bike's");
            }
            for (const auto at : texture_parameters(drone.depot_bytes)) {
                const auto* bound = drone.binding(get_guid(drone.depot_bytes, at+binding_instance), get_guid(drone.depot_bytes, at+binding_file));
                const auto slot = bound ? bound->name.substr(bound->name.rfind('_')+1) : std::string{};
                const auto pair = std::pair{get_guid(depot, at+binding_instance), get_guid(depot, at+binding_file)};
                const auto own = own_bindings.find(slot);
                if (own == own_bindings.end() || own->second != pair)
                    checks.fail("C5", "depot binding at " + std::to_string(at) + " (" + slot + ") is " + pair.first.string() + "/" + pair.second.string() + ", not the pack's bike_" + slot);
            }
        }
        if (depots != 1) checks.fail("C5", std::to_string(depots) + " depots in the pack, one expected");
        checks.pass("C5");
    }

    // C6. The variation database: its own name and GUID, an entry for each mesh, every import an
    // instance the pack holds.
    {
        std::vector<std::string> databases;
        for (const auto& [name, document] : documents) if (document.rootType == "MeshVariationDatabase") databases.push_back(name);
        if (databases.size() != 1) checks.fail("C6", std::to_string(databases.size()) + " variation databases, one expected");
        for (const auto& name : databases) {
            const auto& document = documents.at(name);
            if (name != own::database_name) checks.fail("C6", "database named " + name + ", not " + std::string(own::database_name));
            if (document.fileGuid != own::database_file()) checks.fail("C6", "database file GUID " + document.fileGuid.string() + " is not the bike's " + own::database_file().string());
            const auto& root_name = std::get<std::string>(field(*document.instances[0].object, "Name").value.data);
            if (root_name != name) checks.fail("C6", "database Name field " + root_name + " is not its asset name");
            const auto& entries = std::get<ebx::Value::Array>(field(*document.instances[0].object, "Entries").value.data);
            if (entries.size() != bike_parts || entries.size() != meshes.size())
                checks.fail("C6", std::to_string(entries.size()) + " entries for " + std::to_string(meshes.size()) + " meshes, " + std::to_string(bike_parts) + " expected");
            if (document.imports.size() != 6*bike_parts) checks.fail("C6", std::to_string(document.imports.size()) + " imports, " + std::to_string(6*bike_parts) + " expected");
            std::size_t on_drone{};
            for (const auto& imported : document.imports) {
                if (imported.fileGuid == drone.mesh_file) ++on_drone;
                const auto owner = std::find_if(documents.begin(), documents.end(), [&](const auto& item) { return item.second.fileGuid == imported.fileGuid; });
                const bool resolves = owner != documents.end() && std::ranges::any_of(owner->second.instances, [&](const auto& instance) {
                    return instance.exported && instance.instanceGuid == imported.classGuid; });
                if (!resolves) checks.fail("C6", "import " + imported.fileGuid.string() + "/" + imported.classGuid.string() + " names no instance in the pack");
            }
            if (on_drone) checks.fail("C6", std::to_string(on_drone) + " imports on the drone mesh " + drone.mesh_file.string());
        }
        checks.pass("C6");
    }

    // C7. Every name hash agrees with its lower-case name; each LOD name begins with its mesh's.
    {
        const auto row_hash = [&](const fb::Guid& chunk) -> std::optional<std::uint64_t> {
            const auto index = pack.find_chunk(chunk);
            if (!index) return std::nullopt;
            const auto list = db::read({reinterpret_cast<const unsigned char*>(b.chunkMetadata.data()), b.chunkMetadata.size()}, "chunk metadata", nullptr,
                {.unique_fields=false, .max_entries=b.chunkMetadata.size()});
            if (*index >= list.children.size()) return std::nullopt;
            const auto* owner = list.children[*index].field("h64");
            if (!owner || owner->payload().size() != 8) return std::nullopt;
            std::uint64_t value{}; std::memcpy(&value, owner->payload().data(), 8); return value;
        };
        for (const auto& name : meshes) {
            const auto& document = documents.at(name);
            const auto& root = *document.instances[0].object;
            const auto& own_name = std::get<std::string>(field(root, "Name").value.data);
            if (own_name != name) checks.fail("C7", name + ": Name field " + own_name);
            if (std::get<std::uint64_t>(field(root, "NameHash").value.data) != name_hash32(name)) checks.fail("C7", name + ": EBX NameHash is not its name's");
            const auto* resource = resource_by_rid(std::get<ebx::ResourceReference>(field(root, "MeshSetResource").value.data).id);
            if (!resource || b.resources[resource->index].resourceType != mesh_set_type) { checks.fail("C7", name + ": its mesh set is not in the pack"); continue; }
            const auto& r = resource->bytes;
            if (b.resources[resource->index].name != name) checks.fail("C7", name + ": its mesh set is named " + b.resources[resource->index].name);
            if (get<std::uint32_t>(r, mesh_name_hash) != name_hash32(name)) checks.fail("C7", name + ": RES +120 is not its name's hash");
            if (string_at(r, pointer_at(r, mesh_full_name)) != name) checks.fail("C7", name + ": RES full name " + string_at(r, pointer_at(r, mesh_full_name)));
            if (string_at(r, pointer_at(r, mesh_short_name)) != after_last_slash(name)) checks.fail("C7", name + ": RES short name " + string_at(r, pointer_at(r, mesh_short_name)));
            const MeshLayout layout(r);
            const auto lod = string_at(r, pointer_at(r, layout.lod+lod_medium_at));
            if (!lod.starts_with(name)) checks.fail("C7", name + ": LOD name " + lod + " does not begin with the mesh's name");
            if (string_at(r, pointer_at(r, layout.lod+lod_long_at)) != "Mesh:" + lod) checks.fail("C7", name + ": LOD long name " + string_at(r, pointer_at(r, layout.lod+lod_long_at)));
            if (string_at(r, pointer_at(r, layout.lod+lod_short_at)) != after_last_slash(lod)) checks.fail("C7", name + ": LOD short name " + string_at(r, pointer_at(r, layout.lod+lod_short_at)));
            if (get<std::uint32_t>(r, layout.lod+lod_hash_at) != name_hash32(lod)) checks.fail("C7", name + ": LOD hash is not its LOD name's");
            for (std::size_t section = 0; section < layout.count; ++section) {
                const auto at = layout.section(section);
                const auto section_name = string_at(r, pointer_at(r, at+section_name_pointer));
                if (get<std::uint32_t>(r, at+section_name_hash) != name_hash32(section_name)) checks.fail("C7", name + ": section " + std::to_string(section) + " hash is not " + section_name + "'s");
                if (const auto lod_hash = get<std::uint32_t>(r, at+section_lod_hash); lod_hash && lod_hash != name_hash32(lod))
                    checks.fail("C7", name + ": section " + std::to_string(section) + " LOD hash is not its LOD name's");
            }
            const auto geometry = fb::any_mesh_lod_geometry(r, 0).chunk;
            if (row_hash(geometry) != owner_hash(name)) checks.fail("C7", name + ": its geometry chunk's record is not its name's hash");
        }
        for (const auto& payload : payloads) {
            if (payload.kind != fb::AssetKind::resource || b.resources[payload.index].resourceType != fb::texture_resource_type) continue;
            const auto& name = b.resources[payload.index].name;
            if (get<std::uint64_t>(payload.bytes, 120) != owner_hash(name)) checks.fail("C7", name + ": texture header +120 is not its name's hash");
            const auto header = fb::read_texture_header(payload.bytes, b.resources[payload.index].resourceMeta);
            if (row_hash(header.chunk) != owner_hash(name)) checks.fail("C7", name + ": its chunk's record is not its name's hash");
            if (const auto document = documents.find(name); document == documents.end() ||
                std::get<std::string>(field(*document->second.instances[0].object, "Name").value.data) != name ||
                std::get<ebx::ResourceReference>(field(*document->second.instances[0].object, "Resource").value.data).id != b.resources[payload.index].resourceId)
                checks.fail("C7", name + ": its TextureAsset does not name it and its header");
        }
        // The database's RadiosityMaterials carry the sections' names (2.6): they must agree.
        for (const auto& [name, document] : documents) {
            if (document.rootType != "MeshVariationDatabase") continue;
            for (const auto& entry : std::get<ebx::Value::Array>(field(*document.instances[0].object, "Entries").value.data)) {
                const auto& object = *std::get<std::shared_ptr<ebx::Object>>(entry.data);
                const auto& mesh = std::get<ebx::PointerReference>(field(object, "Mesh").value.data);
                if (mesh.kind != ebx::PointerKind::external || mesh.index < 0 || static_cast<std::size_t>(mesh.index) >= document.imports.size()) continue;
                const auto file = document.imports[static_cast<std::size_t>(mesh.index)].fileGuid;
                const auto owner = std::find_if(documents.begin(), documents.end(), [&](const auto& item) { return item.second.fileGuid == file; });
                if (owner == documents.end() || owner->second.rootType != "RigidMeshAsset") continue;
                const auto* resource = resource_by_rid(std::get<ebx::ResourceReference>(field(*owner->second.instances[0].object, "MeshSetResource").value.data).id);
                if (!resource) continue;
                const MeshLayout layout(resource->bytes);
                const auto& radiosity = std::get<ebx::Value::Array>(field(object, "RadiosityMaterials").value.data);
                for (std::size_t section = 0; section < radiosity.size() && section < material_sections; ++section) {
                    const auto& pointer = std::get<ebx::PointerReference>(radiosity[section].data);
                    if (pointer.kind != ebx::PointerKind::internal) continue;
                    const auto& material = std::get<std::string>(field(*document.instances[static_cast<std::size_t>(pointer.index)].object, "Name").value.data);
                    const auto section_name = string_at(resource->bytes, pointer_at(resource->bytes, layout.section(section)+section_name_pointer));
                    if (material != section_name) checks.fail("C7", owner->first + ": section " + std::to_string(section) + " " + section_name + " but its RadiosityMaterial " + material);
                }
            }
        }
        checks.pass("C7");
    }

    // C8. Every byte of the pack's archives belongs to exactly one payload it names, but for a
    // streamed texture's bundle chunk, which is the end of its own TOC chunk.
    {
        std::map<fb::CasIdentifier, std::set<std::pair<std::uint32_t, std::uint32_t>>> ranges;
        std::size_t ends{};
        const auto chunks_at = pack.first(fb::AssetKind::chunk);
        for (std::size_t i = 0; i < pack.region.files.size(); ++i) {
            const auto& file = pack.region.files[i];
            if (!file.location.patch) continue;
            if (i >= chunks_at && end_of_toc_chunk(file, b.chunks[i-chunks_at].guid, pack.toc.chunks)) { ++ends; continue; }
            ranges[file.location].emplace(file.offset, file.size);
        }
        if (ends) checks.note("C8", std::to_string(ends) + " bundle chunk(s) the end of their TOC chunk's bytes");
        for (const auto& chunk : pack.toc.chunks) if (chunk.location.patch && !chunk.removed) ranges[chunk.location].emplace(chunk.offset, chunk.size);
        for (const auto& [location, list] : ranges) {
            const auto path = pack_root / "Win32" / pack.archives->directory(location.installChunk) / vfs::archive_file(location.archive);
            const auto size = fs::file_size(path);
            std::uint64_t next{}, gaps{}, overlaps{};
            for (const auto& [offset, length] : list) {
                if (offset > next) gaps += offset - next; else if (offset < next) overlaps += next - offset;
                next = std::max<std::uint64_t>(next, std::uint64_t{offset} + length);
            }
            if (next < size) gaps += size - next;
            if (gaps || overlaps) checks.fail("C8", vfs::archive_file(location.archive) + ": " + std::to_string(gaps) + " of " + std::to_string(size) +
                " bytes belong to no payload, " + std::to_string(overlaps) + " bytes to more than one");
            checks.note("C8", vfs::archive_file(location.archive) + ": " + std::to_string(size) + " bytes, " + std::to_string(list.size()) + " payloads");
        }
        checks.pass("C8");
    }

    // C9. The additions are the bike's, and every other entry is the game's own.
    {
        std::size_t ebx_added{}, resources_added{}, tables{}, chunks_added{}, ebx_stock{}, resources_stock{}, chunks_stock{};
        for (std::size_t i = 0; i < b.ebx.size(); ++i) {
            const auto at = stock.ebx.find(b.ebx[i].name);
            if (at == stock.ebx.end()) { ++ebx_added; if (!pack.file(fb::AssetKind::ebx, i).location.patch) checks.fail("C9", "ebx " + b.ebx[i].name + " is in no archive of the pack"); continue; }
            ++ebx_stock;
            if (pack.file(fb::AssetKind::ebx, i).location.patch || stock.bundle.manifest.ebx[at->second].sha1 != b.ebx[i].sha1) checks.fail("C9", "ebx " + b.ebx[i].name + " is the game's name with other bytes");
        }
        for (std::size_t i = 0; i < b.resources.size(); ++i) {
            const auto& row = b.resources[i];
            const auto at = stock.resources.find(row.name);
            if (at == stock.resources.end()) { ++resources_added; continue; }
            ++resources_stock;
            if (row.name == program_table_name || row.name == texture_table_name) { tables += pack.file(fb::AssetKind::resource, i).location.patch; continue; }
            const auto& game_row = stock.bundle.manifest.resources[at->second];
            if (pack.file(fb::AssetKind::resource, i).location.patch || game_row.sha1 != row.sha1 || game_row.resourceId != row.resourceId || game_row.resourceMeta != row.resourceMeta)
                checks.fail("C9", "res " + row.name + " is the game's name with other bytes");
        }
        for (std::size_t i = 0; i < b.chunks.size(); ++i) {
            std::size_t index{};
            const auto* game_chunk = stock.bundle.find_chunk(b.chunks[i].guid, &index);
            if (!game_chunk) { ++chunks_added; continue; }
            ++chunks_stock;
            if (pack.file(fb::AssetKind::chunk, i).location.patch || game_chunk->sha1 != b.chunks[i].sha1) checks.fail("C9", "chunk " + b.chunks[i].guid.string() + " is the game's with other bytes");
        }
        const auto parts = bike_parts;
        checks.note("C9", "added: " + std::to_string(ebx_added) + " EBX, " + std::to_string(resources_added) + " resources plus " + std::to_string(tables) +
            " shader tables, " + std::to_string(chunks_added) + " chunks, for " + std::to_string(meshes.size()) + " meshes");
        if (ebx_added != 5+2*parts || resources_added != 4+parts || tables != 2 || chunks_added != 3+parts)
            checks.fail("C9", "added " + std::to_string(ebx_added) + "/" + std::to_string(resources_added) + "+" + std::to_string(tables) + "/" + std::to_string(chunks_added) +
                ", expected " + std::to_string(5+2*parts) + " EBX, " + std::to_string(4+parts) + " resources + 2 tables, " + std::to_string(3+parts) + " chunks");
        if (meshes.size() != bike_parts) checks.fail("C9", std::to_string(meshes.size()) + " meshes, the bike has " + std::to_string(bike_parts));
        if (ebx_stock != stock.bundle.manifest.ebx.size() || resources_stock != stock.bundle.manifest.resources.size() || chunks_stock != stock.bundle.manifest.chunks.size())
            checks.fail("C9", "the game's entries are not all in the pack");
        // The TOC lists exactly the added chunks, once each.
        std::set<fb::Guid> toc_chunks, added_chunks;
        for (const auto& chunk : pack.toc.chunks) toc_chunks.insert(chunk.guid);
        for (const auto& chunk : b.chunks) if (!stock.chunks.contains(chunk.guid)) added_chunks.insert(chunk.guid);
        for (const auto& chunk : toc_chunks)
            if (!added_chunks.contains(chunk)) checks.fail("C9", "TOC chunk " + chunk.string() + " is not one the pack adds");
        for (const auto& chunk : added_chunks)
            if (!toc_chunks.contains(chunk)) checks.fail("C9", "added chunk " + chunk.string() + " is not in the TOC");
        if (pack.toc.chunks.size() != toc_chunks.size() || std::ranges::any_of(pack.toc.chunks, [](const auto& chunk) { return chunk.removed; }))
            checks.fail("C9", "the TOC lists " + std::to_string(pack.toc.chunks.size()) + " chunks for " + std::to_string(toc_chunks.size()) + " GUIDs, or removes one");
        checks.pass("C9");
    }

    // C10. No new identity is the game's: names, resource ids, chunk and EBX file GUIDs, keys.
    {
        std::set<fb::Guid> stock_files;
        for (std::size_t i = 0; i < stock.bundle.manifest.ebx.size(); ++i) stock_files.insert(ebx::read_file_guid(stock.payload(fb::AssetKind::ebx, i)));
        std::size_t compared{};
        for (const auto& [name, document] : documents) {
            if (stock.ebx.contains(name) || name == lod_name) continue;
            ++compared;
            if (stock_files.contains(document.fileGuid)) checks.fail("C10", "ebx " + name + " file GUID " + document.fileGuid.string() + " is the game's");
        }
        for (const auto& row : b.resources) {
            if (stock.resources.contains(row.name)) continue;
            ++compared;
            if (stock.rids.contains(row.resourceId)) checks.fail("C10", "res " + row.name + " rid " + hex(row.resourceId) + " is the game's");
        }
        for (const auto& chunk : b.chunks) {
            if (stock.chunks.contains(chunk.guid)) continue;
            ++compared;
            if (stock.toc_chunks.contains(chunk.guid)) checks.fail("C10", "chunk " + chunk.guid.string() + " is in the game's TOC");
        }
        const auto stock_program = program_rows(stock.program, stock.program_meta);
        const auto stock_texture = texture_rows(stock.texture);
        for (const auto& name : meshes) {
            const auto* resource = resource_by_rid(std::get<ebx::ResourceReference>(field(*documents.at(name).instances[0].object, "MeshSetResource").value.data).id);
            if (!resource) continue;
            const MeshLayout layout(resource->bytes);
            for (unsigned section = 0; section < material_sections; ++section) {
                const auto key = get<std::uint64_t>(resource->bytes, layout.section(section)+section_key);
                if (std::ranges::any_of(stock_program, [&](const auto& row) { return row.first == key; }) ||
                    std::ranges::any_of(stock_texture, [&](const auto& row) { return row.first == key; }))
                    checks.fail("C10", name + ": section " + std::to_string(section) + " key " + hex(key) + " is a stock material key");
            }
        }
        checks.note("C10", std::to_string(compared) + " new identities against the game's root (" + std::to_string(stock_files.size()) + " EBX files, " +
            std::to_string(stock.rids.size()) + " resources, " + std::to_string(stock.chunks.size()) + " bundle and " + std::to_string(stock.toc_chunks.size()) + " TOC chunks)");
        checks.pass("C10");
    }
    checks.skip("C11", "determinism needs two builds: compare their .files.json, or build with --expect bike/pack-files.json");
    return checks.report();
}

int main(int argc, char** argv) { try {
    std::vector<std::string> args(argv+1, argv+argc);
    KeepNames keep;
    constexpr std::string_view keep_flag = "--keep-template-names=";
    std::erase_if(args, [&](const std::string& arg) {
        if (!arg.starts_with(keep_flag)) return false;
        keep = keep_names(std::string_view(arg).substr(keep_flag.size())); return true;
    });
    if (args.size() == 4 && args[0] == "--check-own-names")
        return check_own_names(fs::absolute(args[1]), fs::absolute(args[2]), fs::absolute(args[3]));
    if (args.size() == 4 && args[0] == "--extract-template") {
        const fs::path root = fs::absolute(args[1]), output = fs::absolute(args[2]), game = fs::absolute(args[3]);
        require(root != output && !fs::exists(output), "Template inspection needs a new separate output directory");
        auto layout = vfs::read_layout(root / "layout.toc"); vfs::GameArchives archives(root, layout.root);
        const auto toc = fb::read_toc(read(root / toc_path));
        require(toc.bundles.size() == 1, "Expected one native template bundle");
        const auto region = fb::read_bundle_region(toc.bundles[0].region);
        require(!region.files.empty(), "Template bundle is empty");
        const auto first = region.files[0];
        const auto bundle = archives.read_manifest(root, first.location, first.offset, first.size, game);
        const auto found = std::find_if(bundle.resources.begin(), bundle.resources.end(), [](const auto& item) { return item.name == drone_mesh_name; });
        require(found != bundle.resources.end(), "Private native mesh template is absent");
        const auto resource_index = static_cast<std::size_t>(found-bundle.resources.begin());
        const auto file = region.files.at(1+bundle.ebx.size()+resource_index);
        require(file.location.patch, "Template resource is not local");
        const auto resource = fb::decode_cas(archives.read(root,file.location,file.offset,file.size),{game});
        const auto mesh = fb::any_mesh_lod_geometry(resource,0);
        const auto chunk = std::find_if(bundle.chunks.begin(),bundle.chunks.end(),[&](const auto& item) { return item.guid == mesh.chunk; });
        require(chunk != bundle.chunks.end(), "Template geometry chunk is absent");
        const auto chunk_file = region.files.at(1+bundle.ebx.size()+bundle.resources.size()+static_cast<std::size_t>(chunk-bundle.chunks.begin()));
        require(chunk_file.location.patch, "Template geometry is not local");
        const auto geometry = fb::decode_cas(archives.read(root,chunk_file.location,chunk_file.offset,chunk_file.size),{game});
        require(fb::check_mesh_lod(resource,0,geometry).empty(), "Invalid original native mesh template");
        write(output/"native-template.mesh",resource); write(output/"native-template.geom",geometry);
        std::cout << "Validated native template declaration and geometry exported.\n";
        return 0;
    }
    require(args.size() == 4 || args.size() == 5,
        "Usage: builder [--keep-template-names=LIST] TEMPLATE PARTS OUTPUT SUPPORTED_GAME [TEXTURES]\n"
        "       builder --check-own-names PACK TEMPLATE SUPPORTED_GAME\n"
        "       builder --extract-template TEMPLATE OUTPUT SUPPORTED_GAME");
    std::optional<fs::path> textures;
    if (args.size() == 5) textures = fs::absolute(args[4]);
    return build(fs::absolute(args[0]), fs::absolute(args[1]), fs::absolute(args[2]), fs::absolute(args[3]), textures, keep);
} catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; } }
