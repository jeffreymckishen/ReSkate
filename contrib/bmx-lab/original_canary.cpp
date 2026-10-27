#include "original_canary.h"
#include "Engine/Core/Json/json.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <bcrypt.h>
#include <algorithm>
#include <charconv>
#include <cmath>
#include <initializer_list>
#include <limits>
#include <set>
#include <stdexcept>
#include <utility>

namespace dingosdk::bmx::original_canary {
namespace {
using Vec3 = std::array<double, 3>;
constexpr double scale = 0.7737670588235294;
constexpr std::array<std::string_view, 8> parts{
    "frame", "fork", "rear_wheel", "front_wheel", "cranks", "handlebars", "left_pedal", "right_pedal"};
constexpr std::array<std::string_view, 13> leaves{
    "frame.obj", "fork.obj", "rear_wheel.obj", "front_wheel.obj", "cranks.obj", "handlebars.obj",
    "left_pedal.obj", "right_pedal.obj", "materials.mtl", "materials.json", "geometry_contract.json", "provenance.json", "LICENSE"};
constexpr std::array<std::pair<std::string_view, std::string_view>, 6> input_pins{{
    {"generate_geometry.py", "6ec14cfb35ecdec17c8aadb84f8370892355afeef46da5391d887390a2c4d73a"},
    {"geometry_contract.json", "86b50ebf37386520e42c5bf6eefbe2cc3bc01f35b27305528887c9d03182aa31"},
    {"provenance.json", "4455da9c001418eaf8e297f6a43a7c53b69f3ea61881c94bc091605a13590a7b"},
    {"LICENSE", "230184f60bae2feaf244f10a8bac053c8ff33a183bcc365b4d8b876d2b7f4809"},
    {"contrib/bmx-lab/bmx-plugin/plugin/bike_geometry.lua", "ea5516324173ab539be6a0a2f0765555c88cb0bc151eb9b9a577f3cacd0ed5ed"},
    {"contrib/bmx-lab/bmx-plugin/plugin/bike_visual.lua", "7daf2ba57a6f267ae41eb82b996ebd723163ca9b5ca0d579fab89549e5bb80d2"},
}};

[[noreturn]] void fail(std::string_view why) { throw std::runtime_error("Original canary: " + std::string(why)); }
void need(bool value, std::string_view why) { if (!value) fail(why); }
void fields(const Json& row, std::initializer_list<std::string_view> names) {
    need(row.is_object() && row.size() == names.size(), "unknown or missing JSON fields");
    for (const auto name : names) need(row.contains(name), "missing JSON field");
}
void text(const Json& row, std::string_view expected) {
    need(row.is_string() && row.string() == expected, "unexpected string value");
}
void flag(const Json& row, bool expected) {
    need(row.is_boolean() && row.get<bool>() == expected, "unexpected boolean value");
}
std::size_t count(const Json& row, std::size_t maximum) {
    need(row.is_number_integer(), "count must be an integer");
    const double value = row.get<double>();
    need(value >= 0 && value <= static_cast<double>(maximum), "count exceeds admission bound");
    return row.get<std::size_t>();
}
double number(const Json& row) {
    need(row.is_number(), "expected numeric geometry value");
    const double value = row.get<double>();
    need(std::isfinite(value) && std::abs(value) <= 10, "nonfinite or out-of-frame geometry value");
    return value;
}
Vec3 vector(const Json& row) {
    need(row.is_array() && row.size() == 3, "expected three geometry coordinates");
    return {number(row[0]), number(row[1]), number(row[2])};
}
void require_near(double actual, double expected, double tolerance = 1e-12) {
    need(std::abs(actual - expected) <= tolerance, "geometry differs from the original common frame");
}
void require_near(const Vec3& actual, const Vec3& expected, double tolerance = 1e-12) {
    for (std::size_t i = 0; i < 3; ++i) require_near(actual[i], expected[i], tolerance);
}
Vec3 add(const Vec3& a, const Vec3& b) { return {a[0] + b[0], a[1] + b[1], a[2] + b[2]}; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a[0] - b[0], a[1] - b[1], a[2] - b[2]}; }
Vec3 mul(const Vec3& a, double value) { return {a[0] * value, a[1] * value, a[2] * value}; }
double dot(const Vec3& a, const Vec3& b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
Vec3 cross(const Vec3& a, const Vec3& b) {
    return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}
bool label(std::string_view value) {
    if (value.empty() || value.size() > 64 || value.front() < 'a' || value.front() > 'z') return false;
    return std::all_of(value.begin(), value.end(), [](char c) {
        return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
    });
}
bool digest(std::string_view value) {
    return value.size() == 64 && std::all_of(value.begin(), value.end(), [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    });
}
Json parse(std::string_view bytes, std::size_t limit) {
    need(!bytes.empty() && bytes.size() <= limit, "JSON byte bound exceeded");
    return Json::parse(bytes, JsonLimits{limit, 16, 131072});
}

// The frozen scalar contract is data, never a recipe interpreter. These values
// match the six reviewed source pins; changing the frame needs a new review.
const Json& contract() {
    static const Json value = parse(R"json({
      "schema":1,"source":"contrib/bmx-lab/bmx-plugin/plugin/bike_geometry.lua",
      "source_commit":"cd749a68ee0ef86c3f3b7bb06022e8aad03c1e10",
      "coordinate_frame":{"x":"left","y":"up","z":"forward","handedness":"right","units":"metres after scale"},
      "scale":0.7737670588235294,"com_metres":[0,0.9,-0.05],"wheel_radius_unscaled":0.34,"wheelbase_unscaled":1.203956057050485,
      "anchors_unscaled":{
        "front_axle":[0,0.33993130346462175,0.6019780285252407],"rear_axle":[0,0.3399312125684516,-0.6019780285252407],
        "bottom_bracket":[0,0.4009181147792979,-0.13677059002727915],"steering_pivot":[0,0.9602538008020781,0.3685461188163388],
        "left_grip":[0.33457504536745686,1.2319480593290573,0.3406239453545827],
        "right_grip":[-0.33457504173973396,1.2319480453628473,0.34062398104089797],
        "left_pedal":[0.084980725506,0.211285091841,0.011246842761],"right_pedal":[-0.084980725506,0.590551321670,-0.284787818885]},
      "steering_axis":[0,0.9601195908265842,-0.279589648075517],
      "parts":[
        {"name":"frame","blueprint":"reskate/bmx/frame","group":"tailwhip"},
        {"name":"fork","blueprint":"reskate/bmx/fork","group":"front"},
        {"name":"rear_wheel","blueprint":"reskate/bmx/rear_wheel","group":"tailwhip","spin":"rear_wheel_phase","pivot":"rear_axle"},
        {"name":"front_wheel","blueprint":"reskate/bmx/front_wheel","group":"front","spin":"front_wheel_phase","pivot":"front_axle"},
        {"name":"cranks","blueprint":"reskate/bmx/cranks","group":"tailwhip","spin":"crank_phase","pivot":"bottom_bracket"},
        {"name":"handlebars","blueprint":"reskate/bmx/handlebars","group":"front"},
        {"name":"left_pedal","blueprint":"reskate/bmx/left_pedal","group":"tailwhip","orbit":"left_pedal","pivot":"bottom_bracket"},
        {"name":"right_pedal","blueprint":"reskate/bmx/right_pedal","group":"tailwhip","orbit":"right_pedal","pivot":"bottom_bracket"}],
      "pose_order":["wheel_or_crank_spin_about_positive_x_or_pedal_translation","front_steer_plus_barspin_or_tailwhip_about_steering_axis",
        "pitch_about_positive_x_at_steering_pivot","roll_about_positive_z_at_steering_pivot","measured_body_orientation_then_bike_root_translation"],
      "authoring":{"wheel_segments":64,"tire_sides":16,"tube_sides":12,"spoke_count":36,"tire_section_radius_unscaled":0.031,
        "pedal_half_extents_unscaled":[0.055,0.012,0.07],"seat_joint_unscaled":[0,0.78,-0.30],
        "saddle_center_unscaled":[0,0.91,-0.33],"saddle_radii_unscaled":[0.08,0.026,0.14]}
    })json", maximum_manifest_bytes);
    return value;
}
const Json& provenance() {
    static const Json value = parse(R"json({
      "schema":1,"asset_family":"ReSkate original procedural BMX",
      "origin":"New mathematical surface construction authored for this repository; no mesh or texture is imported.",
      "compatibility_source":"Scalar anchors and articulation roles from the repository's bike_geometry.lua and bike_visual.lua at cd749a68. These retain the existing Lua frame and do not change handling.",
      "geometry_sources":["closed cylinders","tori","boxes","ellipsoid"],
      "material_sources":["original constant metal, paint and rubber parameters"],
      "external_asset_inputs":[],"game_or_reference_payloads":[],"dependencies":["Python standard library"],
      "license_file":"LICENSE","source_license_file":"../../../../LICENSE",
      "license_note":"Source recipe, authored contract and generated original geometry are supplied under this repository's LICENSE. This does not license or include any game or third-party asset.",
      "native_resource_status":"Not compiled. OBJ/MTL and the JSON manifest are authoring intermediates, not a ReSkate resource pack.",
      "likeness_status":"Original generic BMX construction; no claim of an exact commercial model, tested appearance or gameplay parity."
    })json", maximum_manifest_bytes);
    return value;
}
const Json& materials() {
    static const Json value = parse(R"json({"schema":1,"normal_tangent_space":[0,0,1],
      "materials":{
        "paint":{"base_color":[0.075,0.09,0.105],"roughness":0.42,"metallic":0.0},
        "rubber":{"base_color":[0.025,0.028,0.032],"roughness":0.9,"metallic":0.0},
        "alloy":{"base_color":[0.52,0.55,0.58],"roughness":0.28,"metallic":1.0},
        "steel":{"base_color":[0.29,0.32,0.35],"roughness":0.22,"metallic":1.0}},
      "status":"Original constants; native shader compilation is separate."})json", maximum_manifest_bytes);
    return value;
}

