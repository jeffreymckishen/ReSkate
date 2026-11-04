"""Lighten the supplied "BMX (Free)" model into the bike data the BMX mod carries (our own code).

Reads Ermakov's BMX_sf.fbx and two of its base-colour maps (CC BY 4.0, see the mod's CREDITS.md; which maps, and
why, is under ATLAS_TILES) and writes a NEW folder with:

  bike-geometry.npz  every object of the model, lightened, in the drawn bike's frame (see write_geometry)
  albedo.png         those two maps packed into one 2048x1024 two-tile atlas
  bike-data.json     source and output hashes, the goals, per-object and per-part counts and errors, and the
                     source's own anchor fits, which validate_lightened_bike.py checks the output against

The output is what contrib/bmx-lab/bmx-playable-experimental/bike holds; build_bike_pack.py turns it into the
native pack on a machine with the supported game. Nothing here reads the game.

How the model is lightened, object by object (185 objects):
  * Hidden doubled skin is dropped first: a triangle whose every sample has the object's own same-facing
    surface within 50 um in front of it. Only the grip tape has any (its turns overlap about 6 um apart);
    left in, the covered turn shows through a lightened grip as dark patches.
  * mesh_decimate.py collapses edges onto existing vertices, so every corner left is an authored source corner
    with its own position, normal and UV: nothing moves, triangles only get bigger.
  * Each object keeps one vertex on each face of its bounding box, so every object keeps its exact bounds.
    The objects the anchors are measured on are kept whole: wheel shafts (axles), frame shaft (bottom
    bracket) and pedal pins. The pedals keep every vertex of their upward flat tops, where the feet go.
    A vertex closer to another category's surface behind it than its own error goal is kept, so a sleeve
    cannot sink into the bar it covers.
  * Each object's collapse tolerance is binary-searched so its measured surface error stays at or under its
    category's goal in GOALS. The error is measured one way: from every source vertex and triangle centroid to
    the lightened surface, not from the lightened surface back to the source.

The run is deterministic: the same inputs give the same bytes. It takes about 10 minutes on 7 processes.

Usage: python -I -B lighten_free_model.py --fbx BMX_sf.fbx --zip <bmx-free.zip> --output <new folder>
           [--expect <bike-data.json>] [--workers 7] [--steps 8]
       (--textures <extracted bmx-free/textures> in place of --zip works only if its base_BaseColor.png is the
       map ATLAS_TILES pins: the download holds two files of that name, see there.)
"""
from pathlib import Path
import argparse
import hashlib
import io
import json
import re
import sys
import time
import zipfile

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fbx_binary  # noqa: E402
import mesh_decimate  # noqa: E402

FORMAT = 'reskate-bmx-lightened-v1'
# Ermakov's "BMX (Free)" download, as supplied (sha256 of the files).
SOURCE_SHA = '00ce4d383a31b786837a0d229dcb8d651dc7580166aff8741308c202647caa2a'
PARTS_MAP = Path(__file__).with_name('free_model_parts.json')
# The drawn bike's frame: (FBX world metres - origin) * scale, the conversion prepare_free_native_parts.py
# used, at the selected 0.2630808 m wheel radius (0.34 m * G.scale in bike_geometry.lua).
SOURCE_ORIGIN = np.array([0.0, -1.6979001667381863, 0.016188328673421237])
UNIFORM_SCALE = 0.31318080951710964
WHEEL_RADIUS_M = 0.2630808
PARTS = ('frame', 'fork', 'rear_wheel', 'front_wheel', 'cranks', 'handlebars', 'left_pedal', 'right_pedal')
# A part that spins has its origin where it spins (see prepare_free_native_parts.py PIVOTS), in the frame above.
PIVOTS = {'rear_wheel': 'rear_axle', 'front_wheel': 'front_axle', 'cranks': 'bb'}
ANCHORS = {'rear_axle': [0.0, 0.26302757455140674, -0.46579076860836216],
           'front_axle': [0.0, 0.263027644883869, 0.46579076860836216],
           'bb': [0.0, 0.3102172305018515, -0.10582857717896653]}
