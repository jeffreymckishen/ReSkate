"""Check the BMX mod's lightened bike data (our own code).

Reads bike-geometry.npz, albedo.png and bike-data.json (written by lighten_free_model.py) and the anchors the mod's
physics, presentation and rider pose read from plugin/bike_geometry.lua, and refuses the data unless:

  * the files are the ones bike-data.json records, with the 185 objects in their parts, the recorded triangle
    count per part, and no more than the triangle budget in all;
  * the axles, bottom bracket and pedal spindles measured on the data are where bike_geometry.lua has them, and so
    is the wheelbase (all to under 0.5 mm; the objects they are measured on are kept whole, so they are exact);
  * the grips, the steerer and the pedal tops, fitted over their surfaces (area weighted), are within 0.5 mm and
    0.5 degrees of the same fits on the source model, which bike-data.json records;
  * every part keeps the source's bounds, the wheels have bike_geometry.lua's radius (to 0.5 mm) and the wheels and
    cranks are authored about their hubs: centred on their own origin to 0.1 mm (bike_spawn.lua refuses 5 mm).

With --fbx it also re-reads the source model and checks that every corner of the data is an authored source corner,
that every object keeps its bounds and its surface stays within its goal of the source, and that the recorded source
fits are the source's.

Vertex-mean fits are not used to compare: lightening moves where the vertices are, not where the surface is (the
grips' vertex mean moves 7 mm while their surface moves 0.4 mm). The anchors stay the Lua constants, measured once on
the source.

Usage: python -I -B validate_lightened_bike.py --data <bike folder> [--lua plugin/bike_geometry.lua] [--fbx BMX_sf.fbx]
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lighten_free_model as lf  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
LUA = REPO/'contrib/bmx-lab/bmx-playable-experimental/plugin/bike_geometry.lua'
ANCHOR_MM = 0.5
AXIS_DEG = 0.5
HUB_CENTRE_M = 1e-4


def sha(data):
    return hashlib.sha256(data).hexdigest()


def lua_anchors(path):
    """The anchors bike_geometry.lua gives physics and the pose, in the drawn bike's frame."""
    text = Path(path).read_text()

    def number(pattern):
        found = re.search(pattern, text)
        if not found:
            raise ValueError(f'bike_geometry.lua has no {pattern}')
        return float(found.group(1))

    def triple(body):
        values = [float(v) for v in body.split(',')]
        if len(values) != 3:
            raise ValueError('Expected three coordinates')
        return np.array(values)
    s = number(r'G = \{scale = ([0-9.e-]+)')
    out = {'scale': s, 'wheel_radius': number(r'G\.wheel_radius = ([0-9.e-]+)\*s')*s,
           'wheelbase': number(r'G\.wheelbase = ([0-9.e-]+)\*s')*s}
    for key in ('front_axle', 'rear_axle', 'bottom_bracket', 'steering_pivot', 'left_grip', 'right_grip'):
        found = re.search(r'G\.'+key+r' = scaled\(([^)]*)\)', text)
        if not found:
            raise ValueError(f'bike_geometry.lua has no {key}')
        out[key] = triple(found.group(1))*s
    found = re.search(r'G\.steering_axis = \{([^}]*)\}', text)
    pedals = re.search(r'G\.pedals = \{scaled\(([^)]*)\),\s*scaled\(([^)]*)\)\}', text)
    if not found or not pedals:
        raise ValueError('bike_geometry.lua has no steering axis or pedals')
    out['steering_axis'] = triple(found.group(1))
    out['left_pedal'], out['right_pedal'] = triple(pedals.group(1))*s, triple(pedals.group(2))*s
    return out


def used_vertices(o):
    return np.unique(o['position'][np.unique(o['triangles'])], axis=0)


def bbox_mid(v):
    return (v.min(0)+v.max(0))/2


def area_fit(corners, sign_axis):
    """Centroid and principal axis of a triangle surface, weighted by area (exact second moments)."""
    a, b, c = corners[:, 0], corners[:, 1], corners[:, 2]
    area = np.linalg.norm(np.cross(b-a, c-a), axis=1)/2
    total = area.sum()
    centroid = (area[:, None]*(a+b+c)/3).sum(0)/total
    pa, pb, pc = a-centroid, b-centroid, c-centroid
    s = pa+pb+pc
    m = (np.einsum('n,ni,nj->ij', area, s, s)+np.einsum('n,ni,nj->ij', area, pa, pa)
         + np.einsum('n,ni,nj->ij', area, pb, pb)+np.einsum('n,ni,nj->ij', area, pc, pc))/12
    _, vectors = np.linalg.eigh(m)
    axis = vectors[:, -1]
    return centroid, axis*np.sign(axis[sign_axis])


