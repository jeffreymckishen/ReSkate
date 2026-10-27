#!/usr/bin/env python3
"""Author original BMX OBJ parts in the existing Lua bike frame.

Only mathematical primitives and the adjacent authored contract are inputs.
This is a source-geometry intermediate, not a Frostbite resource compiler.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any

SOURCE_DIR = Path(__file__).resolve().parent
PART_NAMES = (
    "frame", "fork", "rear_wheel", "front_wheel", "cranks", "handlebars",
    "left_pedal", "right_pedal",
)
ANCHOR_NAMES = (
    "front_axle", "rear_axle", "bottom_bracket", "steering_pivot",
    "left_grip", "right_grip", "left_pedal", "right_pedal",
)
PART_ROLES = {
    "frame": {}, "fork": {},
    "rear_wheel": {"spin": "rear_wheel_phase", "pivot": "rear_axle"},
    "front_wheel": {"spin": "front_wheel_phase", "pivot": "front_axle"},
    "cranks": {"spin": "crank_phase", "pivot": "bottom_bracket"},
    "handlebars": {},
    "left_pedal": {"orbit": "left_pedal", "pivot": "bottom_bracket"},
    "right_pedal": {"orbit": "right_pedal", "pivot": "bottom_bracket"},
}
POSE_ORDER = [
    "wheel_or_crank_spin_about_positive_x_or_pedal_translation",
    "front_steer_plus_barspin_or_tailwhip_about_steering_axis",
    "pitch_about_positive_x_at_steering_pivot",
    "roll_about_positive_z_at_steering_pivot",
    "measured_body_orientation_then_bike_root_translation",
]
MATERIALS = {
    "paint": {"base_color": [0.075, 0.09, 0.105], "roughness": 0.42, "metallic": 0.0},
    "rubber": {"base_color": [0.025, 0.028, 0.032], "roughness": 0.9, "metallic": 0.0},
    "alloy": {"base_color": [0.52, 0.55, 0.58], "roughness": 0.28, "metallic": 1.0},
    "steel": {"base_color": [0.29, 0.32, 0.35], "roughness": 0.22, "metallic": 1.0},
}
Vec3 = tuple[float, float, float]


def add(a: Vec3, b: Vec3) -> Vec3:
    return tuple(a[i] + b[i] for i in range(3))


def sub(a: Vec3, b: Vec3) -> Vec3:
    return tuple(a[i] - b[i] for i in range(3))


def mul(a: Vec3, amount: float) -> Vec3:
    return tuple(x * amount for x in a)


def dot(a: Vec3, b: Vec3) -> float:
    return sum(a[i] * b[i] for i in range(3))


def cross(a: Vec3, b: Vec3) -> Vec3:
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def unit(a: Vec3) -> Vec3:
    length = math.sqrt(dot(a, a))
    if not math.isfinite(length) or length <= 1e-12:
        raise ValueError("cannot normalize a zero or invalid direction")
    return mul(a, 1.0 / length)


def finite_number(value: Any) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def vector(value: Any, label: str) -> Vec3:
    if not isinstance(value, (list, tuple)) or len(value) != 3 or not all(finite_number(x) for x in value):
        raise ValueError(f"{label} must contain three finite numbers")
    if max(abs(x) for x in value) > 10:
        raise ValueError(f"{label} exceeds the bounded bike authoring frame")
    return tuple(float(x) for x in value)


def validate_contract(contract: dict[str, Any]) -> None:
    if contract.get("schema") != 1:
        raise ValueError("unsupported geometry contract")
    scale = contract.get("scale")
    if not finite_number(scale) or not 0 < scale <= 1:
        raise ValueError("invalid source-to-metre scale")
    if contract.get("coordinate_frame") != {
        "x": "left", "y": "up", "z": "forward", "handedness": "right", "units": "metres after scale",
    }:
        raise ValueError("unsupported coordinate frame")
    anchors = contract.get("anchors_unscaled", {})
    if set(anchors) != set(ANCHOR_NAMES):
        raise ValueError("missing or unexpected compatibility anchor")
    for name in ANCHOR_NAMES:
        vector(anchors[name], name)
    vector(contract.get("com_metres"), "unscaled COM")
    unit(vector(contract.get("steering_axis"), "steering axis"))
    radius = contract.get("wheel_radius_unscaled")
    wheelbase = contract.get("wheelbase_unscaled")
    if not finite_number(radius) or not 0.1 < radius < 1:
        raise ValueError("invalid wheel radius")
    if not finite_number(wheelbase) or abs(anchors["front_axle"][2] - anchors["rear_axle"][2] - wheelbase) > 1e-12:
        raise ValueError("axles disagree with the compatibility wheelbase")
    parts = contract.get("parts", [])
    if [part.get("name") for part in parts] != list(PART_NAMES):
        raise ValueError("part order must match bike_visual.lua")
    for part in parts:
        name = part["name"]
        if part.get("blueprint") != "reskate/bmx/" + name:
            raise ValueError("unexpected blueprint identity")
        expected_group = "front" if name in ("fork", "front_wheel", "handlebars") else "tailwhip"
        expected = {"name": name, "blueprint": "reskate/bmx/" + name, "group": expected_group, **PART_ROLES[name]}
        if part != expected:
            raise ValueError("part has incompatible articulation roles or extra fields")
    if contract.get("pose_order") != POSE_ORDER:
        raise ValueError("articulation order differs from bike_visual.lua")
    authoring = contract.get("authoring", {})
    for key, low, high in (("wheel_segments", 16, 128), ("tire_sides", 8, 32), ("tube_sides", 6, 24), ("spoke_count", 8, 64)):
        value = authoring.get(key)
        if type(value) is not int or not low <= value <= high:
            raise ValueError(f"invalid {key}")
    if authoring["wheel_segments"] % 4 or authoring["tire_sides"] % 4 or authoring["spoke_count"] % 2:
        raise ValueError("wheel extrema and alternating spoke sides require complete cardinal/even sampling")
    section = authoring.get("tire_section_radius_unscaled")
    if not finite_number(section) or not 0 < section < radius / 3:
        raise ValueError("invalid tire section")
    for key in ("pedal_half_extents_unscaled", "saddle_radii_unscaled"):
        if min(vector(authoring.get(key), key)) <= 0:
            raise ValueError(f"{key} must be positive")
    for key in ("seat_joint_unscaled", "saddle_center_unscaled"):
        vector(authoring.get(key), key)


def load_contract(path: Path | None = None) -> dict[str, Any]:
    contract = json.loads((path or SOURCE_DIR / "geometry_contract.json").read_text(encoding="utf-8-sig"))
    validate_contract(contract)
    return contract


@dataclass(frozen=True)
class Vertex:
    position: Vec3
    normal: Vec3
    uv: tuple[float, float]


@dataclass
class Mesh:
    name: str
    vertices: list[Vertex] = field(default_factory=list)
    triangles: list[tuple[int, int, int]] = field(default_factory=list)
    components: list[dict[str, Any]] = field(default_factory=list)

    def vertex(self, position: Vec3, normal: Vec3, uv: tuple[float, float]) -> int:
        self.vertices.append(Vertex(position, normal, uv))
        return len(self.vertices) - 1

    def begin(self, label: str) -> tuple[int, int]:
        if not re.fullmatch(r"[a-z][a-z0-9_]*", label) or any(c["label"] == label for c in self.components):
            raise ValueError("invalid or duplicate primitive label")
        return len(self.vertices), len(self.triangles)

    def finish(self, start: tuple[int, int], label: str, kind: str, material: str, **parameters: Any) -> None:
        self.components.append({
            "label": label, "kind": kind, "material": material,
            "first_vertex": start[0], "vertex_count": len(self.vertices) - start[0],
            "first_triangle": start[1], "triangle_count": len(self.triangles) - start[1],
            "parameters": parameters,
        })


def add_tube(mesh: Mesh, label: str, a: Vec3, b: Vec3, radius: float, material: str, sides: int = 12) -> None:
    if not finite_number(radius) or radius <= 0 or type(sides) is not int or sides < 3:
        raise ValueError("invalid cylinder radius or tessellation")
    axis = unit(sub(b, a))
    helper = (1.0, 0.0, 0.0) if abs(axis[0]) < 0.8 else (0.0, 1.0, 0.0)
    u = unit(cross(helper, axis))
    v = cross(axis, u)
    start = mesh.begin(label)
    rings = []
    for center, height in ((a, 0.0), (b, 1.0)):
        ring = []
        for i in range(sides + 1):
            theta = math.tau * i / sides
            normal = add(mul(u, math.cos(theta)), mul(v, math.sin(theta)))
            ring.append(mesh.vertex(add(center, mul(normal, radius)), normal, (i / sides, height)))
        rings.append(ring)
    for i in range(sides):
        mesh.triangles.extend(((rings[0][i], rings[0][i + 1], rings[1][i + 1]), (rings[0][i], rings[1][i + 1], rings[1][i])))
    for center, direction in ((a, -1.0), (b, 1.0)):
        normal = mul(axis, direction)
        middle = mesh.vertex(center, normal, (0.5, 0.5))
        cap = []
        for i in range(sides + 1):
            theta = math.tau * i / sides
            radial = add(mul(u, math.cos(theta)), mul(v, math.sin(theta)))
            cap.append(mesh.vertex(add(center, mul(radial, radius)), normal, (0.5 + 0.5 * math.cos(theta), 0.5 + 0.5 * math.sin(theta))))
        for i in range(sides):
            mesh.triangles.append((middle, cap[i], cap[i + 1]) if direction > 0 else (middle, cap[i + 1], cap[i]))
    mesh.finish(start, label, "cylinder", material, a=a, b=b, radius=radius)


def add_torus(mesh: Mesh, label: str, center: Vec3, major: float, minor: float, material: str, segments: int = 64, sides: int = 16) -> None:
    if not all(finite_number(x) for x in (major, minor)) or not 0 < minor < major or segments < 4 or sides < 4:
        raise ValueError("invalid torus dimensions or tessellation")
    start = mesh.begin(label)
    rows = []
    for i in range(segments + 1):
        theta = math.tau * i / segments
        row = []
        for j in range(sides + 1):
            phi = math.tau * j / sides
            normal = (math.sin(phi), math.cos(phi) * math.cos(theta), math.cos(phi) * math.sin(theta))
            radial = major + minor * math.cos(phi)
            position = add(center, (minor * math.sin(phi), radial * math.cos(theta), radial * math.sin(theta)))
            row.append(mesh.vertex(position, normal, (i / segments, j / sides)))
        rows.append(row)
    for i in range(segments):
        for j in range(sides):
            mesh.triangles.extend(((rows[i][j], rows[i + 1][j], rows[i + 1][j + 1]), (rows[i][j], rows[i + 1][j + 1], rows[i][j + 1])))
    mesh.finish(start, label, "torus_x", material, center=center, major_radius=major, minor_radius=minor)


def add_box(mesh: Mesh, label: str, center: Vec3, half: Vec3, material: str) -> None:
    if min(half) <= 0 or not all(finite_number(x) for x in half):
        raise ValueError("invalid box extents")
    start = mesh.begin(label)
    x, y, z = half
    faces = (
        ((x, 0, 0), (0, y, 0), (0, 0, z), (1, 0, 0)),
        ((-x, 0, 0), (0, y, 0), (0, 0, -z), (-1, 0, 0)),
        ((0, y, 0), (0, 0, z), (x, 0, 0), (0, 1, 0)),
        ((0, -y, 0), (0, 0, z), (-x, 0, 0), (0, -1, 0)),
        ((0, 0, z), (x, 0, 0), (0, y, 0), (0, 0, 1)),
        ((0, 0, -z), (x, 0, 0), (0, -y, 0), (0, 0, -1)),
    )
    for offset, u, v, normal in faces:
        indices = []
        for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            position = add(add(add(center, offset), mul(u, su)), mul(v, sv))
            indices.append(mesh.vertex(position, normal, ((su + 1) / 2, (sv + 1) / 2)))
        mesh.triangles.extend(((indices[0], indices[1], indices[2]), (indices[0], indices[2], indices[3])))
    mesh.finish(start, label, "box", material, center=center, half_extents=half)


def add_ellipsoid(mesh: Mesh, label: str, center: Vec3, radii: Vec3, material: str, segments: int = 24, latitudes: int = 12) -> None:
    if min(radii) <= 0 or not all(finite_number(x) for x in radii) or segments < 4 or latitudes < 3:
        raise ValueError("invalid ellipsoid dimensions or tessellation")
    start = mesh.begin(label)
    rings = []
    for latitude in range(1, latitudes):
        phi = math.pi * latitude / latitudes
        ring = []
        for i in range(segments + 1):
            theta = math.tau * i / segments
            relative = (radii[0] * math.sin(phi) * math.cos(theta), radii[1] * math.cos(phi), radii[2] * math.sin(phi) * math.sin(theta))
            normal = unit(tuple(relative[j] / (radii[j] * radii[j]) for j in range(3)))
            ring.append(mesh.vertex(add(center, relative), normal, (i / segments, latitude / latitudes)))
        rings.append(ring)
    for row in range(len(rings) - 1):
        for i in range(segments):
            mesh.triangles.extend(((rings[row][i], rings[row][i + 1], rings[row + 1][i + 1]), (rings[row][i], rings[row + 1][i + 1], rings[row + 1][i])))
    # Fans avoid zero-area quads at the poles and give each fan a local UV.
    for i in range(segments):
        top = mesh.vertex(add(center, (0, radii[1], 0)), (0, 1, 0), ((i + 0.5) / segments, 0))
        bottom = mesh.vertex(add(center, (0, -radii[1], 0)), (0, -1, 0), ((i + 0.5) / segments, 1))
        mesh.triangles.extend(((top, rings[0][i + 1], rings[0][i]), (bottom, rings[-1][i], rings[-1][i + 1])))
    mesh.finish(start, label, "ellipsoid", material, center=center, radii=radii)


def bounds(mesh: Mesh) -> tuple[Vec3, Vec3]:
    if not mesh.vertices:
        raise ValueError("empty mesh")
    return tuple(min(v.position[i] for v in mesh.vertices) for i in range(3)), tuple(max(v.position[i] for v in mesh.vertices) for i in range(3))


def validate_mesh(mesh: Mesh) -> None:
    if not mesh.vertices or not mesh.triangles or not mesh.components:
        raise ValueError("mesh must have vertices, triangles and authored components")
    for vertex in mesh.vertices:
        vector(vertex.position, "vertex position")
        if len(vertex.normal) != 3 or not all(finite_number(x) for x in vertex.normal) or abs(dot(vertex.normal, vertex.normal) - 1) > 1e-6:
            raise ValueError("invalid unit normal")
        if len(vertex.uv) != 2 or not all(finite_number(x) and -1e-12 <= x <= 1 + 1e-12 for x in vertex.uv):
            raise ValueError("invalid UV")
    expected_vertex = expected_triangle = 0
    labels = set()
    for component in mesh.components:
        label = component["label"]
        if label in labels or not re.fullmatch(r"[a-z][a-z0-9_]*", label) or component["material"] not in MATERIALS:
            raise ValueError("invalid component label or material")
        labels.add(label)
        if component["first_vertex"] != expected_vertex or component["first_triangle"] != expected_triangle or min(component["vertex_count"], component["triangle_count"]) <= 0:
            raise ValueError("component ranges must cover the mesh exactly")
        vertex_end = expected_vertex + component["vertex_count"]
        triangle_end = expected_triangle + component["triangle_count"]
        if vertex_end > len(mesh.vertices) or triangle_end > len(mesh.triangles):
            raise ValueError("component range exceeds mesh")
        signed_volume = 0.0
        # Use a nearby origin to avoid losing small spoke volumes to cancellation.
        reference = mesh.vertices[expected_vertex].position
        used = set()
        for triangle in mesh.triangles[expected_triangle:triangle_end]:
            if len(triangle) != 3 or any(type(index) is not int or not expected_vertex <= index < vertex_end for index in triangle):
                raise ValueError("triangle index escapes its authored component")
            a, b, c = (mesh.vertices[index] for index in triangle)
            surface = cross(sub(b.position, a.position), sub(c.position, a.position))
            if math.sqrt(dot(surface, surface)) <= 1e-12:
                raise ValueError("degenerate triangle")
            if dot(surface, add(add(a.normal, b.normal), c.normal)) <= 0:
                raise ValueError("triangle winding disagrees with normals")
            signed_volume += dot(sub(a.position, reference), cross(sub(b.position, reference), sub(c.position, reference))) / 6
            used.update(triangle)
        if len(used) != component["vertex_count"]:
            raise ValueError("unused vertices in component")
        if not math.isfinite(signed_volume) or signed_volume <= 1e-15:
            raise ValueError("component winding must enclose positive volume")
        expected_vertex, expected_triangle = vertex_end, triangle_end
    if expected_vertex != len(mesh.vertices) or expected_triangle != len(mesh.triangles):
        raise ValueError("unowned mesh data")


def validate_wheel(mesh: Mesh, contract: dict[str, Any]) -> None:
    anchor_name = {"front_wheel": "front_axle", "rear_wheel": "rear_axle"}[mesh.name]
    axle = mul(tuple(contract["anchors_unscaled"][anchor_name]), contract["scale"])
    radius = contract["wheel_radius_unscaled"] * contract["scale"]
    low, high = bounds(mesh)
    if any(abs((low[i] + high[i]) * 0.5 - axle[i]) > 1e-8 for i in range(3)):
        raise ValueError("wheel bounds must preserve the Lua axle, without recentering")
    if any(abs((high[i] - low[i]) * 0.5 - radius) > 1e-8 for i in (1, 2)):
        raise ValueError("wheel bounds disagree with the Lua wheel radius")
    if any(math.hypot(v.position[1] - axle[1], v.position[2] - axle[2]) > radius + 1e-8 for v in mesh.vertices):
        raise ValueError("wheel component extends beyond the tire")


def build_bike(contract: dict[str, Any]) -> dict[str, Mesh]:
    validate_contract(contract)
    scale = contract["scale"]
    raw = lambda x, y, z: (x * scale, y * scale, z * scale)
    anchors = {name: mul(vector(value, name), scale) for name, value in contract["anchors_unscaled"].items()}
    shape = contract["authoring"]
    axis = unit(tuple(contract["steering_axis"]))
    front, rear, bracket, steering = (anchors[name] for name in ("front_axle", "rear_axle", "bottom_bracket", "steering_pivot"))
    radius = contract["wheel_radius_unscaled"] * scale
    sides = shape["tube_sides"]
    meshes = {name: Mesh(name) for name in PART_NAMES}

    frame = meshes["frame"]
    seat_joint = mul(tuple(shape["seat_joint_unscaled"]), scale)
    saddle = mul(tuple(shape["saddle_center_unscaled"]), scale)
    head_low = add(steering, mul(axis, -0.075 * scale))
    head_high = add(steering, mul(axis, 0.075 * scale))
    for label, start, end, thickness in (
        ("seat_tube", bracket, seat_joint, 0.019),
        ("top_tube", seat_joint, head_high, 0.019),
        ("down_tube", bracket, head_low, 0.023),
        ("head_tube", head_low, head_high, 0.033),
        ("seat_post", seat_joint, sub(saddle, raw(0, 0.02, 0)), 0.013),
    ):
        add_tube(frame, label, start, end, thickness * scale, "paint", sides)
    add_tube(frame, "bottom_bracket_shell", add(bracket, raw(-0.055, 0, 0)), add(bracket, raw(0.055, 0, 0)), 0.035 * scale, "paint", sides)
    for side, suffix in ((1, "left"), (-1, "right")):
        dropout = add(rear, raw(side * 0.065, 0, 0))
        add_tube(frame, "chainstay_" + suffix, add(bracket, raw(side * 0.035, 0, 0)), dropout, 0.013 * scale, "paint", sides)
        add_tube(frame, "seatstay_" + suffix, add(seat_joint, raw(side * 0.018, 0, 0)), dropout, 0.010 * scale, "paint", sides)
        add_tube(frame, "dropout_" + suffix, add(dropout, raw(-0.007, 0, 0)), add(dropout, raw(0.007, 0, 0)), 0.027 * scale, "steel", sides)
    add_ellipsoid(frame, "saddle", saddle, mul(tuple(shape["saddle_radii_unscaled"]), scale), "rubber")
    # This original static chain is visual only; it changes no drive physics.
    chain_x = -0.067 * scale
    for direction, label in ((1, "chain_upper"), (-1, "chain_lower")):
        add_tube(frame, label, (chain_x, bracket[1] + direction * 0.075 * scale, bracket[2]),
                 (chain_x, rear[1] + direction * 0.037 * scale, rear[2]), 0.003 * scale, "steel", 8)

    fork = meshes["fork"]
    crown = add(steering, mul(axis, -0.17 * scale))
    steerer_top = add(steering, mul(axis, 0.11 * scale))
    add_tube(fork, "steerer", crown, steerer_top, 0.018 * scale, "steel", sides)
    add_tube(fork, "crown", add(crown, raw(-0.055, 0, 0)), add(crown, raw(0.055, 0, 0)), 0.020 * scale, "paint", sides)
    for side, suffix in ((1, "left"), (-1, "right")):
        shoulder = add(crown, raw(side * 0.055, 0, 0))
        knee = raw(side * 0.060, 0.52, 0.53)
        dropout = add(front, raw(side * 0.065, 0, 0))
        add_tube(fork, "leg_upper_" + suffix, shoulder, knee, 0.018 * scale, "paint", sides)
        add_tube(fork, "leg_lower_" + suffix, knee, dropout, 0.016 * scale, "paint", sides)
        add_tube(fork, "dropout_" + suffix, add(dropout, raw(-0.007, 0, 0)), add(dropout, raw(0.007, 0, 0)), 0.027 * scale, "steel", sides)

    for name, center in (("rear_wheel", rear), ("front_wheel", front)):
        wheel = meshes[name]
        section = shape["tire_section_radius_unscaled"] * scale
        rim_major, rim_minor = radius - 1.85 * section, 0.006 * scale
        add_torus(wheel, "tire", center, radius - section, section, "rubber", shape["wheel_segments"], shape["tire_sides"])
        add_torus(wheel, "rim", center, rim_major, rim_minor, "alloy", shape["wheel_segments"], 12)
        add_tube(wheel, "hub", add(center, raw(-0.055, 0, 0)), add(center, raw(0.055, 0, 0)), 0.025 * scale, "alloy", 24)
        add_tube(wheel, "axle", add(center, raw(-0.083, 0, 0)), add(center, raw(0.083, 0, 0)), 0.009 * scale, "steel", 12)
        for side, suffix in ((1, "left"), (-1, "right")):
            add_tube(wheel, "flange_" + suffix, add(center, raw(side * 0.037 - 0.004, 0, 0)),
                     add(center, raw(side * 0.037 + 0.004, 0, 0)), 0.036 * scale, "alloy", 24)
        count = shape["spoke_count"]
        for i in range(count):
            theta = math.tau * i / count
            side = 1 if i % 2 == 0 else -1
            hub_theta = theta + side * math.tau * 2 / count
            hub_end = add(center, (side * 0.037 * scale, 0.030 * scale * math.cos(hub_theta), 0.030 * scale * math.sin(hub_theta)))
            rim_end = add(center, (side * 0.004 * scale, (rim_major - rim_minor) * math.cos(theta), (rim_major - rim_minor) * math.sin(theta)))
            add_tube(wheel, f"spoke_{i:02d}", hub_end, rim_end, 0.0013 * scale, "steel", 6)
        if name == "rear_wheel":
            add_tube(wheel, "rear_sprocket", add(center, raw(-0.071, 0, 0)), add(center, raw(-0.063, 0, 0)), 0.037 * scale, "steel", 24)

    cranks = meshes["cranks"]
    add_tube(cranks, "spindle", add(bracket, raw(-0.060, 0, 0)), add(bracket, raw(0.060, 0, 0)), 0.014 * scale, "steel", sides)
    add_torus(cranks, "chainring", add(bracket, raw(-0.067, 0, 0)), 0.075 * scale, 0.006 * scale, "alloy", 48, 8)
    for side, name in ((1, "left_pedal"), (-1, "right_pedal")):
        pedal = anchors[name]
        inner = add(pedal, raw(-side * 0.0385, 0, 0))
        add_tube(cranks, "arm_" + name, add(bracket, raw(side * 0.055, 0, 0)), inner, 0.012 * scale, "alloy", sides)
        add_tube(cranks, "spindle_" + name, inner, add(pedal, raw(side * 0.025, 0, 0)), 0.007 * scale, "steel", sides)

    bars = meshes["handlebars"]
    bar_base = raw(0, 1.08, 0.40)
    add_tube(bars, "stem", steerer_top, bar_base, 0.023 * scale, "paint", sides)
    for side, name in ((1, "left_grip"), (-1, "right_grip")):
        grip = anchors[name]
        low = raw(side * 0.17, 1.08, 0.40)
        high = raw(side * 0.25, 1.20, 0.36)
        bar_end = add(grip, raw(side * 0.060, 0, 0))
        add_tube(bars, "lower_" + name, bar_base, low, 0.014 * scale, "paint", sides)
        add_tube(bars, "riser_" + name, low, high, 0.014 * scale, "paint", sides)
        add_tube(bars, "upper_" + name, high, bar_end, 0.012 * scale, "paint", sides)
        add_tube(bars, name, add(grip, raw(-0.055, 0, 0)), add(grip, raw(0.055, 0, 0)), 0.020 * scale, "rubber", 20)
    add_tube(bars, "crossbar", raw(-0.23, 1.18, 0.37), raw(0.23, 1.18, 0.37), 0.011 * scale, "paint", sides)

    half = mul(tuple(shape["pedal_half_extents_unscaled"]), scale)
    for name in ("left_pedal", "right_pedal"):
        pedal = meshes[name]
        center = anchors[name]
        add_box(pedal, "platform", center, half, "alloy")
        # The platform and pins are a separate rigid part. Only its spindle
        # translation follows the crank; exporting it on the crank would tumble it.
        for face in (-1, 1):
            for ix, x in enumerate((-0.039, 0.039)):
                for iz, z in enumerate((-0.05, 0.05)):
                    pin_base = add(center, (x * scale, face * half[1], z * scale))
                    pin_end = add(pin_base, raw(0, face * 0.007, 0))
                    add_tube(pedal, f"pin_{'top' if face > 0 else 'bottom'}_{ix}_{iz}", pin_base, pin_end, 0.002 * scale, "steel", 6)
    for mesh in meshes.values():
        validate_mesh(mesh)
        if mesh.name in ("front_wheel", "rear_wheel"):
            validate_wheel(mesh, contract)
    return meshes


def rounded(value: Any) -> Any:
    if isinstance(value, float):
        value = round(value, 9)
        return 0.0 if value == 0 else value
    if isinstance(value, (list, tuple)):
        return [rounded(item) for item in value]
    if isinstance(value, dict):
        return {key: rounded(item) for key, item in value.items()}
    return value


def quantized_mesh(mesh: Mesh) -> Mesh:
    result = Mesh(mesh.name, [Vertex(tuple(rounded(v.position)), tuple(rounded(v.normal)), tuple(rounded(v.uv))) for v in mesh.vertices], list(mesh.triangles), list(mesh.components))
    validate_mesh(result)
    return result


def number(value: float) -> str:
    # Fixed precision and canonical zero make OBJ independent of locale/path.
    return f"{rounded(float(value)):.9f}"


def obj_bytes(mesh: Mesh) -> bytes:
    mesh = quantized_mesh(mesh)
    lines = ["# Original procedural BMX; see manifest.json and provenance.json.", "# Metres; +X left, +Y up, +Z forward. Common bike-space origin.", "mtllib materials.mtl", f"o {mesh.name}"]
    for vertex in mesh.vertices:
        lines.append("v " + " ".join(number(x) for x in vertex.position))
    for vertex in mesh.vertices:
        lines.append("vt " + " ".join(number(x) for x in vertex.uv))
    for vertex in mesh.vertices:
        lines.append("vn " + " ".join(number(x) for x in vertex.normal))
    for component in mesh.components:
        lines.extend(("g " + component["label"], "usemtl " + component["material"]))
        start = component["first_triangle"]
        for triangle in mesh.triangles[start:start + component["triangle_count"]]:
            lines.append("f " + " ".join(f"{index + 1}/{index + 1}/{index + 1}" for index in triangle))
    return ("\n".join(lines) + "\n").encode("ascii")


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True, allow_nan=False) + "\n").encode("utf-8")


def material_bytes() -> bytes:
    lines = ["# Original constant preview materials; not native shader bytecode."]
    for name, material in MATERIALS.items():
        # MTL is only a preview approximation of the separately recorded PBR constants.
        specular = 0.6 if material["metallic"] else 0.12
        exponent = max(1.0, 2.0 / material["roughness"] ** 2 - 2.0)
        lines.extend(("newmtl " + name, "Ka 0.000000000 0.000000000 0.000000000", "Kd " + " ".join(number(v) for v in material["base_color"]),
                      "Ks " + " ".join([number(specular)] * 3), "Ns " + number(exponent), "d 1.000000000", "illum 2", ""))
    return ("\n".join(lines) + "\n").encode("ascii")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_payloads() -> dict[str, bytes]:
    contract = load_contract()
    meshes = build_bike(contract)
    payloads = {name + ".obj": obj_bytes(meshes[name]) for name in PART_NAMES}
    payloads["materials.mtl"] = material_bytes()
    payloads["materials.json"] = json_bytes({"schema": 1, "normal_tangent_space": [0, 0, 1], "materials": MATERIALS, "status": "Original constants; native shader compilation is separate."})
    payloads["geometry_contract.json"] = json_bytes(contract)
    provenance = json.loads((SOURCE_DIR / "provenance.json").read_text(encoding="utf-8-sig"))
    provenance["source_license_file"] = provenance["license_file"]
    provenance["license_file"] = "LICENSE"
    payloads["provenance.json"] = json_bytes(provenance)
    repo = SOURCE_DIR.parents[3]
    payloads["LICENSE"] = (repo / "LICENSE").read_bytes()
    input_paths = {
        "generate_geometry.py": SOURCE_DIR / "generate_geometry.py",
        "geometry_contract.json": SOURCE_DIR / "geometry_contract.json",
        "provenance.json": SOURCE_DIR / "provenance.json",
        "LICENSE": repo / "LICENSE",
        contract["source"]: repo / contract["source"],
        "contrib/bmx-lab/bmx-plugin/plugin/bike_visual.lua": repo / "contrib/bmx-lab/bmx-plugin/plugin/bike_visual.lua",
    }
    records = []
    for part in contract["parts"]:
        mesh = quantized_mesh(meshes[part["name"]])
        low, high = bounds(mesh)
        if mesh.name in ("front_wheel", "rear_wheel"):
            validate_wheel(mesh, contract)
        records.append({**part, "file": mesh.name + ".obj", "vertices": len(mesh.vertices), "triangles": len(mesh.triangles),
                        "bounds_metres": {"min": rounded(low), "max": rounded(high)}, "components": rounded(mesh.components)})
    manifest = {
        "schema": 1, "format": "original-bmx-obj-v1", "native_ready": False,
        "coordinate_frame": contract["coordinate_frame"], "scale_applied": contract["scale"],
        "common_origin_preserved": True, "com_subtracted": False,
        "com_metres": contract["com_metres"], "wheel_radius_metres": contract["wheel_radius_unscaled"] * contract["scale"],
        "anchors_metres": {name: list(mul(tuple(value), contract["scale"])) for name, value in contract["anchors_unscaled"].items()},
        "steering_axis_unit": list(unit(tuple(contract["steering_axis"]))), "pose_order": contract["pose_order"],
        "parts": records, "recipe_inputs_sha256": {name: sha256(path.read_bytes()) for name, path in input_paths.items()},
        "payloads": {name: {"bytes": len(data), "sha256": sha256(data)} for name, data in payloads.items()},
        "qualification": {"offline_mesh_validation": "Performed by this generator, including serialized precision.", "native_resource_build": "not performed", "native_rendering": "not performed", "gameplay_parity": "not measured"},
    }
    payloads["manifest.json"] = json_bytes(manifest)
    return payloads


def write_package(output: Path, payloads: dict[str, bytes]) -> None:
    # Deliberately refuse every existing path; this tool never deletes or replaces.
    if output.exists() or output.is_symlink():
        raise FileExistsError(f"output path already exists: {output}")
    if not output.parent.is_dir():
        raise FileNotFoundError("output parent must already exist")
    if "manifest.json" not in payloads or any(Path(name).name != name or name in (".", "..") for name in payloads):
        raise ValueError("invalid package leaf name or missing manifest")
    output.mkdir()
    for name, data in payloads.items():
        if name != "manifest.json":
            with (output / name).open("xb") as file:
                file.write(data)
    # A failed write leaves an incomplete new directory; do not call it a package.
    with (output / "manifest.json").open("xb") as file:
        file.write(payloads["manifest.json"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--output", type=Path, help="new directory under an existing parent; never overwritten")
    action.add_argument("--check-only", action="store_true", help="build and validate intermediates in memory without creating files")
    args = parser.parse_args()
    payloads = build_payloads()
    if args.output is not None:
        write_package(args.output, payloads)
    print(json.dumps({"parts": list(PART_NAMES), "manifest_sha256": sha256(payloads["manifest.json"]), "files_written": 0 if args.check_only else len(payloads), "native_ready": False}, sort_keys=True))


if __name__ == "__main__":
    main()