Bounds bounds(const Json& row) {
    fields(row, {"min", "max"});
    Bounds result{vector(row["min"]), vector(row["max"])};
    for (std::size_t i = 0; i < 3; ++i) need(result.min[i] < result.max[i], "empty or reversed part bounds");
    return result;
}
void parameters(const Json& row, std::string_view kind) {
    if (kind == "box" || kind == "ellipsoid") {
        const auto extent = kind == "box" ? "half_extents" : "radii";
        fields(row, {"center", extent});
        (void)vector(row["center"]);
        for (const double value : vector(row[extent])) need(value > 0, "nonpositive primitive extent");
    } else if (kind == "cylinder") {
        fields(row, {"a", "b", "radius"});
        const auto direction = sub(vector(row["a"]), vector(row["b"]));
        need(dot(direction, direction) > 1e-18 && number(row["radius"]) > 0, "empty cylinder");
    } else if (kind == "torus_x") {
        fields(row, {"center", "major_radius", "minor_radius"});
        (void)vector(row["center"]);
        need(number(row["minor_radius"]) > 0 && number(row["major_radius"]) > number(row["minor_radius"]), "invalid torus");
    } else fail("unknown original primitive kind");
}
std::vector<Component> components(const Json& rows, std::size_t vertices, std::size_t triangles) {
    need(rows.is_array() && !rows.empty() && rows.size() <= 512, "invalid component count");
    std::vector<Component> result;
    std::set<std::string> labels;
    std::size_t next_vertex = 0, next_triangle = 0;
    for (const auto& row : rows) {
        fields(row, {"label", "kind", "material", "first_vertex", "vertex_count", "first_triangle", "triangle_count", "parameters"});
        need(row["label"].is_string() && label(row["label"].string()), "invalid component label");
        need(labels.insert(row["label"].string()).second, "duplicate component label");
        need(row["kind"].is_string() && row["material"].is_string(), "invalid component kind or material");
        const auto& material = row["material"].string();
        need(material == "paint" || material == "rubber" || material == "alloy" || material == "steel", "unknown original material");
        parameters(row["parameters"], row["kind"].string());
        Component component{row["label"].string(), material, count(row["first_vertex"], vertices), count(row["vertex_count"], vertices),
            count(row["first_triangle"], triangles), count(row["triangle_count"], triangles)};
        need(component.first_vertex == next_vertex && component.first_triangle == next_triangle &&
            component.vertex_count > 0 && component.triangle_count > 0 && component.vertex_count <= vertices - next_vertex &&
            component.triangle_count <= triangles - next_triangle, "component ranges must cover the part exactly");
        next_vertex += component.vertex_count; next_triangle += component.triangle_count;
        result.push_back(std::move(component));
    }
    need(next_vertex == vertices && next_triangle == triangles, "unowned part ranges");
    return result;
}
void selected_components(const Json& rows, const std::vector<Component>& selected) {
    need(selected.size() == 9, "the canary requires exactly nine pedal components");
    const Vec3 center = mul(vector(contract()["anchors_unscaled"]["left_pedal"]), scale);
    const Vec3 half = mul(Vec3{0.055, 0.012, 0.07}, scale);
    for (std::size_t i = 0; i < selected.size(); ++i) {
        const auto& value = selected[i];
        const auto& row = rows[i];
        if (i == 0) {
            need(value.label == "platform" && value.material == "alloy" && value.vertex_count == 24 && value.triangle_count == 12,
                "unexpected pedal platform");
            text(row["kind"], "box");
            require_near(vector(row["parameters"]["center"]), center, 1e-9);
            require_near(vector(row["parameters"]["half_extents"]), half, 1e-9);
        } else {
            const auto pin = i - 1;
            const double face = pin < 4 ? -1.0 : 1.0;
            const auto ix = (pin % 4) / 2, iz = pin % 2;
            const auto name = std::string("pin_") + (pin < 4 ? "bottom_" : "top_") + std::to_string(ix) + "_" + std::to_string(iz);
            need(value.label == name && value.material == "steel" && value.vertex_count == 30 && value.triangle_count == 24,
                "unexpected pedal pin");
            text(row["kind"], "cylinder");
            const auto a = add(center, Vec3{(ix == 0 ? -0.039 : 0.039) * scale, face * half[1], (iz == 0 ? -0.05 : 0.05) * scale});
            const auto b = add(a, Vec3{0, face * 0.007 * scale, 0});
            require_near(vector(row["parameters"]["a"]), a, 1e-9);
            require_near(vector(row["parameters"]["b"]), b, 1e-9);
            require_near(number(row["parameters"]["radius"]), 0.002 * scale, 1e-9);
        }
    }
}