def pedal_plane(o):
    """Area and area-weighted centroid of the pedal's largest upward horizontal plane (its top)."""
    c = o['position'][o['triangles']]
    cross = np.cross(c[:, 1]-c[:, 0], c[:, 2]-c[:, 0])
    area = np.linalg.norm(cross, axis=1)/2
    n = cross/np.maximum(2*area[:, None], 1e-20)
    h = c[:, :, 1].mean(1)
    horizontal = (n[:, 1] > .99) & (np.ptp(c[:, :, 1], axis=1) < 1e-6) & (area > 1e-11)
    best = None
    for height in np.unique(np.round(h[horizontal], 6)):
        mask = horizontal & (np.abs(h-height) < 1e-6)
        candidate = (float(area[mask].sum()), np.average(c[mask].mean(1), axis=0, weights=area[mask]))
        if best is None or candidate[0] > best[0]:
            best = candidate
    return best


def measure(objects, lua):
    """Every anchor fit on one set of objects (dicts with name, part, position and triangles)."""
    find = lambda prefix: [o for o in objects if o['name'].startswith(prefix)]  # noqa: E731
    out = {}
    for o in find('wheelshaft'):
        mid = bbox_mid(used_vertices(o))
        out['rear_axle' if mid[2] < 0 else 'front_axle'] = mid
    out['bottom_bracket'] = bbox_mid(used_vertices(find('frameshaft')[0]))
    for o in find('pedalpin'):
        mid = bbox_mid(used_vertices(o))
        out['left_pedal' if mid[0] > 0 else 'right_pedal'] = mid
    out['wheelbase'] = float(np.linalg.norm(out['front_axle']-out['rear_axle']))
    grips = find('Cylinder')[0]
    corners = grips['position'][grips['triangles']]
    for side, sign in (('left', 1), ('right', -1)):
        keep = corners[:, :, 0].mean(1)*sign > 0
        out[side+'_grip_surface'] = area_fit(corners[keep], 0)
        vertices = used_vertices(grips)
        out[side+'_grip_vertex_mean'] = vertices[vertices[:, 0]*sign > 0].mean(0)
    for o in find('pedal_low'):
        area, centroid = pedal_plane(o)
        out[('left' if centroid[0] > 0 else 'right')+'_pedal_top'] = (area, centroid)
    # The steerer shell: the fork's corners within 20 mm of the Lua axis, between the crown and the top.
    axis = lua['steering_axis']/np.linalg.norm(lua['steering_axis'])
    fork = find('frontframe')[0]
    c = fork['position'][fork['triangles']]
    mid = c.mean(1)-lua['steering_pivot']
    t = mid@axis
    r = np.linalg.norm(mid-t[:, None]*axis, axis=1)
    out['steerer_surface'] = area_fit(c[(r < .02) & (t > -.20) & (t < .02)], 1)
    parts = {}
    for part in lf.PARTS:
        v = np.concatenate([used_vertices(o) for o in objects if o['part'] == part])
        if part in lf.PIVOTS:
            v = v-np.array(lf.ANCHORS[lf.PIVOTS[part]])
        parts[part] = (v.min(0), v.max(0))
    out['parts'] = parts
    return out


def source_reference(objects):
    """The source model's fits that the lightened data is compared with (from lighten_free_model.load_objects)."""
    source = [{'name': o['name'], 'part': o['part'], 'position': o['wedge_position'], 'triangles': o['triangles']}
              for o in objects]
    fits = measure(source, lua_anchors(LUA))
    return {'left_grip_surface': [x.tolist() for x in fits['left_grip_surface']],
            'right_grip_surface': [x.tolist() for x in fits['right_grip_surface']],
            'left_grip_vertex_mean': fits['left_grip_vertex_mean'].tolist(),
            'right_grip_vertex_mean': fits['right_grip_vertex_mean'].tolist(),
            'steerer_surface': [x.tolist() for x in fits['steerer_surface']],
            'left_pedal_top': [fits['left_pedal_top'][0], fits['left_pedal_top'][1].tolist()],
            'right_pedal_top': [fits['right_pedal_top'][0], fits['right_pedal_top'][1].tolist()],
            'parts': {k: [lo.tolist(), hi.tolist()] for k, (lo, hi) in fits['parts'].items()}}


