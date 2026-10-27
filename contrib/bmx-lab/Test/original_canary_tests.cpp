// Synthetic admission tests. No game archives, native assets or generator process.
#include "contrib/bmx-lab/original_canary.h"
#include "contrib/bmx-lab/original_canary_cli.h"
#include "Engine/Core/Json/json.h"
#include <Windows.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <locale>
#include <numbers>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace canary = dingosdk::bmx::original_canary;
namespace fs = std::filesystem;
using dingosdk::Json;
using Point = std::array<double, 3>;
using Triangle = std::array<std::uint32_t, 3>;

namespace {
std::size_t cases{}, checks{}, skipped{};
std::string current_case;
void check(bool value, std::string_view why) {
    ++checks;
    if (!value) throw std::runtime_error(std::string(why));
}
template<class F> void test(std::string_view name, F&& body) {
    current_case = name; ++cases; body();
}
template<class F> void refused(F&& body, std::string_view message = {}) {
    bool rejected = false;
    try { body(); }
    catch (const std::runtime_error& error) {
        rejected = true;
        if (!message.empty()) check(std::string_view(error.what()).find(message) != std::string_view::npos,
            std::string("wrong refusal: ") + error.what());
    }
    check(rejected, "candidate unexpectedly admitted");
}
std::string read_source(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot read test source: " + path.string());
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
double rounded(double value) {
    const auto result = std::round(value * 1e9) / 1e9;
    return result == 0 ? 0 : result;
}
Point rounded(Point value) { for (auto& item : value) item = rounded(item); return value; }
Point plus(Point a, const Point& b) { for (std::size_t i = 0; i < 3; ++i) a[i] += b[i]; return a; }
Point times(Point a, double scale) { for (auto& item : a) item *= scale; return a; }
Point cross(const Point& a, const Point& b) {
    return {a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]};
}
Point unit(Point value) {
    const auto length = std::sqrt(value[0]*value[0]+value[1]*value[1]+value[2]*value[2]);
    return times(value, 1 / length);
}
Json vector_json(const Point& point, bool quantize = true) { return Json(quantize ? rounded(point) : point); }

struct Mesh {
    std::vector<canary::Vertex> vertices;
    std::vector<Triangle> triangles;
    Json components = Json::array();

