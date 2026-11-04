"""Quadric-error half-edge-collapse decimation that keeps authored vertices (our own code).

lighten_free_model.py runs it on each object of the supplied bike model.

Every surviving vertex is an original source vertex with its original position,
authored normal and UV, so nothing moves: triangles only get larger. A collapse
u -> v is refused when it would
  * break manifold topology (link condition),
  * cross an attribute seam or open boundary except along it,
  * move a locked vertex (object bounding-box extremes, anchor objects),
  * flip or degenerate a triangle, or flip/degenerate its UV triangle,
  * tilt a triangle more than `max_shade_deg` away from its authored corner normals
    (keeps smooth shading believable on thin tubes),
  * exceed `tolerance` metres of quadric error (planes of the original faces,
    plus perpendicular planes along boundaries and seams),
  * move the texture: with `uv_tolerance` (source UV units), the UV the new triangles
    give at the removed vertex's own position must stay within that distance of its
    authored UV, for each of its wedges. This keeps chart borders and painted detail
    where they were (a half-edge collapse otherwise straightens UV seams).
"""
import heapq
import math

import numpy as np


def _plane_quadrics(p, tris, n_vertices, boundary_weight=1.0, seam_edges=()):
    a, b, c = p[tris[:, 0]], p[tris[:, 1]], p[tris[:, 2]]
    normal = np.cross(b-a, c-a)
    length = np.linalg.norm(normal, axis=1)
    ok = length > 1e-18
    normal[ok] /= length[ok, None]
    d = -np.einsum('ij,ij->i', normal, a)
    plane = np.c_[normal, d]
    plane[~ok] = 0
    k = np.einsum('ni,nj->nij', plane, plane)
    q = np.zeros((n_vertices, 4, 4))
    for corner in range(3):
        np.add.at(q, tris[:, corner], k)
    # Constraint planes through boundary/seam edges, perpendicular to their face.
    for (x, y, f) in seam_edges:
        e = p[y]-p[x]
        n = np.cross(e, plane[f, :3])
        ln = np.linalg.norm(n)
        if ln < 1e-18:
            continue
        n /= ln
        pl = np.r_[n, -n@p[x]]
        kk = boundary_weight*np.outer(pl, pl)
        q[x] += kk
        q[y] += kk
    return q


def _closest_bary(p, a, b, c):
    """Barycentric weights of the point of triangle abc closest to p (Ericson, Real-Time Collision Detection 5.1.5)."""
    ab, ac, ap = b-a, c-a, p-a
    d1, d2 = float(ab@ap), float(ac@ap)
    if d1 <= 0 and d2 <= 0:
        return 1.0, 0.0, 0.0
    bp = p-b
    d3, d4 = float(ab@bp), float(ac@bp)
    if d3 >= 0 and d4 <= d3:
        return 0.0, 1.0, 0.0
    vc = d1*d4-d3*d2
    if vc <= 0 and d1 >= 0 and d3 <= 0:
        v = d1/(d1-d3)
        return 1-v, v, 0.0
    cp = p-c
    d5, d6 = float(ab@cp), float(ac@cp)
    if d6 >= 0 and d5 <= d6:
        return 0.0, 0.0, 1.0
    vb = d5*d2-d1*d6
    if vb <= 0 and d2 >= 0 and d6 <= 0:
        w = d2/(d2-d6)
        return 1-w, 0.0, w
    va = d3*d6-d5*d4
    if va <= 0 and (d4-d3) >= 0 and (d5-d6) >= 0:
        w = (d4-d3)/((d4-d3)+(d5-d6))
        return 0.0, 1-w, w
    denom = 1.0/(va+vb+vc)
    v, w = vb*denom, vc*denom
    return 1-v-w, v, w


