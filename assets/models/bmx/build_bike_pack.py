"""Build the BMX mod's native bike pack on this machine, from the mod's own bike data and this machine's game.

The repository carries only our own data: the lightened bike (bike-geometry.npz), its atlas (albedo.png) and
bike-data.json, in contrib/bmx-lab/bmx-playable-experimental/bike. A native pack also needs pieces that come from
Skate's own files: a copy of the dingolevel_root bundle's manifest and table of contents, its two shader tables with
the bike material's rows added, and the LOD group the template mesh imports. Those are never committed. This builds
them here from the supported game's own files, with dingosdk_bmx_native_pack_builder, and the FPV drone template
that ReSkate Studio made (PinaPipe, CC BY 4.0), read from the repository's history (upstream 0dcbcb3a,
assets/builtin/fpv_drone.zip).

The template gives the bike the layout of its native assets, not their names: the builder takes the drone's own
assets out of the pack and writes the bike's (three textures, the shader depot, the variation database, a mesh and
blueprint per part) under names, GUIDs, resource ids and material keys of their own, so that none of them is also
an asset of the ReSkate FPV Drone mod (whether the two then draw side by side is for a game trial). After the build, builder --check-own-names checks that nothing of the drone's is
left; a failed check fails the build. --keep-template-names (database, block-hashes, section-names, partition-guid)
keeps the template's value for those, for a game trial that has to find which of them the game minds; such a pack
must fail the check, and only in the checks the kept values explain.

Steps: check the game is the supported build; take the template from git; validate the template's mesh declaration
(builder --extract-template); turn each of the eight parts into native mesh and geometry files with
prepare_free_native_parts.py's own writer (the spinning parts about their hubs); encode the atlas and a flat normal
with prepare_free_native_textures.py; assemble the pack with the builder; then copy into OUTPUT only what a mod
needs: layout.toc, .reskate-studio-patch, BMX-NATIVE.txt (the credits) and the Win32 tree. The template's copy of
the game's initfs_win32 and the builder's texture-audit folder are left out: the merge never reads a mod's initfs.
Then check the copied pack's names (builder --check-own-names).

The game folder is only read. OUTPUT must be a new folder; its files, sizes and sha256 are written to
OUTPUT.files.json beside it, and --expect compares them with a recorded list (bike/pack-files.json): the build is
deterministic, so a supported game gives the same bytes.

Usage: python -I -B build_bike_pack.py --game-root <Skate folder> --builder <dingosdk_bmx_native_pack_builder.exe>
           --output <new folder> [--data <bike folder>] [--template <fpv_drone.zip>] [--expect <pack-files.json>]
           [--keep-template-names <list>]
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import zipfile

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lighten_free_model as lf  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DATA = REPO/'contrib/bmx-lab/bmx-playable-experimental/bike'
# Engine/Game/Build/supported_build.h game_sha256.
GAME_SHA = 'fbce74d5e28ef525dbba2cb4adbebc13405bdbd88f31bc940bca45e4ae88b8f9'
TEMPLATE_COMMIT = '0dcbcb3a89dbda262dec9143c38e55371087dfdd'
TEMPLATE_PATH = 'assets/builtin/fpv_drone.zip'
TEMPLATE_SHA = 'd79b054e94265e892fa6318870e0e6d9bee1dd16cd112659b9797426d872dd49'
TEMPLATE_FILES = {'.reskate-studio-patch', 'initfs_win32', 'layout.toc',
                  'Win32/configurations/layout/initialinstallpackage/cas_01.cas',
                  'Win32/levels/game/dingolevel_root/dingolevel_root.toc'}
# What the mod folder needs; everything else the builder writes stays out.
PACK_FILES = ('.reskate-studio-patch', 'layout.toc', 'BMX-NATIVE.txt',
              'Win32/configurations/layout/initialinstallpackage/cas_01.cas',
              'Win32/levels/game/dingolevel_root/dingolevel_root.toc')
# What the builder's --keep-template-names can keep of the template's, and the --check-own-names checks a
# kept value fails: C1 finds the template's identities, C6 checks the database, C5 the depot, C3 the meshes'
# OriginalPartitionGuid.
KEEP_FAILS = {'database': {'C1', 'C6'}, 'block-hashes': {'C1', 'C5'}, 'section-names': {'C1'},
              'partition-guid': {'C1', 'C3'}}
KEEP_NAMES = set(KEEP_FAILS)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def module(name):
    spec = importlib.util.spec_from_file_location(name, HERE/f'{name}.py')
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def template_zip(path):
    if path:
        data = Path(path).read_bytes()
    else:
        data = subprocess.run(['git', '-C', str(REPO), 'cat-file', '-p', f'{TEMPLATE_COMMIT}:{TEMPLATE_PATH}'],
                              check=True, capture_output=True).stdout
    if sha(data) != TEMPLATE_SHA:
        raise SystemExit('The FPV template is not the one upstream shipped in 0dcbcb3a')
    return data


def unpack_template(data, target):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = {info.filename for info in archive.infolist() if not info.is_dir()}
        if names != TEMPLATE_FILES:
            raise SystemExit(f'Unexpected template files: {sorted(names)}')
        for name in sorted(names):
            out = target/name
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(archive.read(name))


def run(command):
    print('>', ' '.join(str(c) for c in command), flush=True)
    result = subprocess.run([str(c) for c in command])
    if result.returncode:
        raise SystemExit(f'{Path(command[0]).name} failed ({result.returncode})')


def write_parts(objects, inspection, target):
    """The eight native parts, as prepare_free_native_parts.py writes them, from the lightened objects."""
    parts = module('prepare_free_native_parts')
    encoder, _ = parts.verified_encoder()
    target.mkdir(parents=True)
    reports = []
    for part in lf.PARTS:
        chunks, offset = [], 0
        for o in objects:
            if o['part'] != part:
                continue
            uv = parts.atlas_uv(o['uv'], o['tile'])
            p, n, uv, t, hand, faces, _ = parts.tangents(o['position'], o['normal'], uv, o['triangles'])
            chunks.append((p, n, uv, t, hand, faces+offset))
            offset += len(p)
        joined = [np.concatenate([c[k] for c in chunks]) for k in range(6)]
        if part in lf.PIVOTS:
            joined[0] = joined[0]-np.asarray(lf.ANCHORS[lf.PIVOTS[part]])
        report = parts.write_native(part, *joined, inspection, target, encoder)
        reports.append(report)
        print(json.dumps({'part': part, 'vertices': report['vertices'], 'triangles': report['triangles'],
                          'geometry_bytes': (target/f'{part}.geom').stat().st_size}), flush=True)
    (target/'part-list.txt').write_text('\n'.join(lf.PARTS)+'\n', newline='\n')
    (target/'geometry.json').write_text(json.dumps(reports, indent=2)+'\n', newline='\n')
    return reports


def credits(report, keep=()):
    note = (
        'BMX bike for the BMX mod: a native pack built on this machine by assets/models/bmx/build_bike_pack.py from\n'
        'the mod\'s own bike data and this game\'s own files.\n\n'
        'Bike model: "BMX (Free)" by Ermakov (https://sketchfab.com/Ermakovv)\n'
        'https://sketchfab.com/3d-models/bmx-free-547a95dab9dd4f598237f7ab2885443d\n'
        'Licensed under CC BY 4.0: https://creativecommons.org/licenses/by/4.0/\n'
        f'Changed: lightened from {report["triangles_before"]:,} to {report["triangles_after"]:,} triangles, every '
        'corner and face centre of the original surface within 0.5 mm of the lightened one (1 mm on the tyres, 0.7 mm '
        'on the spokes), with the hidden overlapping layers of the grip tape removed; its 185 objects grouped into 8 '
        'parts (frame, fork, rear wheel, front wheel, cranks, handlebars, two pedals); scaled to a 0.2630808 m wheel '
        'radius and re-centred; the wheels and cranks given their origins at their hubs; two of its three base-colour '
        'maps packed into one 2048x1024 atlas, the grips\' and bars\' map ("rul"), which its "base" parts are drawn '
        'with too, and the "extra" map; the "base" parts\' own colour map and its normal, roughness and metallic maps '
        'not used; converted to native meshes.\n\n'
        'Native material and mesh template: "FPV Drone" by PinaPipe, built into a pack by ReSkate Studio\n'
        'https://sketchfab.com/3d-models/fpv-drone-92152c31ec9a4a87b2a0478bd114d293\n'
        'Licensed under CC BY 4.0: https://creativecommons.org/licenses/by/4.0/\n'
        'Changed: none of its assets is in this pack. The bike\'s parts reuse the Studio pack\'s structure: its EBX '
        'layouts (mesh, materials, blueprint, textures), its shader depot\'s blocks and its variation database\'s '
        'material variations (which refer to the game\'s own), written under the bike\'s own names. The bike\'s frame '
        'mask is the drone\'s mask '
        'value (one texel); its colour and normal are the bike\'s atlas and a flat normal.\n')
    if keep:
        note += f'\nBisect build for a game trial: it keeps the FPV drone template\'s {", ".join(keep)}.\n'
    return note


def file_list(root):
    return {name: {'bytes': (root/name).stat().st_size, 'sha256': sha((root/name).read_bytes())} for name in PACK_FILES}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--game-root', type=Path, required=True)
    parser.add_argument('--builder', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--data', type=Path, default=DATA)
    parser.add_argument('--template', type=Path, help='fpv_drone.zip; by default it is read from git history')
    parser.add_argument('--expect', type=Path, help='a pack-files.json the built pack must match')
    parser.add_argument('--keep-work', type=Path, help='keep the intermediate folders here (a NEW folder)')
    parser.add_argument('--keep-template-names', default='',
                        help='comma list of database, block-hashes, section-names, partition-guid: keep the '
                             'template\'s value for those (a bisect build for a game trial; its check must fail, '
                             'and only where the kept values explain)')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        raise SystemExit('Output must be a NEW folder')
    keep = [name for name in args.keep_template_names.split(',') if name and name != 'none']
    if set(keep) - KEEP_NAMES:
        raise SystemExit(f'--keep-template-names takes {", ".join(sorted(KEEP_NAMES))}')
    if sha((args.game_root/'Skate.exe').read_bytes()) != GAME_SHA:
        raise SystemExit('The game folder is not the supported Skate build')
    report = json.loads((args.data/'bike-data.json').read_text())
    for name, digest in report['files'].items():
        if sha((args.data/name).read_bytes()) != digest:
            raise SystemExit(f'{name} is not the file bike-data.json records')
    template = template_zip(args.template)
    objects = lf.read_geometry(args.data/'bike-geometry.npz')
    work = Path(tempfile.mkdtemp(prefix='bmx-bike-pack-')) if not args.keep_work else args.keep_work.resolve()
    if args.keep_work:
        work.mkdir(parents=True)
    try:
        unpack_template(template, work/'template')
        run([args.builder, '--extract-template', work/'template', work/'inspection', args.game_root])
        write_parts(objects, work/'inspection', work/'parts')
        module('prepare_free_native_textures').prepare(args.data, work/'native-textures')
        keep_flag = [f'--keep-template-names={",".join(keep)}'] if keep else []
        run([args.builder, *keep_flag, work/'template', work/'parts', work/'pack', args.game_root, work/'native-textures'])
        output.mkdir(parents=True)
        for name in PACK_FILES:
            if name == 'BMX-NATIVE.txt':
                # The builder's own note calls the pack private; this one carries the credits.
                (output/name).write_text(credits(report, keep), newline='\n')
                continue
            (output/name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(work/'pack'/name, output/name)
        # The pack as the mod folder will hold it: nothing of the drone's may be left in it.
        command = [args.builder, '--check-own-names', output, work/'template', args.game_root]
        print('>', ' '.join(str(c) for c in command), flush=True)
        if not keep:
            if subprocess.run([str(c) for c in command]).returncode:
                raise SystemExit(f'The pack in {output} keeps names of the FPV drone template (--check-own-names failed)')
        else:
            # A bisect pack must fail, and only in the checks its kept values explain; a check that
            # stopped on an error prints no verdict line.
            result = subprocess.run([str(c) for c in command], capture_output=True, text=True, errors='replace')
            sys.stdout.write(result.stdout)
            sys.stderr.write(result.stderr)
            sys.stdout.flush()
            verdict = [line for line in result.stdout.splitlines() if line.startswith('own names: ')]
            failed = set(verdict[-1].removeprefix('own names: FAIL in').split()) \
                if verdict and verdict[-1].startswith('own names: FAIL in') else set()
            explained = set().union(*(KEEP_FAILS[name] for name in keep))
            if result.returncode != 1 or not failed or not failed <= explained:
                raise SystemExit(f'--check-own-names on the pack in {output} did not fail as a pack that keeps '
                                 f'{", ".join(keep)} must: exit {result.returncode}, failed '
                                 f'{" ".join(sorted(failed)) or "nothing"}, explained {" ".join(sorted(explained))}')
            print('Bisect build: --check-own-names fails in', ' '.join(sorted(failed)), 'as a pack that keeps',
                  ', '.join(keep), 'must', flush=True)
    finally:
        if not args.keep_work:
            shutil.rmtree(work, ignore_errors=True)
    files = file_list(output)
    listing = output.parent/(output.name+'.files.json')
    listing.write_text(json.dumps(files, indent=1)+'\n', newline='\n')
    for name, row in files.items():
        print(f'{row["bytes"]:>10}  {row["sha256"]}  {name}')
    if args.expect:
        expected = json.loads(args.expect.read_text())
        if expected != files:
            raise SystemExit(f'The pack differs from {args.expect}')
        print('matches', args.expect)
    print('Built', output)


if __name__ == '__main__':
    main()
