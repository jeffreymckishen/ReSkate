"""One fixed ordinary right-walk request; default is a driver-free dry-run.

Use only after separately observing a standing rider and the retained bike.
Schedule neutral at 0ms, LS X=+.65 at 240..840ms, then neutral through 3000ms.
All buttons, other axes and triggers stay zero. No pedal, brake, Y, LB, hop,
D-pad, menu input, conditional follow-up or automatic retry is scheduled.
Movement, proximity, custody and remount readiness require separate evidence.

The exact pinned SwitchLeg retains its two-second guarded neutral preflight.
Its pinned base supplies owner/runtime/foreground/Escape checks, bootstrap,
nonce-bound ready/GO, unchanged six-second maximum and 120ms lateness bounds,
final neutral and disconnect. This wrapper does not launch, focus, capture,
install dependencies or inspect the game, and never requests a remount.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys
import types

ROOT = Path(__file__).resolve().parents[2]
SWITCH_PATH = ROOT / "contrib/bmx-lab/Bmx-SwitchLeg.py"
APPROVED_SWITCH_SHA256 = "F87B84720AAB804869732940489EF6D4DD54C2D1F23ED92621417FDADBD3B6E2"
SCENARIO = "ordinary-walk-right"


class Refused(RuntimeError):
    pass


def load_switch():
    raw = SWITCH_PATH.read_bytes()
    if hashlib.sha256(raw).hexdigest().upper() != APPROVED_SWITCH_SHA256:
        raise Refused("Approved switch wrapper source changed")
    module = types.ModuleType("reskate_walk_switch")
    module.__file__ = str(SWITCH_PATH)
    sys.modules[module.__name__] = module
    try:
        exec(compile(raw, str(SWITCH_PATH), "exec"), module.__dict__)
    except BaseException:
        sys.modules.pop(module.__name__, None)
        raise
    return module


def timeline(h):
    events = (h.Event(0, h.NEUTRAL), h.Event(240, h.State(left_x=.65)),
              h.Event(840, h.NEUTRAL), h.Event(3000, h.NEUTRAL))
    h.validate_timeline(events)
    return events


def configure(switch):
    h = switch.configure(switch.load_driver())
    events = timeline(h)
    h.scenarios = lambda: {SCENARIO: events}
    h.__doc__ = __doc__
    return h


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    selection = argparse.ArgumentParser(add_help=False)
    selection.add_argument("--execute", action="store_true")
    selection.add_argument("--start-gate")
    selection.add_argument("--start-nonce")
    selection.add_argument("--scenario", choices=(SCENARIO,))
    selected, _ = selection.parse_known_args(args)
    if selected.execute and not (selected.start_gate and selected.start_nonce):
        raise Refused("Live walk requires a fresh --start-gate and --start-nonce")
    if selected.scenario is None:
        args = ["--scenario", SCENARIO, *args]
    switch = load_switch()
    try:
        h = configure(switch)
    except switch.Refused as error:
        raise Refused(str(error)) from error
    try:
        return h.main(args)
    except h.Refused as error:
        raise Refused(str(error)) from error


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Refused, OSError, ValueError, ImportError) as error:
        print(f"Walk leg refused: {error}")
        raise SystemExit(2)
