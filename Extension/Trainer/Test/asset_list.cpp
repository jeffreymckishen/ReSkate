// Lists the data assets of the game's level root bundle, or the values of one of them.
//   dingosdk_trainer_asset_list <Skate folder> <word> [<word> ...]   names containing any word
//   dingosdk_trainer_asset_list <Skate folder> --dump <asset name>   every plain value, by name
#include "Engine/Resource/ebx_document.h"
#include "Engine/Vfs/game_bundles.h"
#include <algorithm>
#include <fstream>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <memory>
#include <string>
#include <variant>
#include <vector>

#pragma warning(disable : 4996) // std::getenv in a command line tool
namespace ebx = dingosdk::frostbite::ebx;
namespace {
std::string lower(std::string_view text) {
    std::string result(text);
    std::transform(result.begin(), result.end(), result.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return result;
}
std::size_t value_size(ebx::FieldType type) {
    switch (type) {
    case ebx::FieldType::boolean: case ebx::FieldType::int8: case ebx::FieldType::uint8: return 1;
    case ebx::FieldType::int16: case ebx::FieldType::uint16: return 2;
    case ebx::FieldType::int32: case ebx::FieldType::uint32: case ebx::FieldType::enumeration:
    case ebx::FieldType::float32: return 4;
    case ebx::FieldType::int64: case ebx::FieldType::uint64: case ebx::FieldType::float64: return 8;
    default: return 0;
    }
}
void walk(const ebx::Document &document, const ebx::TypeDescriptor &type, std::span<const std::byte> image, std::size_t start, int depth,
          const std::string &path) {
    if (depth > 16) return;
    for (std::size_t i = 0; i < type.fieldCount; ++i) {
        const auto index = static_cast<std::size_t>(type.fieldIndex) + i;
        if (index >= document.fields.size()) return;
        const auto &field = document.fields[index];
        const auto kind = field.type();
        const auto name = path.empty() ? field.name : field.name.empty() ? path : path + "." + field.name;
        if (kind == ebx::FieldType::inherited || (kind == ebx::FieldType::structure && field.category() != ebx::FieldCategory::array)) {
            if (field.classRef >= document.types.size()) continue;
            const bool inherited = kind == ebx::FieldType::inherited;
            walk(document, document.types[field.classRef], image, inherited ? start : start + field.dataOffset, depth + 1,
                 inherited ? path : name);
            continue;
        }
        const auto offset = start + field.dataOffset;
        if (field.category() == ebx::FieldCategory::array) {
            std::cout << name << "\t0x" << std::hex << offset << std::dec << "\tarray\n";
            continue;
        }
        if (kind == ebx::FieldType::pointer) {
            std::cout << name << "\t0x" << std::hex << offset << std::dec << "\tpointer\n";
            continue;
        }
        const auto size = value_size(kind);
        if (!size || offset + size > image.size()) continue;
        std::cout << name << "\t0x" << std::hex << offset << std::dec << '\t';
        if (kind == ebx::FieldType::float32) {
            float value;
            std::memcpy(&value, image.data() + offset, 4);
            std::cout << "real\t" << value;
        } else if (kind == ebx::FieldType::boolean) {
            std::cout << "flag\t" << static_cast<int>(image[offset]);
        } else {
            std::int64_t value{};
            std::memcpy(&value, image.data() + offset, size);
            std::cout << "int" << size * 8 << '\t' << value;
        }
        std::cout << '\n';
    }
}
void tree(const ebx::Value &value, int depth, const std::string &indent);
void tree(const ebx::Object &object, int depth, const std::string &indent) {
    for (const auto &field : object.fields) {
        std::cout << indent << (field.name.empty() ? "?" : field.name) << " = ";
        tree(field.value, depth, indent);
    }
}
void tree(const ebx::Value &value, int depth, const std::string &indent) {
    if (depth > 12) { std::cout << "...\n"; return; }
    if (const auto *b = std::get_if<bool>(&value.data)) std::cout << (*b ? "true" : "false") << '\n';
    else if (const auto *i = std::get_if<std::int64_t>(&value.data)) std::cout << *i << '\n';
    else if (const auto *u = std::get_if<std::uint64_t>(&value.data)) std::cout << *u << '\n';
    else if (const auto *d = std::get_if<double>(&value.data)) std::cout << *d << '\n';
    else if (const auto *s = std::get_if<std::string>(&value.data)) std::cout << '"' << *s << "\"\n";
    else if (const auto *r = std::get_if<ebx::PointerReference>(&value.data))
        std::cout << (r->kind == ebx::PointerKind::null ? "null" : r->kind == ebx::PointerKind::internal ? "-> instance " : "-> import ") << r->index << '\n';
    else if (const auto *x = std::get_if<ebx::BoxedReference>(&value.data)) std::cout << "boxed type 0x" << std::hex << x->encodedType << std::dec << " at " << x->dataOffset << '\n';
    else if (const auto *y = std::get_if<ebx::TypeReference>(&value.data)) std::cout << "type " << y->descriptor << " 0x" << std::hex << y->encoded << std::dec << '\n';
    else if (const auto *o = std::get_if<std::shared_ptr<ebx::Object>>(&value.data)) {
        std::cout << "{\n";
        if (*o) tree(**o, depth + 1, indent + "  ");
        std::cout << indent << "}\n";
    } else if (const auto *a = std::get_if<ebx::Value::Array>(&value.data)) {
        std::cout << "[" << a->size() << "]\n";
        std::size_t shown{};
        for (const auto &element : *a) {
            if (++shown > 40) { std::cout << indent << "  ...\n"; break; }
            std::cout << indent << "  - ";
            tree(element, depth + 1, indent + "    ");
        }
    } else std::cout << "(other)\n";
}
// These modes report identities only; presence in a manifest is not a store or residency check.
std::string metadata_text(std::string_view value) {
    std::string text;
    for (const auto c : value) {
        switch (c) {
        case '\\': text += "\\\\"; break;
        case '\t': text += "\\t"; break;
        case '\r': text += "\\r"; break;
        case '\n': text += "\\n"; break;
        default: text += c; break;
        }
    }
    return text;
}
std::string metadata_hex(std::span<const std::byte> bytes) {
    constexpr char digits[] = "0123456789abcdef";
    std::string text;
    for (const auto byte : bytes) {
        const auto value = std::to_integer<unsigned>(byte);
        text += digits[value >> 4];
        text += digits[value & 15];
    }
    return text;
}
void asset_metadata(const dingosdk::frostbite::BundleAsset &asset, bool has_location) {
    using dingosdk::frostbite::AssetKind;
    const auto kind = asset.kind == AssetKind::ebx ? "EBX" : asset.kind == AssetKind::resource ? "RES" : "CHUNK";
    std::cout << "ASSET\tkind=" << kind << "\tname=" << metadata_text(asset.name)
              << "\tsha1=" << metadata_hex(asset.sha1.bytes) << "\tsize=" << asset.originalSize
              << "\tpayload_location=" << (has_location ? "present" : "missing");
    if (asset.kind == AssetKind::resource)
        std::cout << "\tresource_type=0x" << std::hex << asset.resourceType << "\tresource_id=0x" << asset.resourceId << std::dec;
    else if (asset.kind == AssetKind::chunk)
        std::cout << "\tguid=" << asset.guid.string() << "\tlogical_offset=" << asset.logicalOffset << "\tlogical_size=" << asset.logicalSize;
    else std::cout << "\troot_type=not_decoded";
    std::cout << '\n';
}
int metadata_inventory(const dingosdk::vfs::GameBundle &bundle, const std::vector<std::string> &words) {
    std::size_t ebx_count{}, resource_count{}, chunk_count{}, missing{};
    const auto list = [&](const auto &assets, std::size_t &count) {
        for (std::size_t i = 0; i < assets.size(); ++i) {
            const auto &asset = assets[i];
            const auto name = lower(asset.name);
            if (!words.empty() && std::ranges::none_of(words, [&](const auto &word) { return name.find(word) != std::string::npos; })) continue;
            const bool present = bundle.payload(asset.kind, i) != nullptr;
            asset_metadata(asset, present);
            ++count;
            if (!present) ++missing;
        }
    };
    list(bundle.manifest.ebx, ebx_count);
    list(bundle.manifest.resources, resource_count);
    list(bundle.manifest.chunks, chunk_count);
    std::cout << "SUMMARY\tmode=metadata\tebx=" << ebx_count << "\tresources=" << resource_count << "\tchunks=" << chunk_count
              << "\tpayload_locations_missing=" << missing << "\tebx_decoded=0\tebx_decode_failed=0\tebx_not_decoded=" << ebx_count << '\n';
    return missing == 0 ? 0 : 1;
}
int inspect_asset(const dingosdk::vfs::GameData &data, const dingosdk::vfs::GameBundle &bundle, std::string_view wanted_name) {
    using dingosdk::frostbite::AssetKind;
    const auto wanted = lower(wanted_name);
    std::size_t selected{}, decoded{}, missing{}, read_failed{}, decode_failed{}, untyped{}, resource_locations_missing{};
    for (std::size_t i = 0; i < bundle.manifest.ebx.size(); ++i) {
        const auto &asset = bundle.manifest.ebx[i];
        if (lower(asset.name) != wanted) continue;
        ++selected;
        const auto *payload = bundle.payload(AssetKind::ebx, i);
        asset_metadata(asset, payload != nullptr);
        if (!payload) { ++missing; continue; }
        std::vector<std::byte> bytes;
        try {
            bytes = data.read(*payload);
        } catch (const std::exception &error) {
            ++read_failed;
            std::cout << "ERROR\tstage=payload_read\tname=" << metadata_text(asset.name) << "\tmessage=" << metadata_text(error.what()) << '\n';
            continue;
        }
        std::optional<ebx::Document> document;
        try {
            document = ebx::read_document(bytes);
        } catch (const std::exception &error) {
            ++decode_failed;
            std::cout << "ERROR\tstage=ebx_decode\tname=" << metadata_text(asset.name) << "\tmessage=" << metadata_text(error.what()) << '\n';
            continue;
        }
        ++decoded;
        if (document->rootType.empty()) ++untyped;
        std::cout << "EBX\tname=" << metadata_text(asset.name) << "\tfile_guid=" << document->fileGuid.string()
                  << "\troot_type=" << metadata_text(document->rootType) << "\tinstances=" << document->instances.size()
                  << "\timports=" << document->imports.size() << "\tresource_refs=" << document->resourceRefOffsets.size() << '\n';
        for (std::size_t n = 0; n < document->imports.size(); ++n) {
            const auto &import = document->imports[n];
            std::cout << "IMPORT\tindex=" << n << "\tfile_guid=" << import.fileGuid.string() << "\tclass_guid=" << import.classGuid.string() << '\n';
        }
        for (const auto &type : document->types) {
            // The reader leaves these zero when a reflection identity was not supplied.
            const bool has_identity = type.signature != 0 || std::ranges::any_of(type.guid.bytes, [](std::byte byte) { return byte != std::byte{}; });
            std::cout << "TYPE\tname=" << metadata_text(type.name) << "\tguid=" << type.guid.string()
                      << "\tsignature=0x" << std::hex << type.signature << std::dec
                      << "\tidentity=" << (has_identity ? "recorded" : "zero_or_unavailable") << '\n';
        }
        // EFIX records these slots relative to EBXD; no object walk or payload dump is needed.
        dingosdk::frostbite::BinaryReader reader(document->payload);
        for (const auto offset : document->resourceRefOffsets) {
            reader.seek(offset);
            const auto id = reader.u64();
            std::size_t local_matches{};
            for (std::size_t n = 0; n < bundle.manifest.resources.size(); ++n) {
                const auto &resource = bundle.manifest.resources[n];
                if (id == 0 || resource.resourceId != id) continue;
                ++local_matches;
                std::cout << "RESOURCE_MATCH\tref_offset=" << offset << "\tname=" << metadata_text(resource.name) << '\n';
                const bool has_location = bundle.payload(AssetKind::resource, n) != nullptr;
                asset_metadata(resource, has_location);
                if (!has_location) ++resource_locations_missing;
            }
            std::cout << "RESOURCE_REF\toffset=" << offset << "\tid=0x" << std::hex << id << std::dec
                      << "\tlocal_matches=" << local_matches << "\tresolution="
                      << (id == 0 ? "null" : local_matches ? "selected_bundle_manifest" : "external_or_missing") << '\n';
        }
    }
    std::cout << "SUMMARY\tmode=inspect\tselected=" << selected << "\tmissing_asset=" << (selected == 0 ? 1 : 0)
              << "\tebx_payload_location_missing=" << missing << "\tebx_read_failed=" << read_failed << "\tebx_decode_failed=" << decode_failed
              << "\tebx_decoded=" << decoded << "\tebx_untyped=" << untyped << "\tmatched_resource_locations_missing=" << resource_locations_missing
              << "\tsuccess_scope=ebx_decode\n";
    return selected != 0 && decoded == selected && untyped == 0 ? 0 : 1;
}
} // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: dingosdk_trainer_asset_list <Skate folder> <word>... | --dump <asset name> | --types <word>... | --metadata [word]... | --inspect <exact EBX name>\n";
        return 2;
    }
    try {
        const std::filesystem::path game_root(argv[1]);
        const dingosdk::vfs::GameData data(game_root);
        // ASSET_TOC / ASSET_BUNDLE: another superbundle and bundle than the level root; ASSET_BUNDLE=? lists the names.
        const auto *toc_name = std::getenv("ASSET_TOC");
        const auto *bundle_name = std::getenv("ASSET_BUNDLE");
        const auto toc = data.read_toc(toc_name ? toc_name : "Win32/levels/game/bam_levelroot/bam_levelroot.toc");
        if (bundle_name && std::string_view(bundle_name) == "?") {
            for (const auto &entry : toc.bundles) std::cout << entry.name << std::endl;
            return 0;
        }
        const auto found = data.read_bundle(toc, bundle_name ? bundle_name : "win32/levels/game/bam_levelroot/bam_levelroot");
        if (!found) throw std::runtime_error("the level root bundle was not found");
        const auto &bundle = *found;
        const std::string mode = argv[2];
        if (mode == "--metadata" || mode == "--inspect") {
            if (mode == "--inspect" && argc != 4) {
                std::cerr << "--inspect requires one exact EBX name\n";
                return 2;
            }
            std::cout << "CONTEXT\ttoc=" << metadata_text(toc_name ? toc_name : "Win32/levels/game/bam_levelroot/bam_levelroot.toc")
                      << "\tbundle=" << metadata_text(bundle_name ? bundle_name : "win32/levels/game/bam_levelroot/bam_levelroot")
                      << "\tstore_classification=unknown\tresidency=manifest_only\n";
            if (mode == "--inspect") return inspect_asset(data, bundle, argv[3]);
            std::vector<std::string> words;
            for (int i = 3; i < argc; ++i) words.push_back(lower(argv[i]));
            return metadata_inventory(bundle, words);
        }
        if (mode == "--floats" && argc >= 4) {
            // Every aligned four bytes of the asset's data that read as a plausible number.
            const auto wanted = lower(argv[3]);
            for (std::size_t i = 0; i < bundle.manifest.ebx.size(); ++i) {
                if (lower(bundle.manifest.ebx[i].name) != wanted) continue;
                const auto *payload = bundle.payload(dingosdk::frostbite::AssetKind::ebx, i);
                if (!payload) break;
                const auto bytes = data.read(*payload);
                const auto document = ebx::read_document(bytes);
                std::cerr << document.rootType << ": data " << document.dataStart << ".." << document.dataEnd << " of " << bytes.size() << "\n";
                for (std::size_t at = document.dataStart & ~std::size_t{3}; at + 4 <= bytes.size(); at += 4) {
                    float value;
                    std::memcpy(&value, bytes.data() + at, 4);
                    const float size = value < 0 ? -value : value;
                    if (size > 0.0009f && size < 100000.0f) std::cout << "0x" << std::hex << at << std::dec << "\t" << value << "\n";
                }
                return 0;
            }
            return 1;
        }
        if (mode == "--tree" && argc >= 4) {
            const auto wanted = lower(argv[3]);
            for (std::size_t i = 0; i < bundle.manifest.ebx.size(); ++i) {
                if (lower(bundle.manifest.ebx[i].name) != wanted) continue;
                const auto *payload = bundle.payload(dingosdk::frostbite::AssetKind::ebx, i);
                if (!payload) break;
                const auto bytes = data.read(*payload);
                const auto document = ebx::read_document(bytes);
                std::size_t number{};
                for (const auto &instance : document.instances) {
                    const auto type = instance.descriptor >= 0 && static_cast<std::size_t>(instance.descriptor) < document.types.size()
                        ? document.types[static_cast<std::size_t>(instance.descriptor)].name : std::string("?");
                    std::cout << "# instance " << number++ << " " << type << "\n";
                    if (instance.object) tree(*instance.object, 0, "  ");
                }
                number = 0;
                for (const auto &boxed : document.boxedValues) {
                    std::cout << "# boxed " << number++ << ": type 0x" << std::hex << boxed.encodedType << std::dec << " class " << boxed.classRef
                              << " count " << boxed.count << " offset " << boxed.offset << " bytes " << boxed.rawBytes.size() << " :";
                    for (std::size_t at = 0; at + 4 <= boxed.rawBytes.size() && at < 256; at += 4) {
                        float real; std::int32_t whole;
                        std::memcpy(&real, boxed.rawBytes.data() + at, 4);
                        std::memcpy(&whole, boxed.rawBytes.data() + at, 4);
                        const float size = real < 0 ? -real : real;
                        if (size > 0.0001f && size < 1.0e6f) std::cout << ' ' << real; else std::cout << " #" << whole;
                    }
                    std::cout << "\n";
                }
                for (const auto &import : document.imports) (void)import;
                std::cout << "# imports " << document.imports.size() << ", arrays " << document.arrays.size() << ", types";
                for (const auto &type : document.types) std::cout << ' ' << type.name;
                std::cout << "\n";
                return 0;
            }
            return 1;
        }
        if (mode == "--export" && argc >= 5) {
            // The raw bytes of every asset whose name contains a word, as <folder>/<number>.ebx,
            // with one line each: number, name, file id as hex, the ids it imports.
            const std::filesystem::path folder(argv[3]);
            std::filesystem::create_directories(folder);
            std::vector<std::string> wanted;
            for (int i = 4; i < argc; ++i) wanted.push_back(lower(argv[i]));
            const auto hex = [](const dingosdk::frostbite::Guid &guid) {
                static const char digits[] = "0123456789abcdef";
                std::string text;
                for (const auto byte : guid.bytes) {
                    text += digits[static_cast<unsigned>(byte) >> 4];
                    text += digits[static_cast<unsigned>(byte) & 15];
                }
                return text;
            };
            for (std::size_t i = 0; i < bundle.manifest.ebx.size(); ++i) {
                const auto name = lower(bundle.manifest.ebx[i].name);
                if (std::ranges::none_of(wanted, [&](const std::string &w) { return name.find(w) != std::string::npos; })) continue;
                try {
                    const auto *payload = bundle.payload(dingosdk::frostbite::AssetKind::ebx, i);
                    if (!payload) continue;
                    const auto bytes = data.read(*payload);
                    const auto document = ebx::read_document(bytes);
                    std::ofstream(folder / (std::to_string(i) + ".ebx"), std::ios::binary)
                        .write(reinterpret_cast<const char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
                    std::cout << i << '\t' << name << '\t' << hex(document.fileGuid) << '\t' << document.rootType << '\t';
                    for (const auto &import : document.imports) std::cout << hex(import.fileGuid) << ' ';
                    std::cout << '\n';
                } catch (const std::exception &) {}
            }
            return 0;
        }
        if (mode == "--dump" && argc >= 4) {
            const auto wanted = lower(argv[3]);
            for (std::size_t i = 0; i < bundle.manifest.ebx.size(); ++i) {
                if (lower(bundle.manifest.ebx[i].name) != wanted) continue;
                const auto *payload = bundle.payload(dingosdk::frostbite::AssetKind::ebx, i);
                if (!payload) break;
                const auto bytes = data.read(*payload);
                const auto document = ebx::read_document(bytes);
                std::cerr << bundle.manifest.ebx[i].name << ": root type " << document.rootType << ", " << document.instances.size()
                          << " instances\n";
                // Every instance: an asset keeps its lists and sub-objects as separate ones.
                std::size_t number{};
                for (const auto &instance : document.instances) {
                    if (instance.descriptor < 0 || static_cast<std::size_t>(instance.descriptor) >= document.types.size()) continue;
                    const auto &type = document.types[static_cast<std::size_t>(instance.descriptor)];
                    std::cout << "# instance " << number++ << " " << type.name << " (" << instance.rawImage.size() << " bytes)\n";
                    walk(document, type, instance.rawImage, 0, 0, {});
                }
                return 0;
            }
            std::cerr << "no such asset\n";
            return 1;
        }
        std::vector<std::string> words;
        for (int i = (mode == "--types" ? 3 : 2); i < argc; ++i) words.push_back(lower(argv[i]));
        std::size_t shown{};
        for (std::size_t i = 0; i < bundle.manifest.ebx.size(); ++i) {
            const auto name = lower(bundle.manifest.ebx[i].name);
            std::string type;
            bool match = mode != "--types" && std::ranges::any_of(words, [&](const std::string &w) { return name.find(w) != std::string::npos; });
            if (mode == "--types") {
                // Slower: opens every asset to learn its root type.
                try {
                    if (const auto *payload = bundle.payload(dingosdk::frostbite::AssetKind::ebx, i)) {
                        type = ebx::read_document(data.read(*payload)).rootType;
                        const auto low = lower(type);
                        match = std::ranges::any_of(words, [&](const std::string &w) { return low.find(w) != std::string::npos; });
                    }
                } catch (const std::exception &) {}
            }
            if (!match) continue;
            std::cout << bundle.manifest.ebx[i].name << (type.empty() ? "" : "\t" + type) << '\n';
            ++shown;
        }
        std::cerr << shown << " of " << bundle.manifest.ebx.size() << " assets\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "error: " << error.what() << '\n';
        return 1;
    }
}