    std::uint32_t vertex(Point position, Point normal, std::array<double, 2> uv) {
        for (auto& item : uv) item = rounded(item);
        const auto index = static_cast<std::uint32_t>(vertices.size());
        vertices.push_back({rounded(position), rounded(normal), uv});
        return index;
    }
    void component(std::string name, std::string kind, std::string material,
        std::size_t first_vertex, std::size_t first_triangle, Json parameters) {
        Json row = Json::object();
        row["label"] = std::move(name); row["kind"] = std::move(kind); row["material"] = std::move(material);
        row["first_vertex"] = first_vertex; row["vertex_count"] = vertices.size() - first_vertex;
        row["first_triangle"] = first_triangle; row["triangle_count"] = triangles.size() - first_triangle;
        row["parameters"] = std::move(parameters); components.push_back(std::move(row));
    }
    void platform(Point center, Point half) {
        // Independent oriented face construction: u cross v is each face normal.
        const auto first_vertex = vertices.size(), first_triangle = triangles.size();
        for (std::size_t axis = 0; axis < 3; ++axis) for (const double side : {1.0, -1.0}) {
            Point normal{}, u{}, offset{};
            normal[axis] = side; offset[axis] = side * half[axis];
            u[(axis + 1) % 3] = 1;
            const Point v = cross(normal, u);
            const auto first = static_cast<std::uint32_t>(vertices.size());
            for (const auto& corner : std::array<std::array<double, 2>, 4>{{{-1,-1},{1,-1},{1,1},{-1,1}}}) {
                const auto position = plus(plus(plus(center, offset), times(u, corner[0]*half[(axis+1)%3])),
                    times(v, corner[1]*half[(axis+2)%3]));
                vertex(position, normal, {(corner[0]+1)/2, (corner[1]+1)/2});
            }
            triangles.push_back({first, first+1, first+2}); triangles.push_back({first, first+2, first+3});
        }
        Json parameters = Json::object(); parameters["center"] = vector_json(center); parameters["half_extents"] = vector_json(half);
        component("platform", "box", "alloy", first_vertex, first_triangle, std::move(parameters));
    }
    void pin(std::string label, Point a, Point b, double radius) {
        const auto first_vertex = vertices.size(), first_triangle = triangles.size();
        const double side = b[1] > a[1] ? 1.0 : -1.0;
        const Point axis{0,side,0};
        const auto radial = [side](unsigned index) -> Point {
            const auto angle = 2 * std::numbers::pi * static_cast<double>(index) / 6;
            return {std::sin(angle), 0, side*std::cos(angle)};
        };
        std::array<std::array<std::uint32_t, 7>, 2> rings{};
        for (unsigned ring = 0; ring < 2; ++ring) for (unsigned i = 0; i <= 6; ++i) {
            const auto normal = radial(i);
            rings[ring][i] = vertex(plus(ring ? b : a, times(normal, radius)), normal,
                {static_cast<double>(i)/6, static_cast<double>(ring)});
        }
        for (unsigned i = 0; i < 6; ++i) {
            triangles.push_back({rings[0][i],rings[0][i+1],rings[1][i+1]});
            triangles.push_back({rings[0][i],rings[1][i+1],rings[1][i]});
        }
        for (unsigned cap = 0; cap < 2; ++cap) {
            const auto center = cap ? b : a;
            const auto normal = times(axis, cap ? 1.0 : -1.0);
            const auto middle = vertex(center, normal, {.5,.5});
            std::array<std::uint32_t, 7> ring{};
            for (unsigned i = 0; i <= 6; ++i) {
                const auto angle = 2 * std::numbers::pi * static_cast<double>(i) / 6;
                ring[i] = vertex(plus(center, times(radial(i), radius)), normal,
                    {.5+.5*std::cos(angle), .5+.5*std::sin(angle)});
            }
            for (unsigned i = 0; i < 6; ++i) triangles.push_back(cap
                ? Triangle{middle,ring[i],ring[i+1]} : Triangle{middle,ring[i+1],ring[i]});
        }
        Json parameters = Json::object(); parameters["a"] = vector_json(a); parameters["b"] = vector_json(b);
        parameters["radius"] = rounded(radius);
        component(std::move(label), "cylinder", "steel", first_vertex, first_triangle, std::move(parameters));
    }
    canary::Bounds bounds() const {
        canary::Bounds result{vertices.front().position, vertices.front().position};
        for (const auto& point : vertices) for (std::size_t axis = 0; axis < 3; ++axis) {
            result.min[axis] = std::min(result.min[axis], point.position[axis]);
            result.max[axis] = std::max(result.max[axis], point.position[axis]);
        }
        return result;
    }
    std::string obj() const {
        std::ostringstream output; output.imbue(std::locale::classic());
        output << "# Original procedural BMX; see manifest.json and provenance.json.\n"
            "# Metres; +X left, +Y up, +Z forward. Common bike-space origin.\n"
            "mtllib materials.mtl\no left_pedal\n" << std::fixed << std::setprecision(9);
        for (const auto& point : vertices) output << "v " << point.position[0] << ' ' << point.position[1] << ' ' << point.position[2] << '\n';
        for (const auto& point : vertices) output << "vt " << point.uv[0] << ' ' << point.uv[1] << '\n';
        for (const auto& point : vertices) output << "vn " << point.normal[0] << ' ' << point.normal[1] << ' ' << point.normal[2] << '\n';
        for (const auto& component : components) {
            output << "g " << component.at("label").string() << "\nusemtl " << component.at("material").string() << '\n';
            const auto first = component.at("first_triangle").get<std::size_t>();
            const auto end = first + component.at("triangle_count").get<std::size_t>();
            for (std::size_t i = first; i < end; ++i) {
                output << 'f';
                for (const auto index : triangles[i]) output << ' ' << index+1 << '/' << index+1 << '/' << index+1;
                output << '\n';
            }
        }
        return output.str();
    }
};

struct Fixture {
    Mesh mesh;
    Json manifest;
    canary::Payloads payloads;

