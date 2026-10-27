// Lists the data assets of the game's level root bundle, or the values of one of them.
//   dingosdk_trainer_asset_list <Skate folder> <word> [<word> ...]   names containing any word
//   dingosdk_trainer_asset_list <Skate folder> --dump <asset name>   every plain value, by name
#include "asset_chunk_locator.h"
#include "asset_chunk_locator_tests.h"
#include "asset_manhole_candidate.h"
#include "asset_manhole_candidate_tests.h"
#include "asset_manhole_position.h"
#include "asset_manhole_position_tests.h"
#include "asset_mesh_output.h"
#include "asset_mesh_output_tests.h"
#include "Engine/Core/Platform/path_text.h"
#include "Engine/Resource/cas_codec.h"
#include "Engine/Resource/ebx_document.h"
#include "Engine/Resource/mesh_set.h"
#include "Engine/Vfs/game_bundles.h"
#include <algorithm>
#include <cctype>
#include <limits>
#include <sstream>
#include <fstream>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <iomanip>
#include <optional>
#include <stdexcept>
#include <memory>
#include <string>
#include <variant>
#include <vector>

#pragma warning(disable : 4996) // std::getenv in a command line tool
namespace ebx = dingosdk::frostbite::ebx;
namespace {
using dingosdk::trainer::asset_tools::ManholeInspectionProgress;
using dingosdk::trainer::asset_tools::MeshMetadataOutput;

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
bool mesh_metadata_lod(std::string_view text, std::size_t& value) {
    if (text.empty()) return false;
    value = 0;
    for (const unsigned char byte : text) {
        if (byte < '0' || byte > '9') return false;
        const auto digit = static_cast<std::size_t>(byte - '0');
        if (value > (std::numeric_limits<std::size_t>::max() - digit) / 10) return false;
        value = value * 10 + digit;
    }
    return true;
}
bool mesh_metadata_name(std::string_view left, std::string_view right) {
    if (left.size() != right.size()) return false;
    for (std::size_t i = 0; i < left.size(); ++i)
        if (std::tolower(static_cast<unsigned char>(left[i])) != std::tolower(static_cast<unsigned char>(right[i]))) return false;
    return true;
}

void mesh_metadata_rows(MeshMetadataOutput& out, const dingosdk::frostbite::MeshLodMetadata& mesh) {
    if (mesh.lod_kind_supported) {
        out.record("LOD\tlayout=", mesh.skinned ? "skinned" : "static", "\tcount=", mesh.lod_count,
                   "\tindex=", mesh.lod_index, "\tresource_offset=", mesh.lod_offset, "\tkind_raw=", mesh.lod_kind,
                   "\tkind_supported=1\tindex_format_raw=", mesh.index_format, "\tindex_width=", mesh.index_format == 33 ? "2" : "unknown",
                   "\tvertex_bytes=", mesh.geometry.vertex_bytes, "\tindex_bytes=", mesh.geometry.index_bytes,
                   "\tchunk_guid=", mesh.geometry.chunk.string(), "\tsection_count=", mesh.section_count,
                   "\tsection_table_offset=", mesh.section_table, "\tstride_ambiguous=", mesh.ambiguous ? 1 : 0,
                   "\tparser_complete=", mesh.complete ? 1 : 0);
    } else {
        // Later fields have not been interpreted for this LOD kind; zero-initialized members are not observations.
        out.record("LOD\tlayout=", mesh.skinned ? "skinned" : "static", "\tcount=", mesh.lod_count,
                   "\tindex=", mesh.lod_index, "\tresource_offset=", mesh.lod_offset, "\tkind_raw=", mesh.lod_kind,
                   "\tkind_supported=0\tparser_complete=0\tinterpretation=unsupported_lod_kind");
    }
    for (const auto& diagnostic : mesh.diagnostics) {
        if (!out.open()) break;
        out.record("DIAGNOSTIC\tscope=lod\tmessage=", out.text(diagnostic));
    }
    if (!mesh.lod_kind_supported) {
        if (mesh.static_common_offsets) {
            const auto& observed = *mesh.static_common_offsets;
            out.record("STATIC_COMMON_OFFSET\tlod_relative_offset=8\tresource_offset=", mesh.lod_offset + 8,
                       "\twidth=4\traw_value=", observed.section_count_raw, "\tcandidate_role=section_count",
                       "\tbasis=existing_static_reader\tinterpretation=unverified_common_layout");
            out.record("STATIC_COMMON_OFFSET\tlod_relative_offset=12\tresource_offset=", mesh.lod_offset + 12,
                       "\twidth=8\traw_value=", observed.section_pointer_raw, "\tcandidate_role=section_pointer",
                       "\tbasis=existing_static_reader\tinterpretation=unverified_common_layout");
            out.record("STATIC_COMMON_OFFSET\tlod_relative_offset=84\tresource_offset=", mesh.lod_offset + 84,
                       "\twidth=4\traw_value=", observed.index_format_raw, "\tcandidate_role=index_format",
                       "\tbasis=existing_static_reader\tinterpretation=unverified_common_layout");
            out.record("STATIC_COMMON_OFFSET\tlod_relative_offset=88\tresource_offset=", mesh.lod_offset + 88,
                       "\twidth=4\traw_value=", observed.index_bytes_raw, "\tcandidate_role=index_bytes",
                       "\tbasis=existing_static_reader\tinterpretation=unverified_common_layout");
            out.record("STATIC_COMMON_OFFSET\tlod_relative_offset=92\tresource_offset=", mesh.lod_offset + 92,
                       "\twidth=4\traw_value=", observed.vertex_bytes_raw, "\tcandidate_role=vertex_bytes",
                       "\tbasis=existing_static_reader\tinterpretation=unverified_common_layout");
            out.record("STATIC_COMMON_OFFSET\tlod_relative_offset=116\tresource_offset=", mesh.lod_offset + 116,
                       "\twidth=16\traw_bytes_hex=", metadata_hex(observed.geometry_identity_raw), "\tcandidate_role=geometry_identity",
                       "\tbasis=existing_static_reader\tinterpretation=unverified_common_layout");
            out.record("STATIC_SECTION_LIMITS\tsection_count_limit=64\tcombined_candidate_span_bytes_limit=32768"
                       "\telement_count_limit=16\tstream_count_limit=16\tdiagnostics_per_candidate_limit=16\tlimits_provenance=authored");
            for (std::size_t candidate_index = 0; candidate_index < mesh.static_section_candidates.size() && out.open(); ++candidate_index) {
                const auto& candidate = mesh.static_section_candidates[candidate_index];
                const bool diagnostics_truncated = candidate.diagnostic_count > candidate.diagnostics.size();
                if (diagnostics_truncated) out.mark_truncated();
                out.record("STATIC_SECTION_CANDIDATE\tindex=", candidate_index, "\tsection_stride=", candidate.stride,
                           "\ttable_pointer_resolved=", candidate.table_pointer_resolved ? 1 : 0,
                           candidate.table_pointer_resolved ? "\ttable_offset=" + std::to_string(candidate.table_offset) : std::string{},
                           "\ttable_span_valid=", candidate.table_span_valid ? 1 : 0,
                           "\tcandidate_span_bytes_available=", candidate.table_span_valid ? 1 : 0,
                           candidate.table_span_valid ? "\tcandidate_span_bytes=" + std::to_string(candidate.span_bytes) : std::string{},
                           "\tobservation_complete=", candidate.observation_complete ? 1 : 0,
                           "\tsections_reported=", candidate.sections.size(), "\tdiagnostic_count=", candidate.diagnostic_count,
                           "\tdiagnostics_truncated=", diagnostics_truncated ? 1 : 0,
                           "\tbasis=existing_mesh_reader_offsets\tinterpretation=unverified_static_section_layout");
                for (const auto& diagnostic : candidate.diagnostics) {
                    if (!out.open()) break;
                    out.record("DIAGNOSTIC\tscope=static_section_candidate\tcandidate=", candidate_index,
                               "\tmessage=", out.text(diagnostic));
                }
                for (std::size_t section_index = 0; section_index < candidate.sections.size() && out.open(); ++section_index) {
                    const auto& section = candidate.sections[section_index];
                    out.record("STATIC_SECTION_RAW\tcandidate=", candidate_index, "\tindex=", section_index,
                               "\tresource_offset=", section.resource_offset,
                               "\tprimitive_relative_offset=31\tprimitive_raw=", static_cast<unsigned>(section.primitive_raw),
                               "\ttriangle_count_relative_offset=32\ttriangle_count_raw=", section.triangle_count_raw,
                               "\tfirst_index_relative_offset=36\tfirst_index_raw=", section.first_index_raw,
                               "\tvertex_start_relative_offset=40\tvertex_start_raw=", section.vertex_start_raw,
                               "\tvertex_count_relative_offset=44\tvertex_count_raw=", section.vertex_count_raw,
                               "\telement_count_relative_offset=208\telement_count_raw=", static_cast<unsigned>(section.element_count_raw),
                               "\tstream_count_relative_offset=209\tstream_count_raw=", static_cast<unsigned>(section.stream_count_raw),
                               "\tdeclarations_observed=", section.declarations_observed ? 1 : 0,
                               "\tbasis=existing_mesh_reader_offsets\tinterpretation=unverified_static_section_layout");
                    for (std::size_t element_index = 0; element_index < section.elements.size() && out.open(); ++element_index) {
                        const auto& element = section.elements[element_index];
                        const auto relative_offset = 112 + 4 * element_index;
                        out.record("STATIC_ELEMENT_RAW\tcandidate=", candidate_index, "\tsection=", section_index, "\tindex=", element_index,
                                   "\tsection_relative_offset=", relative_offset, "\tresource_offset=", section.resource_offset + relative_offset,
                                   "\tusage_raw=", static_cast<unsigned>(element.usage_raw), "\tformat_raw=", static_cast<unsigned>(element.format_raw),
                                   "\toffset_raw=", static_cast<unsigned>(element.offset_raw), "\tstream_raw=", static_cast<unsigned>(element.stream_raw),
                                   "\tbasis=existing_mesh_reader_offsets\tinterpretation=unverified_static_section_layout");
                    }
                    for (std::size_t stream_index = 0; stream_index < section.streams.size() && out.open(); ++stream_index) {
                        const auto& stream = section.streams[stream_index];
                        const auto relative_offset = 176 + 2 * stream_index;
                        out.record("STATIC_STREAM_RAW\tcandidate=", candidate_index, "\tsection=", section_index, "\tindex=", stream_index,
                                   "\tsection_relative_offset=", relative_offset, "\tresource_offset=", section.resource_offset + relative_offset,
                                   "\tstride_raw=", static_cast<unsigned>(stream.stride_raw), "\tclassification_raw=", static_cast<unsigned>(stream.classification_raw),
                                   "\tbasis=existing_mesh_reader_offsets\tinterpretation=unverified_static_section_layout");
                    }
                }
            }
        }
        return;
    }
    for (std::size_t candidate_index = 0; candidate_index < mesh.candidates.size() && out.open(); ++candidate_index) {
        const auto& candidate = mesh.candidates[candidate_index];
        if (candidate.diagnostic_count > candidate.diagnostics.size()) out.mark_truncated();
        out.record("CANDIDATE\tindex=", candidate_index, "\tsection_stride=", candidate.stride,
                   "\tstructurally_valid=", candidate.structurally_valid ? 1 : 0,
                   "\tdeclarations_supported=", candidate.declarations_supported ? 1 : 0,
                   "\tsections_reported=", candidate.sections.size(), "\tdiagnostic_count=", candidate.diagnostic_count,
                   "\tdiagnostics_truncated=", candidate.diagnostic_count > candidate.diagnostics.size() ? 1 : 0);
        for (const auto& diagnostic : candidate.diagnostics) {
            if (!out.open()) break;
            out.record("DIAGNOSTIC\tcandidate=", candidate_index, "\tmessage=", out.text(diagnostic));
        }
        for (std::size_t section_index = 0; section_index < candidate.sections.size() && out.open(); ++section_index) {
            const auto& section = candidate.sections[section_index];
            out.record("SECTION\tcandidate=", candidate_index, "\tindex=", section_index,
                       "\tresource_offset=", section.resource_offset, "\tprimitive_raw=", static_cast<unsigned>(section.primitive),
                       "\ttriangles=", section.triangle_count, "\tfirst_index=", section.first_index,
                       "\tvertex_start=", section.vertex_start, "\tvertex_count=", section.vertex_count,
                       "\telement_count=", static_cast<unsigned>(section.element_count),
                       "\tstream_count=", static_cast<unsigned>(section.stream_count),
                       "\tvertex_range_checked=", section.vertex_range_checked ? 1 : 0,
                       "\tindex_range_checked=", section.index_range_checked ? 1 : 0);
            for (std::size_t element_index = 0; element_index < section.elements.size() && out.open(); ++element_index) {
                const auto& element = section.elements[element_index];
                out.record("ELEMENT\tcandidate=", candidate_index, "\tsection=", section_index, "\tindex=", element_index,
                           "\tusage_raw=", static_cast<unsigned>(element.usage), "\tformat_raw=", static_cast<unsigned>(element.format),
                           "\toffset=", static_cast<unsigned>(element.offset), "\tstream=", static_cast<unsigned>(element.stream),
                           "\tknown_width=", static_cast<unsigned>(element.width), "\tsemantic_supported=", element.semantic_supported ? 1 : 0);
            }
            for (std::size_t stream_index = 0; stream_index < section.streams.size() && out.open(); ++stream_index) {
                const auto& stream = section.streams[stream_index];
                out.record("STREAM\tcandidate=", candidate_index, "\tsection=", section_index, "\tindex=", stream_index,
                           "\tstride=", static_cast<unsigned>(stream.stride),
                           "\tclassification_raw=", static_cast<unsigned>(stream.classification));
            }
        }
    }
}

void mesh_chunk_location_rows(MeshMetadataOutput& out, const dingosdk::frostbite::Guid& candidate,
                              const dingosdk::trainer::asset_tools::ChunkLocationLookup& lookup) {
    using dingosdk::trainer::asset_tools::ChunkLocationScope;
    if (lookup.omitted) out.mark_truncated();
    out.record("STATIC_GEOMETRY_LOCATION_CANDIDATE\traw_bytes_hex=", metadata_hex(candidate.bytes),
               "\tcandidate_guid_text=", candidate.string(), "\tcomparison=normalized_guid_full16bytes",
               "\tbundle_matches=", lookup.bundle_matches, "\ttoc_matches=", lookup.toc_matches,
               "\tremoved_matches=", lookup.removed_matches, "\tzero_identity=", lookup.zero_identity ? 1 : 0,
               "\tduplicate_identity=", lookup.duplicate ? 1 : 0, "\tconflicting_locations=", lookup.conflict ? 1 : 0,
               "\tlocation_resolved=", lookup.resolved ? 1 : 0, "\trefusal=", lookup.refusal,
               "\tmatch_records_retained=", lookup.retained, "\tmatch_records_omitted=", lookup.omitted,
               "\tmatch_record_limit=16\tlimits_provenance=authored\tidentity_interpretation=unverified",
               "\tfile_bounds_verified=0\tgeometry_payload_read=0");
    for (std::size_t i = 0; i < lookup.retained && out.open(); ++i) {
        const auto& observation = lookup.observations[i];
        out.record("STATIC_GEOMETRY_LOCATION_MATCH\tscope=",
                   observation.scope == ChunkLocationScope::bundle ? "selected_bundle" : "selected_toc",
                   "\tindex=", observation.index, "\tremoved=", observation.removed ? 1 : 0,
                   "\tpayload_location_present=", observation.payload_present ? 1 : 0,
                   "\tnonempty_range=", observation.range_valid ? 1 : 0,
                   observation.payload_present ? "\tpatch=" + std::to_string(observation.payload.location.patch ? 1 : 0) : std::string{},
                   observation.payload_present ? "\tinstall_chunk=" + std::to_string(observation.payload.location.installChunk) : std::string{},
                   observation.payload_present ? "\tarchive=" + std::to_string(observation.payload.location.archive) : std::string{},
                   observation.payload_present ? "\toffset=" + std::to_string(observation.payload.offset) : std::string{},
                   observation.payload_present ? "\tcompressed_bytes=" + std::to_string(observation.payload.size) : std::string{},
                   observation.range_valid ? "\trange_end=" + std::to_string(observation.range_end) : std::string{},
                   "\tfile_bounds_verified=0\tgeometry_payload_read=0");
    }
}

void bounded_archive_rows(MeshMetadataOutput& out, std::string_view role,
                          const dingosdk::frostbite::BundleFileInfo& payload,
                          const dingosdk::vfs::BoundedArchiveRead& read) {
    out.record("BOUNDED_ARCHIVE_READ\trole=", role, "\tpath=", out.text(dingosdk::path_utf8(read.path)),
               "\tpatch=", payload.location.patch ? 1 : 0, "\tinstall_chunk=", payload.location.installChunk,
               "\tarchive=", payload.location.archive, "\toffset=", payload.offset,
               "\tcompressed_bytes=", read.encoded.size(), "\tarchive_bytes=", read.archive_size,
               "\tvolume_serial=", read.volume_serial, "\tfile_index=", read.file_index,
               "\tlast_write_time_raw=", read.last_write_time,
               "\tdirectory_binding=unique_explicit\tphysical_range_checked=1\tsame_file_rechecked=1"
               "\tcontent_identity_authenticated=0");
}

void position_half_lane_row(MeshMetadataOutput& out, std::string_view role, std::string_view section,
                            std::string_view component, const dingosdk::trainer::asset_tools::HalfLaneSummary& lane) {
    out.record("HALF_LANES\trole=", role, "\tsection=", section, "\tcomponent=", component,
               "\ttotal=", lane.total, "\tfinite=", lane.finite, "\trefused_nonfinite=", lane.refused,
               "\tpositive_zero=", lane.positive_zero, "\tnegative_zero=", lane.negative_zero,
               "\tsubnormal=", lane.subnormal, "\tnormal=", lane.normal,
               "\tpositive_infinity=", lane.positive_infinity, "\tnegative_infinity=", lane.negative_infinity,
               "\tnan=", lane.nan, "\tclassification_basis=raw_binary16_hypothesis");
}

void manhole_position_rows(MeshMetadataOutput& out,
                           const dingosdk::trainer::asset_tools::ManholePositionInspection& inspection) {
    const auto& indices = inspection.indices;
    out.record("INDEX_INSPECTION\tinspected=", indices.inspected ? 1 : 0, "\tconsistent=", indices.consistent ? 1 : 0,
               "\trefusal=", indices.refusal, "\tvalues_checked=", indices.total_count,
               "\toutside_count=", indices.outside_count, "\tinterpretation=unverified_uint16_le_triangle_indices");
    out.record("POSITION_INSPECTION\tinspected=", inspection.inspected ? 1 : 0, "\trefusal=", inspection.refusal,
               "\tgeometry_qualification=unverified\tfourth_lane_interpretation=unverified");
    if (!inspection.inspected) return;
    position_half_lane_row(out, "xyz", "all", "all", inspection.xyz_lanes);
    position_half_lane_row(out, "fourth_uninterpreted", "all", "3", inspection.fourth_lanes);
    for (std::size_t i = 0; i < inspection.sections.size(); ++i) {
        const auto& section = inspection.sections[i];
        for (std::size_t component = 0; component < section.components.size(); ++component) {
            const auto& lane = section.components[component];
            position_half_lane_row(out, component == 3 ? "fourth_uninterpreted" : "xyz", std::to_string(i),
                                   std::to_string(component), lane);
            // Numeric fourth-lane values never contribute to geometry or acquire a meaning in the report.
            if (component < 3 && lane.extrema_available)
                out.record(std::setprecision(std::numeric_limits<double>::max_digits10),
                           "HALF_FINITE_RANGE\tsection=", i, "\tcomponent=", component,
                           "\ttotal=", lane.total, "\teligible_finite=", lane.finite, "\trefused_nonfinite=", lane.refused,
                           "\tcoverage_complete=", lane.refused == 0 ? 1 : 0,
                           "\tminimum=", lane.minimum, "\tmaximum=", lane.maximum, "\tbasis=binary16_hypothesis_only");
        }
        const auto& vertices = section.vertices;
        out.record("POSITION_VERTICES\tsection=", i, "\ttotal=", vertices.total, "\teligible_finite_xyz=", vertices.eligible,
                   "\trefused_nonfinite_xyz=", vertices.refused, "\tcoverage_complete=", vertices.complete() ? 1 : 0,
                   "\taabb_available=", section.aabb.available ? 1 : 0);
        if (section.aabb.available)
            out.record(std::setprecision(std::numeric_limits<double>::max_digits10),
                       "POSITION_AABB\tsection=", i, "\ttotal=", vertices.total, "\teligible_finite_xyz=", vertices.eligible,
                       "\trefused_nonfinite_xyz=", vertices.refused, "\tcoverage_complete=", vertices.complete() ? 1 : 0,
                       "\tminimum_x=", section.aabb.minimum[0], "\tminimum_y=", section.aabb.minimum[1],
                       "\tminimum_z=", section.aabb.minimum[2], "\tmaximum_x=", section.aabb.maximum[0],
                       "\tmaximum_y=", section.aabb.maximum[1], "\tmaximum_z=", section.aabb.maximum[2],
                       "\tunits_and_axes=unverified");
        const auto& triangles = section.triangles;
        const auto& coverage = triangles.coverage;
        out.record("POSITION_TRIANGLES\tsection=", i, "\ttotal=", coverage.total,
                   "\teligible_finite_xyz=", coverage.eligible, "\trefused_nonfinite_xyz=", coverage.refused,
                   "\tcoverage_complete=", coverage.complete() ? 1 : 0,
                   "\tnumerical_range_available=", triangles.extrema_available ? 1 : 0);
        if (triangles.extrema_available)
            out.record(std::setprecision(std::numeric_limits<double>::max_digits10),
                       "POSITION_TRIANGLE_NUMERICS\tsection=", i, "\ttotal=", coverage.total,
                       "\teligible_finite_xyz=", coverage.eligible, "\trefused_nonfinite_xyz=", coverage.refused,
                       "\tcoverage_complete=", coverage.complete() ? 1 : 0,
                       "\teligible_numerical_zero_cross_count=", triangles.numerical_zero_count,
                       "\teligible_cross_length_squared_minimum=", triangles.minimum_cross_squared,
                       "\teligible_cross_length_squared_maximum=", triangles.maximum_cross_squared,
                       "\tzero_rule=all_three_double_cross_components_equal_zero\tepsilon=none");
    }
    const auto& xyz = inspection.xyz_overlap;
    out.record("XYZ_OVERLAP_COVERAGE\tavailable=", xyz.available ? 1 : 0,
               "\tsection0_total=", xyz.coverage[0].total, "\tsection0_eligible=", xyz.coverage[0].eligible,
               "\tsection0_refused=", xyz.coverage[0].refused, "\tsection1_total=", xyz.coverage[1].total,
               "\tsection1_eligible=", xyz.coverage[1].eligible, "\tsection1_refused=", xyz.coverage[1].refused,
               "\tkey=raw_unsigned_u16_le_xyz\tsigned_zero_keys=distinct\tfourth_lane_in_key=0");
    if (xyz.available)
        out.record("XYZ_OVERLAP_MATCHES\tsection0_total=", xyz.coverage[0].total,
                   "\tsection0_eligible=", xyz.coverage[0].eligible, "\tsection0_refused=", xyz.coverage[0].refused,
                   "\tsection1_total=", xyz.coverage[1].total, "\tsection1_eligible=", xyz.coverage[1].eligible,
                   "\tsection1_refused=", xyz.coverage[1].refused,
                   "\tsection0_records_present_in_section1=", xyz.directional_matches[0],
                   "\tsection1_records_present_in_section0=", xyz.directional_matches[1],
                   "\tmultiset_intersection=", xyz.multiset_matches, "\tsemantic_interpretation=unverified");
    const auto& triangles = inspection.triangle_overlap;
    out.record("TRIANGLE_OVERLAP_COVERAGE\tavailable=", triangles.available ? 1 : 0,
               "\tsection0_total=", triangles.coverage[0].total, "\tsection0_eligible=", triangles.coverage[0].eligible,
               "\tsection0_refused=", triangles.coverage[0].refused, "\tsection1_total=", triangles.coverage[1].total,
               "\tsection1_eligible=", triangles.coverage[1].eligible, "\tsection1_refused=", triangles.coverage[1].refused,
               "\tkey=minimum_cyclic_rotation_of_raw_xyz_keys\treversed_winding_merged=0"
               "\tdegenerates_included=1\tdegenerate_winding=uninformative\tsigned_zero_keys=distinct");
    if (triangles.available)
        out.record("TRIANGLE_OVERLAP_MATCHES\tsection0_total=", triangles.coverage[0].total,
                   "\tsection0_eligible=", triangles.coverage[0].eligible, "\tsection0_refused=", triangles.coverage[0].refused,
                   "\tsection1_total=", triangles.coverage[1].total, "\tsection1_eligible=", triangles.coverage[1].eligible,
                   "\tsection1_refused=", triangles.coverage[1].refused,
                   "\tmultiset_intersection=", triangles.multiset_matches,
                   "\tsection0_unmatched=", triangles.coverage[0].eligible - triangles.multiset_matches,
                   "\tsection1_unmatched=", triangles.coverage[1].eligible - triangles.multiset_matches,
                   "\tsemantic_interpretation=unverified");
}

int manhole_candidate_command(int argc, char** argv, bool position_hypothesis = false) {
    using namespace dingosdk::frostbite;
    using namespace dingosdk::trainer::asset_tools;
    MeshMetadataOutput out;
    ManholeInspectionProgress progress;
    const auto mode = position_hypothesis ? ManholeCandidateMode::position_hypothesis : ManholeCandidateMode::indices;
    const auto finish = [&](int failure_code = 1) { return out.finish_candidate(progress, failure_code, mode); };
    if (argc != 3 || std::string_view(argv[1]).empty() || std::string_view(argv[1]).size() > 4096) {
        out.record("ERROR\tstage=arguments\tmessage=expected one game folder and ",
                   position_hypothesis ? "--inspect-manhole-position-candidate" : "--inspect-manhole-candidate");
        return finish(2);
    }
    std::string_view stage = "context";
    try {
        const auto* toc_environment = std::getenv("ASSET_TOC");
        const auto* bundle_environment = std::getenv("ASSET_BUNDLE");
        if ((toc_environment && std::string_view(toc_environment) != manhole_toc_name) ||
            (bundle_environment && std::string_view(bundle_environment) != manhole_bundle_name)) {
            out.record("ERROR\tstage=arguments\tmessage=this inspection requires its pinned TOC and bundle");
            return finish(2);
        }
        out.record("CONTEXT\tmode=", position_hypothesis ? "manhole-position-candidate" : "manhole-candidate",
                   "\ttoc=", manhole_toc_name, "\tbundle=", manhole_bundle_name,
                   "\texact_res_name=", manhole_resource_name, "\tlod=0\tcontract=manhole03_dc8d_capture",
                   "\tmaximum_encoded_bytes=", manhole_encoded_limit, "\tmaximum_decoded_bytes=", manhole_decoded_size,
                   "\tmaximum_resource_decoded_bytes=", manhole_resource_decoded_size,
                   "\tmaximum_oodle_destination_bytes=", manhole_oodle_buffer_limit,
                   "\tlimits_provenance=authored\tmetadata_loading_policy=existing_GameData"
                   "\tlibrary_workspace_limit=not_claimed\ttotal_heap_limit=not_claimed"
                   "\tstore_classification=unknown\tsemantic_qualification=unverified");
        if (position_hypothesis) {
            // Reference declarations and consumers describe this immutable release, not this game's profile binding.
            // https://github.com/CadeEvs/FrostyToolsuite/tree/e400dcb283ad743071263ea7b34ff86780ffe910
            out.record("POSITION_HYPOTHESIS_REFERENCE\treference_release=v1.0.6.3"
                       "\treference_commit=e400dcb283ad743071263ea7b34ff86780ffe910"
                       "\tdeclarations=FrostySdk/Utils.cs\tserialized_reader=Plugins/MeshSetPlugin/Resources/MeshSet.cs"
                       "\tconsumer=Plugins/MeshSetPlugin/FrostyMeshSetEditor.cs\tbasis_reference=Shaders/UnpackNormals.hlsl"
                       "\tgame_enum_and_profile_binding=unverified\tstorage_hypothesis=little_endian_binary16_xyz_in_stride8"
                       "\tfourth_lane_interpretation=unverified\tuv_and_basis_inspected=0"
                       "\toutput_bytes_limit=", MeshMetadataOutput::maximum_bytes, "\toutput_limit_includes_summary=1");
        }
        const std::filesystem::path game_root(argv[1]);
        const dingosdk::vfs::GameData data(game_root);
        stage = "bundle_read";
        const auto toc = data.read_toc(manhole_toc_name);
        const auto found = data.read_bundle(toc, manhole_bundle_name);
        if (!found) throw std::runtime_error("pinned bundle was not found");
        const auto& bundle = *found;
        std::size_t matches{}, resource_index{};
        for (std::size_t i = 0; i < bundle.manifest.resources.size(); ++i)
            if (bundle.manifest.resources[i].name == manhole_resource_name) { ++matches; resource_index = i; }
        if (matches != 1) throw std::runtime_error("pinned resource is absent or ambiguous");
        const auto& resource = bundle.manifest.resources[resource_index];
        const auto resource_admission = manhole_resource_gate(resource);
        if (!resource_admission.accepted) throw std::runtime_error(resource_admission.refusal);
        const auto* resource_payload = bundle.payload(AssetKind::resource, resource_index);
        // The resource's compressed length is also an observation from the same sealed capture.
        if (!resource_payload || resource_payload->size != 796 || resource_payload->location.patch)
            throw std::runtime_error("resource_location_metadata_changed");
        out.record("RESOURCE_BINDING\tresource_id=", resource.resourceId, "\tmanifest_sha1=", metadata_hex(resource.sha1.bytes),
                   "\tmanifest_hash_matched=1\tpayload_hash_verified=0\tcompressed_bytes=", resource_payload->size);
        if (!out.open()) return finish();
        stage = "resource_read";
        progress.resource_read_attempted = true;
        const auto encoded_resource = data.read_encoded_bounded(*resource_payload, manhole_encoded_limit);
        progress.resource_read_complete = true;
        bounded_archive_rows(out, "mesh_resource", *resource_payload, encoded_resource);
        stage = "resource_decode";
        const auto resource_bytes = decode_cas(encoded_resource.encoded,
            {game_root, manhole_resource_decoded_size, manhole_oodle_buffer_limit});
        progress.resource_decode_complete = true;
        if (resource_bytes.size() != manhole_resource_decoded_size) throw std::runtime_error("resource_decoded_size_changed");
        stage = "candidate_admission";
        const auto mesh = read_mesh_lod_metadata(resource_bytes, 0);
        if (!mesh.static_common_offsets) throw std::runtime_error("static_common_observations_unavailable");
        Guid candidate;
        candidate.bytes = mesh.static_common_offsets->geometry_identity_raw;
        const auto lookup = locate_chunk_candidate(candidate, bundle, toc);
        const auto admission = manhole_candidate_gate(mesh, lookup);
        out.record("CANDIDATE_ADMISSION\taccepted_for_inspection=", admission.accepted ? 1 : 0,
                   "\trefusal=", admission.refusal, "\traw_identity_hex=", metadata_hex(candidate.bytes),
                   "\tbundle_matches=", lookup.bundle_matches, "\ttoc_matches=", lookup.toc_matches,
                   "\tremoved_matches=", lookup.removed_matches, "\tduplicate_identity=", lookup.duplicate ? 1 : 0,
                   "\tconflicting_locations=", lookup.conflict ? 1 : 0,
                   "\tlod_kind_supported=", mesh.lod_kind_supported ? 1 : 0,
                   "\tidentity_interpretation=unverified");
        if (!admission.accepted || !out.open()) return finish();
        const auto& geometry_payload = lookup.observations[0].payload;
        stage = "geometry_read";
        progress.geometry_read_attempted = true;
        const auto encoded_geometry = data.read_encoded_bounded(geometry_payload, manhole_encoded_limit);
        progress.geometry_read_complete = true;
        bounded_archive_rows(out, "geometry_candidate", geometry_payload, encoded_geometry);
        stage = "geometry_decode";
        const auto decoded = decode_cas(encoded_geometry.encoded,
            {game_root, manhole_decoded_size, manhole_oodle_buffer_limit});
        progress.geometry_decode_complete = true;
        if (position_hypothesis) {
            out.record("POSITION_CANDIDATE_DECODE\tdecoded_bytes=", decoded.size(), "\tauthored_expected_bytes=", manhole_decoded_size,
                       "\tvertex_format_qualified=0\tsemantic_qualification=unverified");
            stage = "candidate_position_hypothesis";
            const auto inspection = inspect_manhole_position_candidate(decoded);
            progress.inspection_complete = inspection.inspected;
            progress.indices_consistent = inspection.indices.consistent;
            manhole_position_rows(out, inspection);
            return finish();
        }
        out.record("CANDIDATE_DECODE\tdecoded_bytes=", decoded.size(), "\tauthored_expected_bytes=", manhole_decoded_size,
                   "\tvertex_fields_interpreted=0\tsemantic_qualification=unverified");
        stage = "candidate_indices";
        const auto inspection = inspect_manhole_candidate_indices(decoded);
        progress.inspection_complete = inspection.inspected;
        progress.indices_consistent = inspection.consistent;
        out.record("INDEX_INSPECTION\tinspected=", inspection.inspected ? 1 : 0,
                   "\tconsistent=", inspection.consistent ? 1 : 0, "\trefusal=", inspection.refusal,
                   "\tvalues_checked=", inspection.total_count, "\toutside_count=", inspection.outside_count,
                   "\tbad_records_retained=", inspection.retained, "\tbad_records_omitted=", inspection.omitted,
                   "\tinterpretation=unverified_uint16_le_triangle_indices");
        if (inspection.inspected) {
            for (const auto& window : manhole_windows)
                out.record("AUTHORED_WINDOW\tname=", window.name, "\tbegin=", window.begin, "\tend_exclusive=", window.end,
                           "\twidth=", window.end - window.begin, "\tbasis=captured_declaration_hypothesis");
            for (std::size_t i = 0; i < inspection.sections.size(); ++i) {
                const auto& section = inspection.sections[i];
                out.record("INDEX_SECTION\tsection=", i, "\tvalues_checked=", section.count,
                           "\tminimum=", section.minimum, "\tmaximum=", section.maximum,
                           "\tvertex_limit=", i == 0 ? 252 : 109, "\toutside_count=", section.outside_count);
            }
            if (inspection.omitted) out.mark_truncated();
            for (std::size_t i = 0; i < inspection.retained && out.open(); ++i) {
                const auto& invalid = inspection.bad_indices[i];
                out.record("INDEX_OUTSIDE_CANDIDATE\tsection=", invalid.section, "\tindex=", invalid.index,
                           "\tbyte_offset=", invalid.byte_offset, "\tvalue=", invalid.value);
            }
        }
        return finish();
    } catch (const std::exception& error) {
        out.record("ERROR\tstage=", stage, "\tmessage=", out.text(error.what()));
        return finish();
    }
}

int mesh_metadata_command(int argc, char** argv) {
    using namespace dingosdk::frostbite;
    MeshMetadataOutput out;
    std::size_t lod{};
    // A malformed request never opens GameData or a TOC. The exact resource still comes from the selected manifest.
    if (argc != 5 || std::string_view(argv[3]).empty() || std::string_view(argv[3]).size() > 4096 ||
        !mesh_metadata_lod(argv[4], lod)) {
        out.record("ERROR\tstage=arguments\tmessage=expected one exact RES name and an unsigned decimal LOD index");
        return out.finish(false, 2);
    }
    constexpr std::size_t resource_limit = 16 * 1024 * 1024;
    constexpr std::uint32_t mesh_set_type = 0x49b156d4; // Existing MeshSet RES type used by the VFS mesh readers.
    std::string_view stage = "context";
    try {
        const auto* toc_environment = std::getenv("ASSET_TOC");
        const auto* bundle_environment = std::getenv("ASSET_BUNDLE");
        const std::string_view toc_name = toc_environment ? toc_environment : "Win32/levels/game/bam_levelroot/bam_levelroot.toc";
        const std::string_view bundle_name = bundle_environment ? bundle_environment : "win32/levels/game/bam_levelroot/bam_levelroot";
        if (toc_name.empty() || bundle_name.empty() || toc_name.size() > 4096 || bundle_name.size() > 4096 || bundle_name == "?") {
            out.record("ERROR\tstage=arguments\tmessage=mesh metadata needs one bounded TOC and bundle selection, not a bundle listing");
            return out.finish(false, 2);
        }
        out.record("CONTEXT\ttoc=", out.text(toc_name), "\tbundle=", out.text(bundle_name),
                   "\tstore_classification=unknown\tresidency=manifest_only\tgeometry_payload_read=0\toutput_bytes_limit=1048576"
                   "\toutput_records_limit=8192\tescaped_text_bytes_limit=512\tresource_tool_limit_bytes=16777216"
                   "\tdecoder_output_limit_bytes=268435456\tlimits_provenance=authored");
        stage = "bundle_read";
        const dingosdk::vfs::GameData data{std::filesystem::path(argv[1])};
        const auto toc = data.read_toc(toc_name);
        const auto found = data.read_bundle(toc, bundle_name);
        if (!found) throw std::runtime_error("selected bundle was not found");
        const auto& bundle = *found;
        std::size_t matches{}, resource_index{};
        for (std::size_t i = 0; i < bundle.manifest.resources.size(); ++i)
            if (mesh_metadata_name(bundle.manifest.resources[i].name, argv[3])) { ++matches; resource_index = i; }
        out.record("SELECTION\texact_res_name=", out.text(argv[3]), "\tlod=", lod, "\tmatched_resources=", matches);
        if (matches != 1) {
            out.record("ERROR\tstage=resource_selection\tmessage=", matches ? "exact RES name is ambiguous" : "exact RES name was not found in this bundle");
            return out.finish(false);
        }
        const auto& asset = bundle.manifest.resources[resource_index];
        const auto* payload = bundle.payload(AssetKind::resource, resource_index);
        out.record("RESOURCE\tname=", out.text(asset.name), "\tresource_type_raw=", asset.resourceType,
                   "\tresource_id=", asset.resourceId, "\tsha1=", metadata_hex(asset.sha1.bytes),
                   "\tsha1_source=manifest\tpayload_sha1_verified=0\tadvertised_bytes=", asset.originalSize,
                   "\tpayload_location=", payload ? "present" : "missing");
        if (asset.resourceType != mesh_set_type || !payload) {
            out.record("ERROR\tstage=resource_selection\tmessage=", payload ? "selected RES is not a MeshSet" : "selected RES has no payload location record");
            return out.finish(false);
        }
        out.record("PAYLOAD\tcompressed_bytes=", payload->size,
                   "\tdecoder_policy=existing_GameData_256MiB_cap\ttool_size_checks=advertised_compressed_then_actual");
        if (!asset.originalSize || asset.originalSize > resource_limit || !payload->size || payload->size > resource_limit) {
            out.record("ERROR\tstage=resource_size\tmessage=advertised or compressed resource size is outside the tool limit");
            return out.finish(false);
        }
        stage = "resource_read";
        // GameData retains its existing 256 MiB decode cap; the manifest precheck is not a smaller decoder quota.
        const auto bytes = data.read(*payload);
        out.record("RESOURCE_READ\tactual_bytes=", bytes.size(), "\tgeometry_payload_read=0");
        if (bytes.size() > resource_limit || bytes.size() != asset.originalSize) {
            out.record("ERROR\tstage=resource_size\tmessage=decoded size exceeds the tool limit or differs from the manifest");
            return out.finish(false);
        }
        if (bytes.size() >= 16) {
            BinaryReader header(bytes);
            const auto first = header.u32(), second = header.u32(), third = header.u32(), fourth = header.u32();
            out.record("HEADER\tword0=", first, "\tword1=", second, "\tword2=", third, "\tword3=", fourth);
        }
        stage = "mesh_metadata";
        const auto mesh = read_mesh_lod_metadata(bytes, lod);
        mesh_metadata_rows(out, mesh);
        if (!mesh.lod_kind_supported) {
            if (mesh.static_common_offsets && out.open()) {
                // A location match tests this raw identity candidate; it does not qualify the LOD or read geometry.
                Guid candidate;
                candidate.bytes = mesh.static_common_offsets->geometry_identity_raw;
                const auto lookup = dingosdk::trainer::asset_tools::locate_chunk_candidate(candidate, bundle, toc);
                mesh_chunk_location_rows(out, candidate, lookup);
            }
            return out.finish(false);
        }
        std::size_t chunk_matches{}, chunk_index{};
        for (std::size_t i = 0; i < bundle.manifest.chunks.size(); ++i)
            if (bundle.manifest.chunks[i].guid == mesh.geometry.chunk) { ++chunk_matches; chunk_index = i; }
        out.record("CHUNK_REF\tguid=", mesh.geometry.chunk.string(), "\tlocal_matches=", chunk_matches,
                   "\tresolution=", chunk_matches == 1 ? "selected_bundle_manifest" : chunk_matches ? "ambiguous" : "external_or_missing",
                   "\tpayload_read=0");
        bool chunk_location{};
        if (chunk_matches == 1) {
            const auto& chunk = bundle.manifest.chunks[chunk_index];
            chunk_location = bundle.payload(AssetKind::chunk, chunk_index) != nullptr;
            out.record("CHUNK_METADATA\tguid=", chunk.guid.string(), "\tsha1=", metadata_hex(chunk.sha1.bytes),
                       "\tsha1_source=manifest\tadvertised_bytes=", chunk.originalSize, "\tlogical_offset=", chunk.logicalOffset,
                       "\tlogical_size=", chunk.logicalSize, "\tpayload_location=", chunk_location ? "present" : "missing", "\tpayload_read=0");
        }
        if (chunk_matches != 1 || !chunk_location)
            out.record("DIAGNOSTIC\tscope=chunk_manifest\tmessage=unique local geometry location is unresolved; global absence is not established");
        return out.finish(mesh.complete && chunk_matches == 1 && chunk_location);
    } catch (const std::exception& error) {
        out.record("ERROR\tstage=", stage, "\tmessage=", out.text(error.what()));
        return out.finish(false);
    }
}
} // namespace