# The atlas: two 2048 tiles with 8-texel gutters at 4096x2048 (prepare_free_native_parts.atlas_uv), then halved.
TILE, GUTTER = 2048, 8
INTERIOR = TILE-2*GUTTER
ATLAS_SIZE = (2048, 1024)
# The download as Sketchfab serves it (bmx-free.zip).
DOWNLOAD_SHA = 'cc8375c11deba3d48fd1d1d8ea71f90bbd3028e88774664c4f05f00bb0f7d1a3'
# The FBX gives each of its three materials its own base-colour map: "base" (174 objects: the frame, fork, chain,
# spokes, cranks, pedals, pegs and the rest) uses Texture 4k\base_BaseColor.png, "rul" (2 objects: the grips and the
# bars) uses Texture 4k\rul\base_BaseColor.png, and "extra" (9 objects: the tyres, rims, hubs, valves and seat) uses
# Texture 4k\extra_BaseColor.png. The download flattens the two folders into textures/, so its zip holds
# textures/base_BaseColor.png twice, and an extractor keeps whichever it likes (Windows kept the later one, entry 6).
# Drawing each material's UV islands over both shows entry 3 is the "base" map and entry 6 the "rul" map. The bike
# has always been drawn from entry 6: tile 0 holds the "rul" map and the "base" objects sample it too, so the "base"
# map is not used. Giving the base objects their own map would change how the bike looks in game, so it is left as
# it is until that is decided.
ATLAS_TILES = (
    {'tile': 0, 'name': 'textures/base_BaseColor.png', 'zip_entry': 6, 'material': 'rul',
     'fbx_texture': 'Texture 4k\\rul\\base_BaseColor.png', 'drawn_on': ['rul', 'base'],
     'sha256': '711d17bd229e09a871d8157f8842c2f25f7d0b20485f2d7a3b8dc01c669efd70'},
    {'tile': 1, 'name': 'textures/extra_BaseColor.png', 'zip_entry': 7, 'material': 'extra',
     'fbx_texture': 'Texture 4k\\extra_BaseColor.png', 'drawn_on': ['extra'],
     'sha256': '1a0027f713191c2cef7feb3c7f4f819a6792e3b277619aac42ccfd20cb57ce22'},
)
UNUSED_MAPS = (
    {'name': 'textures/base_BaseColor.png', 'zip_entry': 3, 'material': 'base',
     'fbx_texture': 'Texture 4k\\base_BaseColor.png',
     'sha256': 'eb1fc8b5d8d2489fe4b513b02233ab024e4f47ac088a634cc819e9f74668cf55'},
)
TILE_OF = {material: t['tile'] for t in ATLAS_TILES for material in t['drawn_on']}

# Objects that define anchors by their own vertices keep every vertex:
# wheel shafts (axles), frame shaft (bottom bracket), pedal pins (pedal spindles).
KEEP_WHOLE = ('wheelshaft', 'frameshaft', 'pedalpin')
# Pedal platforms are lightened, but every vertex of their upward horizontal planes is kept,
# so the broad top plane the feet use keeps its exact triangles, area and centroid.
PLANE_LOCKED = ('pedal_low',)
# A vertex nearer to another object's surface than the error its own object may have is kept, so a
# lightened surface cannot sink below a neighbour it covers (a grip sleeve over its bar). Chords of a
# convex surface only cut inward, so the covered object's own lightening never pushes it out.
CLEARANCE_M = 0.001  # how far the clearance search reaches
# A triangle with its own object's same-facing surface this close in front of it everywhere is a hidden
# doubled skin (the grip tape's overlapping turns) and is dropped before lightening.
COVERED_M = 0.00005
# Largest allowed surface error per category, in millimetres of the drawn bike.
GOALS = {'default': 0.5, 'grips (Cylinder)': 0.4, 'spoke': 0.7, 'chain link': 0.5, 'tire': 1.0}
# Largest angle a lightened face may make with its authored corner normals (degrees), so thin tubes keep
# believable smooth shading.
SHADE = {'spoke': 55.0, 'chain link': 55.0, 'wire': 50.0}
# How far the texture may slide, in source UV units: one unit spans 2032 texels of a 4096-wide atlas tile and
# 1016 of the 2048-wide one, so 5e-4 is half a texel of the shipped atlas. Chain links and spokes may slide about
# as far as their surface may move.
UV_TOLERANCE = {'default': 5e-4, 'chain link': 1.2e-3, 'spoke': 1.0e-3}
TRIANGLE_BUDGET = 50000


def sha(data):
    return hashlib.sha256(data).hexdigest()


def category(name):
    n = name.lower()
    for prefix, label in (('spoke', 'spoke'), ('chaindet', 'chain link'), ('pedalpin', 'pedal pin'),
                          ('pedal_low', 'pedal'), ('tire', 'tire'), ('rim', 'rim'), ('hub', 'hub'),
                          ('valve', 'valve'), ('shaft', 'wheel shaft'), ('crank', 'crank arm'),
                          ('peg', 'peg'), ('holder', 'holder pin'), ('frame', 'frame'), ('seat', 'seat'),
                          ('sprocket', 'sprocket'), ('star', 'sprocket'), ('rudderholder', 'stem'),
                          ('rudder', 'bars'), ('tube', 'tube'), ('wire', 'wire'), ('cylinder', 'grips (Cylinder)')):
        if n.startswith(prefix):
            return label
    return re.sub(r'[._].*', '', n)


