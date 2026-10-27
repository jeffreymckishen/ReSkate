"""Fake-only recovery candidate tests; no game, Win32 guard or HID calls."""
import builtins
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "bmx_recovery_leg", Path(__file__).with_name("Bmx-RecoveryLeg.py"))
w = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = w
SPEC.loader.exec_module(w)


class Sink:
    def __init__(self): self.rows = []
    def write(self, event, **fields): self.rows.append(dict(event=event, **fields))


class Backend:
    def __init__(self, h, fail_at=None):
        self.h, self.states, self.closed, self.fail_at = h, [], 0, fail_at
    def prime_lsb(self): self.send(self.h.State(left_x=1 / 32767))
    def send(self, state):
        self.states.append(state)
        if len(self.states) == self.fail_at: raise OSError("fake driver failure")
    def raw_report_hex(self):
        s = self.states[-1]
        return struct.pack("<HBBhhhh", s.buttons, round(s.left_trigger * 255),
                           round(s.right_trigger * 255), round(s.left_x * 32767),
                           round(s.left_y * 32767), round(s.right_x * 32767),
                           round(s.right_y * 32767)).hex()
    def readback(self):
        return dict(available=True, slot=0, neutral=True, raw_report_hex="00" * 12)
    def close(self): self.closed += 1


class Guard:
    def __init__(self, h, clock, abort_at=None):
        self.h, self.clock, self.abort_at, self.closed = h, clock, abort_at, 0
    def check(self):
        if self.abort_at is not None and self.clock.now() >= self.abort_at:
            raise self.h.Refused("fake focus loss")
    def close(self): self.closed += 1


def nonlead_gate(h, scenario):
    # Skip filesystem setup only when the base wait is patched; retain gate validation.
    gate = object.__new__(h.StartGate)
    gate.scenario, gate.lead_ms = scenario, None
    gate._lead_configuration = gate._ready_configuration = None
    return gate