struct Lines {
    std::string_view bytes;
    std::size_t offset{};
    std::string_view next() {
        need(offset < bytes.size(), "truncated original OBJ");
        const auto end = bytes.find('\n', offset);
        need(end != std::string_view::npos && end > offset && end - offset <= 512, "OBJ line bound or final newline missing");
        const auto result = bytes.substr(offset, end - offset); offset = end + 1; return result;
    }
};
std::vector<std::string_view> tokens(std::string_view line) {
    std::vector<std::string_view> result;
    std::size_t start = 0;
    for (;;) {
        const auto end = line.find(' ', start);
        const auto token = line.substr(start, end == std::string_view::npos ? line.size() - start : end - start);
        need(!token.empty() && result.size() < 5, "invalid OBJ token spacing or count");
        result.push_back(token);
        if (end == std::string_view::npos) return result;
        start = end + 1;
    }
}
double decimal(std::string_view token) {
    const auto digits = token.starts_with('-') ? token.substr(1) : token;
    const auto point = digits.find('.');
    need(point != std::string_view::npos && point > 0 && point + 10 == digits.size() &&
        (point == 1 || digits.front() != '0'), "OBJ requires fixed nine-decimal numbers");
    for (std::size_t i = 0; i < digits.size(); ++i) if (i != point)
        need(digits[i] >= '0' && digits[i] <= '9', "invalid OBJ decimal");
    double value{};
    const auto parsed = std::from_chars(token.data(), token.data() + token.size(), value, std::chars_format::fixed);
    need(parsed.ec == std::errc{} && parsed.ptr == token.data() + token.size() && std::isfinite(value) && std::abs(value) <= 10 &&
        !(value == 0 && token.starts_with('-')), "invalid OBJ numeric value");
    return value;
}
std::uint32_t index(std::string_view token) {
    need(!token.empty() && token.front() >= '1' && token.front() <= '9', "OBJ indices must be positive canonical integers");
    std::uint32_t value{};
    const auto parsed = std::from_chars(token.data(), token.data() + token.size(), value);
    need(parsed.ec == std::errc{} && parsed.ptr == token.data() + token.size() && value <= 264, "OBJ index exceeds selected mesh");
    return value - 1;
}
std::uint32_t corner(std::string_view token) {
    const auto first = token.find('/'), second = first == std::string_view::npos ? first : token.find('/', first + 1);
    need(first != std::string_view::npos && second != std::string_view::npos && token.find('/', second + 1) == std::string_view::npos,
        "OBJ face requires position/UV/normal triplets");
    const auto a = token.substr(0, first), b = token.substr(first + 1, second - first - 1), c = token.substr(second + 1);
    need(a == b && a == c, "OBJ corner indices must remain aligned");
    return index(a);
}
void geometry(AdmittedPart& part, std::string_view bytes) {
    need(!bytes.empty() && bytes.size() <= maximum_obj_bytes, "selected OBJ byte bound exceeded");
    for (const unsigned char c : bytes) need(c == '\n' || (c >= 32 && c <= 126), "OBJ must be ASCII with LF newlines");
    Lines lines{bytes};
    need(lines.next() == "# Original procedural BMX; see manifest.json and provenance.json." &&
        lines.next() == "# Metres; +X left, +Y up, +Z forward. Common bike-space origin." &&
        lines.next() == "mtllib materials.mtl" && lines.next() == "o left_pedal", "unexpected original OBJ preamble");
    part.vertices.resize(264);
    for (const auto kind : {std::string_view("v"), std::string_view("vt"), std::string_view("vn")}) {
        for (auto& vertex : part.vertices) {
            const auto row = tokens(lines.next());
            const auto width = kind == "vt" ? std::size_t{2} : std::size_t{3};
            need(row.size() == width + 1 && row[0] == kind, "unexpected OBJ directive or record count");
            for (std::size_t i = 0; i < width; ++i) {
                const double value = decimal(row[i + 1]);
                if (kind == "vt") {
                    need(value >= 0 && value <= 1, "OBJ UV outside original unit range"); vertex.uv[i] = value;
                } else if (kind == "vn") vertex.normal[i] = value;
                else vertex.position[i] = value;
            }
            if (kind == "vn") need(std::abs(dot(vertex.normal, vertex.normal) - 1) <= 1e-6, "OBJ normal is not unit length");
        }
    }
    part.triangles.reserve(204);
    for (const auto& component : part.components) {
        need(lines.next() == "g " + component.label && lines.next() == "usemtl " + component.material,
            "OBJ groups or original material assignments changed");
        std::vector<bool> used(component.vertex_count, false);
        double volume = 0;
        const auto origin = part.vertices[component.first_vertex].position;
        for (std::size_t i = 0; i < component.triangle_count; ++i) {
            const auto row = tokens(lines.next());
            need(row.size() == 4 && row[0] == "f", "OBJ supports triangles only");
            const std::array<std::uint32_t, 3> triangle{corner(row[1]), corner(row[2]), corner(row[3])};
            for (const auto vertex : triangle) {
                need(vertex >= component.first_vertex && vertex - component.first_vertex < component.vertex_count,
                    "OBJ triangle crosses a component boundary");
                used[vertex - component.first_vertex] = true;
            }
            const auto& a = part.vertices[triangle[0]];
            const auto& b = part.vertices[triangle[1]];
            const auto& c = part.vertices[triangle[2]];
            const auto surface = cross(sub(b.position, a.position), sub(c.position, a.position));
            need(dot(surface, surface) > 1e-24 && dot(surface, add(add(a.normal, b.normal), c.normal)) > 0,
                "degenerate or reversed original triangle");
            volume += dot(sub(a.position, origin), cross(sub(b.position, origin), sub(c.position, origin))) / 6;
            part.triangles.push_back(triangle);
        }
        need(std::all_of(used.begin(), used.end(), [](bool value) { return value; }), "unused component vertex");
        need(std::isfinite(volume) && volume > 1e-15, "component must enclose outward positive volume");
    }
    need(lines.offset == bytes.size() && part.triangles.size() == 204, "trailing OBJ directives or wrong triangle count");
    Bounds actual{part.vertices.front().position, part.vertices.front().position};
    for (const auto& vertex : part.vertices) for (std::size_t i = 0; i < 3; ++i) {
        actual.min[i] = std::min(actual.min[i], vertex.position[i]); actual.max[i] = std::max(actual.max[i], vertex.position[i]);
    }
    require_near(actual.min, part.bounds.min); require_near(actual.max, part.bounds.max);
    const auto center = mul(vector(contract()["anchors_unscaled"]["left_pedal"]), scale);
    const auto half = mul(Vec3{0.055, 0.019, 0.07}, scale);
    require_near(actual.min, sub(center, half), 1e-9); require_near(actual.max, add(center, half), 1e-9);
}
}