def load_objects(fbx_path):
    """Each FBX mesh object as wedges (corner position, authored normal, source UV) in the drawn bike's frame."""
    data = fbx_binary.load(fbx_path)
    part_of = json.loads(PARTS_MAP.read_text())
    objects = []
    for m in data['meshes']:
        tris, _ = fbx_binary.triangulate(m['polygon_vertex_index'])
        corner = m['polygon_vertex_index']
        corner = np.where(corner < 0, -corner-1, corner)
        material = m['materials'][int(m['polygon_material'][0])] if m['polygon_material'] is not None else m['materials'][0]
        if m['polygon_material'] is not None and len(set(m['polygon_material'].tolist())) != 1:
            raise ValueError('Mixed-material object needs per-polygon tiles')
        world = (m['vertices']/100.0-SOURCE_ORIGIN)*UNIFORM_SCALE
        # "rul" and "base" both draw from tile 0, which holds the "rul" map (see ATLAS_TILES).
        objects.append({'name': m['name'], 'geometry_id': int(m['geometry_id']), 'category': category(m['name']),
                        'part': part_of[m['name']], 'material': material, 'tile': TILE_OF[material],
                        'vertex_positions': world, 'wedge_vertex': corner,
                        'wedge_position': world[corner], 'wedge_normal': m['wedge_normals'],
                        'wedge_uv': m['wedge_uv'], 'triangles': tris})
    if sorted(o['name'] for o in objects) != sorted(part_of) or len(objects) != 185:
        raise ValueError('The FBX objects differ from free_model_parts.json')
    return objects


def topology(obj):
    """Topological vertices = the FBX control points; wedges = distinct (vertex, normal, uv) corners."""
    wv = obj['wedge_vertex']
    key = np.c_[wv, np.round(obj['wedge_normal'], 6), np.round(obj['wedge_uv'], 7)]
    _, first, inverse = np.unique(key, axis=0, return_index=True, return_inverse=True)
    inverse = inverse.ravel()
    return (obj['vertex_positions'], wv[obj['triangles']], inverse[obj['triangles']],
            obj['wedge_normal'][first], obj['wedge_uv'][first], wv[first])


def extreme_locks(p, used):
    """Lock one vertex at each bounding-box face so every object keeps its exact bounds."""
    locked = np.zeros(len(p), bool)
    for axis in range(3):
        locked[used[np.argmin(p[used, axis])]] = True
        locked[used[np.argmax(p[used, axis])]] = True
    return locked


def plane_locks(p, tris):
    """Vertices of upward-facing horizontal planes (normal Y > .99, flat to 1 um)."""
    c = p[tris]
    n = np.cross(c[:, 1]-c[:, 0], c[:, 2]-c[:, 0])
    ln = np.linalg.norm(n, axis=1)
    up = (n[:, 1] > .99*ln) & (np.ptp(c[:, :, 1], axis=1) < 1e-6) & (ln > 1e-12)
    locked = np.zeros(len(p), bool)
    locked[np.unique(tris[up])] = True
    return locked


def pair_distance(p, a, b, c):
    """Exact point-triangle distance for matched rows (Ericson's regions, vectorized)."""
    ab, ac, ap = b-a, c-a, p-a
    d1, d2 = np.einsum('ij,ij->i', ab, ap), np.einsum('ij,ij->i', ac, ap)
    bp = p-b
    d3, d4 = np.einsum('ij,ij->i', ab, bp), np.einsum('ij,ij->i', ac, bp)
    cp = p-c
    d5, d6 = np.einsum('ij,ij->i', ab, cp), np.einsum('ij,ij->i', ac, cp)
    va, vb, vc = d3*d6-d5*d4, d5*d2-d1*d6, d1*d4-d3*d2
    denom = va+vb+vc
    denom = np.where(np.abs(denom) < 1e-30, 1e-30, denom)
    v, w = vb/denom, vc/denom
    q = a+ab*v[:, None]+ac*w[:, None]
    region = [
        ((d1 <= 0) & (d2 <= 0), a),
        ((d3 >= 0) & (d4 <= d3), b),
        ((d6 >= 0) & (d5 <= d6), c),
        ((vc <= 0) & (d1 >= 0) & (d3 <= 0), a+ab*(d1/np.where(d1-d3 == 0, 1e-30, d1-d3))[:, None]),
        ((vb <= 0) & (d2 >= 0) & (d6 <= 0), a+ac*(d2/np.where(d2-d6 == 0, 1e-30, d2-d6))[:, None]),
        ((va <= 0) & ((d4-d3) >= 0) & ((d5-d6) >= 0),
         b+(c-b)*((d4-d3)/np.where((d4-d3)+(d5-d6) == 0, 1e-30, (d4-d3)+(d5-d6)))[:, None]),
    ]
    done = np.zeros(len(p), bool)
    for mask, point in region:
        m = mask & ~done
        q[m] = point[m]
        done |= m
    return np.linalg.norm(p-q, axis=1), q


