"""One fixed low-speed steering/pedal/park request; default is driver-free.

Start only after separately viewing the mounted rider and a clear short route.
Hold B and full left/right steer for1s, pedal with that steer for1s, brake with
centered steering for1s, then request one200ms ordinary Y park and release.
Neutral bookends keep the complete timeline within4s. Parking, retained trace
coverage, actual fork angle/crank/pedal and repair activation require evidence;
no input request or completed schedule establishes them.

This pins the existing PostureLeg, which pins SwitchLeg and the original base.
Owner/runtime/foreground/Escape checks, two-second neutral discovery preflight,
nonce-bound READY/GO,120ms lateness, final neutral and disconnect stay intact.
No equipment chord, hop, D-pad, menu, retry, launch or pose/physics change.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys
import types

ROOT = Path(__file__).resolve().parents[2]
POSTURE_PATH = ROOT / "contrib/bmx-lab/Bmx-PostureLeg.py"
APPROVED_POSTURE_SHA256 = "8356E0FEBE12FF2D59345809F6152993742D169178001300042F4343809593F8"
DEFAULT_SCENARIO = "ordinary-posture-capture-left"
SCENARIOS = (DEFAULT_SCENARIO, "ordinary-posture-capture-right")


class Refused(RuntimeError):
    pass


def load_posture():
    raw = POSTURE_PATH.read_bytes()
    if hashlib.sha256(raw).hexdigest().upper() != APPROVED_POSTURE_SHA256:
        raise Refused("Approved posture wrapper source changed")
    module = types.ModuleType("reskate_posture_capture_parent")
    module.__file__ = str(POSTURE_PATH)
    sys.modules[module.__name__] = module
    try:
        exec(compile(raw, str(POSTURE_PATH), "exec"), module.__dict__)
    except BaseException:
        sys.modules.pop(module.__name__, None)
        raise
    return module


def timelines(h):
    result = {}
    for name, steer in zip(SCENARIOS, (-1, 1)):
        events = (h.Event(0, h.NEUTRAL),
                  h.Event(240, h.State(h.B, left_x=steer)),
                  h.Event(1240, h.State(h.A, left_x=steer)),
                  h.Event(2240, h.State(h.B)),
                  h.Event(3240, h.State(h.Y)),
                  h.Event(3440, h.NEUTRAL), h.Event(4000, h.NEUTRAL))
        h.validate_timeline(events)
        result[name] = events
    return result


def configure(posture):
    switch = posture.load_switch()
    try:
        h = posture.configure(switch)
    except switch.Refused as error:
        raise Refused(str(error)) from error
    events = timelines(h)
    h.scenarios = lambda: dict(events)
    h.__doc__ = __doc__
    return h


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    selection = argparse.ArgumentParser(add_help=False)
    selection.add_argument("--execute", action="store_true")
    selection.add_argument("--start-gate")
    selection.add_argument("--start-nonce")
    selection.add_argument("--scenario", choices=SCENARIOS)
    selected, _ = selection.parse_known_args(args)
    if selected.execute and not (selected.start_gate and selected.start_nonce):
        raise Refused("Live posture capture requires a fresh --start-gate and --start-nonce")
    if selected.scenario is None:
        args = ["--scenario", DEFAULT_SCENARIO, *args]
    posture = load_posture()
    try:
        h = configure(posture)
    except posture.Refused as error:
        raise Refused(str(error)) from error
    try:
        return h.main(args)
    except h.Refused as error:
        raise Refused(str(error)) from error


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Refused, OSError, ValueError, ImportError) as error:
        print(f"Posture capture leg refused: {error}")
        raise SystemExit(2)