const std::array<std::string_view, 13>& payload_names() { return leaves; }

std::string sha256(std::string_view bytes) {
    need(bytes.size() <= maximum_total_payload_bytes, "hash input exceeds admission bound");
    struct Algorithm { BCRYPT_ALG_HANDLE value{}; ~Algorithm() { if (value) BCryptCloseAlgorithmProvider(value, 0); } } algorithm;
    need(BCryptOpenAlgorithmProvider(&algorithm.value, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0, "cannot initialize SHA-256");
    DWORD object_size{}, property_size{};
    need(BCryptGetProperty(algorithm.value, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&object_size),
        sizeof(object_size), &property_size, 0) >= 0 && property_size == sizeof(object_size) && object_size <= 1024 * 1024,
        "cannot query bounded SHA-256 state");
    std::vector<UCHAR> object(object_size);
    struct Hash { BCRYPT_HASH_HANDLE value{}; ~Hash() { if (value) BCryptDestroyHash(value); } } hash;
    need(BCryptCreateHash(algorithm.value, &hash.value, object.data(), object_size, nullptr, 0, 0) >= 0, "cannot create SHA-256 state");
    need(BCryptHashData(hash.value, reinterpret_cast<PUCHAR>(const_cast<char*>(bytes.data())),
        static_cast<ULONG>(bytes.size()), 0) >= 0, "cannot hash source bytes");
    std::array<UCHAR, 32> result{};
    need(BCryptFinishHash(hash.value, result.data(), static_cast<ULONG>(result.size()), 0) >= 0, "cannot finish SHA-256");
    constexpr char digits[] = "0123456789abcdef";
    std::string output; output.reserve(64);
    for (const auto byte : result) { output += digits[byte >> 4]; output += digits[byte & 15]; }
    return output;
}

