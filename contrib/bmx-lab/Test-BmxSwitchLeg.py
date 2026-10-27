"""Pure fake-backend/clock/gate tests; no Win32 or real controller calls."""
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
SPEC = importlib.util.spec_from_file_location("bmx_switch_leg", Path(__file__).with_name("Bmx-SwitchLeg.py"))
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
        return struct.pack("<HBBhhhh", s.buttons, 0, 0, round(s.left_x * 32767),
                           round(s.left_y * 32767), round(s.right_x * 32767), round(s.right_y * 32767)).hex()
    def readback(self): return dict(available=True, slot=0, neutral=True, raw_report_hex="00" * 12)
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


class SwitchLegTests(unittest.TestCase):
    def setUp(self): self.h = w.load_driver()

    def test_import_pin_and_no_controller_import(self):
        self.assertEqual(hashlib.sha256(w.BASE_PATH.read_bytes()).hexdigest().upper(), w.APPROVED_BASE_SHA256)
        self.assertEqual(self.h.WORKSPACE, w.ROOT)
        self.assertFalse(any(n == "vgamepad" or n.startswith("vgamepad.") for n in sys.modules))
        with patch.object(Path, "read_bytes", return_value=b"raise RuntimeError('must never execute')"), \
                patch.object(w.types, "ModuleType", side_effect=AssertionError("allocated before pin")):
            with self.assertRaisesRegex(w.Refused, "base source changed"): w.load_driver()

    def test_only_scenario_and_bounded_gate_specialization_change(self):
        h = self.h
        scenarios, gate = h.scenarios(), h.StartGate
        originals = {n: getattr(h, n) for n in ("main", "run", "WindowsGuard", "bootstrap", "make_vgamepad", "validate_timeline")}
        w.configure(h)
        for name, function in originals.items(): self.assertIs(getattr(h, name), function)
        self.assertTrue(issubclass(h.StartGate, gate))
        self.assertEqual((h.MAX_LATE_MS, h.MAX_DURATION_MS, h.PERIOD_MS, h.POLL_MS, h.START_GATE_LIMIT_MS), (120, 6000, 20, 10, 60000))
        self.assertEqual(set(h.scenarios()) - set(scenarios), {w.SCENARIO})
        for name, original in scenarios.items(): self.assertEqual(h.scenarios()[name], original)

    def test_exact_single_chord_with_neutral_end(self):
        h = self.h
        events = w.timeline(h)
        self.assertEqual([(e.at_ms, e.state.buttons) for e in events],
                         [(0, 0), (240, h.LB), (320, h.LB | h.Y), (520, h.LB), (600, 0), (6000, 0)])
        north = [bool(e.state.buttons & h.Y) for e in events]
        self.assertEqual(sum(b and not a for a, b in zip([False] + north, north)), 1)
        self.assertEqual(sum(a and not b for a, b in zip(north, north[1:])), 1)
        for e in events: self.assertEqual(h.State(e.state.buttons), e.state)
        self.assertEqual(events[-1], h.Event(6000, h.NEUTRAL))

    def fake_run(self, *, clock=None, abort_at=None, fail_at=None, gate=None):
        h = self.h
        clock = clock or h.PreviewClock()
        backend, sink = Backend(h, fail_at), Sink()
        guard = Guard(h, clock, abort_at)
        result = h.run(w.timeline(h), guard, lambda: backend, sink, execute=True, clock=clock, start_gate=gate)
        return result, backend, guard, sink

    def test_base_scheduler_301_reports_and_cleanup(self):
        result, backend, guard, sink = self.fake_run()
        self.assertTrue(result["completed"])
        self.assertEqual(result["driver_report_count"], 301)
        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
        self.assertEqual(backend.states[-1], self.h.NEUTRAL)
        self.assertEqual((backend.closed, guard.closed), (1, 1))
        reports = [r for r in sink.rows if r["event"] == "controller_report"]
        self.assertEqual([r["planned_ms"] for r in reports if r["state"]["buttons"] == self.h.LB | self.h.Y], list(range(320, 520, 20)))
        self.assertIsNone(result["input_consumed"])
        self.assertIsNone(result["native_quality"])

    def test_two_seconds_before_original_ready_publication_and_same_backend(self):
        h = self.h
        original_gate, calls = h.StartGate, []
        clock = h.PreviewClock()
        def original_wait(gate, guard, ledger, current_clock):
            guard.check()
            calls.append(current_clock.now())
            ledger.write("original_gate_ready")
        with patch.object(original_gate, "wait", original_wait):
            w.configure(h)
            # Skip only filesystem construction; call the actual derived wait.
            gate = nonlead_gate(h, w.SCENARIO)
            result, backend, _, sink = self.fake_run(clock=clock, gate=gate)
        self.assertTrue(result["completed"])
        preflight = next(r for r in sink.rows if r["event"] == "controller_switch_neutral_preflight")
        self.assertGreaterEqual(preflight["elapsed_ms"], 2000)
        self.assertFalse(preflight["sdk_discovery_verified"])
        self.assertEqual(len(calls), 1)
        self.assertGreaterEqual(calls[0], 2)
        self.assertEqual(sum(r["event"] == "controller_backend_ready" for r in sink.rows), 1)
        self.assertEqual(backend.closed, 1)
        self.assertLess(next(i for i, r in enumerate(sink.rows) if r["event"] == "controller_switch_neutral_preflight"),
                        next(i for i, r in enumerate(sink.rows) if r["event"] == "original_gate_ready"))
        first = next(r for r in sink.rows if r["event"] == "controller_report")
        self.assertEqual(first["elapsed_ms"], 0)

    def test_preflight_and_original_go_wait_share_total_60second_limit(self):
        h = self.h
        original_gate = h.StartGate
        def original_wait(gate, guard, ledger, clock):
            clock.sleep(58)
            guard.check()
        with patch.object(original_gate, "wait", original_wait):
            w.configure(h)
            result, backend, _, _ = self.fake_run(gate=nonlead_gate(h, w.SCENARIO))
        self.assertFalse(result["completed"])
        self.assertIn("total deadline", result["issue"])
        self.assertEqual(result["driver_report_count"], 0)
        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
        self.assertEqual(backend.states[-1], h.NEUTRAL)

    def test_actual_original_gate_files_are_published_after_preflight_and_valid_go_is_consumed(self):
        h = w.configure(self.h)
        clock = h.PreviewClock()
        backend = Backend(h)
        guard = Guard(h, clock)
        owner = h.Owner(1234, 134054832620000000, str(w.ROOT / "build/bmx-game/Skate.exe"), "A" * 64)
        nonce = "a" * 32
        with tempfile.TemporaryDirectory(prefix="switch-leg-gate-", dir=w.ROOT / "build/bmx") as folder:
            gate = h.StartGate(Path(folder) / "fresh-gate", nonce, owner, w.SCENARIO, w.APPROVED_BASE_SHA256)

            class ReceiptSink(Sink):
                def write(inner, event, **fields):
                    if event == "controller_start_gate_ready":
                        self.assertGreaterEqual(clock.now(), 2)
                        self.assertEqual(backend.states[-1], h.NEUTRAL)
                        self.assertTrue(gate.ready.is_file())
                        # Simulate the external operator's atomic GO publication.
                        temp = gate.path / "operator-go.tmp"
                        temp.write_text(json.dumps(dict(schema=1, event="bmx_virtual_gamepad_go", process_id=owner.process_id,
                                                       process_creation_filetime=str(owner.process_creation_filetime), nonce=nonce)))
                        temp.replace(gate.go)
                    super().write(event, **fields)

            sink = ReceiptSink()
            result = h.run(w.timeline(h), guard, lambda: backend, sink, execute=True, clock=clock, start_gate=gate)
            self.assertTrue(result["completed"])
            self.assertEqual(result["driver_report_count"], 301)
            self.assertEqual(sum(r["event"] == "controller_start_gate_go" for r in sink.rows), 1)
            self.assertEqual((backend.closed, guard.closed), (1, 1))

    def test_focus_loss_during_preflight_aborts_before_ready_and_cleans_up(self):
        h = self.h
        original_gate = h.StartGate
        with patch.object(original_gate, "wait", side_effect=AssertionError("ready before neutral preflight")):
            w.configure(h)
            result, backend, _, _ = self.fake_run(abort_at=1, gate=nonlead_gate(h, w.SCENARIO))
        self.assertFalse(result["completed"])
        self.assertEqual(result["driver_report_count"], 0)
        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
        self.assertEqual(backend.states[-1], h.NEUTRAL)

    def test_focus_loss_or_driver_failure_reuses_final_neutral_and_disconnect(self):
        for options in ({"abort_at": 1.0}, {"fail_at": 80}):
            with self.subTest(options=options):
                result, backend, guard, _ = self.fake_run(**options)
                self.assertFalse(result["completed"])
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
                self.assertEqual((backend.closed, guard.closed), (1, 1))
                self.assertEqual(backend.states[-1], self.h.NEUTRAL)

    def test_120ms_lateness_still_aborts(self):
        h = self.h
        class LateClock(h.PreviewClock):
            def sleep(self, seconds): self.value += seconds + (.2 if self.value >= 1 else 0)
        result, backend, _, _ = self.fake_run(clock=LateClock())
        self.assertFalse(result["completed"])
        self.assertIn("120ms", result["issue"])
        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])

    def test_cli_default_dry_run_has_no_live_guard_or_backend(self):
        h = self.h
        with tempfile.TemporaryDirectory(prefix="switch-leg-test-", dir=w.ROOT / "build/bmx") as folder:
            ledger = Path(folder) / "dry.jsonl"
            with patch.object(w, "load_driver", return_value=h), \
                    patch.object(h, "WindowsGuard", side_effect=AssertionError("live guard")), \
                    patch.object(h, "make_vgamepad", side_effect=AssertionError("live backend")), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(w.main(["--ledger", str(ledger)]), 0)
            rows = [json.loads(line) for line in ledger.read_text().splitlines()]
            self.assertEqual(rows[0]["scenario"], w.SCENARIO)
            self.assertFalse(rows[0]["execute"])
            self.assertEqual(rows[0]["source_sha256"], w.APPROVED_BASE_SHA256)
            self.assertEqual(rows[-1]["report_count"], 301)
            self.assertEqual(rows[-1]["driver_report_count"], 0)
            self.assertTrue(rows[-1]["completed"])

    def test_live_requires_gate_nonce_and_base_owner_before_driver(self):
        for args in (["--execute"], ["--exec"], ["--execute", "--start-gate", "fake"], ["--execute", "--start-nonce", "a" * 32]):
            with self.subTest(args=args), self.assertRaisesRegex(w.Refused, "requires a fresh"):
                w.main(args)
        h = self.h
        with patch.object(w, "load_driver", return_value=h), \
                patch.object(h, "make_vgamepad", side_effect=AssertionError("backend before owner")), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                w.main(["--execute", "--start-gate", "fake", "--start-nonce", "a" * 32])
        self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
