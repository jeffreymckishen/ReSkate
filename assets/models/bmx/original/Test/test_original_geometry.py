"""Offline source-geometry regressions. Run only in an assigned execution slot."""
from __future__ import annotations

from contextlib import contextmanager
import copy
from dataclasses import replace
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest

SOURCE_DIR = Path(__file__).resolve().parents[1]
REPO_DIR = SOURCE_DIR.parents[3]
sys.path.insert(0, str(SOURCE_DIR))
import generate_geometry as geometry


def signed_volume(mesh, component=None):
    triangles = mesh.triangles
    if component is not None:
        start = component["first_triangle"]
        triangles = triangles[start:start + component["triangle_count"]]
    # This standard tetrahedron sum is independent of the generator's normals.
    origin = mesh.vertices[triangles[0][0]].position
    volume = 0.0
    for indices in triangles:
        a, b, c = [tuple(mesh.vertices[index].position[j] - origin[j] for j in range(3)) for index in indices]
        volume += (a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] * c[1] - b[1] * c[0])) / 6
    return volume


def obj_records(data):
    result = {"v": [], "vt": [], "vn": [], "f": [], "g": [], "usemtl": []}
    for line in data.decode("ascii").splitlines():
        fields = line.split()
        if fields and fields[0] in result:
            result[fields[0]].append(fields[1:])
    return result


def component(mesh, name):
    return next(item for item in mesh.components if item["label"] == name)


def vertices_for(mesh, item):
    start = item["first_vertex"]
    return mesh.vertices[start:start + item["vertex_count"]]


def mean_position(vertices):
    return tuple(sum(vertex.position[i] for vertex in vertices) / len(vertices) for i in range(3))


def quarter_turn_x(point, pivot):
    # Exact +90-degree fixture avoids sharing trigonometry with the authoring code.
    return (point[0], pivot[1] - (point[2] - pivot[2]), pivot[2] + (point[1] - pivot[1]))


def rodrigues(point, pivot, axis, angle):
    length = math.sqrt(sum(value * value for value in axis))
    x, y, z = [value / length for value in axis]
    c, s, t = math.cos(angle), math.sin(angle), 1 - math.cos(angle)
    matrix = ((t*x*x+c, t*x*y-s*z, t*x*z+s*y), (t*x*y+s*z, t*y*y+c, t*y*z-s*x), (t*x*z-s*y, t*y*z+s*x, t*z*z+c))
    relative = [point[i] - pivot[i] for i in range(3)]
    return tuple(pivot[row] + sum(matrix[row][col] * relative[col] for col in range(3)) for row in range(3))


@contextmanager
def owned_tempdir():
    # Default temp storage stays in this E-drive source lane. A coordinator may
    # choose another existing E-drive scratch parent with this environment value.
    parent = Path(os.environ.get("BMX_ORIGINAL_TEST_TMP", str(Path(__file__).resolve().parent))).resolve(strict=True)
    directory = Path(tempfile.mkdtemp(prefix="original-geometry-test-", dir=parent)).resolve(strict=True)
    if directory.parent != parent:
        raise RuntimeError("temporary directory escaped its intended parent")
    try:
        yield directory
    finally:
        # Only remove this fresh owned directory; never derive a broader target.
        if directory.is_symlink() or directory.resolve(strict=True) != directory or directory.parent != parent:
            raise RuntimeError("temporary directory identity changed; cleanup refused")
        shutil.rmtree(directory)


