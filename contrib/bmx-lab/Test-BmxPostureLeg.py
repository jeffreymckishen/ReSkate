"""Fake-only posture contract checks; no game, Win32, real driver or HID."""
import builtins
import collections
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


w = module("posture_author_fake", ROOT / "contrib/bmx-lab/Bmx-PostureLeg.py")
f = module("posture_fake_helpers", ROOT / "contrib/bmx-lab/Test-BmxSwitchLeg.py")


class PostureTests(unittest.TestCase):
    def setUp(self):
        self.switch = w.load_switch()
        self.h = w.configure(self.switch)

    def fake_run(self, scenario, *, abort_at=None, fail_at=None, gate=None):
        h = self.h
        clock = h.PreviewClock()
        backend, sink = f.Backend(h, fail_at), f.Sink()
        guard = f.Guard(h, clock, abort_at)
        result = h.run(h.scenarios()[scenario], guard, lambda: backend, sink,
                       execute=True, clock=clock, start_gate=gate)
        return result, backend, guard, sink

    def test_source_pins_and_only_three_scenarios_with_straight_default(self):
        self.assertEqual(hashlib.sha256(w.SWITCH_PATH.read_bytes()).hexdigest().upper(),
                         w.APPROVED_SWITCH_SHA256)
        self.assertEqual(hashlib.sha256(self.switch.BASE_PATH.read_bytes()).hexdigest().upper(),
                         self.switch.APPROVED_BASE_SHA256)
        self.assertEqual(w.DEFAULT_SCENARIO, "ordinary-posture-straight")
        self.assertEqual(set(self.h.scenarios()),
                         {"ordinary-posture-straight", "ordinary-posture-left", "ordinary-posture-right"})
        # Returned dictionaries cannot add another action to a later selection.
        self.h.scenarios()["native-y"] = ()
        self.assertEqual(set(self.h.scenarios()), set(w.SCENARIOS))

    def test_fixed_schedule_control_exclusions_and_steering_release_before_brake(self):
        h = self.h
        for scenario, steer in zip(w.SCENARIOS, (0, -.4, .4)):
            with self.subTest(scenario=scenario):
                events = h.scenarios()[scenario]
                self.assertEqual(events, (h.Event(0, h.NEUTRAL),
                    h.Event(240, h.State(h.A, left_x=steer)),
                    h.Event(2240, h.State(h.B)), h.Event(3240, h.NEUTRAL),
                    h.Event(4000, h.NEUTRAL)))
                h.validate_timeline(events)
                for event in events:
                    self.assertEqual(event.state.buttons & ~(h.A | h.B), 0)
                    self.assertEqual(event.state.left_x, steer if event.at_ms == 240 else 0)
                    self.assertEqual(event.state, h.State(event.state.buttons,
                                                         left_x=event.state.left_x))
                self.assertEqual(events[2].state, h.State(h.B))

    def test_scheduler_201_reports_100_pedal_50_brake_51_neutral_each_case(self):
        h = self.h
        for scenario, steer in zip(w.SCENARIOS, (0, -.4, .4)):
            with self.subTest(scenario=scenario):
                result, backend, guard, sink = self.fake_run(scenario)
                self.assertTrue(result["completed"])
                self.assertEqual(result["driver_report_count"], 201)
                rows = [r for r in sink.rows if r["event"] == "controller_report"]
                self.assertEqual(collections.Counter(r["state"]["buttons"] for r in rows),
                                 {0: 51, h.A: 100, h.B: 50})
                self.assertEqual([r["planned_ms"] for r in rows], list(range(0, 4001, 20)))
                for button, start, stop in ((h.A, 240, 2240), (h.B, 2240, 3240)):
                    self.assertEqual([r["planned_ms"] for r in rows if r["state"]["buttons"] == button],
                                     list(range(start, stop, 20)))
                for row in rows:
                    state = row["state"]
                    self.assertEqual(state["left_x"], steer if state["buttons"] == h.A else 0)
                    self.assertTrue(all(value == 0 for key, value in state.items()
                                        if key not in ("buttons", "left_x")))
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
                self.assertEqual(backend.states[-1], h.NEUTRAL)
                self.assertEqual((backend.closed, guard.closed), (1, 1))
                self.assertIsNone(result["input_consumed"])
                self.assertIsNone(result["native_quality"])

    def test_original_guard_scheduler_bootstrap_identity_only_duration_tightened(self):
        switch = w.load_switch()
        raw = switch.load_driver()
        names = ("main", "run", "WindowsGuard", "bootstrap", "make_vgamepad", "validate_timeline")
        originals = {name: getattr(raw, name) for name in names}
        original_gate = raw.StartGate
        self.assertEqual(raw.MAX_DURATION_MS, 6000)
        with patch.object(switch, "load_driver", return_value=raw):
            h = w.configure(switch)
        for name, value in originals.items():
            self.assertIs(getattr(h, name), value)
        self.assertTrue(issubclass(h.StartGate, original_gate))
        self.assertEqual((h.MAX_LATE_MS, h.MAX_DURATION_MS, h.START_GATE_LIMIT_MS,
                          h.PERIOD_MS, h.POLL_MS), (120, 4000, 60000, 20, 10))

    def test_real_validator_rejects_beyond_four_seconds_and_nonfinite_axes(self):
        h = self.h
        events = h.scenarios()[w.DEFAULT_SCENARIO]
        with self.assertRaises(h.Refused):
            h.validate_timeline((*events[:-1], h.Event(4020, h.NEUTRAL)))
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(value=value), self.assertRaises(h.Refused):
                h.validate_timeline((h.Event(0, h.NEUTRAL),
                    h.Event(240, h.State(h.A, left_x=value)), h.Event(4000, h.NEUTRAL)))

    def test_two_second_neutral_preflight_before_ready_and_guard_loss_zero_scheduled(self):
        h = self.h
        original_gate = h.StartGate.__bases__[0]
        ready = []

        def original_wait(gate, guard, ledger, clock):
            guard.check()
            ready.append(clock.now())

        with patch.object(original_gate, "wait", original_wait):
            result, _, _, sink = self.fake_run(w.DEFAULT_SCENARIO,
                                             gate=object.__new__(h.StartGate))
        self.assertTrue(result["completed"])
        self.assertEqual(len(ready), 1)
        self.assertGreaterEqual(ready[0], 2)
        self.assertEqual(sum(row["event"] == "controller_switch_neutral_preflight"
                             for row in sink.rows), 1)
        with patch.object(original_gate, "wait", side_effect=AssertionError("ready after guard loss")):
            result, backend, _, _ = self.fake_run(w.DEFAULT_SCENARIO,
                abort_at=1, gate=object.__new__(h.StartGate))
        self.assertFalse(result["completed"])
        self.assertEqual(result["driver_report_count"], 0)
        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
        self.assertEqual(backend.states[-1], h.NEUTRAL)

    def test_live_gate_required_including_abbreviations_before_source_loading(self):
        cases = [[option] for option in ("--execute", "--exec", "--exe", "--e")]
        cases += [["--exec", "--start-gate", "fake"],
                  ["--execute", "--start-nonce", "a" * 32]]
        for args in cases:
            with self.subTest(args=args), patch.object(w, "load_switch",
                    side_effect=AssertionError("source loaded before gate")):
                with self.assertRaisesRegex(w.Refused, "requires a fresh"):
                    w.main(args)

    def test_invalid_scenarios_refused_before_source_loading(self):
        for option in ("--scenario", "--scen"):
            for scenario in ("native-y", "equipment-switch-observe", "ground-pump",
                             "ordinary-approach-right", "ordinary-walk-right", "unknown"):
                with self.subTest(option=option, scenario=scenario), \
                        patch.object(w, "load_switch", side_effect=AssertionError("loaded invalid scenario")), \
                        contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        w.main([option, scenario])
                    self.assertEqual(error.exception.code, 2)

    def test_abbreviated_selection_forwarded_and_default_inserted_once(self):
        h = self.h
        args = ["--exec", "--start-g", "fake", "--start-n", "a" * 32,
                "--scen", "ordinary-posture-left"]
        with patch.object(w, "configure", return_value=h), \
                patch.object(h, "main", return_value=19) as main:
            self.assertEqual(w.main(args), 19)
            main.assert_called_once_with(args)
        with patch.object(w, "configure", return_value=h), \
                patch.object(h, "main", return_value=0) as main:
            self.assertEqual(w.main([]), 0)
            main.assert_called_once_with(["--scenario", w.DEFAULT_SCENARIO])

    def test_outer_and_inner_source_changes_fail_before_unpinned_execution(self):
        with patch.object(Path, "read_bytes", return_value=b"raise RuntimeError('must not execute')"), \
                patch.object(w.types, "ModuleType", side_effect=AssertionError("allocated before pin")):
            with self.assertRaisesRegex(w.Refused, "source changed"):
                w.load_switch()
        original = Path.read_bytes

        def read(path):
            return b"raise RuntimeError('must not execute')" if path == self.switch.BASE_PATH else original(path)

        with patch.object(Path, "read_bytes", read):
            with self.assertRaisesRegex(w.Refused, "base source changed"):
                w.main([])

    def test_guard_or_driver_failure_cleanup_without_restarting_the_timeline(self):
        for options in ({"abort_at": .5}, {"abort_at": 2.6}, {"abort_at": 3.6}, {"fail_at": 65}):
            with self.subTest(options=options):
                result, backend, guard, sink = self.fake_run(w.DEFAULT_SCENARIO, **options)
                self.assertFalse(result["completed"])
                self.assertLess(result["driver_report_count"], 201)
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
                self.assertEqual(backend.states[-1], self.h.NEUTRAL)
                self.assertEqual((backend.closed, guard.closed), (1, 1))
                rows = [row for row in sink.rows if row["event"] == "controller_report"]
                planned = [row["planned_ms"] for row in rows]
                self.assertEqual(planned, list(range(0, 20 * len(planned), 20)))

    def test_owner_precedes_win32_backend_and_actual_all_case_dryruns_driver_free(self):
        h = self.h
        with patch.object(w, "configure", return_value=h), \
                patch.object(h, "WindowsGuard", side_effect=AssertionError("Win32 before owner")), \
                patch.object(h, "make_vgamepad", side_effect=AssertionError("backend before owner")), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                w.main(["--execute", "--start-gate", "fake", "--start-nonce", "a" * 32])
        self.assertEqual(error.exception.code, 2)
        real_import = builtins.__import__

        def no_driver(name, *args, **kwargs):
            if name == "vgamepad" or name.startswith("vgamepad."):
                raise AssertionError("dry-run imported controller")
            return real_import(name, *args, **kwargs)

        scratch = ROOT / "build/bmx"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="posture-fake-", dir=scratch) as temp, \
                patch("builtins.__import__", no_driver):
            for scenario in w.SCENARIOS:
                ledger = Path(temp) / (scenario + ".jsonl")
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(w.main(["--scenario", scenario, "--ledger", str(ledger)]), 0)
                rows = [json.loads(line) for line in ledger.read_text().splitlines()]
                reports = [row for row in rows if row["event"] == "controller_report"]
                self.assertEqual(len(reports), 201)
                self.assertTrue(all(row["driver_submitted"] is False for row in reports))
        self.assertFalse(any(name == "vgamepad" or name.startswith("vgamepad.") for name in sys.modules))


if __name__ == "__main__":
    unittest.main(verbosity=2)