def angle_deg(a, b):
    return float(np.degrees(np.arccos(np.clip(abs(np.dot(a, b))/np.linalg.norm(a)/np.linalg.norm(b), 0, 1))))


class Checks:
    def __init__(self):
        self.rows, self.failed = [], 0

    def __call__(self, ok, what, value=''):
        self.rows.append((bool(ok), what, value))
        if not ok:
            self.failed += 1
        print(('ok    ' if ok else 'FAIL  ')+what+(f'  [{value}]' if value != '' else ''), flush=True)


def check_data(folder, lua_path, check):
    report = json.loads((folder/'bike-data.json').read_text())
    for name, digest in report['files'].items():
        check(sha((folder/name).read_bytes()) == digest, f'{name} is the file bike-data.json records')
    objects = lf.read_geometry(folder/'bike-geometry.npz')
    names = json.loads(lf.PARTS_MAP.read_text())
    check(len(objects) == 185 and all(names.get(o['name']) == o['part'] for o in objects),
          'all 185 source objects, each in its native part')
    total = 0
    for part in lf.PARTS:
        count = sum(len(o['triangles']) for o in objects if o['part'] == part)
        total += count
        check(count == report['parts'][part]['triangles_after'], f'{part}: {count} triangles, as recorded')
    check(total == report['triangles_after'] and total <= report['triangle_budget'],
          f'{total} triangles in all, within the {report["triangle_budget"]} budget')
    for o in objects:
        if not (len(o['triangles']) and o['triangles'].max() < len(o['position']) and
                np.isfinite(o['position']).all() and np.allclose(np.linalg.norm(o['normal'], axis=1), 1, atol=1e-5) and
                o['uv'].min() >= 0 and o['uv'].max() <= 1):
            check(False, f'{o["name"]}: well-formed corners, unit normals and UVs within its tile')
    lua = lua_anchors(lua_path)
    fits = measure(objects, lua)
    for key in ('rear_axle', 'front_axle', 'bottom_bracket', 'left_pedal', 'right_pedal'):
        delta = float(np.linalg.norm(fits[key]-lua[key])*1000)
        check(delta < ANCHOR_MM, f'{key} where bike_geometry.lua has it', f'{delta:.4f} mm')
    delta = abs(fits['wheelbase']-lua['wheelbase'])*1000
    check(delta < ANCHOR_MM, 'wheelbase as bike_geometry.lua has it', f'{delta:.4f} mm')
    ref = report['source_reference']
    for side in ('left', 'right'):
        centre, axis = fits[side+'_grip_surface']
        source_centre, source_axis = (np.array(x) for x in ref[side+'_grip_surface'])
        shift, turn = float(np.linalg.norm(centre-source_centre)*1000), angle_deg(axis, source_axis)
        check(shift < ANCHOR_MM and turn < AXIS_DEG, f'{side} grip surface where the source has it',
              f'{shift:.4f} mm, {turn:.4f} deg')
        lua_shift = float(np.linalg.norm(np.array(ref[side+'_grip_vertex_mean'])-lua[side+'_grip'])*1000)
        check(lua_shift < ANCHOR_MM, f'{side} grip anchor in bike_geometry.lua is the source fit', f'{lua_shift:.4f} mm')
        area, centroid = fits[side+'_pedal_top']
        source_area, source_centroid = ref[side+'_pedal_top']
        shift = float(np.linalg.norm(centroid-np.array(source_centroid))*1000)
        check(shift < ANCHOR_MM and abs(area-source_area) <= 1e-3*source_area, f'{side} pedal top where the source has it',
              f'{shift:.4f} mm, area {area*1e6:.3f} of {source_area*1e6:.3f} mm2')
    centre, axis = fits['steerer_surface']
    source_centre, source_axis = (np.array(x) for x in ref['steerer_surface'])
    shift, turn = float(np.linalg.norm(centre-source_centre)*1000), angle_deg(axis, source_axis)
    check(shift < ANCHOR_MM and turn < AXIS_DEG, 'steerer surface where the source has it', f'{shift:.4f} mm, {turn:.4f} deg')
    check(angle_deg(axis, lua['steering_axis']) < AXIS_DEG, 'steerer along the bike_geometry.lua steering axis',
          f'{angle_deg(axis, lua["steering_axis"]):.4f} deg')
    for part in lf.PARTS:
        lo, hi = fits['parts'][part]
        source_lo, source_hi = (np.array(x) for x in ref['parts'][part])
        change = float(max(np.abs(lo-source_lo).max(), np.abs(hi-source_hi).max())*1000)
        check(change < ANCHOR_MM, f'{part} keeps the source bounds', f'{change:.4f} mm')
        if part in lf.PIVOTS:
            # Across the spin axis (y and z), as bike_spawn.lua measures it: the rear wheel's sprocket is to one side.
            offset = float(np.abs(lo[1:]+hi[1:]).max())/2
            check(offset <= HUB_CENTRE_M, f'{part} is authored about its hub', f'{offset*1000:.4f} mm off centre')
        if part in ('rear_wheel', 'front_wheel'):
            radius = float(max(hi[1]-lo[1], hi[2]-lo[2])/2)
            check(abs(radius-lua['wheel_radius'])*1000 < ANCHOR_MM, f'{part} radius is bike_geometry.lua\'s',
                  f'{(radius-lua["wheel_radius"])*1000:.4f} mm')
    return report, objects, fits