class RecoveryLegTests(unittest.TestCase):
    def setUp(self): self.h = w.load_driver()

    def configured(self): return w.configure(self.h)

    def test_two_source_pins_and_deferred_controller_import(self):
        self.assertEqual(hashlib.sha256(w.SWITCH_PATH.read_bytes()).hexdigest().upper(),
                         w.SWITCH_SHA256)
        switch = sys.modules["reskate_recovery_switch_base"]
        self.assertEqual(hashlib.sha256(switch.BASE_PATH.read_bytes()).hexdigest().upper(),
                         switch.APPROVED_BASE_SHA256)
        self.assertEqual(self.h.WORKSPACE, w.ROOT)
        self.assertFalse(any(n == "vgamepad" or n.startswith("vgamepad.") for n in sys.modules))

    def test_switch_pin_failure_precedes_module_execution(self):
        with patch.object(Path, "read_bytes", return_value=b"raise RuntimeError('never execute')"), \
                patch.object(w.types, "ModuleType", side_effect=AssertionError("allocated before pin")):
            with self.assertRaisesRegex(w.Refused, "wrapper changed"):
                w.load_driver()

    def test_inner_base_pin_failure_is_a_recovery_refusal_and_drops_outer_module(self):
        original = Path.read_bytes
        switch = sys.modules["reskate_recovery_switch_base"]
        def read(path):
            if path == switch.BASE_PATH: return b"raise RuntimeError('never execute')"
            return original(path)
        with patch.object(Path, "read_bytes", read):
            with self.assertRaisesRegex(w.Refused, "base source changed"):
                w.load_driver()
        self.assertNotIn("reskate_recovery_switch_base", sys.modules)

    def test_configuration_preserves_guard_scheduler_cleanup_and_limits(self):
        h = self.h
        before = h.scenarios()
        names = ("main", "run", "StartGate", "WindowsGuard", "bootstrap", "make_vgamepad", "validate_timeline")
        original = {name: getattr(h, name) for name in names}
        w.configure(h)
        for name, value in original.items(): self.assertIs(getattr(h, name), value)
        self.assertEqual((h.MAX_LATE_MS, h.MAX_DURATION_MS, h.PERIOD_MS,
                          h.POLL_MS, h.START_GATE_LIMIT_MS), (120, 6000, 20, 10, 60000))
        expected = {f"native-{button}-recovery-candidate" for button in ("south", "east", "north")}
        self.assertEqual(set(h.scenarios()) - set(before), expected)
        for name, events in before.items(): self.assertEqual(h.scenarios()[name], events)

    def test_exact_three_fixed_200ms_pulses_and_no_dpad_axes_or_chords(self):
        h = self.configured()
        for name, button in (("south", h.A), ("east", h.B), ("north", h.Y)):
            with self.subTest(candidate=name):
                events = h.scenarios()[f"native-{name}-recovery-candidate"]
                self.assertEqual(events, (h.Event(0, h.NEUTRAL), h.Event(240, h.State(button)),
                                          h.Event(440, h.NEUTRAL), h.Event(6000, h.NEUTRAL)))
                h.validate_timeline(events)
                for event in events:
                    self.assertEqual(event.state, h.State(event.state.buttons))
                    self.assertEqual(event.state.buttons & 0x000F, 0)
                    self.assertIn(event.state.buttons, (0, button))
                for unsupported in (1, 2, 4, 8, 0x10, 0x20):
                    invalid = (h.Event(0, h.NEUTRAL), h.Event(240, h.State(unsupported)), h.Event(6000, h.NEUTRAL))
                    with self.assertRaises(h.Refused): h.validate_timeline(invalid)

    def test_cli_whitelist_rejects_base_and_unknown_scenarios_before_loading(self):
        for name in ("native-y", "equipment-switch-observe", "equipment-switch",
                     "ground-pump", "bunnyhop-tailwhip", "unknown", "native-west-recovery-candidate"):
            for option in ("--scenario", "--scen"):
                with self.subTest(scenario=name, option=option), \
                        patch.object(w, "load_driver", side_effect=AssertionError("loaded rejected scenario")), \
                        contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        w.main([option, name])
                    self.assertEqual(error.exception.code, 2)

    def test_live_gate_required_even_with_argparse_abbreviations(self):
        cases = [[option] for option in ("--execute", "--exec", "--exe", "--execut", "--e")]
        cases += [["--execute", "--start-gate=fake"],
                  ["--exec", "--start-nonce=" + "a" * 32],
                  ["--exe", "--start-gate=", "--start-nonce=" + "a" * 32]]
        for args in cases:
            with self.subTest(args=args), \
                    patch.object(w, "load_driver", side_effect=AssertionError("loaded before required gate")):
                with self.assertRaisesRegex(w.Refused, "requires a fresh ready/GO gate"):
                    w.main(args)

    def test_abbreviated_valid_selection_is_forwarded_without_inserting_default(self):
        h = self.h
        args = ["--exec", "--start-g", "fake", "--start-n", "a" * 32,
                "--scen", "native-east-recovery-candidate"]
        with patch.object(w, "load_driver", return_value=h), patch.object(h, "main", return_value=19) as main:
            self.assertEqual(w.main(args), 19)
        main.assert_called_once_with(args)

    def test_exact_owner_remains_required_before_live_backend(self):
        h = self.h
        with patch.object(w, "load_driver", return_value=h), \
                patch.object(h, "make_vgamepad", side_effect=AssertionError("backend before owner")), \
                patch.object(h, "WindowsGuard", side_effect=AssertionError("guard before owner")), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                w.main(["--execute", "--start-gate", "fake", "--start-nonce", "a" * 32])
        self.assertEqual(error.exception.code, 2)

    def fake_run(self, events, *, clock=None, abort_at=None, fail_at=None, gate=None):
        h = self.h
        clock = clock or h.PreviewClock()
        backend, sink = Backend(h, fail_at), Sink()
        guard = Guard(h, clock, abort_at)
        result = h.run(events, guard, lambda: backend, sink,
                       execute=True, clock=clock, start_gate=gate)
        return result, backend, guard, sink

    def test_scheduler_pulse_edges_neutral_tail_and_cleanup_for_every_candidate(self):
        h = self.configured()
        for candidate, button in (("south", h.A), ("east", h.B), ("north", h.Y)):
            with self.subTest(candidate=candidate):
                events = h.scenarios()[f"native-{candidate}-recovery-candidate"]
                result, backend, guard, sink = self.fake_run(events)
                self.assertTrue(result["completed"])
                self.assertEqual(result["driver_report_count"], 301)
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
                self.assertEqual((backend.closed, guard.closed), (1, 1))
                self.assertEqual(backend.states[-1], h.NEUTRAL)
                reports = [r for r in sink.rows if r["event"] == "controller_report"]
                self.assertEqual([r["planned_ms"] for r in reports if r["state"]["buttons"]], list(range(240, 440, 20)))
                self.assertEqual({r["state"]["buttons"] for r in reports}, {0, button})
                for row in reports:
                    self.assertTrue(all(value == 0 for name, value in row["state"].items() if name != "buttons"))
                self.assertTrue(all(r["state"]["buttons"] == 0 for r in reports if r["planned_ms"] >= 440))
                self.assertIsNone(result["input_consumed"])
                self.assertIsNone(result["native_quality"])

    def test_inherited_gate_waits_two_neutral_seconds_before_ready(self):
        h = self.configured()
        clock, calls = h.PreviewClock(), []
        base_gate = h.StartGate.__bases__[0]
        def original_wait(gate, guard, ledger, current):
            guard.check()
            calls.append(current.now())
            ledger.write("fake_original_ready")
        with patch.object(base_gate, "wait", original_wait):
            result, backend, _, sink = self.fake_run(h.scenarios()[w.DEFAULT_SCENARIO],
                clock=clock, gate=nonlead_gate(h, w.DEFAULT_SCENARIO))
        self.assertTrue(result["completed"])
        self.assertEqual(len(calls), 1)
        self.assertGreaterEqual(calls[0], 2)
        preflight = next(r for r in sink.rows if r["event"] == "controller_switch_neutral_preflight")
        self.assertGreaterEqual(preflight["elapsed_ms"], 2000)
        self.assertFalse(preflight["sdk_discovery_verified"])
        self.assertEqual(sum(r["event"] == "controller_backend_ready" for r in sink.rows), 1)
        self.assertEqual(backend.closed, 1)
        self.assertLess(next(i for i, r in enumerate(sink.rows) if r["event"] == "controller_switch_neutral_preflight"),
                        next(i for i, r in enumerate(sink.rows) if r["event"] == "fake_original_ready"))

    def test_focus_loss_during_discovery_has_no_pulse_and_cleans_up(self):
        h = self.configured()
        base_gate = h.StartGate.__bases__[0]
        with patch.object(base_gate, "wait", side_effect=AssertionError("ready before preflight")):
            result, backend, guard, _ = self.fake_run(h.scenarios()[w.DEFAULT_SCENARIO],
                abort_at=1, gate=nonlead_gate(h, w.DEFAULT_SCENARIO))
        self.assertFalse(result["completed"])
        self.assertEqual(result["driver_report_count"], 0)
        self.assertTrue(all(s.buttons == 0 for s in backend.states))
        self.assertEqual(backend.states[-1], h.NEUTRAL)
        self.assertEqual((backend.closed, guard.closed), (1, 1))

    def test_pulse_focus_loss_or_driver_failure_still_releases_and_disconnects(self):
        h = self.configured()
        for options in ({"abort_at": .35}, {"fail_at": 17}):
            with self.subTest(options=options):
                result, backend, guard, _ = self.fake_run(h.scenarios()[w.DEFAULT_SCENARIO], **options)
                self.assertFalse(result["completed"])
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
                self.assertEqual(backend.states[-1], h.NEUTRAL)
                self.assertEqual((backend.closed, guard.closed), (1, 1))

    def test_120ms_late_report_still_aborts_and_neutralizes(self):
        h = self.configured()
        class LateClock(h.PreviewClock):
            def sleep(self, seconds): self.value += seconds + (.2 if self.value >= .3 else 0)
        result, backend, _, _ = self.fake_run(h.scenarios()[w.DEFAULT_SCENARIO], clock=LateClock())
        self.assertFalse(result["completed"])
        self.assertIn("120ms", result["issue"])
        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
        self.assertEqual(backend.states[-1], h.NEUTRAL)

    def test_default_dryrun_is_driver_free_and_does_not_claim_recovery(self):
        h = self.h
        original_import, controller_imports = builtins.__import__, []
        def checked_import(name, *args, **kwargs):
            if name == "vgamepad" or name.startswith("vgamepad."):
                controller_imports.append(name)
                raise AssertionError("controller import during preview")
            return original_import(name, *args, **kwargs)
        with tempfile.TemporaryDirectory(prefix="recovery-leg-test-", dir=w.ROOT / "build/bmx") as folder:
            ledger = Path(folder) / "dry.jsonl"
            with patch.object(w, "load_driver", return_value=h), \
                    patch.object(h, "WindowsGuard", side_effect=AssertionError("live guard during preview")), \
                    patch.object(h, "make_vgamepad", side_effect=AssertionError("live backend during preview")), \
                    patch.object(builtins, "__import__", checked_import), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(w.main(["--ledger", str(ledger)]), 0)
            rows = [json.loads(line) for line in ledger.read_text().splitlines()]
        self.assertEqual(controller_imports, [])
        self.assertEqual(rows[0]["scenario"], w.DEFAULT_SCENARIO)
        self.assertFalse(rows[0]["execute"])
        self.assertTrue(rows[0]["timing_simulated"])
        switch = sys.modules["reskate_recovery_switch_base"]
        self.assertEqual(rows[0]["source_sha256"], switch.APPROVED_BASE_SHA256)
        self.assertEqual(rows[-1]["report_count"], 301)
        self.assertEqual(rows[-1]["driver_report_count"], 0)
        self.assertTrue(rows[-1]["completed"])
        self.assertIsNone(rows[-1]["input_consumed"])
        self.assertIsNone(rows[-1]["native_quality"])


if __name__ == "__main__":
    unittest.main()