AdmittedPart admit_original(std::string_view manifest, const Payloads& payloads) {
    const auto row = parse(manifest, maximum_manifest_bytes);
    fields(row, {"schema", "format", "native_ready", "coordinate_frame", "scale_applied", "common_origin_preserved", "com_subtracted",
        "com_metres", "wheel_radius_metres", "anchors_metres", "steering_axis_unit", "pose_order", "parts", "recipe_inputs_sha256", "payloads", "qualification"});
    need(count(row["schema"], 1) == 1, "unsupported original manifest schema");
    text(row["format"], "original-bmx-obj-v1"); flag(row["native_ready"], false);
    flag(row["common_origin_preserved"], true); flag(row["com_subtracted"], false);
    need(row["coordinate_frame"] == contract()["coordinate_frame"] && row["pose_order"] == contract()["pose_order"], "original frame or pose order changed");
    require_near(number(row["scale_applied"]), scale); require_near(vector(row["com_metres"]), vector(contract()["com_metres"]));
    require_near(number(row["wheel_radius_metres"]), 0.34 * scale);
    const auto& anchors = row["anchors_metres"];
    need(anchors.is_object() && anchors.size() == 8, "missing original anchors");
    for (const auto& [name, value] : contract()["anchors_unscaled"].items()) require_near(vector(anchors.at(name)), mul(vector(value), scale));
    const auto axis = vector(contract()["steering_axis"]);
    require_near(vector(row["steering_axis_unit"]), mul(axis, 1.0 / std::sqrt(dot(axis, axis))));
    const auto& pins = row["recipe_inputs_sha256"];
    need(pins.is_object() && pins.size() == input_pins.size(), "unexpected source-input hash table");
    for (const auto& [name, value] : input_pins) text(pins.at(name), value);
    const auto& qualified = row["qualification"];
    fields(qualified, {"offline_mesh_validation", "native_resource_build", "native_rendering", "gameplay_parity"});
    text(qualified["offline_mesh_validation"], "Performed by this generator, including serialized precision.");
    text(qualified["native_resource_build"], "not performed"); text(qualified["native_rendering"], "not performed"); text(qualified["gameplay_parity"], "not measured");
    const auto& hashes = row["payloads"];
    need(payloads.size() == leaves.size() && hashes.is_object() && hashes.size() == leaves.size(), "original payload set differs");
    std::size_t total = 0;
    for (const auto name : leaves) {
        const auto found = payloads.find(std::string(name));
        need(found != payloads.end() && !found->second.empty() && found->second.size() <= maximum_payload_bytes, "missing or oversized original payload");
        need(found->second.size() <= maximum_total_payload_bytes - total, "original package byte bound exceeded");
        total += found->second.size();
        const auto& expected = hashes.at(name); fields(expected, {"bytes", "sha256"});
        need(count(expected["bytes"], maximum_payload_bytes) == found->second.size(), "original payload size mismatch");
        need(expected["sha256"].is_string() && digest(expected["sha256"].string()) && sha256(found->second) == expected["sha256"].string(), "original payload hash mismatch");
    }
    const auto parsed_contract = parse(payloads.at("geometry_contract.json"), maximum_manifest_bytes);
    need(count(parsed_contract.at("schema"), 1) == 1 && parsed_contract == contract(), "original scalar contract changed");
    const auto parsed_provenance = parse(payloads.at("provenance.json"), maximum_manifest_bytes);
    need(count(parsed_provenance.at("schema"), 1) == 1 && parsed_provenance == provenance(), "unreviewed original provenance");
    const auto parsed_materials = parse(payloads.at("materials.json"), maximum_manifest_bytes);
    need(count(parsed_materials.at("schema"), 1) == 1 && parsed_materials == materials(), "original material metadata changed");
    text(hashes.at("LICENSE")["sha256"], input_pins[3].second);

    const auto& rows = row["parts"];
    need(rows.is_array() && rows.size() == parts.size(), "original package must describe eight ordered parts");
    AdmittedPart result;
    for (std::size_t i = 0; i < parts.size(); ++i) {
        const auto& part = rows[i]; const auto& role = contract()["parts"][i];
        need(part.is_object() && part.size() == role.size() + 5, "unknown or missing part fields");
        for (const auto& [name, value] : role.items()) need(part.at(name) == value, "original part identity or articulation changed");
        text(part.at("file"), std::string(parts[i]) + ".obj");
        const auto vertices = count(part.at("vertices"), 65535), triangles = count(part.at("triangles"), 131072);
        need(vertices > 0 && triangles > 0, "empty original part");
        const auto part_bounds = bounds(part.at("bounds_metres"));
        auto part_components = components(part.at("components"), vertices, triangles);
        if (parts[i] == "left_pedal") {
            need(vertices == 264 && triangles == 204, "selected original pedal count changed");
            selected_components(part.at("components"), part_components);
            result.components = std::move(part_components); result.bounds = part_bounds;
        }
    }
    geometry(result, payloads.at("left_pedal.obj"));
    result.manifest_sha256 = sha256(manifest);
    return result;
}

