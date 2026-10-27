"""Fake-only approach contract checks. No game, Win32 guard, driver or HID."""
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


w = module("approach_author_fake", ROOT / "contrib/bmx-lab/Bmx-ApproachLeg.py")
f = module("approach_fake_helpers", ROOT / "contrib/bmx-lab/Test-BmxSwitchLeg.py")


class ApproachTests(unittest.TestCase):
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

    def test_two_source_pins_and_default_scenario(self):
        self.assertEqual(hashlib.sha256(w.SWITCH_PATH.read_bytes()).hexdigest().upper(),
                         w.APPROVED_SWITCH_SHA256)
        self.assertEqual(hashlib.sha256(self.switch.BASE_PATH.read_bytes()).hexdigest().upper(),
                         self.switch.APPROVED_BASE_SHA256)
        self.assertEqual(w.DEFAULT_SCENARIO, "ordinary-approach-left")
        self.assertEqual(set(self.h.scenarios()),
                         {"ordinary-approach-left", "ordinary-approach-straight", "ordinary-approach-right"})

    def test_exact_timeline_and_all_control_exclusions(self):
        h = self.h
        for scenario, steer in zip(w.SCENARIOS, (-.8, 0, .8)):
            with self.subTest(scenario=scenario):
                events = h.scenarios()[scenario]
                self.assertEqual(events, (h.Event(0, h.NEUTRAL),
                    h.Event(240, h.State(h.A, left_x=steer)),
                    h.Event(2240, h.NEUTRAL), h.Event(6000, h.NEUTRAL)))
                h.validate_timeline(events)
                self.assertTrue(all(e.state == h.NEUTRAL for e in events if e.at_ms != 240))
                self.assertEqual(events[1].state.buttons & (h.B | h.Y | h.LB | 0xF), 0)

    def test_scheduler_301_reports_exact_100_pedal_201_neutral_each_route(self):
        h = self.h
        for scenario, steer in zip(w.SCENARIOS, (-.8, 0, .8)):
            with self.subTest(scenario=scenario):
                result, backend, guard, sink = self.fake_run(scenario)
                self.assertTrue(result["completed"])
                self.assertEqual(result["driver_report_count"], 301)
                rows = [r for r in sink.rows if r["event"] == "controller_report"]
                self.assertEqual(collections.Counter(r["state"]["buttons"] for r in rows),
                                 {0: 201, h.A: 100})
                self.assertEqual([r["planned_ms"] for r in rows if r["state"]["buttons"]],
                                 list(range(240, 2240, 20)))
                for row in rows:
                    state = row["state"]
                    self.assertEqual(state["left_x"], steer if state["buttons"] == h.A else 0)
                    self.assertTrue(all(v == 0 for k, v in state.items()
                                        if k not in ("buttons", "left_x")))
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
                self.assertEqual(backend.states[-1], h.NEUTRAL)
                self.assertEqual((backend.closed, guard.closed), (1, 1))
                self.assertIsNone(result["input_consumed"])
                self.assertIsNone(result["native_quality"])

    def test_guard_scheduler_bootstrap_and_limits_are_unmodified_base_objects(self):
        switch = w.load_switch()
        raw = switch.load_driver()
        names = ("main", "run", "WindowsGuard", "bootstrap", "make_vgamepad", "validate_timeline")
        originals = {name: getattr(raw, name) for name in names}
        gate = raw.StartGate
        with patch.object(switch, "load_driver", return_value=raw):
            h = w.configure(switch)
        for name, value in originals.items():
            self.assertIs(getattr(h, name), value)
        self.assertTrue(issubclass(h.StartGate, gate))
        self.assertEqual((h.MAX_LATE_MS, h.MAX_DURATION_MS, h.START_GATE_LIMIT_MS,
                          h.PERIOD_MS, h.POLL_MS), (120, 6000, 60000, 20, 10))

    def test_real_neutral_discovery_gate_precedes_ready_and_remains_guarded(self):
        h = self.h
        base_gate = h.StartGate.__bases__[0]
        ready = []
        def original_wait(gate, guard, ledger, clock):
            guard.check()
            ready.append(clock.now())
        with patch.object(base_gate, "wait", original_wait):
            result, _, _, sink = self.fake_run(w.DEFAULT_SCENARIO,
                                             gate=f.nonlead_gate(h, w.DEFAULT_SCENARIO))
        self.assertTrue(result["completed"])
        self.assertEqual(len(ready), 1)
        self.assertGreaterEqual(ready[0], 2)
        self.assertEqual(sum(r["event"] == "controller_switch_neutral_preflight"
                             for r in sink.rows), 1)
        with patch.object(base_gate, "wait", side_effect=AssertionError("ready after guard loss")):
            result, backend, _, sink = self.fake_run(w.DEFAULT_SCENARIO,
                abort_at=1.0, gate=f.nonlead_gate(h, w.DEFAULT_SCENARIO))
        self.assertFalse(result["completed"])
        self.assertEqual(result["driver_report_count"], 0)
        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
        self.assertEqual(backend.states[-1], h.NEUTRAL)

    def test_live_gate_required_including_argparse_abbreviations_before_loading(self):
        cases = [[option] for option in ("--execute", "--exec", "--exe", "--e")]
        cases += [["--exec", "--start-gate", "fake"],
                  ["--execute", "--start-nonce", "a" * 32]]
        for args in cases:
            with self.subTest(args=args), patch.object(w, "load_switch",
                    side_effect=AssertionError("source loaded before gate")):
                with self.assertRaisesRegex(w.Refused, "requires a fresh"):
                    w.main(args)

    def test_only_three_cli_choices_and_rejections_precede_source_loading(self):
        for option in ("--scenario", "--scen"):
            for scenario in ("native-y", "equipment-switch-observe", "ground-pump",
                             "ordinary-departure-left-park", "unknown"):
                with self.subTest(option=option, scenario=scenario), \
                        patch.object(w, "load_switch", side_effect=AssertionError("loaded invalid scenario")), \
                        contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        w.main([option, scenario])
                    self.assertEqual(error.exception.code, 2)

    def test_abbreviated_selection_is_forwarded_and_default_is_inserted_once(self):
        h = self.h
        args = ["--exec", "--start-g", "fake", "--start-n", "a" * 32,
                "--scen", "ordinary-approach-straight"]
        with patch.object(w, "configure", return_value=h), \
                patch.object(h, "main", return_value=19) as main:
            self.assertEqual(w.main(args), 19)
            main.assert_called_once_with(args)
        with patch.object(w, "configure", return_value=h), \
                patch.object(h, "main", return_value=0) as main:
            self.assertEqual(w.main([]), 0)
            main.assert_called_once_with(["--scenario", w.DEFAULT_SCENARIO])

    def test_outer_pin_rejected_before_exec_and_inner_pin_propagates_refusal(self):
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

    def test_guard_and_driver_failures_cleanup_no_rescheduled_pedal(self):
        for options in ({"abort_at": 1}, {"abort_at": 3}, {"fail_at": 60}):
            with self.subTest(options=options):
                result, backend, guard, sink = self.fake_run(w.DEFAULT_SCENARIO, **options)
                self.assertFalse(result["completed"])
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
                self.assertEqual(backend.states[-1], self.h.NEUTRAL)
                self.assertEqual((backend.closed, guard.closed), (1, 1))

    def test_exact_owner_required_before_win32_or_backend_and_dryrun_driver_free(self):
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
        with tempfile.TemporaryDirectory(prefix="approach-fake-", dir=scratch) as temp, \
                patch("builtins.__import__", no_driver):
            for scenario in w.SCENARIOS:
                ledger = Path(temp) / (scenario + ".jsonl")
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(w.main(["--scenario", scenario, "--ledger", str(ledger)]), 0)
                rows = [json.loads(line) for line in ledger.read_text().splitlines()]
                reports = [r for r in rows if r["event"] == "controller_report"]
                self.assertEqual(len(reports), 301)
                self.assertTrue(all(r["driver_submitted"] is False for r in reports))
        self.assertFalse(any(n == "vgamepad" or n.startswith("vgamepad.") for n in sys.modules))


if __name__ == "__main__":
    unittest.main(verbosity=2)