def source_object(job):
    """One object against its source: corners that are not source corners, bounds change (m), surface error (mm)."""
    o, s = job
    # Every corner is an authored source corner: its position, normal and UV are the source's, stored as float32.
    table = set(map(bytes, np.c_[s['wedge_position'], s['wedge_normal'], s['wedge_uv']].astype(np.float32)))
    corners = np.c_[o['position'], o['normal'], o['uv']].astype(np.float32)
    foreign = sum(bytes(row) not in table for row in corners)
    used = s['wedge_position'][np.unique(s['triangles'])]
    mine = o['position'][np.unique(o['triangles'])]
    change = float(max(np.abs(used.min(0)-mine.min(0)).max(), np.abs(used.max(0)-mine.max(0)).max()))
    # The surface error is measured from the visible source, as the lightening measured it.
    visible = s['triangles'][~lf.covered_triangles(s)]
    t = o['position'][o['triangles']]
    p = s['wedge_position']
    samples = np.r_[p[np.unique(visible)], p[visible].mean(axis=1)]
    error = float(lf.point_triangle_distance(samples, t[:, 0], t[:, 1], t[:, 2]).max())*1000
    return o['name'], o['category'], foreign, change, error


def check_source(fbx, report, objects, check, workers):
    from multiprocessing import Pool
    source = lf.load_objects(fbx)
    by_name = {o['name']: o for o in source}
    worst, foreign_total, moved = {}, 0, 0
    jobs = sorted(((o, by_name[o['name']]) for o in objects), key=lambda j: -len(j[1]['triangles']))
    with Pool(workers) as pool:
        for name, kind, foreign, change, error in pool.imap_unordered(source_object, jobs):
            foreign_total += foreign
            if foreign:
                check(False, f'{name}: every corner is an authored source corner', f'{foreign} are not')
            if change > 2e-6:
                moved += 1
                check(False, f'{name}: keeps its bounds', f'{change*1000:.4f} mm')
            goal = lf.GOALS.get(kind, lf.GOALS['default'])
            if error > goal+1e-3:
                check(False, f'{name}: within {goal} mm of the source', f'{error:.4f} mm')
            worst[kind] = max(worst.get(kind, 0.0), error)
    check(foreign_total == 0 and moved == 0,
          f'every corner of all {len(objects)} objects is an authored source corner and every object keeps its bounds')
    for name, error in sorted(worst.items()):
        check(error <= lf.GOALS.get(name, lf.GOALS['default'])+1e-3, f'{name}: largest surface error from the source',
              f'{error:.3f} mm of {lf.GOALS.get(name, lf.GOALS["default"])} mm')

    def flat(value):
        if isinstance(value, dict):
            return [x for key in sorted(value) for x in flat(value[key])]
        if isinstance(value, (list, tuple)):
            return [x for item in value for x in flat(item)]
        return [float(value)]
    fresh, recorded = flat(source_reference(source)), flat(report['source_reference'])
    check(len(fresh) == len(recorded) and np.allclose(fresh, recorded, rtol=0, atol=1e-9),
          'the recorded source fits are the source model\'s')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--lua', type=Path, default=LUA)
    parser.add_argument('--fbx', type=Path)
    parser.add_argument('--workers', type=int, default=7)
    args = parser.parse_args()
    check = Checks()
    report, objects, _ = check_data(args.data, args.lua, check)
    if args.fbx:
        check_source(args.fbx, report, objects, check, args.workers)
    print(f'{len(check.rows)-check.failed} of {len(check.rows)} checks pass')
    if check.failed:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