    void hash_payload(std::string_view name) {
        const auto& bytes = payloads.at(std::string(name));
        Json row = Json::object(); row["bytes"] = bytes.size(); row["sha256"] = canary::sha256(bytes);
        manifest["payloads"][name] = std::move(row);
    }
    explicit Fixture(const fs::path& repository) {
        const auto source = repository / "assets/models/bmx/original";
        const auto contract = Json::parse(read_source(source / "geometry_contract.json"));
        const double scale = contract.at("scale").get<double>();
        Point center{}, half{};
        for (std::size_t i = 0; i < 3; ++i) {
            center[i] = contract.at("anchors_unscaled").at("left_pedal")[i].get<double>() * scale;
            half[i] = contract.at("authoring").at("pedal_half_extents_unscaled")[i].get<double>() * scale;
        }
        mesh.platform(center, half);
        for (const int side : {-1, 1}) for (unsigned x = 0; x < 2; ++x) for (unsigned z = 0; z < 2; ++z) {
            const Point a = plus(center, {(x ? .039 : -.039)*scale, static_cast<double>(side)*half[1], (z ? .05 : -.05)*scale});
            const Point b = plus(a, {0, static_cast<double>(side)*.007*scale, 0});
            mesh.pin(std::string("pin_") + (side > 0 ? "top_" : "bottom_") + std::to_string(x) + '_' + std::to_string(z), a, b, .002*scale);
        }
        // Nonselected members are opaque hash-bound fixtures; only left_pedal is parsed.
        for (const auto name : canary::payload_names()) payloads.emplace(name, "Synthetic original canary fixture member.\n");
        payloads["left_pedal.obj"] = mesh.obj();
        payloads["geometry_contract.json"] = contract.dump();
        auto provenance = Json::parse(read_source(source / "provenance.json"));
        provenance["source_license_file"] = provenance.at("license_file"); provenance["license_file"] = "LICENSE";
        payloads["provenance.json"] = provenance.dump(); payloads["LICENSE"] = read_source(repository / "LICENSE");
        Json material_rows = Json::object();
        const auto material = [&](std::string_view name, Point color, double roughness, double metallic) {
            Json row = Json::object(); row["base_color"] = Json(color); row["roughness"] = roughness; row["metallic"] = metallic;
            material_rows[name] = std::move(row);
        };
        material("paint", {.075,.09,.105}, .42, 0); material("rubber", {.025,.028,.032}, .9, 0);
        material("alloy", {.52,.55,.58}, .28, 1); material("steel", {.29,.32,.35}, .22, 1);
        Json materials = Json::object(); materials["schema"] = 1; materials["normal_tangent_space"] = Json::array({0,0,1});
        materials["materials"] = std::move(material_rows); materials["status"] = "Original constants; native shader compilation is separate.";
        payloads["materials.json"] = materials.dump();
        manifest = Json::object(); manifest["schema"] = 1; manifest["format"] = "original-bmx-obj-v1";
        manifest["native_ready"] = false; manifest["coordinate_frame"] = contract.at("coordinate_frame");
        manifest["scale_applied"] = scale; manifest["common_origin_preserved"] = true; manifest["com_subtracted"] = false;
        manifest["com_metres"] = contract.at("com_metres"); manifest["wheel_radius_metres"] = .34*scale;
        manifest["anchors_metres"] = Json::object();
        for (const auto& [name, anchor] : contract.at("anchors_unscaled").items()) {
            Point value{}; for (std::size_t i = 0; i < 3; ++i) value[i] = anchor[i].get<double>()*scale;
            manifest["anchors_metres"][name] = vector_json(value, false);
        }
        Point steering{}; for (std::size_t i = 0; i < 3; ++i) steering[i] = contract.at("steering_axis")[i].get<double>();
        manifest["steering_axis_unit"] = vector_json(unit(steering), false); manifest["pose_order"] = contract.at("pose_order");
        manifest["parts"] = Json::array();
        const auto box = mesh.bounds();
        for (const auto& role : contract.at("parts")) {
            Json row = role; row["file"] = role.at("name").string() + ".obj";
            row["vertices"] = mesh.vertices.size(); row["triangles"] = mesh.triangles.size();
            Json bounds = Json::object(); bounds["min"] = vector_json(box.min); bounds["max"] = vector_json(box.max);
            row["bounds_metres"] = std::move(bounds); row["components"] = mesh.components;
            manifest["parts"].push_back(std::move(row));
        }
        Json inputs = Json::object();
        inputs["generate_geometry.py"] = "6ec14cfb35ecdec17c8aadb84f8370892355afeef46da5391d887390a2c4d73a";
        inputs["geometry_contract.json"] = "86b50ebf37386520e42c5bf6eefbe2cc3bc01f35b27305528887c9d03182aa31";
        inputs["provenance.json"] = "4455da9c001418eaf8e297f6a43a7c53b69f3ea61881c94bc091605a13590a7b";
        inputs["LICENSE"] = "230184f60bae2feaf244f10a8bac053c8ff33a183bcc365b4d8b876d2b7f4809";
        inputs["contrib/bmx-lab/bmx-plugin/plugin/bike_geometry.lua"] = "ea5516324173ab539be6a0a2f0765555c88cb0bc151eb9b9a577f3cacd0ed5ed";
        inputs["contrib/bmx-lab/bmx-plugin/plugin/bike_visual.lua"] = "7daf2ba57a6f267ae41eb82b996ebd723163ca9b5ca0d579fab89549e5bb80d2";
        manifest["recipe_inputs_sha256"] = std::move(inputs); manifest["payloads"] = Json::object();
        for (const auto name : canary::payload_names()) hash_payload(name);
        Json qualification = Json::object();
        qualification["offline_mesh_validation"] = "Performed by this generator, including serialized precision.";
        qualification["native_resource_build"] = "not performed"; qualification["native_rendering"] = "not performed";
        qualification["gameplay_parity"] = "not measured"; manifest["qualification"] = std::move(qualification);
    }
    canary::AdmittedPart admit() const { return canary::admit_original(manifest.dump(), payloads); }
};

void replace_line(std::string& text, std::string_view prefix, std::string_view replacement) {
    std::size_t start = 0;
    while (start < text.size()) {
        const auto end = text.find('\n', start);
        if (text.compare(start, prefix.size(), prefix) == 0) {
            text.replace(start, end - start, replacement); return;
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
    throw std::runtime_error("test fixture line not found");
}
void write_fixture(const fs::path& path, std::string_view bytes) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file || !file.write(bytes.data(), static_cast<std::streamsize>(bytes.size()))) throw std::runtime_error("fixture write failed");
}
bool descendant(const fs::path& child, const fs::path& parent) {
    auto a = child.begin(), b = parent.begin();
    for (; b != parent.end(); ++a, ++b) if (a == child.end() || *a != *b) return false;
    return a != child.end();
}
struct Scratch {
    fs::path base, path;
    explicit Scratch(const fs::path& repository) {
        const auto owned_repository = fs::canonical(repository);
        base = (owned_repository / "build/bmx-original-canary-tests").lexically_normal();
        check(descendant(base, owned_repository), "scratch base must stay in the source workspace");
        auto prefix = base.root_path();
        for (const auto& component : base.relative_path()) {
            prefix /= component;
            const auto attributes = GetFileAttributesW(prefix.c_str());
            if (attributes == INVALID_FILE_ATTRIBUTES) {
                const auto error = GetLastError();
                check(error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND, "scratch ancestor inspection failed");
                break;
            }
            check((attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0, "scratch cannot traverse an existing reparse point");
        }
        fs::create_directories(base);
        base = fs::canonical(base);
        check(descendant(base, owned_repository), "resolved scratch base remains inside source workspace");
        const auto tick = std::chrono::steady_clock::now().time_since_epoch().count();
        path = base / ("fixture-" + std::to_string(GetCurrentProcessId()) + '-' + std::to_string(tick));
        check(fs::create_directory(path), "scratch must be new"); path = fs::canonical(path);
        check(descendant(path, base), "scratch containment before ownership");
    }
    ~Scratch() {
        // Remove only this freshly created exact child; never the shared parent.
        std::error_code error;
        const auto actual = fs::weakly_canonical(path, error);
        if (!error && actual == path && descendant(actual, base)) fs::remove_all(path, error);
    }
};

void parser_tests(const Fixture& valid, const std::string& recipe) {
    test("SHA256 known vectors", [] {
        check(canary::sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty SHA256");
        check(canary::sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc SHA256");
    });
    test("selected original arrays and components remain unchanged", [&] {
        const auto admitted = valid.admit();
        check(admitted.vertices.size() == 264 && admitted.triangles.size() == 204 && admitted.components.size() == 9, "source-derived selected topology");
        check(admitted.triangles == valid.mesh.triangles, "triangle indices preserved");
        for (std::size_t i = 0; i < admitted.vertices.size(); ++i) {
            for (std::size_t axis = 0; axis < 3; ++axis) {
                check(std::abs(admitted.vertices[i].position[axis]-valid.mesh.vertices[i].position[axis]) < 1e-12, "common-frame positions preserved");
                check(std::abs(admitted.vertices[i].normal[axis]-valid.mesh.vertices[i].normal[axis]) < 1e-12, "explicit normals preserved");
            }
            for (std::size_t axis = 0; axis < 2; ++axis)
                check(std::abs(admitted.vertices[i].uv[axis]-valid.mesh.vertices[i].uv[axis]) < 1e-12, "authored UVs preserved");
        }
        check(admitted.components.front().label == "platform" && admitted.components.front().material == "alloy", "platform label/material retained");
        for (std::size_t i = 1; i < admitted.components.size(); ++i) check(admitted.components[i].material == "steel", "pin materials retained");
        for (std::size_t i = 0; i < admitted.components.size(); ++i) {
            const auto& actual = admitted.components[i]; const auto& expected = valid.mesh.components[i];
            check(actual.label == expected.at("label").string() && actual.material == expected.at("material").string(),
                "every authored component label and material survives admission");
            check(actual.first_vertex == expected.at("first_vertex").get<std::size_t>() &&
                actual.vertex_count == expected.at("vertex_count").get<std::size_t>() &&
                actual.first_triangle == expected.at("first_triangle").get<std::size_t>() &&
                actual.triangle_count == expected.at("triangle_count").get<std::size_t>(),
                "every authored component range survives admission");
        }
        check(admitted.bounds.min == valid.mesh.bounds().min && admitted.bounds.max == valid.mesh.bounds().max, "quantized common-frame bounds preserved");
        check(admitted.manifest_sha256 == canary::sha256(valid.manifest.dump()), "admission binds exact manifest bytes");
    });
    const auto bad_manifest = [&](std::string_view name, const std::function<void(Json&)>& mutation) {
        test(name, [&] { auto changed = valid; mutation(changed.manifest); refused([&] { (void)changed.admit(); }); });
    };
    bad_manifest("unknown manifest field", [](Json& j) { j["execute"] = "native"; });
    bad_manifest("wrong manifest schema", [](Json& j) { j["schema"] = 2; });
    bad_manifest("schema is not Boolean", [](Json& j) { j["schema"] = true; });
    bad_manifest("native-ready claim rejected", [](Json& j) { j["native_ready"] = true; });
    bad_manifest("wrong coordinate frame", [](Json& j) { j["coordinate_frame"]["x"] = "right"; });
    bad_manifest("unknown coordinate field", [](Json& j) { j["coordinate_frame"]["transform"] = true; });
    bad_manifest("implicit rescaling rejected", [](Json& j) { j["scale_applied"] = 1; });
    bad_manifest("recentered origin rejected", [](Json& j) { j["common_origin_preserved"] = false; });
    bad_manifest("COM subtraction rejected", [](Json& j) { j["com_subtracted"] = true; });
    bad_manifest("foreign selected identity", [](Json& j) { j["parts"][6]["blueprint"] = "reskate/drone/left_pedal"; });
    bad_manifest("selected articulation changed", [](Json& j) { j["parts"][6]["orbit"] = "right_pedal"; });
    bad_manifest("selected part file traversal", [](Json& j) { j["parts"][6]["file"] = "../left_pedal.obj"; });
    bad_manifest("unknown selected parameter", [](Json& j) { j["parts"][6]["components"][0]["parameters"]["offset"] = 1; });
    bad_manifest("component range gap", [](Json& j) { j["parts"][6]["components"][1]["first_vertex"] = 25; });
    bad_manifest("selected bounds mismatch", [](Json& j) { j["parts"][6]["bounds_metres"]["min"][0] = 0; });
    bad_manifest("wrong input pin", [](Json& j) { j["recipe_inputs_sha256"]["generate_geometry.py"] = std::string(64, '0'); });
    bad_manifest("untrusted extra input path", [](Json& j) { j["recipe_inputs_sha256"]["../../game.bin"] = std::string(64, '0'); });
    bad_manifest("wrong payload hash", [](Json& j) { j["payloads"]["left_pedal.obj"]["sha256"] = std::string(64, '0'); });
    bad_manifest("malformed payload hash", [](Json& j) { j["payloads"]["left_pedal.obj"]["sha256"] = "not-a-hash"; });
    bad_manifest("wrong payload byte count", [](Json& j) { j["payloads"]["left_pedal.obj"]["bytes"] = 1; });
    bad_manifest("unknown payload metadata", [](Json& j) { j["payloads"]["left_pedal.obj"]["path"] = "other.obj"; });
    bad_manifest("claimed native qualification rejected", [](Json& j) { j["qualification"]["native_rendering"] = "passed"; });
    test("duplicate JSON key rejected", [&] {
        auto duplicate = valid.manifest.dump(); duplicate.insert(1, "\"schema\":1,");
        refused([&] { (void)canary::admit_original(duplicate, valid.payloads); });
    });
    test("truncated JSON rejected", [&] {
        auto malformed = valid.manifest.dump(); malformed.pop_back();
        refused([&] { (void)canary::admit_original(malformed, valid.payloads); });
    });
    test("manifest byte bound", [&] {
        auto oversized = valid.manifest.dump(); oversized.append(canary::maximum_manifest_bytes, ' ');
        refused([&] { (void)canary::admit_original(oversized, valid.payloads); });
    });
    test("missing fixed payload", [&] { auto changed = valid; changed.payloads.erase("frame.obj"); refused([&] { (void)changed.admit(); }); });
    test("extra traversal payload", [&] { auto changed = valid; changed.payloads["../outside.obj"] = "x"; refused([&] { (void)changed.admit(); }); });
    test("payload corruption without new hash", [&] { auto changed = valid; changed.payloads.at("left_pedal.obj")[0] = '!'; refused([&] { (void)changed.admit(); }); });
    test("payload byte bound", [&] {
        auto changed = valid; changed.payloads["frame.obj"] = std::string(canary::maximum_payload_bytes+1, 'x'); changed.hash_payload("frame.obj");
        refused([&] { (void)changed.admit(); });
    });
    const auto bad_obj = [&](std::string_view name, const std::function<void(std::string&)>& mutation) {
        test(name, [&] { auto changed = valid; mutation(changed.payloads["left_pedal.obj"]); changed.hash_payload("left_pedal.obj");
            refused([&] { (void)changed.admit(); }); });
    };
    bad_obj("OBJ unknown directive", [](std::string& s) { s += "s off\n"; });
    bad_obj("OBJ additional object", [](std::string& s) { s += "o another\n"; });
    bad_obj("OBJ external material file", [](std::string& s) { replace_line(s, "mtllib ", "mtllib ../outside.mtl"); });
    bad_obj("OBJ wrong selected name", [](std::string& s) { replace_line(s, "o ", "o right_pedal"); });
    bad_obj("OBJ negative indices", [](std::string& s) { replace_line(s, "f ", "f -1/-1/-1 2/2/2 3/3/3"); });
    bad_obj("OBJ unequal index triplets", [](std::string& s) { replace_line(s, "f ", "f 1/1/2 2/2/2 3/3/3"); });
    bad_obj("OBJ zero index", [](std::string& s) { replace_line(s, "f ", "f 0/0/0 2/2/2 3/3/3"); });
    bad_obj("OBJ out-of-range index", [](std::string& s) { replace_line(s, "f ", "f 999/999/999 2/2/2 3/3/3"); });
    bad_obj("OBJ nontriangle face", [](std::string& s) { replace_line(s, "f ", "f 1/1/1 2/2/2 3/3/3 4/4/4"); });
    bad_obj("OBJ missing normal index", [](std::string& s) { replace_line(s, "f ", "f 1/1 2/2 3/3"); });
    bad_obj("OBJ degenerate triangle", [](std::string& s) { replace_line(s, "f ", "f 1/1/1 1/1/1 3/3/3"); });
    bad_obj("OBJ inward winding", [](std::string& s) { replace_line(s, "f ", "f 1/1/1 3/3/3 2/2/2"); });
    bad_obj("OBJ nonfinite position", [](std::string& s) { replace_line(s, "v ", "v nan 0.000000000 0.000000000"); });
    bad_obj("OBJ unbounded position", [](std::string& s) { replace_line(s, "v ", "v 100.000000000 0.000000000 0.000000000"); });
    bad_obj("OBJ invalid normal", [](std::string& s) { replace_line(s, "vn ", "vn 0.000000000 0.000000000 0.000000000"); });
    bad_obj("OBJ invalid UV", [](std::string& s) { replace_line(s, "vt ", "vt 2.000000000 0.000000000"); });
    bad_obj("OBJ material labels retained", [](std::string& s) { replace_line(s, "usemtl ", "usemtl rubber"); });
    bad_obj("OBJ component labels retained", [](std::string& s) { replace_line(s, "g ", "g translated_platform"); });
    bad_obj("OBJ final newline required", [](std::string& s) { s.pop_back(); });
    bad_obj("OBJ CRLF subset refused", [](std::string& s) { s.insert(s.find('\n'), "\r"); });
    bad_obj("OBJ selected byte bound", [](std::string& s) { s.append(canary::maximum_obj_bytes, ' '); });
    test("changed original contract payload", [&] {
        auto changed = valid; auto contract = Json::parse(changed.payloads.at("geometry_contract.json")); contract["scale"] = 1;
        changed.payloads["geometry_contract.json"] = contract.dump(); changed.hash_payload("geometry_contract.json"); refused([&] { (void)changed.admit(); });
    });
    test("foreign provenance input rejected", [&] {
        auto changed = valid; auto provenance = Json::parse(changed.payloads.at("provenance.json")); provenance["external_asset_inputs"].push_back("donor.obj");
        changed.payloads["provenance.json"] = provenance.dump(); changed.hash_payload("provenance.json"); refused([&] { (void)changed.admit(); });
    });
    test("original material constants retained", [&] {
        auto changed = valid; auto materials = Json::parse(changed.payloads.at("materials.json")); materials["materials"]["alloy"]["metallic"] = 0;
        changed.payloads["materials.json"] = materials.dump(); changed.hash_payload("materials.json"); refused([&] { (void)changed.admit(); });
    });
    test("valid recipe is metadata only", [&] { canary::validate_unqualified_recipe(recipe); check(Json::parse(recipe).at("status").string() == "unqualified", "recipe never declares native-ready"); });
    const auto bad_recipe = [&](std::string_view name, const std::function<void(Json&)>& mutation) {
        test(name, [&] { auto changed = Json::parse(recipe); mutation(changed); refused([&] { canary::validate_unqualified_recipe(changed.dump()); }); });
    };
    bad_recipe("recipe unknown field", [](Json& j) { j["script"] = "install"; });
    bad_recipe("recipe self-qualification rejected", [](Json& j) { j["status"] = "qualified"; });
    bad_recipe("recipe native identity not invented", [](Json& j) { j["native_identities"]["template"] = "default"; });
    bad_recipe("recipe unknown native field", [](Json& j) { j["native_identities"]["paid_override"] = true; });
    bad_recipe("recipe wrong supported build", [](Json& j) { j["supported_build"] = 20260930; });
    bad_recipe("recipe normal conversion rejected", [](Json& j) { j["preserve_normals"] = false; });
    bad_recipe("recipe auto-install rejected", [](Json& j) { j["auto_install"] = true; });
    bad_recipe("recipe unreviewed manifest rejected", [](Json& j) { j["expected_manifest_sha256"] = std::string(64, '0'); });
    test("duplicate recipe field", [&] { auto duplicate = recipe; duplicate.insert(duplicate.find('{')+1, "\"schema\":1,"); refused([&] { canary::validate_unqualified_recipe(duplicate); }); });
}

void filesystem_tests(const Fixture& valid, const fs::path& repository, const std::string& recipe,
    const fs::path& original_package) {
    Scratch scratch(repository);
    const auto package = scratch.path / "package", cache = scratch.path / "cache", recipe_path = scratch.path / "native-canary.recipe.json";
    fs::create_directory(package); fs::create_directory(cache); write_fixture(recipe_path, recipe);
    write_fixture(package / "manifest.json", valid.manifest.dump());
    for (const auto& [name, bytes] : valid.payloads) write_fixture(package / name, bytes);
    const canary::Request request{package, recipe_path, cache / "new-canary", cache};
    test("new fixed-cache path admitted lexically", [&] { check(canary::lexical_output_path(request) == request.output, "new cache output identity"); });
    const auto bad_path = [&](std::string_view name, const std::function<void(canary::Request&)>& mutation, std::string_view why) {
        test(name, [&] { auto changed = request; mutation(changed); refused([&] { (void)canary::lexical_output_path(changed); }, why); });
    };
    bad_path("output escape refused", [&](canary::Request& r) { r.output = scratch.path / "outside"; }, "strict descendant");
    bad_path("output cache root refused", [&](canary::Request& r) { r.output = cache; }, "strict descendant");
    bad_path("case-variant cache prefix refused", [&](canary::Request& r) { r.output = scratch.path / "CACHE" / "nested"; }, "strict descendant");
    bad_path("output traversal refused", [&](canary::Request& r) { r.output = cache / ".." / "outside"; }, "path traversal refused");
    bad_path("output ADS refused", [&](canary::Request& r) { r.output = cache / "output:stream"; }, "alternate stream");
    bad_path("output input overlap refused", [&](canary::Request& r) { r.package = cache / "input"; r.output = r.package / "nested"; }, "output overlaps an input");
    test("synthetic admission cannot impersonate reviewed package", [&] {
        refused([&] { (void)canary::preflight(request); }, "manifest is not the reviewed original package");
        check(!fs::exists(request.output), "failed qualification creates no cache output");
    });
    test("nonselected OBJ uses the payload bound rather than the selected OBJ bound", [&] {
        auto large = valid; large.payloads["frame.obj"] = std::string(canary::maximum_obj_bytes + 1024, 'x');
        large.hash_payload("frame.obj");
        write_fixture(package / "frame.obj", large.payloads.at("frame.obj"));
        write_fixture(package / "manifest.json", large.manifest.dump());
        refused([&] { (void)canary::preflight(request); }, "manifest is not the reviewed original package");
        check(!fs::exists(request.output), "large opaque nonselected member creates no output");
        write_fixture(package / "frame.obj", valid.payloads.at("frame.obj"));
        write_fixture(package / "manifest.json", valid.manifest.dump());
    });
    test("existing output refused before package admission", [&] {
        auto changed = request; changed.output = cache / "existing"; fs::create_directory(changed.output);
        write_fixture(changed.output / "sentinel", "keep");
        refused([&] { (void)canary::preflight(changed); }, "output already exists");
        check(read_source(changed.output / "sentinel") == "keep", "existing output preserved");
    });
    test("hard-linked recipe refused", [&] {
        const auto alias = scratch.path / "recipe-alias.json";
        check(CreateHardLinkW(alias.c_str(), recipe_path.c_str(), nullptr) != 0, "synthetic hard link creation");
        refused([&] { (void)canary::preflight(request); }, "hard-linked input refused");
        check(!fs::exists(request.output), "hard-link refusal creates no output");
        check(fs::remove(alias), "remove only fixture hard link");
    });
    test("concurrent recipe writer prevents an immutable snapshot", [&] {
        struct Writer {
            HANDLE value;
            ~Writer() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
        } writer{CreateFileW(recipe_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr)};
        check(writer.value != INVALID_HANDLE_VALUE, "synthetic writer handle creation");
        refused([&] { (void)canary::preflight(request); }, "cannot open an immutable input snapshot");
        check(!fs::exists(request.output), "sharing refusal creates no output");
    });
    test("null CLI arguments refused before input access", [&] {
        refused([&] { (void)canary::run(5, nullptr, cache); });
        std::array<std::string, 5> values{"canary-test", "--original-canary", package.string(), recipe_path.string(), request.output.string()};
        std::array<char*, 5> arguments{}; for (std::size_t i = 0; i < arguments.size(); ++i) arguments[i] = values[i].data();
        arguments[2] = nullptr;
        refused([&] { (void)canary::run(static_cast<int>(arguments.size()), arguments.data(), cache); });
        check(!fs::exists(request.output), "invalid CLI arguments create no output");
    });
    test("reparse package refused when symlink creation is available", [&] {
        const auto link = scratch.path / "package-link";
        std::error_code error; fs::create_directory_symlink(package, link, error);
        if (error) { ++skipped; std::cout << "reparse fixture unavailable: " << error.message() << '\n'; return; }
        auto changed = request; changed.package = link;
        refused([&] { (void)canary::preflight(changed); }, "reparse point refused");
        check(!fs::exists(request.output), "reparse refusal creates no output");
        check(fs::remove(link), "remove only fixture reparse entry");
    });
    if (!original_package.empty()) test("reviewed original admits but native recipe still blocks emission", [&] {
        auto trusted = request; trusted.package = fs::absolute(original_package); trusted.output = cache / "trusted-original";
        const auto admitted = canary::preflight(trusted);
        check(admitted.vertex_count == 264 && admitted.triangle_count == 204, "real original selected counts");
        check(admitted.manifest_sha256 == Json::parse(recipe).at("expected_manifest_sha256").string(), "real manifest pin");
        std::array<std::string, 5> arguments{"canary-test", "--original-canary", trusted.package.string(), recipe_path.string(), trusted.output.string()};
        std::array<char*, 5> argv{}; for (std::size_t i = 0; i < argv.size(); ++i) argv[i] = arguments[i].data();
        const auto before = static_cast<std::size_t>(std::distance(fs::recursive_directory_iterator(cache), fs::recursive_directory_iterator{}));
        check(canary::run(static_cast<int>(argv.size()), argv.data(), cache) == 2, "valid original remains explicitly unqualified");
        check(!fs::exists(trusted.output), "valid unqualified input creates no native output");
        check(static_cast<std::size_t>(std::distance(fs::recursive_directory_iterator(cache), fs::recursive_directory_iterator{})) == before,
            "refused native emission leaves the entire cache unchanged");
    });
}
}

int main(int argc, char* argv[]) {
    try {
        if (argc < 2 || argc > 3) throw std::runtime_error("Usage: original_canary_tests RECIPE_JSON [REVIEWED_ORIGINAL_PACKAGE]");
        const auto recipe_path = fs::absolute(argv[1]);
        auto repository = recipe_path.parent_path(); for (unsigned i = 0; i < 4; ++i) repository = repository.parent_path();
        const auto recipe = read_source(recipe_path);
        const Fixture fixture(repository);
        parser_tests(fixture, recipe);
        filesystem_tests(fixture, repository, recipe, argc == 3 ? fs::path(argv[2]) : fs::path{});
        std::cout << cases << " original-canary cases, " << checks << " checks, " << skipped << " unavailable reparse fixtures\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Original canary test failed [" << current_case << "]: " << error.what() << '\n';
        return 1;
    }
}
