"""One bounded candidate recovery-button pulse through the installed controller.

Default is a dry-run. This requests game-facing input, never a native GetUp intent.
The action mapping and native recovery outcome must be measured separately.
Live runs require the exact isolated game owner and a fresh neutral ready/GO gate.
The pinned switch wrapper supplies its guarded two-second controller-discovery
wait; its pinned base supplies owner/focus/Escape/dependency checks, the 120ms
report deadline, and final neutral/disconnect. No game launch or camera action.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys
import types

ROOT = Path(__file__).resolve().parents[2]
SWITCH_PATH = ROOT / "contrib/bmx-lab/Bmx-SwitchLeg.py"
SWITCH_SHA256 = "B970050F32BA2595C083B1A3598BB6E163EEECAC2821CC4506ECCBB617320E11"
DEFAULT_SCENARIO = "native-south-recovery-candidate"


class Refused(RuntimeError):
    pass


def load_driver():
    raw = SWITCH_PATH.read_bytes()
    if hashlib.sha256(raw).hexdigest().upper() != SWITCH_SHA256:
        raise Refused("Approved neutral-gate wrapper changed")
    module = types.ModuleType("reskate_recovery_switch_base")
    module.__file__ = str(SWITCH_PATH)
    sys.modules[module.__name__] = module
    try:
        exec(compile(raw, str(SWITCH_PATH), "exec"), module.__dict__)
        return module.configure(module.load_driver())
    except BaseException as error:
        sys.modules.pop(module.__name__, None)
        if isinstance(error, getattr(module, "Refused", Refused)):
            raise Refused(str(error)) from error
        raise


def configure(h):
    original = h.scenarios
    candidates = {}
    for name, button in (("south", h.A), ("east", h.B), ("north", h.Y)):
        events = (h.Event(0, h.NEUTRAL), h.Event(240, h.State(button)),
                  h.Event(440, h.NEUTRAL), h.Event(6000, h.NEUTRAL))
        h.validate_timeline(events)
        candidates[f"native-{name}-recovery-candidate"] = events
    h.scenarios = lambda: {**original(), **candidates}
    h.__doc__ = __doc__
    return h


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    selection = argparse.ArgumentParser(add_help=False)
    selection.add_argument("--execute", action="store_true")
    selection.add_argument("--start-gate")
    selection.add_argument("--start-nonce")
    selection.add_argument("--scenario", choices=[
        f"native-{name}-recovery-candidate" for name in ("south", "east", "north")])
    selected, _ = selection.parse_known_args(args)
    if selected.execute and not (selected.start_gate and selected.start_nonce):
        raise Refused("Live recovery candidate requires a fresh ready/GO gate")
    if selected.scenario is None:
        args = ["--scenario", DEFAULT_SCENARIO, *args]
    h = configure(load_driver())
    try:
        return h.main(args)
    except h.Refused as error:
        raise Refused(str(error)) from error


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Refused, OSError, ValueError, ImportError) as error:
        print(f"Recovery candidate refused: {error}")
        raise SystemExit(2)
