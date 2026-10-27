"""One fixed ordinary BMX posture input; default is a driver-free dry-run.

Choose straight, left or right only after viewing the mounted rider, heading
and clear route. All schedule neutral at 0ms, A at 240..2240ms, B alone at
2240..3240ms, then neutral through 4000ms. Left/right use LS X=-.4/+.4 during
A only; straight and every other axis/trigger stay zero. No Y, LB, hop, D-pad,
menu input, conditional follow-up or automatic retry is scheduled.

The four-second timeline cap is stricter than the pinned base's six seconds.
The exact pinned SwitchLeg retains its additional two-second guarded neutral
preflight. Its pinned base supplies owner/runtime/foreground/Escape checks,
bootstrap, nonce-bound ready/GO, unchanged 120ms lateness and 60s gate bounds,
final neutral and disconnect. This wrapper does not launch, focus, capture,
install dependencies, inspect the game or change physics/pose configuration.

These are input requests for an independently selected private posture test.
Native observations and footage must establish movement, braking, repair
activation, contacts and visual quality; scheduled reports prove none of them.
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
DEFAULT_SCENARIO = "ordinary-posture-straight"
SCENARIOS = (DEFAULT_SCENARIO, "ordinary-posture-left", "ordinary-posture-right")


class Refused(RuntimeError):
    pass


def load_switch():
    raw = SWITCH_PATH.read_bytes()
    if hashlib.sha256(raw).hexdigest().upper() != APPROVED_SWITCH_SHA256:
        raise Refused("Approved switch wrapper source changed")
    module = types.ModuleType("reskate_posture_switch")
    module.__file__ = str(SWITCH_PATH)
    sys.modules[module.__name__] = module
    try:
        exec(compile(raw, str(SWITCH_PATH), "exec"), module.__dict__)
    except BaseException:
        sys.modules.pop(module.__name__, None)
        raise
    return module


def timelines(h):
    result = {}
    for name, left_x in zip(SCENARIOS, (0, -.4, .4)):
        events = (h.Event(0, h.NEUTRAL),
                  h.Event(240, h.State(h.A, left_x=left_x)),
                  h.Event(2240, h.State(h.B)),
                  h.Event(3240, h.NEUTRAL), h.Event(4000, h.NEUTRAL))
        h.validate_timeline(events)
        result[name] = events
    return result


def configure(switch):
    h = switch.configure(switch.load_driver())
    h.MAX_DURATION_MS = 4000
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
        raise Refused("Live posture requires a fresh --start-gate and --start-nonce")
    if selected.scenario is None:
        args = ["--scenario", DEFAULT_SCENARIO, *args]
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
        print(f"Posture leg refused: {error}")
        raise SystemExit(2)