def clearance_distances(objects, reach=CLEARANCE_M, cell=0.004, touching=0.00005):
    """Per object, each vertex's distance to the nearest surface of another category that lies BEHIND it (the
    vertex covers it), or inf beyond `reach`. Other objects nearer than `touching` count whatever their
    direction. A spoke end beside its rim or a link on a sprocket covers nothing, so it is not counted.
    Triangles are binned on a uniform grid by their bounds grown by `reach`, so only vertex/triangle pairs
    sharing a cell are measured. (Locking vertices over an object's own layers as well was tried on the grips:
    59k triangles, and the patches stayed, because the covered layer itself was the problem.)"""
    tri_pos, tri_obj = [], []
    for j, o in enumerate(objects):
        t = o['wedge_position'][o['triangles']]
        tri_pos.append(t)
        tri_obj.append(np.full(len(t), j))
    tri_pos, tri_obj = np.concatenate(tri_pos), np.concatenate(tri_obj)
    category_of = np.array([o['category'] for o in objects])
    origin = tri_pos.reshape(-1, 3).min(0)-1
    lo = np.floor((tri_pos.min(1)-reach-origin)/cell).astype(np.int64)
    hi = np.floor((tri_pos.max(1)+reach-origin)/cell).astype(np.int64)
    dims = hi.max(0)+2
    span = hi-lo+1
    counts = span.prod(1)
    owners = np.repeat(np.arange(len(tri_pos)), counts)
    local = np.arange(counts.sum())-np.repeat(np.cumsum(counts)-counts, counts)
    sy, sz = span[owners, 1], span[owners, 2]
    cx = lo[owners, 0]+local//(sy*sz)
    cy = lo[owners, 1]+(local//sz) % sy
    cz = lo[owners, 2]+local % sz
    keys = (cx*dims[1]+cy)*dims[2]+cz
    order = np.argsort(keys, kind='stable')
    keys, owners = keys[order], owners[order]
    out = []
    for j, o in enumerate(objects):
        v = o['vertex_positions']
        c = np.floor((v-origin)/cell).astype(np.int64)
        vk = (c[:, 0]*dims[1]+c[:, 1])*dims[2]+c[:, 2]
        start, stop = np.searchsorted(keys, vk, 'left'), np.searchsorted(keys, vk, 'right')
        n = stop-start
        vi = np.repeat(np.arange(len(v)), n)
        ti = owners[np.repeat(start, n)+(np.arange(n.sum())-np.repeat(np.cumsum(n)-n, n))] if n.sum() else np.zeros(0, int)
        mine = tri_obj[ti] == j
        keep = category_of[tri_obj[ti]] != o['category']
        vi, ti, mine = vi[keep], ti[keep], mine[keep]
        dist = np.full(len(v), np.inf)
        if len(vi):
            normal = np.zeros_like(v)
            np.add.at(normal, o['wedge_vertex'], o['wedge_normal'])
            normal /= np.maximum(np.linalg.norm(normal, axis=1), 1e-12)[:, None]
            t = tri_pos[ti]
            d, q = pair_distance(v[vi], t[:, 0], t[:, 1], t[:, 2])
            behind = np.einsum('ij,ij->i', v[vi]-q, normal[vi]) > .5*d
            d = np.where(behind | ((d < touching) & ~mine), d, np.inf)
            np.minimum.at(dist, vi, d)
        dist[dist > reach] = np.inf
        out.append(dist)
    return out


def cell_pairs(points, tri_pos, reach, cell):
    """(point, triangle) index pairs whose grid cells meet: each triangle is binned by its bounds
    grown by `reach`, each point by its own cell."""
    origin = np.minimum(tri_pos.reshape(-1, 3).min(0), points.min(0))-1
    lo = np.floor((tri_pos.min(1)-reach-origin)/cell).astype(np.int64)
    hi = np.floor((tri_pos.max(1)+reach-origin)/cell).astype(np.int64)
    c = np.floor((points-origin)/cell).astype(np.int64)
    dims = np.maximum(hi.max(0), c.max(0))+2
    span = hi-lo+1
    counts = span.prod(1)
    owners = np.repeat(np.arange(len(tri_pos)), counts)
    local = np.arange(counts.sum())-np.repeat(np.cumsum(counts)-counts, counts)
    sy, sz = span[owners, 1], span[owners, 2]
    keys = ((lo[owners, 0]+local//(sy*sz))*dims[1]+lo[owners, 1]+(local//sz) % sy)*dims[2]+lo[owners, 2]+local % sz
    order = np.argsort(keys, kind='stable')
    keys, owners = keys[order], owners[order]
    pk = (c[:, 0]*dims[1]+c[:, 1])*dims[2]+c[:, 2]
    start, stop = np.searchsorted(keys, pk, 'left'), np.searchsorted(keys, pk, 'right')
    n = stop-start
    pi = np.repeat(np.arange(len(points)), n)
    ti = owners[np.repeat(start, n)+(np.arange(n.sum())-np.repeat(np.cumsum(n)-n, n))] if n.sum() else np.zeros(0, np.int64)
    return pi, ti


def covered_triangles(obj, gap=COVERED_M, cell=0.002):
    """Triangles of a doubled skin: every sample of the triangle (corners, edge midpoints, centroid)
    has the object's own same-facing surface IN FRONT of it within `gap`. The grip tape is modelled
    as overlapping turns a few micrometres apart; the covered turn is never seen, and once either
    layer is lightened the two swap places and the covered one shows through as dark patches."""
    vid = obj['wedge_vertex'][obj['triangles']]
    t = obj['wedge_position'][obj['triangles']]
    n = np.cross(t[:, 1]-t[:, 0], t[:, 2]-t[:, 0])
    ln = np.linalg.norm(n, axis=1)
    n = n/np.maximum(ln, 1e-18)[:, None]
    w = np.array([[1, 0, 0], [0, 1, 0], [0, 0, 1], [.5, .5, 0], [0, .5, .5], [.5, 0, .5], [1/3, 1/3, 1/3]])
    samples = np.einsum('sk,tkj->tsj', w, t).reshape(-1, 3)
    owner = np.repeat(np.arange(len(t)), len(w))
    pi, ti = cell_pairs(samples, t, gap, cell)
    src = owner[pi]
    # never the triangle itself or one sharing a corner with it (the same sheet)
    keep = ~np.any(vid[ti][:, :, None] == vid[src][:, None, :], axis=(1, 2))
    keep &= np.einsum('ij,ij->i', n[ti], n[src]) > .5
    pi, ti, src = pi[keep], ti[keep], src[keep]
    covered = np.zeros(len(samples), bool)
    if len(pi):
        d, q = pair_distance(samples[pi], t[ti, 0], t[ti, 1], t[ti, 2])
        front = (np.einsum('ij,ij->i', q-samples[pi], n[src]) > .5*d) & (d < gap) & (d > 0)
        covered[pi[front]] = True
    return covered.reshape(-1, len(w)).all(axis=1) & (ln > 1e-18)


def point_triangle_distance(points, a, b, c):
    """Distance from each point to the nearest of triangles (a,b,c); chunked numpy."""
    best = np.full(len(points), np.inf)
    ab, ac = b-a, c-a
    n = np.cross(ab, ac)
    nn = np.einsum('ij,ij->i', n, n)
    good = nn > 1e-30
    a, b, c, ab, ac, n, nn = a[good], b[good], c[good], ab[good], ac[good], n[good], nn[good]
    d00 = np.einsum('ij,ij->i', ab, ab)
    d01 = np.einsum('ij,ij->i', ab, ac)
    d11 = np.einsum('ij,ij->i', ac, ac)
    denom = d00*d11-d01*d01
    denom = np.where(np.abs(denom) < 1e-30, 1e-30, denom)

    def seg(p, s, e):
        se = e-s
        t = np.clip(np.einsum('kmj,mj->km', p[:, None, :]-s[None], se)/np.maximum(np.einsum('ij,ij->i', se, se), 1e-30)[None], 0, 1)
        q = s[None]+t[..., None]*se[None]
        return np.linalg.norm(p[:, None, :]-q, axis=2)
    step = max(1, int(1_500_000//max(len(a), 1)))
    for i in range(0, len(points), step):
        p = points[i:i+step]
        ap = p[:, None, :]-a[None]
        d20 = np.einsum('kmj,mj->km', ap, ab)
        d21 = np.einsum('kmj,mj->km', ap, ac)
        v = (d11[None]*d20-d01[None]*d21)/denom[None]
        w = (d00[None]*d21-d01[None]*d20)/denom[None]
        inside = (v >= 0) & (w >= 0) & (v+w <= 1)
        plane = np.abs(np.einsum('kmj,mj->km', ap, n))/np.sqrt(nn)[None]
        edge = np.minimum(np.minimum(seg(p, a, b), seg(p, b, c)), seg(p, c, a))
        d = np.where(inside, plane, edge)
        best[i:i+step] = d.min(axis=1)
    return best


def surface_error(p, tris_before, tris_after):
    """Max/95th distance from original vertices and face centroids to the lightened surface."""
    if len(tris_after) == len(tris_before):
        return 0.0, 0.0
    samples = np.r_[p[np.unique(tris_before)], p[tris_before].mean(axis=1)]
    t = p[tris_after]
    d = point_triangle_distance(samples, t[:, 0], t[:, 1], t[:, 2])
    return float(d.max()), float(np.quantile(d, .95))


def goal_mm(obj):
    return GOALS.get(obj['category'], GOALS['default'])


def lighten_object(job):
    index, obj, steps, near = job
    p, tris, wedges, wn, wuv, wvert = topology(obj)
    if obj['name'].startswith(KEEP_WHOLE):
        return index, tris, wedges, None, 0.0, 0.0, wvert, wn, wuv, p
    shade = SHADE.get(obj['category'], 45.0)
    uv_tolerance = UV_TOLERANCE.get(obj['category'], UV_TOLERANCE['default'])
    locks = extreme_locks(p, np.unique(tris)) | near
    if obj['name'].startswith(PLANE_LOCKED):
        locks |= plane_locks(p, tris)
    best = (tris, wedges, None, 0.0, 0.0)
    lo, hi = np.log(0.0001), np.log(0.012)
    for _ in range(steps):
        mid = (lo+hi)/2
        tol = float(np.exp(mid))
        nt, nw = mesh_decimate.decimate(p, tris, wedges, wn, wuv, tol, locks, max_shade_deg=shade, uv_tolerance=uv_tolerance)
        err, e95 = surface_error(p, tris, nt)
        if err <= goal_mm(obj)/1000:
            lo = mid
            if len(nt) <= len(best[0]):
                best = (nt, nw, tol, err, e95)
        else:
            hi = mid
    return (index,)+best+(wvert, wn, wuv, p)


def lighten(objects, steps, workers):
    """The lightened wedges of every object, and a report row for each."""
    from multiprocessing import Pool
    started = time.time()
    source_tris = [o['triangles'] for o in objects]
    hidden = [covered_triangles(o) for o in objects]
    visible = [dict(o, triangles=o['triangles'][~h]) for o, h in zip(objects, hidden)]
    print('hidden doubled-skin triangles dropped', int(sum(h.sum() for h in hidden)), flush=True)
    clearance = clearance_distances(visible)
    near = [d < goal_mm(o)/1000 for o, d in zip(visible, clearance)]
    print('clearance-locked vertices', int(sum(n.sum() for n in near)), 'in', round(time.time()-started, 1), 's', flush=True)
    jobs = [(i, o, steps, near[i]) for i, o in enumerate(visible)]
    jobs.sort(key=lambda j: -len(j[1]['triangles']))
    rows, result = [None]*len(objects), [None]*len(objects)
    with Pool(workers) as pool:
        for index, nt, nw, tol, err, e95, wvert, wn, wuv, p in pool.imap_unordered(lighten_object, jobs):
            obj = objects[index]
            tris = obj['wedge_vertex'][source_tris[index]]
            used_before, used_after = np.unique(tris), np.unique(nt)
            bounds_same = bool(np.array_equal(p[used_before].min(0), p[used_after].min(0)) and
                               np.array_equal(p[used_before].max(0), p[used_after].max(0)))
            if not bounds_same:
                raise ValueError(f"{obj['name']}: lightening changed the object's bounds")
            kept_whole = obj['name'].startswith(KEEP_WHOLE)
            rows[index] = {'name': obj['name'], 'category': obj['category'], 'part': obj['part'],
                           'triangles_before': int(len(tris)), 'triangles_after': int(len(nt)),
                           'goal_mm': None if kept_whole else goal_mm(obj), 'kept_whole': kept_whole,
                           'tolerance_m': tol, 'error_max_mm': err*1000, 'error_p95_mm': e95*1000,
                           'clearance_locked_vertices': int(near[index].sum()),
                           'hidden_triangles_dropped': int(hidden[index].sum())}
            # Only the wedges the lightened triangles use, in index order (as the native parts are built).
            used, local = np.unique(nw, return_inverse=True)
            result[index] = (p[wvert][used], wn[used], wuv[used], local.reshape(-1, 3))
            print(f"{index:3d} {obj['name'][:34]:34s} {len(tris):6d} -> {len(nt):6d}  err {err*1000:.3f} mm", flush=True)
    print('lightened in', round(time.time()-started, 1), 's', flush=True)
    return result, rows


def write_geometry(path, objects, lightened):
    """Our own format, a .npz numpy reads (np.load) with fixed zip timestamps so the bytes reproduce:
      format          'reskate-bmx-lightened-v1'
      object_name     (N,) the FBX object names, object_part (N,) the native part each belongs to,
      object_tile     (N,) uint8 atlas tile (0 base, 1 extra)
      wedge_start     (N+1,) int64 and triangle_start (N+1,) int64, each object's rows in the arrays below
      position        (W,3) float32 corner positions, metres, in the drawn bike's frame (part pivots not applied)
      normal          (W,3) float32 authored unit normals
      uv              (W,2) float32 source UVs (FBX convention: V from the bottom, 0..1 within the object's tile)
      triangles       (T,3) uint16 corner indices within the object, in source winding"""
    wedge_start, triangle_start = [0], [0]
    for p, _, _, t in lightened:
        if len(p) > 65535:
            raise ValueError('An object exceeds 16-bit corner indices')
        wedge_start.append(wedge_start[-1]+len(p))
        triangle_start.append(triangle_start[-1]+len(t))
    arrays = {
        'format': np.array([FORMAT]),
        'object_name': np.array([o['name'] for o in objects]),
        'object_part': np.array([o['part'] for o in objects]),
        'object_tile': np.array([o['tile'] for o in objects], dtype=np.uint8),
        'wedge_start': np.array(wedge_start, dtype=np.int64),
        'triangle_start': np.array(triangle_start, dtype=np.int64),
        'position': np.concatenate([x[0] for x in lightened]).astype(np.float32),
        'normal': np.concatenate([x[1] for x in lightened]).astype(np.float32),
        'uv': np.concatenate([x[2] for x in lightened]).astype(np.float32),
        'triangles': np.concatenate([x[3] for x in lightened]).astype(np.uint16),
    }
    with zipfile.ZipFile(path, 'w') as archive:
        for name, value in arrays.items():
            buffer = io.BytesIO()
            np.lib.format.write_array(buffer, np.ascontiguousarray(value), allow_pickle=False)
            info = zipfile.ZipInfo(name+'.npy', date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, buffer.getvalue(), compresslevel=9)


def read_geometry(path):
    """bike-geometry.npz as one dict per object: name, part, tile, category, position/normal/uv (float64) and triangles."""
    with np.load(path, allow_pickle=False) as data:
        if data['format'].tolist() != [FORMAT]:
            raise ValueError('Not a lightened bike geometry file')
        ws, ts = data['wedge_start'], data['triangle_start']
        position, normal, uv, triangles = data['position'], data['normal'], data['uv'], data['triangles']
        objects = []
        for i, name in enumerate(data['object_name'].tolist()):
            objects.append({'name': name, 'part': str(data['object_part'][i]), 'tile': int(data['object_tile'][i]),
                            'category': category(name),
                            'position': position[ws[i]:ws[i+1]].astype(np.float64),
                            'normal': normal[ws[i]:ws[i+1]].astype(np.float64),
                            'uv': uv[ws[i]:ws[i+1]].astype(np.float64),
                            'triangles': triangles[ts[i]:ts[i+1]].astype(np.int64)})
    return objects


def read_tile_maps(download=None, folder=None):
    """The bytes of each ATLAS_TILES map: by zip entry from the download, or by file name from a folder it was
    extracted to. Each must be the pinned file, so an extractor that kept the other base_BaseColor.png is refused."""
    if download is not None:
        if sha(download.read_bytes()) != DOWNLOAD_SHA:
            raise SystemExit('This is not the supplied bmx-free.zip')
        with zipfile.ZipFile(download) as archive:
            entries = archive.infolist()
            maps = []
            for t in ATLAS_TILES:
                if entries[t['zip_entry']].filename != t['name']:
                    raise SystemExit(f"bmx-free.zip entry {t['zip_entry']} is not {t['name']}")
                maps.append(archive.read(entries[t['zip_entry']]))
    else:
        maps = [(folder/Path(t['name']).name).read_bytes() for t in ATLAS_TILES]
    for t, data in zip(ATLAS_TILES, maps):
        if sha(data) != t['sha256']:
            raise SystemExit(f"{t['name']} is not the \"{t['material']}\" map tile {t['tile']} holds (bmx-free.zip entry "
                             f"{t['zip_entry']}); the download has two files of that name, so pass the zip with --zip")
    return maps


def make_atlas(maps, path):
    """The 4096x2048 atlas prepare_free_native_parts.make_atlases built (the same bytes), halved to 2048x1024.
    `maps`: the bytes of each ATLAS_TILES map, in tile order (read_tile_maps)."""
    atlas = Image.new('RGBA', (2*TILE, TILE))
    inputs = []
    for t, data in zip(ATLAS_TILES, maps):
        tile = t['tile']
        with Image.open(io.BytesIO(data)) as image:
            inputs.append({'tile': tile, 'name': t['name'], 'zip_entry': t['zip_entry'], 'material': t['material'],
                           'fbx_texture': t['fbx_texture'], 'drawn_on': t['drawn_on'], 'sha256': sha(data),
                           'size': list(image.size)})
            content = image.convert('RGBA').resize((INTERIOR, INTERIOR), Image.Resampling.LANCZOS)
        x = tile*TILE+GUTTER
        atlas.paste(content, (x, GUTTER))
        atlas.paste(content.crop((0, 0, 1, INTERIOR)).resize((GUTTER, INTERIOR)), (tile*TILE, GUTTER))
        atlas.paste(content.crop((INTERIOR-1, 0, INTERIOR, INTERIOR)).resize((GUTTER, INTERIOR)), (x+INTERIOR, GUTTER))
        # Fill full-width top/bottom bands after left/right edge replication.
        top = atlas.crop((tile*TILE, GUTTER, (tile+1)*TILE, GUTTER+1))
        bottom = atlas.crop((tile*TILE, GUTTER+INTERIOR-1, (tile+1)*TILE, GUTTER+INTERIOR))
        atlas.paste(top.resize((TILE, GUTTER)), (tile*TILE, 0))
        atlas.paste(bottom.resize((TILE, GUTTER)), (tile*TILE, TILE-GUTTER))
    full = io.BytesIO()
    atlas.save(full, format='PNG')
    atlas.convert('RGB').resize(ATLAS_SIZE, Image.Resampling.LANCZOS).save(path, optimize=True)
    return {'inputs': inputs, 'not_used': list(UNUSED_MAPS),
            'atlas_4096x2048_sha256': sha(full.getvalue()), 'size': list(ATLAS_SIZE),
            'tile': TILE//2, 'gutter': GUTTER//2,
            'uv': 'u=(tile*2048+8+2032*u)/4096; v=(8+2032*(1-v))/2048 (normalized, so the same at 2048x1024)'}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--fbx', type=Path, required=True, help='BMX_sf.fbx from the "BMX (Free)" download')
    maps = parser.add_mutually_exclusive_group(required=True)
    maps.add_argument('--zip', type=Path, help='bmx-free.zip, the download as Sketchfab serves it (the base-colour '
                      'maps are read from it by entry)')
    maps.add_argument('--textures', type=Path, help='the download\'s extracted textures folder, if its '
                      'base_BaseColor.png is the one ATLAS_TILES pins')
    parser.add_argument('--output', type=Path, required=True, help='a NEW folder')
    parser.add_argument('--expect', type=Path, help='a bike-data.json whose geometry and atlas hashes this run must give')
    parser.add_argument('--steps', type=int, default=8)
    parser.add_argument('--workers', type=int, default=7)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit('Output must be a NEW folder')
    if sha(args.fbx.read_bytes()) != SOURCE_SHA:
        raise SystemExit('This is not the supplied BMX_sf.fbx')
    tile_maps = read_tile_maps(args.zip, args.textures)
    started = time.time()
    objects = load_objects(args.fbx)
    lightened, rows = lighten(objects, args.steps, args.workers)
    args.output.mkdir(parents=True)
    geometry = args.output/'bike-geometry.npz'
    write_geometry(geometry, objects, lightened)
    atlas = make_atlas(tile_maps, args.output/'albedo.png')
    import validate_lightened_bike as check
    source = check.source_reference(objects)
    parts = {part: {'objects': sum(r['part'] == part for r in rows),
                    'triangles_before': sum(r['triangles_before'] for r in rows if r['part'] == part),
                    'triangles_after': sum(r['triangles_after'] for r in rows if r['part'] == part),
                    'corners': int(sum(len(lightened[i][0]) for i, r in enumerate(rows) if r['part'] == part))}
             for part in PARTS}
    report = {'format': FORMAT, 'tool': 'assets/models/bmx/lighten_free_model.py',
              'source': {'model': '"BMX (Free)" by Ermakov, CC BY 4.0',
                         'url': 'https://sketchfab.com/3d-models/bmx-free-547a95dab9dd4f598237f7ab2885443d',
                         'download': 'bmx-free.zip', 'download_sha256': DOWNLOAD_SHA,
                         'fbx': 'source/BMX_sf.fbx', 'fbx_sha256': SOURCE_SHA, 'objects': len(objects)},
              'frame': {'source_origin_m': SOURCE_ORIGIN.tolist(), 'uniform_scale': UNIFORM_SCALE,
                        'wheel_radius_m': WHEEL_RADIUS_M, 'part_pivots': PIVOTS, 'pivots': ANCHORS},
              'method': {'goals_mm': GOALS, 'shade_deg': SHADE, 'uv_tolerance': UV_TOLERANCE, 'kept_whole': KEEP_WHOLE,
                         'plane_locked': PLANE_LOCKED, 'clearance_m': CLEARANCE_M, 'covered_m': COVERED_M,
                         'search_steps': args.steps},
              'files': {'bike-geometry.npz': sha(geometry.read_bytes()),
                        'albedo.png': sha((args.output/'albedo.png').read_bytes())},
              'atlas': atlas,
              'triangles_before': sum(r['triangles_before'] for r in rows),
              'triangles_after': sum(r['triangles_after'] for r in rows),
              'triangle_budget': TRIANGLE_BUDGET, 'parts': parts, 'source_reference': source, 'objects': rows}
    (args.output/'bike-data.json').write_text(json.dumps(report, indent=1)+'\n', newline='\n')
    print('triangles', report['triangles_before'], '->', report['triangles_after'], 'in', round(time.time()-started, 1), 's')
    if args.expect:
        expected = json.loads(args.expect.read_text())['files']
        if expected != report['files']:
            raise SystemExit(f'The output differs from {args.expect}: {report["files"]} != {expected}')
        print('reproduced', args.expect)


if __name__ == '__main__':
    main()