def decimate(positions, tris, wedges, wedge_normal, wedge_uv, tolerance, locked=None,
             max_shade_deg=45.0, max_flip_deg=60.0, target_faces=0, boundary_weight=1.0, uv_tolerance=None):
    """positions: (n,3) topological vertices; tris: (m,3) vertex ids; wedges: (m,3) wedge ids;
    wedge_normal/uv: per wedge. Returns surviving (tris, wedges) arrays."""
    n = len(positions)
    p = np.asarray(positions, dtype=np.float64)
    F = [list(map(int, t)) for t in tris]
    W = [list(map(int, w)) for w in wedges]
    alive = [True]*len(F)
    vf = [set() for _ in range(n)]
    for f, t in enumerate(F):
        for v in t:
            vf[v].add(f)
    locked = np.zeros(n, bool) if locked is None else np.array(locked, bool)
    # Edge -> faces, to find boundaries, seams and non-manifold edges.
    edge_faces = {}
    for f, t in enumerate(F):
        for i in range(3):
            a, b = t[i], t[(i+1) % 3]
            edge_faces.setdefault((min(a, b), max(a, b)), []).append(f)
    constraint = []
    for (a, b), fs in edge_faces.items():
        if len(fs) > 2:
            locked[a] = locked[b] = True
            continue
        if len(fs) == 1:
            constraint.append((a, b, fs[0]))
            continue
        f0, f1 = fs
        wa0, wa1 = W[f0][F[f0].index(a)], W[f1][F[f1].index(a)]
        wb0, wb1 = W[f0][F[f0].index(b)], W[f1][F[f1].index(b)]
        if wa0 != wa1 or wb0 != wb1:
            constraint.append((a, b, f0))
            constraint.append((a, b, f1))
    Q = _plane_quadrics(p, np.asarray(tris), n, boundary_weight, constraint)
    tol2 = tolerance*tolerance
    cos_shade = math.cos(math.radians(max_shade_deg))
    cos_flip = math.cos(math.radians(max_flip_deg))
    wn = np.asarray(wedge_normal, dtype=np.float64)
    wuv = np.asarray(wedge_uv, dtype=np.float64)
    version = [0]*n
    dead = [False]*n
    heap = []
    hom = np.c_[p, np.ones(n)]

    def neighbours(u):
        out = set()
        for f in vf[u]:
            out.update(F[f])
        out.discard(u)
        return out

    def push(u, v):
        if locked[u] or dead[u] or dead[v]:
            return
        h = hom[v]
        cost = float(h@(Q[u]+Q[v])@h)
        heapq.heappush(heap, (cost, u, v, version[u], version[v]))

    for u in range(n):
        for v in neighbours(u):
            push(u, v)

    def face_normal(a, b, c):
        nrm = np.cross(p[b]-p[a], p[c]-p[a])
        ln = math.sqrt(float(nrm@nrm))
        return nrm, ln

    def uv_area(wa, wb, wc):
        a, b, c = wuv[wa], wuv[wb], wuv[wc]
        return float((b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]))

    def u_discontinuities(u):
        """Edges (u,x) that are open boundaries or where u's wedge changes across them."""
        around = {}
        for f in vf[u]:
            t = F[f]
            i = t.index(u)
            for x in (t[(i+1) % 3], t[(i+2) % 3]):
                around.setdefault(x, []).append(f)
        out = set()
        for x, fs in around.items():
            if len(fs) == 1:
                out.add(x)
            elif len(fs) == 2:
                if W[fs[0]][F[fs[0]].index(u)] != W[fs[1]][F[fs[1]].index(u)]:
                    out.add(x)
            else:
                return None
        return out

    faces_alive = len(F)
    while heap and faces_alive > target_faces:
        cost, u, v, vu, vv = heapq.heappop(heap)
        if dead[u] or dead[v] or version[u] != vu or version[v] != vv or locked[u]:
            continue
        if cost > tol2:
            break
        fu = vf[u]
        shared = [f for f in fu if v in F[f]]
        if not shared:
            continue
        # Link condition: common neighbours are exactly the opposite vertices of shared faces.
        opposite = set()
        for f in shared:
            opposite.update(x for x in F[f] if x != u and x != v)
        if (neighbours(u) & neighbours(v)) != opposite:
            continue
        disc = u_discontinuities(u)
        if disc is None:
            continue
        if disc:
            if len(disc) != 2 or v not in disc:
                continue
        else:
            # u is smooth: edge (u,v) must not be a seam at v either.
            if len(shared) != 2:
                continue
            wv = {W[f][F[f].index(v)] for f in shared}
            if len(wv) != 1:
                continue
        mapping = {}
        bad = False
        for f in shared:
            wu_, wv_ = W[f][F[f].index(u)], W[f][F[f].index(v)]
            if mapping.get(wu_, wv_) != wv_:
                bad = True
                break
            mapping[wu_] = wv_
        if bad:
            continue
        survivors = [f for f in fu if f not in shared]
        ok = True
        new_w = {}
        for f in survivors:
            t = F[f]
            i = t.index(u)
            wu_ = W[f][i]
            if wu_ not in mapping:
                ok = False
                break
            nt = list(t)
            nt[i] = v
            nw = list(W[f])
            nw[i] = mapping[wu_]
            old_n, old_l = face_normal(*t)
            new_n, new_l = face_normal(*nt)
            if new_l < 1e-14 or old_l < 1e-18:
                ok = False
                break
            new_unit = new_n/new_l
            if float(old_n@new_unit)/old_l < cos_flip:
                ok = False
                break
            # Shading: the new face must agree with its authored corner normals,
            # unless the source face already disagreed as much.
            old_unit = old_n/old_l
            old_worst = min(float(wn[w]@old_unit) for w in W[f])
            new_worst = min(float(wn[w]@new_unit) for w in nw)
            if new_worst < min(cos_shade, old_worst-1e-9):
                ok = False
                break
            ua_old, ua_new = uv_area(*W[f]), uv_area(*nw)
            if ua_old != 0 and (ua_new == 0 or (ua_old > 0) != (ua_new > 0)):
                ok = False
                break
            new_w[f] = (nt, nw)
        if ok and uv_tolerance is not None:
            pu = p[u]
            for wu_ in {W[f][F[f].index(u)] for f in fu}:
                best = None
                for f, (nt, nw) in new_w.items():
                    if W[f][F[f].index(u)] != wu_:
                        continue
                    a_, b_, c_ = _closest_bary(pu, p[nt[0]], p[nt[1]], p[nt[2]])
                    q = a_*p[nt[0]]+b_*p[nt[1]]+c_*p[nt[2]]
                    d = float((q-pu)@(q-pu))
                    if best is None or d < best[0]:
                        best = (d, a_*wuv[nw[0]]+b_*wuv[nw[1]]+c_*wuv[nw[2]])
                if best is None:
                    continue
                duv = best[1]-wuv[wu_]
                if float(duv@duv) > uv_tolerance*uv_tolerance:
                    ok = False
                    break
        if not ok:
            continue
        # Commit.
        for f in shared:
            alive[f] = False
            faces_alive -= 1
            for x in F[f]:
                vf[x].discard(f)
        for f, (nt, nw) in new_w.items():
            F[f], W[f] = nt, nw
            vf[v].add(f)
        vf[u] = set()
        dead[u] = True
        Q[v] = Q[v]+Q[u]
        ring = neighbours(v)
        for x in ring | {v}:
            version[x] += 1
        for x in ring | {v}:
            for y in neighbours(x):
                push(x, y)
    out_t = np.array([F[f] for f in range(len(F)) if alive[f]], dtype=np.int64).reshape(-1, 3)
    out_w = np.array([W[f] for f in range(len(F)) if alive[f]], dtype=np.int64).reshape(-1, 3)
    return out_t, out_w