int main(int argc, char **argv) {
    if (argc >= 2 && std::string_view(argv[1]) == "--self-test-manhole-position") {
        if (argc != 2) return 2;
        return dingosdk::trainer::asset_tools::manhole_position_self_test();
    }
    if (argc >= 2 && std::string_view(argv[1]) == "--self-test-mesh-output") {
        if (argc != 2) return 2;
        return dingosdk::trainer::asset_tools::mesh_output_self_test();
    }
    if (argc >= 3 && std::string_view(argv[2]) == "--inspect-manhole-position-candidate") return manhole_candidate_command(argc, argv, true);
    if (argc >= 3 && std::string_view(argv[2]) == "--inspect-manhole-candidate") return manhole_candidate_command(argc, argv);
    if (argc >= 2 && std::string_view(argv[1]) == "--self-test-manhole-candidate") {
        if (argc != 2) return 2;
        return dingosdk::trainer::asset_tools::manhole_candidate_self_test();
    }
    if (argc >= 2 && std::string_view(argv[1]) == "--self-test-chunk-locator") {
        if (argc != 2) return 2;
        return dingosdk::trainer::asset_tools::chunk_locator_self_test();
    }
    if (argc >= 3 && std::string_view(argv[2]) == "--mesh-metadata") return mesh_metadata_command(argc, argv);
    if (argc < 3) {
        std::cerr << "usage: dingosdk_trainer_asset_list <Skate folder> <word>... | --dump <asset name> | --types <word>... | --metadata [word]... | --inspect <exact EBX name> | --mesh-metadata <exact RES name> <LOD index> | --inspect-manhole-candidate | --inspect-manhole-position-candidate\n";
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