void validate_unqualified_recipe(std::string_view recipe) {
    const auto row = parse(recipe, maximum_recipe_bytes);
    fields(row, {"schema", "kind", "status", "supported_build", "part", "input_format", "output_namespace", "output_policy", "auto_install",
        "preserve_common_origin", "preserve_normals", "preserve_uvs", "expected_manifest_sha256", "native_identities"});
    need(count(row["schema"], 1) == 1 && count(row["supported_build"], 20260929) == 20260929, "unsupported canary recipe build or schema");
    text(row["kind"], "original-native-canary-v1"); text(row["status"], "unqualified"); text(row["part"], "left_pedal");
    text(row["input_format"], "original-bmx-obj-v1"); text(row["output_namespace"], "reskate/original_canary/left_pedal");
    text(row["output_policy"], "new_local_cache_only"); text(row["expected_manifest_sha256"], expected_manifest_sha256);
    flag(row["auto_install"], false); flag(row["preserve_common_origin"], true); flag(row["preserve_normals"], true); flag(row["preserve_uvs"], true);
    const auto& identities = row["native_identities"];
    fields(identities, {"template", "mesh_declaration", "lod", "material_alloy", "material_steel"});
    for (const auto& [name, value] : identities.items()) { (void)name; need(value.is_null(), "native canary identities remain unqualified"); }
}
}