class ContractTests(unittest.TestCase):
    def test_contract_matches_actual_lua_scalar_inputs_and_order(self):
        contract = geometry.load_contract()
        lua = (REPO_DIR / contract["source"]).read_text(encoding="utf-8-sig")
        scalar = lambda name: float(re.search(r"G\." + name + r"\s*=\s*([-+.0-9eE]+)\s*\*\s*s", lua).group(1))
        self.assertEqual(contract["scale"], float(re.search(r"\bscale\s*=\s*([-+.0-9eE]+)", lua).group(1)))
        self.assertEqual(contract["wheel_radius_unscaled"], scalar("wheel_radius"))
        self.assertEqual(contract["wheelbase_unscaled"], scalar("wheelbase"))
        self.assertEqual(contract["com_metres"], [float(x) for x in re.search(r"\bcom\s*=\s*\{([^}]+)\}", lua).group(1).split(",")])
        for name in ("front_axle", "rear_axle", "bottom_bracket", "steering_pivot", "left_grip", "right_grip"):
            match = re.search(r"G\." + name + r"\s*=\s*scaled\(([^)]+)\)", lua)
            self.assertEqual(contract["anchors_unscaled"][name], [float(x) for x in match.group(1).split(",")])
        pedals = re.search(r"G\.pedals\s*=\s*\{\s*scaled\(([^)]+)\),\s*scaled\(([^)]+)\)\s*\}", lua, re.S)
        for name, capture in (("left_pedal", 1), ("right_pedal", 2)):
            self.assertEqual(contract["anchors_unscaled"][name], [float(x) for x in pedals.group(capture).split(",")])
        axis = re.search(r"G\.steering_axis\s*=\s*\{([^}]+)\}", lua)
        self.assertEqual(contract["steering_axis"], [float(x) for x in axis.group(1).split(",")])
        blueprints = re.search(r"G\.blueprints\s*=\s*\{([^}]+)\}", lua, re.S)
        self.assertEqual([part["blueprint"] for part in contract["parts"]], re.findall(r'"([^"]+)"', blueprints.group(1)))

    def test_rim_cannot_escape_a_thinner_tire(self):
        contract = geometry.load_contract()
        contract["authoring"]["tire_section_radius_unscaled"] = 0.00001
        with self.assertRaisesRegex(ValueError, "wheel bounds"):
            geometry.build_bike(contract)

    def test_invalid_articulation_contracts_refuse(self):
        original = geometry.load_contract()
        mutations = (
            lambda c: c["parts"][3].update(pivot="rear_axle"),
            lambda c: c["parts"][6].update(spin="crank_phase"),
            lambda c: c["parts"][7].pop("orbit"),
            lambda c: c["parts"][1].update(group="tailwhip"),
            lambda c: c["parts"][2].update(blueprint="reskate/bmx/frame"),
            lambda c: c["pose_order"].reverse(),
            lambda c: c["authoring"].update(wheel_segments=62),
            lambda c: c["anchors_unscaled"].update(front_axle=[0, float("nan"), 0.6]),
            lambda c: c.update(scale=0),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                changed = copy.deepcopy(original)
                mutate(changed)
                with self.assertRaises(ValueError):
                    geometry.validate_contract(changed)


class PrimitiveTests(unittest.TestCase):
    def test_closed_primitives_have_independent_positive_volume(self):
        box = geometry.Mesh("box_test")
        geometry.add_box(box, "box", (0.3, 0.4, -0.2), (0.1, 0.2, 0.3), "paint")
        geometry.validate_mesh(box)
        self.assertAlmostEqual(signed_volume(box), 8 * 0.1 * 0.2 * 0.3, places=12)
        for end in ((0, 1, 0), (1, 0, 0), (0.3, 0.4, 0.5)):
            with self.subTest(end=end):
                tube = geometry.Mesh("tube_test")
                geometry.add_tube(tube, "tube", (0, 0, 0), end, 0.05, "steel", 12)
                geometry.validate_mesh(tube)
                length = math.sqrt(sum(x * x for x in end))
                expected = 12 * 0.5 * 0.05**2 * math.sin(math.tau / 12) * length
                self.assertAlmostEqual(signed_volume(tube), expected, places=12)
        torus = geometry.Mesh("torus_test")
        geometry.add_torus(torus, "torus", (0.2, 0.3, -0.4), 0.25, 0.03, "rubber")
        geometry.validate_mesh(torus)
        self.assertAlmostEqual(signed_volume(torus) / (2 * math.pi**2 * 0.25 * 0.03**2), 1, delta=0.04)
        ellipsoid = geometry.Mesh("ellipsoid_test")
        geometry.add_ellipsoid(ellipsoid, "ellipsoid", (0.2, 0.3, -0.4), (0.1, 0.03, 0.2), "rubber")
        geometry.validate_mesh(ellipsoid)
        self.assertAlmostEqual(signed_volume(ellipsoid) / (4 * math.pi * 0.1 * 0.03 * 0.2 / 3), 1, delta=0.08)

    def test_inward_winding_refuses_even_when_normals_are_also_inverted(self):
        mesh = geometry.Mesh("inside_out")
        geometry.add_box(mesh, "box", (0, 0, 0), (1, 1, 1), "paint")
        mesh.vertices = [replace(v, normal=tuple(-x for x in v.normal)) for v in mesh.vertices]
        mesh.triangles = [(a, c, b) for a, b, c in mesh.triangles]
        with self.assertRaisesRegex(ValueError, "positive volume"):
            geometry.validate_mesh(mesh)

    def test_corrupt_geometry_refuses(self):
        base = geometry.Mesh("corruption_test")
        geometry.add_box(base, "box", (0, 0, 0), (0.2, 0.1, 0.3), "paint")
        mutations = (
            lambda m: m.vertices.__setitem__(0, replace(m.vertices[0], position=(float("nan"), 0, 0))),
            lambda m: m.vertices.__setitem__(0, replace(m.vertices[0], normal=(0, 0, 0))),
            lambda m: m.vertices.__setitem__(0, replace(m.vertices[0], uv=(float("inf"), 0))),
            lambda m: m.triangles.__setitem__(0, (-1, 1, 2)),
            lambda m: m.triangles.__setitem__(0, (0, 0, 0)),
            lambda m: m.triangles.__setitem__(0, tuple(reversed(m.triangles[0]))),
            lambda m: m.components[0].update(material="unowned_donor"),
            lambda m: m.vertices.append(m.vertices[0]),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                mesh = copy.deepcopy(base)
                mutate(mesh)
                with self.assertRaises(ValueError):
                    geometry.validate_mesh(mesh)


class BikeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contract = geometry.load_contract()
        cls.meshes = geometry.build_bike(cls.contract)
        cls.scale = cls.contract["scale"]
        cls.anchors = {name: tuple(value * cls.scale for value in vector) for name, vector in cls.contract["anchors_unscaled"].items()}

    def assert_vec_near(self, actual, expected, tolerance=1e-10):
        for a, e in zip(actual, expected):
            self.assertAlmostEqual(a, e, delta=tolerance)

    def test_eight_original_parts_and_closed_components(self):
        self.assertEqual(tuple(self.meshes), geometry.PART_NAMES)
        for name, mesh in self.meshes.items():
            with self.subTest(part=name):
                geometry.validate_mesh(mesh)
                for part in mesh.components:
                    self.assertGreater(signed_volume(mesh, part), 0)
                self.assertNotIn("platform", [item["label"] for item in mesh.components] if name == "cranks" else [])
        for name in ("front_wheel", "rear_wheel"):
            spokes = [item for item in self.meshes[name].components if item["label"].startswith("spoke_")]
            self.assertEqual(len(spokes), 36)

    def test_serialized_wheel_bounds_match_lua_and_preserve_axle_height(self):
        radius = 0.34 * self.scale
        for name, anchor in (("front_wheel", "front_axle"), ("rear_wheel", "rear_axle")):
            with self.subTest(part=name):
                records = obj_records(geometry.obj_bytes(self.meshes[name]))
                positions = [tuple(map(float, values)) for values in records["v"]]
                low = tuple(min(p[i] for p in positions) for i in range(3))
                high = tuple(max(p[i] for p in positions) for i in range(3))
                admitted_radius = max(high[1] - low[1], high[2] - low[2]) * 0.5
                self.assertAlmostEqual(admitted_radius, radius, delta=1e-8)
                self.assertLess(abs(admitted_radius - radius), 0.002)
                self.assert_vec_near(tuple((low[i] + high[i]) * 0.5 for i in range(3)), self.anchors[anchor], 1e-8)
                self.assertNotEqual(self.anchors[anchor][1], radius)
                self.assertLess(low[1], 0)  # Preserve the measured Lua anchor; do not silently ground-lift the mesh.
                for p in positions:
                    radial = math.hypot(p[1] - self.anchors[anchor][1], p[2] - self.anchors[anchor][2])
                    self.assertLessEqual(radial, radius + 1e-8)

    def test_wheel_fork_attachment_stays_coincident_under_steering(self):
        front = self.anchors["front_axle"]
        steering = self.anchors["steering_pivot"]
        axis = self.contract["steering_axis"]
        tire = component(self.meshes["front_wheel"], "tire")
        self.assert_vec_near(tire["parameters"]["center"], front)
        left = component(self.meshes["fork"], "dropout_left")["parameters"]
        right = component(self.meshes["fork"], "dropout_right")["parameters"]
        left_center = tuple((left["a"][i] + left["b"][i]) * 0.5 for i in range(3))
        right_center = tuple((right["a"][i] + right["b"][i]) * 0.5 for i in range(3))
        for angle in (0, 0.7, math.pi, math.tau):
            a = rodrigues(left_center, steering, axis, angle)
            b = rodrigues(right_center, steering, axis, angle)
            self.assert_vec_near(tuple((a[i] + b[i]) * 0.5 for i in range(3)), rodrigues(front, steering, axis, angle))
        top = (front[0], front[1] + self.contract["wheel_radius_unscaled"] * self.scale, front[2])
        turned = quarter_turn_x(top, front)
        self.assert_vec_near(turned, (front[0], front[1], front[2] + self.contract["wheel_radius_unscaled"] * self.scale))

    def test_pedals_are_level_translated_parts_and_cranks_meet_their_spindles(self):
        bracket = self.anchors["bottom_bracket"]
        for name in ("left_pedal", "right_pedal"):
            with self.subTest(part=name):
                center = self.anchors[name]
                mesh = self.meshes[name]
                platform = vertices_for(mesh, component(mesh, "platform"))
                self.assert_vec_near(mean_position(platform), center)
                spindle = component(self.meshes["cranks"], "spindle_" + name)["parameters"]
                self.assert_vec_near(spindle["a"][1:], center[1:])
                self.assert_vec_near(spindle["b"][1:], center[1:])
                self.assertLess(min(spindle["a"][0], spindle["b"][0]), center[0])
                self.assertGreater(max(spindle["a"][0], spindle["b"][0]), center[0])
                target = quarter_turn_x(center, bracket)
                offset = tuple(target[i] - center[i] for i in range(3))
                moved = [replace(v, position=tuple(v.position[i] + offset[i] for i in range(3))) for v in platform]
                self.assert_vec_near(mean_position(moved), target)
                for original, translated in zip(platform, moved):
                    self.assertEqual(original.normal, translated.normal)
                    self.assert_vec_near(tuple(translated.position[i] - target[i] for i in range(3)), tuple(original.position[i] - center[i] for i in range(3)))
                self.assertNotEqual(target, center)

    def test_obj_indices_normals_uvs_and_groups_round_trip(self):
        for name, mesh in self.meshes.items():
            with self.subTest(part=name):
                data = geometry.obj_bytes(mesh)
                records = obj_records(data)
                self.assertEqual(len(records["v"]), len(mesh.vertices))
                self.assertEqual(len(records["vt"]), len(mesh.vertices))
                self.assertEqual(len(records["vn"]), len(mesh.vertices))
                self.assertEqual(len(records["f"]), len(mesh.triangles))
                self.assertEqual([values[0] for values in records["g"]], [item["label"] for item in mesh.components])
                self.assertEqual([values[0] for values in records["usemtl"]], [item["material"] for item in mesh.components])
                for face in records["f"]:
                    self.assertEqual(len(face), 3)
                    for reference in face:
                        vi, ti, ni = map(int, reference.split("/"))
                        self.assertTrue(1 <= vi <= len(mesh.vertices))
                        self.assertEqual((vi, ti, ni), (vi, vi, vi))
                for values in records["vn"]:
                    self.assertAlmostEqual(sum(float(x)**2 for x in values), 1, delta=1e-6)
                for values in records["vt"]:
                    self.assertTrue(all(0 <= float(x) <= 1 for x in values))
                self.assertNotIn(b"-0.000000000", data)


class PackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.payloads = geometry.build_payloads()

    def test_hashes_are_deterministic_and_cover_each_payload(self):
        second = geometry.build_payloads()
        self.assertEqual(self.payloads, second)
        manifest = json.loads(self.payloads["manifest.json"])
        self.assertFalse(manifest["native_ready"])
        self.assertEqual([part["name"] for part in manifest["parts"]], list(geometry.PART_NAMES))
        self.assertEqual(set(manifest["payloads"]), set(self.payloads) - {"manifest.json"})
        for name, record in manifest["payloads"].items():
            self.assertEqual(record["bytes"], len(self.payloads[name]))
            self.assertEqual(record["sha256"], hashlib.sha256(self.payloads[name]).hexdigest())
        self.assertNotIn(str(SOURCE_DIR).encode(), self.payloads["manifest.json"])
        self.assertNotIn(b"timestamp", self.payloads["manifest.json"])
        provenance = json.loads(self.payloads["provenance.json"])
        self.assertEqual(provenance["license_file"], "LICENSE")
        self.assertIn(provenance["license_file"], self.payloads)
        self.assertEqual(provenance["external_asset_inputs"], [])
        self.assertEqual(provenance["game_or_reference_payloads"], [])

    def test_writer_creates_only_new_directory_and_refuses_overwrite(self):
        with owned_tempdir() as scratch:
            target = scratch / "original"
            geometry.write_package(target, self.payloads)
            self.assertEqual({path.name for path in target.iterdir()}, set(self.payloads))
            for name, expected in self.payloads.items():
                self.assertEqual((target / name).read_bytes(), expected)
            sentinel = target / "user.txt"
            sentinel.write_text("preserve", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                geometry.write_package(target, self.payloads)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")
            for invalid in ({"mesh.obj": b""}, {"../escape": b"", "manifest.json": b"{}"}):
                with self.assertRaises(ValueError):
                    geometry.write_package(scratch / "invalid", invalid)
                self.assertFalse((scratch / "invalid").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
