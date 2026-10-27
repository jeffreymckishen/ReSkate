"""Independent fake-only posture-capture admission, scheduler and cleanup checks.

No game, Win32 process API, real controller, or native quality assertion.
"""
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


w = module("posture_capture_independent", ROOT / "contrib/bmx-lab/Bmx-PostureCaptureLeg.py")
f = module("posture_capture_fake_helpers", ROOT / "contrib/bmx-lab/Test-BmxSwitchLeg.py")


class PostureCaptureTests(unittest.TestCase):
    def setUp(self):
        self.posture = w.load_posture()
        self.h = w.configure(self.posture)
        self.scratch = ROOT / "build/bmx"
        self.scratch.mkdir(parents=True, exist_ok=True)

    def fake_run(self, scenario=None, *, clock=None, guard=None, fail_at=None, gate=None, sink=None):
        h = self.h
        clock = clock or h.PreviewClock()
        guard = guard or f.Guard(h, clock)
        backend = f.Backend(h, fail_at)
        sink = sink or f.Sink()
        result = h.run(h.scenarios()[scenario or w.DEFAULT_SCENARIO], guard,
                       lambda: backend, sink, execute=True, clock=clock, start_gate=gate)
        return result, backend, guard, sink

    def assert_clean(self, result, backend, guard):
        self.assertTrue(result["neutral_release_succeeded"])
        self.assertTrue(result["disconnect_succeeded"])
        self.assertEqual(backend.states[-1], self.h.NEUTRAL)
        self.assertEqual((backend.closed, guard.closed), (1, 1))
        self.assertIsNone(result["input_consumed"])
        self.assertIsNone(result["native_quality"])

    def test_exact_three_source_pins_two_scenarios_and_inherited_guard_identity(self):
        posture = w.load_posture()
        switch = posture.load_switch()
        raw = switch.load_driver()
        for path, expected in ((w.POSTURE_PATH, w.APPROVED_POSTURE_SHA256),
                               (posture.SWITCH_PATH, posture.APPROVED_SWITCH_SHA256),
                               (switch.BASE_PATH, switch.APPROVED_BASE_SHA256)):
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest().upper(), expected)
        names = ("main", "run", "WindowsGuard", "bootstrap", "make_vgamepad", "validate_timeline")
        originals = {name: getattr(raw, name) for name in names}
        original_gate = raw.StartGate
        with patch.object(posture, "load_switch", return_value=switch), \
                patch.object(switch, "load_driver", return_value=raw):
            h = w.configure(posture)
        for name, function in originals.items():
            self.assertIs(getattr(h, name), function)
        self.assertTrue(issubclass(h.StartGate, original_gate))
        self.assertEqual((h.MAX_DURATION_MS, h.MAX_LATE_MS, h.START_GATE_LIMIT_MS,
                          h.PERIOD_MS, h.POLL_MS), (4000, 120, 60000, 20, 10))
        self.assertEqual(tuple(h.scenarios()),
                         ("ordinary-posture-capture-left", "ordinary-posture-capture-right"))
        self.assertEqual(w.DEFAULT_SCENARIO, "ordinary-posture-capture-left")
        with self.assertRaises(h.Refused):
            h.validate_timeline((h.Event(0, h.NEUTRAL), h.Event(4020, h.NEUTRAL)))

    def test_actual_scheduler_boundaries_201_reports_ten_y_and_all_excluded_controls(self):
        h = self.h
        for scenario, steer in zip(w.SCENARIOS, (-1, 1)):
            with self.subTest(scenario=scenario):
                result, backend, guard, sink = self.fake_run(scenario)
                self.assertTrue(result["completed"])
                self.assertEqual(result["driver_report_count"], 201)
                rows = [r for r in sink.rows if r["event"] == "controller_report"]
                self.assertEqual([r["planned_ms"] for r in rows], list(range(0, 4001, 20)))
                self.assertEqual(collections.Counter(r["state"]["buttons"] for r in rows),
                                 {0: 41, h.A: 50, h.B: 100, h.Y: 10})
                expected_y = list(range(3240, 3440, 20))
                self.assertEqual([r["planned_ms"] for r in rows if r["state"]["buttons"] == h.Y], expected_y)
                for row in rows:
                    at, state = row["planned_ms"], row["state"]
                    buttons = h.B if 240 <= at < 1240 or 2240 <= at < 3240 else (
                        h.A if 1240 <= at < 2240 else h.Y if 3240 <= at < 3440 else 0)
                    self.assertEqual(state["buttons"], buttons)
                    self.assertEqual(state["left_x"], steer if 240 <= at < 2240 else 0)
                    self.assertEqual(state["buttons"] & (h.LB | 0x0200 | 0x000F), 0)
                    self.assertTrue(all(value == 0 for name, value in state.items()
                                        if name not in ("buttons", "left_x")))
                self.assertEqual(rows[172]["planned_ms"], 3440)
                self.assertEqual(rows[172]["state"], h.asdict(h.NEUTRAL))
                self.assert_clean(result, backend, guard)

    def test_guard_loss_during_y_and_backend_failure_release_without_retry(self):
        h = self.h
        for options in ({"abort": 1.0}, {"abort": 3.4}, {"fail_at": 45}, {"fail_at": 170}):
            with self.subTest(options=options):
                clock = h.PreviewClock()
                guard = f.Guard(h, clock, options.get("abort"))
                result, backend, guard, sink = self.fake_run(
                    clock=clock, guard=guard, fail_at=options.get("fail_at"))
                self.assertFalse(result["completed"])
                self.assertLess(result["driver_report_count"], 201)
                self.assert_clean(result, backend, guard)
                reports = [r for r in sink.rows if r["event"] == "controller_report"]
                self.assertLessEqual(sum(r["state"]["buttons"] == h.Y for r in reports), 10)
                self.assertEqual(sum(r["event"] == "controller_session_end" for r in sink.rows), 1)
                self.assertEqual(sum(r["event"] == "controller_backend_ready" for r in sink.rows), 1)

    def test_late_scheduler_refuses_before_park_and_cleans_up(self):
        h = self.h
        class LateClock(h.PreviewClock):
            def sleep(self, seconds):
                self.value += seconds + (.121 if self.value >= 2.8 else 0)
        result, backend, guard, sink = self.fake_run(clock=LateClock())
        self.assertFalse(result["completed"])
        self.assertIn("120ms", result["issue"])
        self.assertFalse(any(r["event"] == "controller_report" and
                             r["state"]["buttons"] == h.Y for r in sink.rows))
        self.assert_clean(result, backend, guard)

    def test_focus_owner_escape_failures_stop_before_backend_factory(self):
        h = self.h
        for reason in ("foreground lost", "owned PID creation changed", "Escape pressed"):
            with self.subTest(reason=reason):
                guard = f.Guard(h, h.PreviewClock())
                factory = unittest.mock.Mock(side_effect=AssertionError("factory after guard loss"))
                with patch.object(guard, "check", side_effect=h.Refused(reason)):
                    result = h.run(h.scenarios()[w.DEFAULT_SCENARIO], guard, factory,
                                   f.Sink(), execute=True, clock=h.PreviewClock())
                self.assertFalse(result["completed"])
                self.assertIn(reason, result["issue"])
                self.assertFalse(result["backend_factory_attempted"])
                self.assertEqual(result["driver_report_count"], 0)
                factory.assert_not_called()
                self.assertEqual(guard.closed, 1)

    def test_real_gate_ready_after_neutral_preflight_matching_nonce_then_only_one_schedule(self):
        h = self.h
        clock = h.PreviewClock()
        guard = f.Guard(h, clock)
        owner = h.Owner(1234, 134054832620000000,
                        str(ROOT / "build/bmx-game/Skate.exe"), "A" * 64)
        with tempfile.TemporaryDirectory(prefix="posture-capture-gate-", dir=self.scratch) as temp:
            gate = h.StartGate(Path(temp) / "fresh", "a" * 32, owner,
                               w.DEFAULT_SCENARIO, "B" * 64)
            seen = []
            class Publish(f.Sink):
                def write(inner, event, **fields):
                    if event == "controller_start_gate_ready":
                        self.assertGreaterEqual(clock.now(), 2)
                        self.assertFalse(any(r["event"] == "controller_report" for r in inner.rows))
                        seen.append(clock.now())
                        payload = json.loads(gate.ready.read_text())
                        self.assertEqual(payload["scenario"], w.DEFAULT_SCENARIO)
                        self.assertEqual(payload["runtime_sha256"], owner.runtime_sha256)
                        staging = gate.path / "go.tmp"
                        staging.write_text(json.dumps(gate.trigger_fields()))
                        staging.replace(gate.go)
                    super().write(event, **fields)
            result, backend, guard, sink = self.fake_run(clock=clock, guard=guard,
                                                        gate=gate, sink=Publish())
        self.assertTrue(result["completed"])
        self.assertEqual(len(seen), 1)
        self.assertEqual(sum(r["event"] == "controller_start_gate_go" for r in sink.rows), 1)
        self.assertEqual(result["driver_report_count"], 201)
        self.assert_clean(result, backend, guard)

    def test_preflight_guard_failure_never_publishes_ready_or_schedules_y(self):
        h = self.h
        clock = h.PreviewClock()
        guard = f.Guard(h, clock, abort_at=1)
        with patch.object(h.StartGate.__bases__[0], "wait",
                          side_effect=AssertionError("READY after guard loss")):
            result, backend, guard, sink = self.fake_run(
                clock=clock, guard=guard, gate=f.nonlead_gate(h, w.DEFAULT_SCENARIO))
        self.assertFalse(result["completed"])
        self.assertEqual(result["driver_report_count"], 0)
        self.assertFalse(any(r["event"] == "controller_start_gate_ready" for r in sink.rows))
        self.assert_clean(result, backend, guard)

    def test_real_gate_wrong_owner_nonce_and_total_deadline_send_zero_scheduled_reports(self):
        h = self.h
        owner = h.Owner(1234, 134054832620000000,
                        str(ROOT / "build/bmx-game/Skate.exe"), "A" * 64)
        for change in ("nonce", "owner", "deadline"):
            with self.subTest(change=change), tempfile.TemporaryDirectory(
                    prefix="posture-capture-refused-", dir=self.scratch) as temp:
                gate = h.StartGate(Path(temp) / "fresh", "a" * 32, owner,
                                   w.DEFAULT_SCENARIO, "B" * 64)
                class DeadlineClock(h.PreviewClock):
                    def sleep(inner, seconds):
                        # Accelerate only the GO wait, after the real2s preflight.
                        advance = seconds + (.99 if inner.value >= 2.02 else 0)
                        inner.value = min(inner.value + advance, 60.021)
                clock = DeadlineClock() if change == "deadline" else h.PreviewClock()
                class PublishWrong(f.Sink):
                    def write(inner, event, **fields):
                        if event == "controller_start_gate_ready" and change != "deadline":
                            payload = gate.trigger_fields()
                            payload["nonce" if change == "nonce" else "process_id"] = (
                                "b" * 32 if change == "nonce" else owner.process_id + 1)
                            gate.go.write_text(json.dumps(payload))
                        super().write(event, **fields)
                result, backend, guard, sink = self.fake_run(clock=clock, gate=gate, sink=PublishWrong())
                self.assertFalse(result["completed"])
                self.assertEqual(result["driver_report_count"], 0)
                self.assertFalse(any(r["event"] == "controller_start_gate_go" for r in sink.rows))
                if change == "deadline":
                    self.assertIn("total deadline", result["issue"])
                    self.assertLess(clock.now(), 60.1)
                else:
                    self.assertIn("mismatch", result["issue"])
                self.assert_clean(result, backend, guard)

    def test_live_gate_and_nonce_required_before_loading_including_abbreviations(self):
        cases = [[flag] for flag in ("--execute", "--exec", "--exe", "--e")]
        cases += [["--exec", "--start-g", "fake"], ["--exec", "--start-n", "a" * 32]]
        for args in cases:
            with self.subTest(args=args), patch.object(w, "load_posture",
                    side_effect=AssertionError("source loaded before live gate")):
                with self.assertRaisesRegex(w.Refused, "requires a fresh"):
                    w.main(args)

    def test_only_two_choices_reject_parent_routes_before_loading(self):
        for flag in ("--scenario", "--scen"):
            for scenario in ("ordinary-posture-left", "ordinary-posture-straight", "native-y",
                             "equipment-switch-observe", "quickhop-barspin", "unknown"):
                with self.subTest(flag=flag, scenario=scenario), \
                        patch.object(w, "load_posture", side_effect=AssertionError("invalid source load")), \
                        contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        w.main([flag, scenario])
                    self.assertEqual(error.exception.code, 2)

    def test_outer_and_both_inner_pins_refuse_before_compiling_changed_bytes(self):
        switch = self.posture.load_switch()
        real_read, real_compile = Path.read_bytes, builtins.compile
        bad = b"raise AssertionError('changed source must never compile or execute')"
        for target, message in ((w.POSTURE_PATH, "posture wrapper source changed"),
                                (self.posture.SWITCH_PATH, "switch wrapper source changed"),
                                (switch.BASE_PATH, "base source changed")):
            def read(path):
                return bad if path == target else real_read(path)
            def compile_guard(raw, *args, **kwargs):
                if raw == bad:
                    raise AssertionError("tampered bytes reached compile")
                return real_compile(raw, *args, **kwargs)
            with self.subTest(target=target), patch.object(Path, "read_bytes", read), \
                    patch("builtins.compile", compile_guard):
                with self.assertRaisesRegex(w.Refused, message):
                    w.main([])

    def test_default_and_abbreviated_selection_forward_exact_args_once(self):
        h = self.h
        args = ["--exec", "--start-g", "fake", "--start-n", "a" * 32,
                "--scen", w.SCENARIOS[1]]
        with patch.object(w, "configure", return_value=h), patch.object(h, "main", return_value=19) as main:
            self.assertEqual(w.main(args), 19)
            main.assert_called_once_with(args)
        with patch.object(w, "configure", return_value=h), patch.object(h, "main", return_value=0) as main:
            self.assertEqual(w.main([]), 0)
            main.assert_called_once_with(["--scenario", w.DEFAULT_SCENARIO])

    def test_exact_owner_refused_before_win32_or_backend(self):
        h = self.h
        with patch.object(w, "configure", return_value=h), \
                patch.object(h, "WindowsGuard", side_effect=AssertionError("Win32 before owner")), \
                patch.object(h, "make_vgamepad", side_effect=AssertionError("backend before owner")), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                w.main(["--exec", "--start-g", "fake", "--start-n", "a" * 32])
        self.assertEqual(error.exception.code, 2)
        with tempfile.TemporaryDirectory(prefix="posture-capture-owner-", dir=self.scratch) as temp:
            path = Path(temp) / "owner.json"
            for bad in ({"schema": True}, {"schema": 1, "event": "wrong"}):
                path.write_text(json.dumps(bad))
                with self.subTest(owner=bad), patch.object(w, "configure", return_value=h), \
                        patch.object(h, "WindowsGuard", side_effect=AssertionError("Win32 before owner")), \
                        patch.object(h, "make_vgamepad", side_effect=AssertionError("backend before owner")):
                    with self.assertRaises(w.Refused):
                        w.main(["--exec", "--owner", str(path), "--start-g", "fake", "--start-n", "a" * 32])

    def test_actual_default_and_both_scenario_dryruns_are_driver_free(self):
        original_import, configure = builtins.__import__, w.configure
        def no_driver(name, *args, **kwargs):
            if name == "vgamepad" or name.startswith("vgamepad."):
                raise AssertionError("dry-run imported controller")
            return original_import(name, *args, **kwargs)
        def dry_configuration(posture):
            h = configure(posture)
            def forbidden(*args, **kwargs):
                raise AssertionError("dry-run reached live guard/backend")
            h.WindowsGuard = h.make_vgamepad = forbidden
            return h
        with tempfile.TemporaryDirectory(prefix="posture-capture-dry-", dir=self.scratch) as temp, \
                patch("builtins.__import__", no_driver), \
                patch.object(w, "configure", side_effect=dry_configuration):
            for index, selection in enumerate(([], ["--scenario", w.SCENARIOS[0]],
                                               ["--scenario", w.SCENARIOS[1]])):
                ledger = Path(temp) / f"dry-{index}.jsonl"
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(w.main([*selection, "--ledger", str(ledger)]), 0)
                rows = [json.loads(line) for line in ledger.read_text().splitlines()]
                reports = [r for r in rows if r["event"] == "controller_report"]
                self.assertEqual(len(reports), 201)
                self.assertTrue(all(r["driver_submitted"] is False for r in reports))
                self.assertFalse(rows[0]["execute"])
                self.assertEqual(rows[-1]["driver_report_count"], 0)
                self.assertTrue(rows[-1]["completed"])
        self.assertFalse(any(name == "vgamepad" or name.startswith("vgamepad.") for name in sys.modules))


if __name__ == "__main__":
    unittest.main(verbosity=2)
