"""Minimal binary FBX 7.x reader for the supplied bike model (our own code, stdlib + numpy only).

Reads the node tree, then returns each mesh Model with its geometry evaluated in
world space: vertices, polygon-vertex indices, per-polygon-vertex normals and UVs,
the per-polygon material and the model's global transform. Only what BMX_sf.fbx
uses is supported; anything else is refused rather than guessed. It replaces the
earlier FBX-to-intermediate conversion, which is no longer in the repository:
lighten_free_model.py reads the FBX with it directly.
"""
from pathlib import Path
import math
import struct
import zlib

import numpy as np

ARRAY_TYPES = {b'f': ('<f4', 4), b'd': ('<f8', 8), b'l': ('<i8', 8), b'i': ('<i4', 4), b'b': ('<u1', 1)}


class Node:
    __slots__ = ('name', 'props', 'children')

    def __init__(self, name, props, children):
        self.name, self.props, self.children = name, props, children

    def find(self, name):
        return next((c for c in self.children if c.name == name), None)

    def all(self, name):
        return [c for c in self.children if c.name == name]


def _read_props(data, at, count):
    props = []
    for _ in range(count):
        kind = data[at:at+1]; at += 1
        if kind in ARRAY_TYPES:
            length, encoding, size = struct.unpack_from('<III', data, at); at += 12
            raw = data[at:at+size]; at += size
            if encoding == 1:
                raw = zlib.decompress(raw)
            elif encoding != 0:
                raise ValueError('Unsupported FBX array encoding')
            dtype, width = ARRAY_TYPES[kind]
            if len(raw) != length*width:
                raise ValueError('FBX array length mismatch')
            props.append(np.frombuffer(raw, dtype=dtype).copy())
        elif kind == b'S' or kind == b'R':
            length, = struct.unpack_from('<I', data, at); at += 4
            value = data[at:at+length]; at += length
            props.append(value.decode('utf-8', 'replace') if kind == b'S' else value)
        else:
            fmt = {b'Y': '<h', b'C': '<?', b'I': '<i', b'F': '<f', b'D': '<d', b'L': '<q'}.get(kind)
            if fmt is None:
                raise ValueError(f'Unsupported FBX property type {kind!r}')
            props.append(struct.unpack_from(fmt, data, at)[0]); at += struct.calcsize(fmt)
    return props, at


def _read_node(data, at, wide):
    if wide:
        end, count, _, name_len = struct.unpack_from('<QQQB', data, at); at += 25
        sentinel = 25
    else:
        end, count, _, name_len = struct.unpack_from('<IIIB', data, at); at += 13
        sentinel = 13
    if end == 0:
        return None, at
    name = data[at:at+name_len].decode('ascii'); at += name_len
    props, at = _read_props(data, at, count)
    children = []
    while at < end:
        if end-at == sentinel and data[at:end] == bytes(sentinel):
            at = end
            break
        child, at = _read_node(data, at, wide)
        if child is None:
            break
        children.append(child)
    return Node(name, props, children), end


def read_tree(path):
    data = Path(path).read_bytes()
    if not data.startswith(b'Kaydara FBX Binary  \x00'):
        raise ValueError('Not a binary FBX')
    version, = struct.unpack_from('<I', data, 23)
    wide = version >= 7500
    at, nodes = 27, []
    while at < len(data):
        node, at = _read_node(data, at, wide)
        if node is None:
            break
        nodes.append(node)
    return version, Node('root', [], nodes)


def _p70(node):
    out = {}
    block = node.find('Properties70') if node is not None else None
    for p in (block.children if block else []):
        out[p.props[0]] = p.props[4:]
    return out


def _euler_matrix(deg, order=0):
    if order != 0:
        raise ValueError('Only eEulerXYZ rotation order is supported')
    x, y, z = (math.radians(v) for v in deg)
    rx = np.array([[1, 0, 0], [0, math.cos(x), -math.sin(x)], [0, math.sin(x), math.cos(x)]])
    ry = np.array([[math.cos(y), 0, math.sin(y)], [0, 1, 0], [-math.sin(y), 0, math.cos(y)]])
    rz = np.array([[math.cos(z), -math.sin(z), 0], [math.sin(z), math.cos(z), 0], [0, 0, 1]])
    m = np.eye(4)
    m[:3, :3] = rz@ry@rx  # XYZ order: X applied first
    return m


def _translate(v):
    m = np.eye(4); m[:3, 3] = v
    return m


def _scale(v):
    return np.diag([v[0], v[1], v[2], 1.0])


def local_matrix(props):
    """FBX SDK local transform: T*Roff*Rp*Rpre*R*Rpost^-1*Rp^-1*Soff*Sp*S*Sp^-1."""
    g = lambda key, default: np.array(props.get(key, default), dtype=float)
    t, r, s = g('Lcl Translation', (0, 0, 0)), g('Lcl Rotation', (0, 0, 0)), g('Lcl Scaling', (1, 1, 1))
    roff, rp = g('RotationOffset', (0, 0, 0)), g('RotationPivot', (0, 0, 0))
    soff, sp = g('ScalingOffset', (0, 0, 0)), g('ScalingPivot', (0, 0, 0))
    pre, post = g('PreRotation', (0, 0, 0)), g('PostRotation', (0, 0, 0))
    order = int(props.get('RotationOrder', (0,))[0]) if 'RotationOrder' in props else 0
    return (_translate(t)@_translate(roff)@_translate(rp)@_euler_matrix(pre)@_euler_matrix(r, order)
            @np.linalg.inv(_euler_matrix(post))@_translate(-rp)@_translate(soff)@_translate(sp)
            @_scale(s)@_translate(-sp))


