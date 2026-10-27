"""One fixed ordinary BMX departure/park test; default is driver-free dry-run.

Use only after separately viewing a mounted rider and a clear route to the left.
The fixed leg pedals withLS X=-.45 for1s, coasts with centered steering for200ms,
brakes for1s, releases for160ms, requests one200ms ordinaryY park, then neutral.
No pump, hop, LB chord, D-pad, menu input or automatic retry is scheduled.
This is a fixed test sequence, not conditional on a proven brake or mount state.
The Y request is not evidence that parking or native trace export succeeded.

The exact reviewed SwitchLeg supplies its2s neutral discovery preflight and
the exact baseline supplies owner/runtime/foreground/Escape guards, bootstrap,
nonce-bound ready/GO,20ms scheduling,120ms lateness bound, and final neutral /
disconnect. This wrapper does not launch, focus, capture or inspect the game.
Its reports request input; movement, braking and obstacle clearance require
independent native/video evidence. A completion receipt is not a ride verdict.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys
import types

ROOT = Path(__file__).resolve().parents[2]
SWITCH_PATH = ROOT / "contrib/bmx-lab/Bmx-SwitchLeg.py"
APPROVED_SWITCH_SHA256 = "25D6EDFDB8494A264824D85AE3A884B14AAB3951AC5294E5568A9DF66E310779"
SCENARIO = "ordinary-departure-left-park"


class Refused(RuntimeError):
    pass


def load_switch():
    raw = SWITCH_PATH.read_bytes()
    if hashlib.sha256(raw).hexdigest().upper() != APPROVED_SWITCH_SHA256:
        raise Refused("Approved switch wrapper source changed")
    module = types.ModuleType("reskate_departure_switch")
    module.__file__ = str(SWITCH_PATH)
    sys.modules[module.__name__] = module
    try:
        exec(compile(raw, str(SWITCH_PATH), "exec"), module.__dict__)
    except BaseException:
        sys.modules.pop(module.__name__, None)
        raise
    return module


def timeline(h):
    E, S, N = h.Event, h.State, h.NEUTRAL
    events = (E(0, N), E(240, S(h.A, left_x=-.45)), E(1240, N),
              E(1440, S(h.B)), E(2440, N), E(2600, S(h.Y)),
              E(2800, N), E(4000, N))
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
    # Match baseline argparse abbreviations, so --exec cannot bypass the gate.
    selection = argparse.ArgumentParser(add_help=False)
    selection.add_argument("--execute", action="store_true")
    selection.add_argument("--start-gate")
    selection.add_argument("--start-nonce")
    selected, _ = selection.parse_known_args(args)
    if selected.execute and not (selected.start_gate and selected.start_nonce):
        raise Refused("Live departure requires a fresh --start-gate and --start-nonce")
    switch = load_switch()
    try:
        h = configure(switch)
    except switch.Refused as error:
        raise Refused(str(error)) from error
    try:
        # The baseline's fixed default names another scenario. Override it here;
        # explicit caller scenarios still face the single-scenario choices list.
        return h.main(["--scenario", SCENARIO, *args])
    except h.Refused as error:
        raise Refused(str(error)) from error


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Refused, OSError, ValueError, ImportError) as error:
        print(f"Departure leg refused: {error}")
        raise SystemExit(2)
