"""Single LB+Y equipment switch; default is a fast dry-run.

The exact hash-pinned Bmx-VirtualGamepad.py supplies main, WindowsGuard,
bootstrap, the 120ms scheduler limit and final neutral/disconnect. This wrapper
adds only equipment-switch-observe: neutral0, LB240, LB+Y320, LB520, neutral600,
neutral6000. It never schedules a return chord or guesses native completion.

Live preparation: use the isolated HumanNativeSwitch Ride, stopped on clear
ground in the independently verified equipment state. --execute requires a
fresh exact owner receipt AND --start-gate/--start-nonce. After bootstrap, the
same backend remains connected with its last verified neutral report for at
least two guarded seconds BEFORE ready.json is published. This allows SDK
discovery/edge arming but is not a measured SDK-ready witness. The outer guard
includes this preflight in the unchanged 60s ready/GO budget; ordinary base
gate nonce/file/owner checks still control GO. Console closure remains external.

Observe the native terminal receipt and continuous footage before separately
requesting the reverse leg. Scheduled reports do not prove switch completion,
alignment, fall recovery, physical-controller acceptance or handling quality.
The base ledger records its approved base hash and exact timeline; archive this
wrapper's hash separately for full provenance. No game launch, capture, focus
change, native selector write, dependency installation or implicit input occurs.

Examples (repository root):
  python -B contrib/bmx-lab/Bmx-SwitchLeg.py
  build/bmx-gamepad-runtime/Scripts/python.exe -B contrib/bmx-lab/Bmx-SwitchLeg.py --execute --owner <fresh-owner.json> --ledger <fresh-ledger.jsonl> --start-gate <fresh-directory> --start-nonce <32hex>
"""
from __future__ import annotations

import argparse
import hashlib
import math
from pathlib import Path
import sys
import types

ROOT = Path(__file__).resolve().parents[2]
BASE_PATH = ROOT / "contrib/bmx-lab/Bmx-VirtualGamepad.py"
APPROVED_BASE_SHA256 = "2964E18026D92EBD2239E0B938D25FACE48A792F2F14C18C43EF094BE3A2AFFE"
SCENARIO = "equipment-switch-observe"
NEUTRAL_PREFLIGHT_MS = 2000


class Refused(RuntimeError):
    pass


def load_driver():
    # Compile the same bytes that were checked; no second unchecked import or
    # bytecode cache write. The base defers vgamepad import until live guards pass.
    raw = BASE_PATH.read_bytes()
    if hashlib.sha256(raw).hexdigest().upper() != APPROVED_BASE_SHA256:
        raise Refused("Approved virtual-controller base source changed")
    module = types.ModuleType("reskate_switch_leg_base")
    module.__file__ = str(BASE_PATH)
    sys.modules[module.__name__] = module
    try:
        exec(compile(raw, str(BASE_PATH), "exec"), module.__dict__)
    except BaseException:
        sys.modules.pop(module.__name__, None)
        raise
    return module


def timeline(h):
    E, S, N = h.Event, h.State, h.NEUTRAL
    events = (E(0, N), E(240, S(h.LB)), E(320, S(h.LB | h.Y)),
              E(520, S(h.LB)), E(600, N), E(6000, N))
    h.validate_timeline(events)
    return events


def configure(h):
    original_scenarios, original_gate = h.scenarios, h.StartGate
    added = timeline(h)

    def with_switch_leg():
        return {**original_scenarios(), SCENARIO: added}

    class NeutralDiscoveryGate(original_gate):
        def wait(self, guard, ledger, clock):
            begun, last = clock.now(), None
            if not math.isfinite(begun):
                raise h.Refused("Neutral preflight clock is not finite")

            class TotalBudgetGuard:
                def check(self):
                    nonlocal last
                    guard.check()
                    now = clock.now()
                    if (not math.isfinite(now) or now < begun or
                            (last is not None and now < last) or
                            (now - begun) * 1000 >= h.START_GATE_LIMIT_MS):
                        raise h.Refused("Neutral preflight/start-gate total deadline or clock failed")
                    last = now

            bounded = TotalBudgetGuard()
            while True:
                bounded.check()
                remaining = NEUTRAL_PREFLIGHT_MS / 1000 - (clock.now() - begun)
                if remaining <= 0:
                    break
                clock.sleep(min(h.POLL_MS / 1000, remaining))
            ledger.write("controller_switch_neutral_preflight", required_ms=NEUTRAL_PREFLIGHT_MS,
                         elapsed_ms=(clock.now() - begun) * 1000,
                         sdk_discovery_verified=False,
                         boundary="Existing bootstrapped backend stays connected/neutral; no native readiness proof")
            # The original gate publishes ready only now. Its full ready/GO
            # implementation stays intact; bounded also retains the TOTAL60s cap.
            return super().wait(bounded, ledger, clock)

    h.scenarios = with_switch_leg
    h.StartGate = NeutralDiscoveryGate
    h.__doc__ = __doc__
    return h


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    present = lambda option: any(arg == option or arg.startswith(option + "=") for arg in args)
    # Match the base argparse abbreviation semantics too; --exec must not
    # accidentally evade the required live neutral gate.
    selection = argparse.ArgumentParser(add_help=False)
    selection.add_argument("--execute", action="store_true")
    selection.add_argument("--start-gate")
    selection.add_argument("--start-nonce")
    selected, _ = selection.parse_known_args(args)
    if selected.execute and not (selected.start_gate and selected.start_nonce):
        raise Refused("Live switch leg requires a fresh --start-gate and --start-nonce")
    if not present("--scenario"):
        args = ["--scenario", SCENARIO, *args]
    h = configure(load_driver())
    try:
        return h.main(args)
    except h.Refused as error:
        raise Refused(str(error)) from error


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Refused, OSError, ValueError, ImportError) as error:
        print(f"Switch leg refused: {error}")
        raise SystemExit(2)