def geometric_matrix(props):
    g = lambda key, default: np.array(props.get(key, default), dtype=float)
    return (_translate(g('GeometricTranslation', (0, 0, 0)))@_euler_matrix(g('GeometricRotation', (0, 0, 0)))
            @_scale(g('GeometricScaling', (1, 1, 1))))


def _layer(geometry, element, values_name, index_name):
    layer = geometry.find(element)
    if layer is None:
        return None, None
    mapping = layer.find('MappingInformationType').props[0]
    reference = layer.find('ReferenceInformationType').props[0]
    values = layer.find(values_name).props[0]
    index = layer.find(index_name).props[0] if reference in ('IndexToDirect', 'Index') else None
    return (mapping, reference, values, index), layer


def load(path):
    version, root = read_tree(path)
    settings = _p70(root.find('GlobalSettings'))
    objects = root.find('Objects')
    by_id = {}
    for node in objects.children:
        by_id[node.props[0]] = node
    parent_of, children_of = {}, {}
    for c in root.find('Connections').children:
        if c.props[0] == 'OO':
            child, parent = c.props[1], c.props[2]
            children_of.setdefault(parent, []).append(child)
            if by_id.get(child) is not None and by_id[child].name == 'Model':
                parent_of[child] = parent

    def world(model_id):
        node = by_id[model_id]
        m = local_matrix(_p70(node))
        parent = parent_of.get(model_id, 0)
        if parent in by_id and by_id[parent].name == 'Model':
            m = world(parent)@m
        return m

    materials = {k: v.props[1].split('\x00')[0] for k, v in by_id.items() if v.name == 'Material'}
    meshes = []
    for model_id, node in by_id.items():
        if node.name != 'Model' or node.props[2] != 'Mesh':
            continue
        linked = children_of.get(model_id, [])
        geometry_ids = [i for i in linked if i in by_id and by_id[i].name == 'Geometry']
        material_ids = [i for i in linked if i in materials]
        if len(geometry_ids) != 1:
            raise ValueError('Each mesh model must own one geometry')
        geometry = by_id[geometry_ids[0]]
        props = _p70(node)
        transform = world(model_id)@geometric_matrix(props)
        vertices = geometry.find('Vertices').props[0].reshape(-1, 3)
        encoded = geometry.find('PolygonVertexIndex').props[0].astype(np.int64)
        homogeneous = np.c_[vertices, np.ones(len(vertices))]@transform.T
        normal_matrix = np.linalg.inv(transform[:3, :3]).T
        (nmap, nref, nvalues, nindex), _ = _layer(geometry, 'LayerElementNormal', 'Normals', 'NormalsIndex')
        normals = nvalues.reshape(-1, 3)
        if nmap == 'ByPolygonVertex':
            wedge_normals = normals[nindex] if nindex is not None else normals
        elif nmap == 'ByVertice' or nmap == 'ByVertex':
            corner = np.where(encoded < 0, -encoded-1, encoded)
            wedge_normals = (normals[nindex] if nindex is not None else normals)[corner]
        else:
            raise ValueError(f'Unsupported normal mapping {nmap}')
        wedge_normals = wedge_normals@normal_matrix.T
        wedge_normals /= np.linalg.norm(wedge_normals, axis=1)[:, None]
        (umap, uref, uvalues, uindex), _ = _layer(geometry, 'LayerElementUV', 'UV', 'UVIndex')
        uv = uvalues.reshape(-1, 2)
        if umap == 'ByPolygonVertex':
            wedge_uv = uv[uindex] if uindex is not None else uv
        else:
            raise ValueError(f'Unsupported UV mapping {umap}')
        mat_layer = geometry.find('LayerElementMaterial')
        poly_material = None
        if mat_layer is not None:
            mapping = mat_layer.find('MappingInformationType').props[0]
            values = mat_layer.find('Materials').props[0]
            if mapping == 'AllSame':
                poly_material = np.full(int((encoded < 0).sum()), int(values[0]))
            else:
                poly_material = values.astype(np.int64)
        meshes.append({'model_id': model_id, 'geometry_id': geometry.props[0],
                       'name': node.props[1].split('\x00')[0], 'transform': transform,
                       'vertices': homogeneous[:, :3], 'local_vertices': vertices,
                       'polygon_vertex_index': encoded, 'wedge_normals': wedge_normals, 'wedge_uv': wedge_uv,
                       'polygon_material': poly_material,
                       'materials': [materials[i] for i in material_ids]})
    return {'version': version, 'settings': settings, 'meshes': meshes}


def triangulate(encoded):
    """Fan-triangulate FBX polygons; returns wedge-index triangles and polygon ids."""
    ends = np.flatnonzero(encoded < 0)
    starts = np.r_[0, ends[:-1]+1]
    tris, poly = [], []
    sizes = ends-starts+1
    for size in np.unique(sizes):
        sel = np.flatnonzero(sizes == size)
        s = starts[sel]
        for k in range(1, size-1):
            tris.append(np.stack((s, s+k, s+k+1), axis=1))
            poly.append(sel)
    order = np.argsort(np.concatenate(poly), kind='stable')
    return np.concatenate(tris)[order], np.concatenate(poly)[order]
