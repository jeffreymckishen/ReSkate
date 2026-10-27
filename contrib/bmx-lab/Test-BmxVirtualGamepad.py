"""Focused fake-backend/clock/Win32 metadata tests. Never imports vgamepad."""
import ctypes
import hashlib
import importlib.util
import io
import json
from pathlib import Path, PureWindowsPath
import re
import sys
import struct
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("Bmx-VirtualGamepad.py")
spec = importlib.util.spec_from_file_location("bmx_virtual_gamepad", SCRIPT)
h = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = h
spec.loader.exec_module(h)


class Backend:
    def __init__(self, fail_at=None, release_fails=False, close_fails=False):
        self.states, self.closed, self.fail_at = [], 0, fail_at
        self.release_fails, self.close_fails = release_fails, close_fails
        self.prime_count = 0

    def prime_lsb(self):
        self.prime_count += 1
        self.send(h.State(left_x=1 / 32767))

    def raw_report_hex(self):
        state = self.states[-1]
        return struct.pack("<HBBhhhh", state.buttons, round(state.left_trigger * 255), round(state.right_trigger * 255),
                           round(state.left_x * 32767), round(state.left_y * 32767), round(state.right_x * 32767), round(state.right_y * 32767)).hex()

    def readback(self):
        return dict(available=True, slot=0, neutral=True, raw_report_hex="00" * 12)

    def send(self, state):
        self.states.append(state)
        if len(self.states) == self.fail_at or (self.release_fails and state == h.NEUTRAL and len(self.states) > 1):
            raise OSError("fake driver failure")

    def close(self):
        self.closed += 1
        if self.close_fails:
            raise OSError("fake disconnect failure")


class Guard:
    def __init__(self, clock, abort_after=None, issue="Escape abort"):
        self.clock, self.abort_after, self.issue, self.closed = clock, abort_after, issue, 0

    def check(self):
        if self.abort_after is not None and self.clock.now() >= self.abort_after:
            raise h.Refused(self.issue)

    def close(self):
        self.closed += 1


class Sink:
    def __init__(self, fail_event=None):
        self.rows, self.fail_event = [], fail_event

    def write(self, event, **fields):
        if self.fail_event == event:
            raise OSError("fake disk full")
        self.rows.append(dict(event=event, **fields))


class Call:
    def __init__(self, action):
        self.action = action

    def __call__(self, *args):
        return self.action(*args)


class HarnessTests(unittest.TestCase):
    def short(self):
        return (h.Event(0, h.NEUTRAL), h.Event(20, h.State(h.Y)), h.Event(80, h.NEUTRAL))

    def execute_fake(self, backend=None, guard=None, clock=None, sink=None):
        clock = clock or h.PreviewClock()
        backend, sink = backend or Backend(), sink or Sink()
        guard = guard or Guard(clock)
        return h.run(self.short(), guard, lambda: backend, sink, execute=True, clock=clock), backend, guard, sink

    def test_scheduler_uses_high_resolution_monotonic_performance_clock(self):
        import time
        self.assertIs(h.Clock.now, time.perf_counter)
        self.assertTrue(time.get_clock_info("perf_counter").monotonic)

    def test_file_tokens_take_one_stat_per_file_and_preserve_all_fields(self):
        class File:
            def __init__(self, seed): self.seed, self.reads = seed, 0
            def stat(self):
                self.reads += 1
                return types.SimpleNamespace(st_dev=self.seed, st_ino=self.seed+1,
                                             st_size=self.seed+2, st_mtime_ns=self.seed+3, st_ctime_ns=self.seed+4)
        game, runtime = File(10), File(20)
        guard = types.SimpleNamespace(owner=types.SimpleNamespace(game_exe="fake"), runtime=runtime)
        with patch.object(h, "Path", return_value=game):
            self.assertEqual(h.WindowsGuard._file_tokens(guard), ((10,11,12,13,14),(20,21,22,23,24)))
        self.assertEqual((game.reads, runtime.reads), (1,1))

    def test_guard_cost_is_rechecked_before_sleep(self):
        clock, backend, sink = h.PreviewClock(), Backend(), Sink()
        class CostGuard:
            calls = 0
            def check(self):
                self.calls += 1
                if self.calls == 3: clock.value += 0.02
            def close(self): pass
        result = h.run((h.Event(0,h.NEUTRAL),h.Event(20,h.State(h.Y)),h.Event(40,h.NEUTRAL)),
                       CostGuard(),lambda: backend,sink,clock=clock)
        self.assertTrue(result["completed"])
        report = next(row for row in sink.rows if row["event"] == "controller_report" and row["planned_ms"] == 20)
        self.assertEqual(report["elapsed_ms"],20)
        self.assertEqual(backend.states[-1],h.NEUTRAL)

    def test_neutral_follow_exact_timeline_reports_and_fake_cleanup(self):
        events = h.scenarios()["neutral-follow"]
        self.assertEqual(events, (h.Event(0, h.NEUTRAL), h.Event(6000, h.NEUTRAL)))
        self.assertEqual(h.MAX_DURATION_MS, 6000)
        h.validate_timeline(events)
        clock, backend, sink = h.PreviewClock(), Backend(), Sink()
        guard = Guard(clock)
        result = h.run(events, guard, lambda: backend, sink, execute=True, clock=clock)
        self.assertTrue(result["completed"])
        self.assertIsNone(result["issue"])
        self.assertEqual((result["report_count"], result["driver_report_count"]), (301, 301))
        reports = [row for row in sink.rows if row["event"] == "controller_report"]
        self.assertEqual([row["planned_ms"] for row in reports], list(range(0, 6001, 20)))
        self.assertTrue(all(row["state"] == h.asdict(h.NEUTRAL) for row in reports))
        self.assertTrue(all(row["raw_report_hex"] == "00" * 12 for row in reports))
        self.assertEqual([row["planned_ms"] for row in reports if row["planned_ms"] <= 500],
                         list(range(0, 501, 20)))
        # Scheduled reports are neutral; the unchanged preceding bootstrap is not.
        self.assertEqual(backend.states, [h.State(left_x=1 / 32767)] + [h.NEUTRAL] * 304)
        self.assertEqual((backend.prime_count, backend.closed, guard.closed), (1, 1, 1))
        self.assertTrue(result["neutral_release_succeeded"])
        self.assertTrue(result["disconnect_succeeded"])
        self.assertEqual(sink.rows[-2]["event"], "controller_neutral_release")
        self.assertTrue(sink.rows[-2]["succeeded"])
        self.assertEqual(sink.rows[-2]["state"], h.asdict(h.NEUTRAL))
        self.assertEqual(sink.rows[-1]["event"], "controller_session_end")
        self.assertIsNone(result["input_consumed"])
        self.assertIsNone(result["native_quality"])

    def test_ground_pump_scenario_releases_holds_and_settles_without_dpad(self):
        events = h.scenarios()["ground-pump"]
        self.assertEqual(events, (h.Event(0, h.NEUTRAL), h.Event(240, h.State(h.A)),
                                 h.Event(1000, h.NEUTRAL), h.Event(1200, h.State(left_y=-0.7)),
                                 h.Event(1500, h.NEUTRAL), h.Event(3200, h.NEUTRAL)))
        self.assertEqual(events[4].at_ms - events[3].at_ms, 300)
        self.assertTrue(all(event.state.buttons in (0, h.A) for event in events))
        self.assertTrue(all(event.state.right_x == event.state.right_y == 0 for event in events))
        h.validate_timeline(events)

    def test_ground_pump_fake_full_schedule_and_cleanup(self):
        clock, backend, sink = h.PreviewClock(), Backend(), Sink()
        result = h.run(h.scenarios()["ground-pump"], Guard(clock), lambda: backend, sink, clock=clock)
        self.assertTrue(result["completed"])
        self.assertEqual(result["report_count"], 161)
        reports = [row for row in sink.rows if row["event"] == "controller_report"]
        pump = [row for row in reports if row["state"]["left_y"] == -0.7]
        self.assertEqual([row["planned_ms"] for row in pump], list(range(1200, 1500, 20)))
        self.assertTrue(all(row["state"]["buttons"] == 0 for row in pump))
        self.assertTrue(result["neutral_release_succeeded"])
        self.assertTrue(result["disconnect_succeeded"])
        self.assertEqual(backend.states[-1], h.NEUTRAL)
        self.assertIsNone(result["input_consumed"])

    def test_ground_pump_stall_aborts_before_pump_and_still_releases(self):
        class Stalled(h.PreviewClock):
            def sleep(self, seconds):
                self.value += seconds + (0.2 if self.value >= 1.1 else 0)
        clock, backend, sink = Stalled(), Backend(), Sink()
        result = h.run(h.scenarios()["ground-pump"], Guard(clock), lambda: backend, sink, clock=clock)
        self.assertFalse(result["completed"])
        self.assertIn("120ms", result["issue"])
        self.assertTrue(all(state.left_y == 0 for state in backend.states))
        self.assertTrue(result["neutral_release_succeeded"])
        self.assertTrue(result["disconnect_succeeded"])

    def test_ground_pump_switch_exact_contract_without_dpad_or_right_stick(self):
        events = h.scenarios()["ground-pump-switch"]
        expected = (h.Event(0,h.NEUTRAL),h.Event(240,h.State(h.A)),h.Event(1000,h.NEUTRAL),
                    h.Event(1200,h.State(left_y=-0.7)),h.Event(1500,h.State(h.B)),
                    h.Event(2300,h.State(h.LB)),h.Event(2380,h.State(h.LB|h.Y)),
                    h.Event(2580,h.State(h.LB)),h.Event(2660,h.NEUTRAL),h.Event(4000,h.NEUTRAL))
        self.assertEqual(events, expected)
        h.validate_timeline(events)
        self.assertTrue(all(event.state.buttons in (0,h.A,h.B,h.LB,h.LB|h.Y) for event in events))
        self.assertTrue(all(event.state.right_x == event.state.right_y == 0 for event in events))
        self.assertTrue(all(event.state.left_x == event.state.left_trigger == event.state.right_trigger == 0 for event in events))

    def test_ground_pump_switch_full_schedule_brake_release_and_one_chord(self):
        clock, backend, sink = h.PreviewClock(), Backend(), Sink()
        result = h.run(h.scenarios()["ground-pump-switch"],Guard(clock),lambda:backend,sink,clock=clock)
        self.assertTrue(result["completed"])
        self.assertEqual(result["report_count"],201)
        reports = [row for row in sink.rows if row["event"] == "controller_report"]
        pump = [row["planned_ms"] for row in reports if row["state"]["left_y"] == -0.7]
        brake = [row["planned_ms"] for row in reports if row["state"]["buttons"] & h.B]
        chord = [row["planned_ms"] for row in reports if row["state"]["buttons"] & h.Y]
        self.assertEqual(pump,list(range(1200,1500,20)))
        self.assertEqual(brake,list(range(1500,2300,20)))
        self.assertEqual(chord,list(range(2380,2580,20)))
        states = {row["planned_ms"]:row["state"] for row in reports}
        self.assertEqual(states[2300],h.asdict(h.State(h.LB)))
        self.assertEqual(states[2380],h.asdict(h.State(h.LB|h.Y)))
        self.assertEqual(states[2580],h.asdict(h.State(h.LB)))
        self.assertTrue(all(row["state"] == h.asdict(h.NEUTRAL) for row in reports if row["planned_ms"] >= 2660))
        self.assertTrue(result["neutral_release_succeeded"])
        self.assertTrue(result["disconnect_succeeded"])
        self.assertEqual(backend.states[-1],h.NEUTRAL)
        self.assertIsNone(result["input_consumed"])
        self.assertIsNone(result["native_quality"])

    def test_ground_pump_switch_guard_cleanup_during_each_active_phase(self):
        for at_seconds in (.45,1.35,1.95,2.45):
            with self.subTest(at_seconds=at_seconds):
                clock, backend, sink = h.PreviewClock(), Backend(), Sink()
                guard = Guard(clock,at_seconds,"Owned game lost foreground")
                result = h.run(h.scenarios()["ground-pump-switch"],guard,lambda:backend,sink,clock=clock)
                self.assertFalse(result["completed"])
                self.assertIn("lost foreground",result["issue"])
                self.assertLess(result["report_count"],201)
                self.assertEqual(backend.states[-1],h.NEUTRAL)
                self.assertEqual((backend.closed,guard.closed),(1,1))
                self.assertTrue(result["neutral_release_succeeded"])
                self.assertTrue(result["disconnect_succeeded"])

    def test_ground_pump_switch_stall_before_chord_refuses_y_and_cleans_up(self):
        class Stalled(h.PreviewClock):
            def sleep(self,seconds):
                self.value += seconds + (.2 if self.value >= 2.30 else 0)
        clock, backend, sink = Stalled(), Backend(), Sink()
        result = h.run(h.scenarios()["ground-pump-switch"],Guard(clock),lambda:backend,sink,clock=clock)
        self.assertFalse(result["completed"])
        self.assertIn("120ms",result["issue"])
        self.assertFalse(any(state.buttons & h.Y for state in backend.states))
        self.assertEqual(backend.states[-1],h.NEUTRAL)
        self.assertTrue(result["neutral_release_succeeded"])
        self.assertTrue(result["disconnect_succeeded"])

    def test_ground_pump_switch_preserves_original_ground_pump(self):
        self.assertEqual(h.scenarios()["ground-pump"],(h.Event(0,h.NEUTRAL),h.Event(240,h.State(h.A)),
                         h.Event(1000,h.NEUTRAL),h.Event(1200,h.State(left_y=-0.7)),
                         h.Event(1500,h.NEUTRAL),h.Event(3200,h.NEUTRAL)))
        self.assertEqual((h.PERIOD_MS,h.POLL_MS,h.MAX_LATE_MS,h.MAX_DURATION_MS),(20,10,120,6000))

    def test_scenarios_bounded_current_controls(self):
        for name, events in h.scenarios().items():
            with self.subTest(name=name):
                h.validate_timeline(events)
                if name != "neutral-window-20s":
                    self.assertLessEqual(events[-1].at_ms, 6000)
        self.assertEqual(h.scenarios()["native-y"][1].state.buttons, h.Y)
        self.assertEqual(h.scenarios()["equipment-switch"][2].state.buttons, h.LB | h.Y)
        self.assertEqual(h.scenarios()["bunnyhop-tailwhip"][6].state, h.State(right_x=1, left_trigger=1, right_trigger=1))

    def test_completed_reports_and_final_release(self):
        result, backend, guard, sink = self.execute_fake()
        self.assertTrue(result["completed"])
        self.assertEqual(result["report_count"], 5)
        self.assertEqual(backend.states[:3], [h.State(left_x=1 / 32767), h.NEUTRAL, h.NEUTRAL])
        self.assertEqual(backend.states[3:], [h.NEUTRAL, h.State(h.Y), h.State(h.Y), h.State(h.Y), h.NEUTRAL, h.NEUTRAL])
        self.assertEqual(backend.prime_count, 1)
        self.assertEqual(backend.closed, 1)
        self.assertEqual(guard.closed, 1)
        self.assertEqual(sink.rows[-2]["event"], "controller_neutral_release")
        self.assertIsNone(result["input_consumed"])
        self.assertIsNone(result["native_quality"])

    def test_escape_focus_and_owner_change_abort_release(self):
        for reason in ("Escape abort", "Owned game lost foreground", "Owned creation FILETIME changed", "Isolated game/runtime files changed"):
            clock = h.PreviewClock()
            result, backend, guard, _ = self.execute_fake(clock=clock, guard=Guard(clock, .055, reason))
            self.assertFalse(result["completed"])
            self.assertIn(reason, result["issue"])
            self.assertEqual(backend.states[-1], h.NEUTRAL)
            self.assertEqual(backend.closed, 1)
            self.assertTrue(result["neutral_release_succeeded"])
            self.assertEqual(guard.closed, 1)
            self.assertEqual(result["report_count"], 2)

    def test_initial_guard_refuses_before_backend_creation(self):
        clock = h.PreviewClock()
        factory = lambda: self.fail("Backend must not be created")
        guard = Guard(clock, 0)
        result = h.run(self.short(), guard, factory, Sink(), execute=True, clock=clock)
        self.assertFalse(result["completed"])
        self.assertEqual(result["driver_report_count"], 0)
        self.assertFalse(result["driver_submitted"])
        self.assertEqual(guard.closed, 1)

    def test_bootstrap_startup_cache_never_sends_buttons_before_two_zero_samples(self):
        class Startup(Backend):
            def __init__(self):
                super().__init__()
                self.reads = 0
            def readback(self):
                self.reads += 1
                self.assert_no_buttons()
                return dict(available=True, slot=2, neutral=self.reads > 1,
                            raw_report_hex="00" * 12 if self.reads > 1 else "00000000e4f2b3f849f3b0fc")
            def assert_no_buttons(self):
                if any(state.buttons for state in self.states):
                    raise AssertionError("Timeline ran before neutral bootstrap")
        result, backend, _, sink = self.execute_fake(backend=Startup())
        self.assertTrue(result["completed"])
        self.assertEqual((backend.prime_count, backend.reads), (1, 3))
        complete = next(i for i, row in enumerate(sink.rows) if row["event"] == "controller_bootstrap_complete")
        self.assertEqual(sink.rows[complete]["slot"], 2)
        self.assertTrue(all(row["event"] != "controller_report" for row in sink.rows[:complete]))
        primed = [row for row in sink.rows if row["event"] == "controller_bootstrap_report"
                  and row.get("operation") == "raw_left_x_one_lsb"]
        self.assertEqual(len(primed), 1)
        self.assertEqual(primed[0]["raw_report_hex"], "000000000100000000000000")

    def test_bootstrap_timeout_unavailable_changed_slot_or_stalled_readback_aborts(self):
        for fault in ("nonzero", "unavailable", "slot_changed", "readback_stalled"):
            clock = h.PreviewClock()
            class Fault(Backend):
                reads = 0
                def readback(self):
                    self.reads += 1
                    if fault == "readback_stalled":
                        clock.value += 2
                    return dict(available=fault != "unavailable", slot=1 if fault == "slot_changed" and self.reads > 1 else 0,
                                neutral=fault != "nonzero", raw_report_hex="01" * 12 if fault == "nonzero" else "00" * 12)
            with self.subTest(fault=fault):
                result, backend, _, sink = self.execute_fake(backend=Fault(), clock=clock)
                self.assertFalse(result["completed"])
                self.assertEqual(result["driver_report_count"], 0)
                self.assertTrue(result["driver_submitted"])
                self.assertFalse(any(state.buttons for state in backend.states))
                self.assertEqual(backend.states[-1], h.NEUTRAL)
                self.assertEqual((backend.prime_count, backend.closed), (1, 1))
                self.assertLess(len(sink.rows), 512)

    def test_bootstrap_guard_refusal_after_prime_still_releases_and_disconnects(self):
        clock, backend = h.PreviewClock(), Backend()
        class AfterPrime(Guard):
            def check(self):
                if backend.prime_count:
                    raise h.Refused("Focus/Escape changed after prime")
        result, backend, _, _ = self.execute_fake(backend=backend, guard=AfterPrime(clock), clock=clock)
        self.assertFalse(result["completed"])
        self.assertEqual(backend.states, [h.State(left_x=1 / 32767), h.NEUTRAL])
        self.assertEqual(backend.closed, 1)
        self.assertTrue(result["driver_submitted"])

    def test_backend_factory_failure_delivery_is_unknown(self):
        def failed_factory():
            raise OSError("Partial constructor delivery is unknown")
        clock, sink = h.PreviewClock(), Sink()
        result = h.run(self.short(), Guard(clock), failed_factory, sink, execute=True, clock=clock)
        self.assertFalse(result["completed"])
        self.assertTrue(result["backend_factory_attempted"])
        self.assertIsNone(result["driver_submitted"])
        self.assertEqual(result["driver_report_count"], 0)

    def test_bootstrap_and_longest_timeline_fit_bounded_ledger(self):
        class SlowNeutral(Backend):
            reads = 0
            def readback(self):
                self.reads += 1
                return dict(available=True, slot=0, neutral=self.reads >= 47,
                            raw_report_hex="00" * 12 if self.reads >= 47 else "01" * 12)
        clock, backend, sink = h.PreviewClock(), SlowNeutral(), Sink()
        result = h.run((h.Event(0, h.NEUTRAL), h.Event(6000, h.NEUTRAL)), Guard(clock), lambda: backend,
                       sink, execute=True, clock=clock)
        self.assertTrue(result["completed"])
        self.assertEqual(result["driver_report_count"], 301)
        self.assertEqual(backend.reads, 48)
        self.assertLessEqual(len(sink.rows) + 1, 512)  # Session-start row is written by main.

    def test_actual_public_slot_probe_reads_exact_report_and_refuses_bad_status(self):
        probe = h.WindowsControllerProbe.__new__(h.WindowsControllerProbe)
        pad = types.SimpleNamespace(_busp=11, _devicep=22)
        for fault in (None, "startup", "driver", "slot", "xinput"):
            calls = []
            def user_index(bus, target, output):
                calls.append(("index", bus, target))
                ctypes.cast(output, ctypes.POINTER(h.wintypes.DWORD))[0] = 4 if fault == "slot" else 2
                return 0xDEAD if fault == "driver" else 0x20000000
            def get_state(slot, output):
                calls.append(("xinput", slot))
                state = ctypes.cast(output, ctypes.POINTER(h.XInputState)).contents
                state.packet = 42  # A nonzero packet is compatible with neutral input.
                if fault == "startup":
                    ctypes.memmove(ctypes.byref(state.report), bytes.fromhex("00000000e4f2b3f849f3b0fc"), 12)
                return 1167 if fault == "xinput" else 0
            probe.client = types.SimpleNamespace(vigem_target_x360_get_user_index=Call(user_index))
            probe.api = types.SimpleNamespace(XInputGetState=Call(get_state))
            with self.subTest(fault=fault):
                observed = probe.read(pad)
                self.assertEqual(observed["available"], fault not in ("driver", "slot", "xinput"))
                self.assertEqual(observed["neutral"], fault is None)
                if fault is None:
                    self.assertEqual((observed["slot"], observed["packet"], observed["raw_report_hex"]), (2, 42, "00" * 12))
                self.assertEqual(calls[0], ("index", 11, 22))
                self.assertEqual(len(calls), 1 if fault in ("driver", "slot") else 2)

    def test_driver_and_ledger_faults_still_neutral_disconnect(self):
        for backend, sink in ((Backend(fail_at=2), Sink()), (Backend(), Sink("controller_report")),
                              (Backend(), Sink("controller_neutral_release")), (Backend(), Sink("controller_session_end"))):
            result, backend, guard, _ = self.execute_fake(backend=backend, sink=sink)
            self.assertFalse(result["completed"])
            self.assertEqual(backend.states[-1], h.NEUTRAL)
            self.assertEqual(backend.closed, 1)
            self.assertEqual(guard.closed, 1)

    def test_release_failure_does_not_skip_disconnect(self):
        result, backend, _, _ = self.execute_fake(backend=Backend(release_fails=True))
        self.assertFalse(result["completed"])
        self.assertFalse(result["neutral_release_succeeded"])
        self.assertTrue(result["disconnect_succeeded"])
        self.assertEqual(backend.closed, 1)
        result, _, _, _ = self.execute_fake(backend=Backend(close_fails=True))
        self.assertFalse(result["disconnect_succeeded"])
        self.assertFalse(result["completed"])

    def test_keyboard_interrupt_still_cleans_up(self):
        class Interrupted(Backend):
            def send(self, state):
                if state.buttons:
                    raise KeyboardInterrupt()
                super().send(state)
        result, backend, _, _ = self.execute_fake(backend=Interrupted())
        self.assertFalse(result["completed"])
        self.assertIn("KeyboardInterrupt", result["issue"])
        self.assertEqual(backend.states[-1], h.NEUTRAL)
        self.assertEqual(backend.closed, 1)

    def test_scheduler_stall_refuses_late_non_neutral(self):
        class Stalled(h.PreviewClock):
            def sleep(self, seconds):
                self.value += seconds + .2
        result, backend, _, _ = self.execute_fake(clock=Stalled())
        self.assertFalse(result["completed"])
        self.assertTrue(all(s == h.NEUTRAL for s in backend.states[1:]))

    def test_scheduler_reversal_or_nonfinite_refuses(self):
        for bad in (-1, float("nan"), float("inf")):
            class Broken(h.PreviewClock):
                def sleep(self, seconds):
                    self.value = bad
            result, backend, _, _ = self.execute_fake(clock=Broken())
            self.assertFalse(result["completed"])
            self.assertTrue(all(s == h.NEUTRAL for s in backend.states[1:]))

    def test_invalid_timelines_cannot_create_backend(self):
        invalid = [(), (h.Event(0, h.NEUTRAL),), (h.Event(0, h.State(h.Y)), h.Event(20, h.NEUTRAL)),
                   (h.Event(0, h.NEUTRAL), h.Event(20, h.State(h.Y))),
                   (h.Event(0, h.NEUTRAL), h.Event(6010, h.NEUTRAL)),
                   (h.Event(0, h.NEUTRAL), h.Event(21, h.NEUTRAL)),
                   (h.Event(0, h.NEUTRAL), h.Event(0, h.NEUTRAL)),
                   (h.Event(0, h.NEUTRAL), h.Event(20, h.State(1)), h.Event(40, h.NEUTRAL)),
                   (h.Event(0, h.NEUTRAL), h.Event(20, h.State(left_x=float("nan"))), h.Event(40, h.NEUTRAL)),
                   (h.Event(0, h.NEUTRAL), h.Event(20, h.State(right_trigger=-1)), h.Event(40, h.NEUTRAL))]
        for timeline in invalid:
            with self.subTest(timeline=timeline), self.assertRaises(h.Refused):
                h.run(timeline, h.DryGuard(), lambda: self.fail("No device"), Sink(), clock=h.PreviewClock())

    def test_real_backend_mapping_idempotent_disconnect_with_fake_module(self):
        calls = []
        class Pad:
            def __init__(self):
                self._devicep = self._busp = 1
            def __del__(self):
                calls.append(("removed",))
            def reset(self):
                calls.append(("reset",))
            def press_button(self, **kw):
                calls.append(("button", kw["button"]))
            def left_joystick_float(self, **kw):
                calls.append(("left", kw))
            def left_joystick(self, **kw):
                calls.append(("left_raw", kw))
            def right_joystick_float(self, **kw):
                calls.append(("right", kw))
            def left_trigger_float(self, **kw):
                calls.append(("lt", kw))
            def right_trigger_float(self, **kw):
                calls.append(("rt", kw))
            def update(self):
                calls.append(("update",))
        names = ["A", "B", "Y", "LEFT_SHOULDER", "RIGHT_SHOULDER", "RIGHT_THUMB", "START"]
        module = types.SimpleNamespace(VX360Gamepad=Pad, XUSB_BUTTON=types.SimpleNamespace(**{"XUSB_GAMEPAD_" + n: n for n in names}))
        backend = h.VGamepadBackend(module, probe=object())
        backend.prime_lsb()
        self.assertIn(("left_raw", {"x_value": 1, "y_value": 0}), calls)
        backend.send(h.State(h.LB | h.Y, right_y=-1, right_trigger=1))
        self.assertIn(("button", "Y"), calls)
        self.assertIn(("button", "LEFT_SHOULDER"), calls)
        self.assertIn(("right", {"x_value_float": 0.0, "y_value_float": -1}), calls)
        backend.send(h.NEUTRAL)
        backend.close()
        backend.close()
        del backend
        self.assertEqual(calls.count(("removed",)), 1)

    def test_actual_windows_check_rejects_wrong_focus_creation_exit_and_path(self):
        for fault in (None, "escape", "focus", "creation", "exit", "path", "files", "module"):
            guard = h.WindowsGuard.__new__(h.WindowsGuard)
            guard.owner = h.Owner(123, 456, "isolated-game", "A" * 64)
            guard.handle, guard.last_modules, guard.file_tokens = 9, 0, (1,)
            guard._file_tokens = lambda: (2,) if fault == "files" else (1,)
            def modules():
                if fault == "module":
                    raise h.Refused("module absent")
            guard._runtime_loaded = modules
            def foreground(window, pid):
                pid._obj.value = 999 if fault == "focus" else 123
                return 1
            def exited(handle, code):
                code._obj.value = 1 if fault == "exit" else 259
                return 1
            def created(handle, value, *rest):
                value._obj.dwLowDateTime = 457 if fault == "creation" else 456
                value._obj.dwHighDateTime = 0
                return 1
            def path(handle, flags, name, length):
                name.value = "other" if fault == "path" else "isolated-game"
                return 1
            guard.user = types.SimpleNamespace(GetAsyncKeyState=lambda key: 0x8000 if fault == "escape" else 0,
                                              GetForegroundWindow=lambda: 1, GetWindowThreadProcessId=foreground)
            guard.kernel = types.SimpleNamespace(GetExitCodeProcess=exited, GetProcessTimes=created, QueryFullProcessImageNameW=path)
            if fault:
                with self.subTest(fault=fault), self.assertRaises(h.Refused):
                    guard.check()
            else:
                guard.check()

    def test_owner_receipt_strict_and_dryrun_has_no_driver_or_guard(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-test-", dir=folder) as temporary:
            directory = Path(temporary)
            self.assertTrue(directory.resolve().is_relative_to(folder.resolve()))
            owner = directory / "owner.json"
            valid = dict(schema=1, event="bmx_virtual_gamepad_owner", process_id=123, process_creation_filetime="456",
                         game_exe=str(h.WORKSPACE / "build" / "bmx-game" / "Skate.exe"), runtime_sha256="A" * 64)
            owner.write_text(json.dumps(valid))
            self.assertEqual(h.load_owner(owner).process_id, 123)
            for field, bad in (("process_id", True), ("process_id", 0), ("process_creation_filetime", "0456"),
                               ("process_creation_filetime", "18446744073709551616"), ("game_exe", r"D:\SteamLibrary\steamapps\common\Skate\Skate.exe"),
                               ("runtime_sha256", "bad"), ("schema", True), ("event", "other")):
                changed = dict(valid, **{field: bad})
                owner.write_text(json.dumps(changed))
                with self.subTest(field=field, bad=bad), self.assertRaises(h.Refused):
                    h.load_owner(owner)
            ledger = directory / "dry.jsonl"
            with patch.object(h, "WindowsGuard", side_effect=AssertionError("No game inspection")), \
                    patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver import")):
                self.assertEqual(h.main(["--ledger", str(ledger)]), 0)
            rows = [json.loads(line) for line in ledger.read_text().splitlines()]
            self.assertFalse(rows[0]["execute"])
            self.assertTrue(rows[0]["timing_simulated"])
            self.assertTrue(all(row.get("driver_submitted") is not True for row in rows))
            self.assertTrue(all("utc" in row and "host_monotonic_ns" in row for row in rows))
            with self.assertRaises(FileExistsError):
                h.main(["--ledger", str(ledger)])

    def test_execute_requires_owner_and_guard_failure_creates_no_backend(self):
        with patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver")):
            with self.assertRaises(SystemExit) as error:
                h.main(["--execute"])
            self.assertEqual(error.exception.code, 2)
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-test-", dir=folder) as temporary:
            directory = Path(temporary)
            self.assertTrue(directory.resolve().is_relative_to(folder.resolve()))
            ledger = directory / "refused.jsonl"
            with patch.object(h, "load_owner", return_value=h.Owner(123, 456, "game", "A" * 64)), \
                    patch.object(h, "WindowsGuard", side_effect=h.Refused("wrong foreground")), \
                    patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver")):
                with self.assertRaises(h.Refused):
                    h.main(["--execute", "--owner", "stub-receipt", "--ledger", str(ledger)])
            rows = [json.loads(line) for line in ledger.read_text().splitlines()]
            self.assertEqual(rows[-1]["event"], "controller_session_refused")
            self.assertFalse(rows[-1]["driver_submitted"])

    def test_stdout_failure_after_execution_preserves_truthful_session_end(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-test-", dir=folder) as temporary:
            ledger = Path(temporary) / "stdout-failed.jsonl"
            clock, backend = h.PreviewClock(), Backend()
            with patch.object(h, "load_owner", return_value=h.Owner(123, 456, "game", "A" * 64)), \
                    patch.object(h, "WindowsGuard", return_value=Guard(clock)), patch.object(h, "Clock", return_value=clock), \
                    patch.object(h, "make_vgamepad", return_value=backend), patch("builtins.print", side_effect=OSError("closed stdout")):
                with self.assertRaises(OSError):
                    h.main(["--execute", "--owner", "stub-receipt", "--ledger", str(ledger)])
            rows = [json.loads(line) for line in ledger.read_text().splitlines()]
            self.assertEqual(rows[-1]["event"], "controller_session_end")
            self.assertTrue(rows[-1]["driver_submitted"])
            self.assertTrue(rows[-1]["completed"])
            self.assertEqual(backend.closed, 1)

    def test_dependency_exact_file_hashes_and_import_origin_before_import(self):
        import hashlib
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-dependency-test-", dir=folder) as temporary:
            directory = Path(temporary)
            self.assertTrue(directory.resolve().is_relative_to(folder.resolve()))
            package = directory / "venv" / "Lib" / "site-packages" / "vgamepad"
            interpreter = directory / "venv" / "Scripts" / "python.exe"
            interpreter.parent.mkdir(parents=True)
            interpreter.write_bytes(b"nonexecutable fake interpreter")
            files = {}
            for index, name in enumerate(h.DEPENDENCY_FILES):
                path = package / name
                path.parent.mkdir(parents=True, exist_ok=True)
                data = ("fixture-source-" + str(index)).encode()
                path.write_bytes(data)
                files[name] = (hashlib.sha256(data).hexdigest().upper(), len(data))
            receipt = dict(schema=1, event="bmx_virtual_gamepad_dependency", version="0.1.0",
                           source_sha256=h.DEPENDENCY_ARCHIVE_SHA256, package_root=str(package), python_exe=str(interpreter),
                           files=[dict(relative_path=n, sha256=d, bytes=s) for n, (d, s) in files.items()],
                           setup_py_executed=False, bundled_driver_installer_executed=False)
            path = directory / "dependency.json"
            path.write_text(json.dumps(receipt))
            with patch.object(h, "DEPENDENCY_ROOT", package), patch.object(h, "DEPENDENCY_PYTHON", interpreter), \
                    patch.object(h, "DEPENDENCY_FILES", files), patch.object(sys, "executable", str(interpreter)):
                h.validate_dependency(path)
                for field, bad in (("version", "0.1.3"), ("source_sha256", "0" * 64), ("setup_py_executed", True),
                                   ("bundled_driver_installer_executed", True), ("package_root", str(directory)),
                                   ("python_exe", "other-python"), ("files", receipt["files"][:-1])):
                    changed = dict(receipt, **{field: bad})
                    path.write_text(json.dumps(changed))
                    with self.subTest(field=field), self.assertRaises(h.Refused), \
                            patch.object(h.importlib, "import_module", side_effect=AssertionError("Must not import")):
                        h.make_vgamepad(path)
                path.write_text(json.dumps(receipt))
                first = package / "__init__.py"
                original = first.read_bytes()
                first.write_bytes(b"tampered")
                with self.assertRaises(h.Refused):
                    h.validate_dependency(path)
                first.write_bytes(original)
                extra = package / "__pycache__" / "unchecked.pyc"
                extra.parent.mkdir()
                extra.write_bytes(b"unreviewed cache")
                with self.assertRaises(h.Refused):
                    h.validate_dependency(path)
                extra.unlink()
                with patch.object(h.importlib.util, "find_spec", return_value=types.SimpleNamespace(origin=str(directory / "shadow.py"))), \
                        patch.object(h.importlib, "import_module", side_effect=AssertionError("Origin refused before import")), self.assertRaises(h.Refused):
                    h.make_vgamepad(path)

    def new_gate(self, directory):
        return h.StartGate(directory / "fresh-gate", "a" * 32, h.Owner(123, 456, "fake-owned-game", "B" * 64),
                           "native-y", "C" * 64)

    def gate_payload_read_fixture(self, faults, *, payload=None, persistent=False, guard_issue=None,
                                  directory_denied=False):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-read-retry-", dir=folder) as temporary:
            gate, backend, reads, started = self.new_gate(Path(temporary)), Backend(), [], []

            class RetryClock(h.PreviewClock):
                def sleep(self, seconds):
                    # Exercise the unchanged real60s budget without6000 filesystem polls.
                    super().sleep(30.001 if persistent and reads else seconds)

            clock, test = RetryClock(), self

            class TriggerSink(Sink):
                def write(self, event, **fields):
                    super().write(event, **fields)
                    if event == "controller_start_gate_wait":
                        started.append(clock.now())
                        text = json.dumps(gate.trigger_fields()) if payload is None else payload
                        gate.go.write_text(text)

            sink = TriggerSink()

            class ReadGuard(Guard):
                def check(self):
                    super().check()
                    if reads and guard_issue:
                        raise h.Refused(guard_issue)

            guard = ReadGuard(clock)
            original_read, original_directory = Path.read_bytes, gate.check_directory

            def payload_read(path):
                if path != gate.go:
                    return original_read(path)
                reads.append(clock.now())
                test.assertFalse(any(row["event"] == "controller_report" for row in sink.rows))
                test.assertFalse(any(state.buttons for state in backend.states))
                fault = faults[min(len(reads) - 1, len(faults) - 1)]
                if fault == "deny":
                    raise PermissionError("fake GO payload sharing denial")
                if fault == "other_error":
                    raise OSError("fake non-permission payload error")
                raw = original_read(path)
                if fault == "changed":
                    path.write_bytes(raw + b" ")
                return raw

            def check_directory():
                if started and directory_denied:
                    raise PermissionError("fake gate directory permission denial")
                return original_directory()

            with patch.object(Path, "read_bytes", payload_read), patch.object(gate, "check_directory", check_directory):
                result = h.run(self.short(), guard, lambda: backend, sink, execute=True, clock=clock, start_gate=gate)
            self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))
            self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
            return result, sink, reads, clock.now() - started[0]

    def test_start_gate_transient_payload_permission_denial_waits_neutral_then_validates(self):
        result, sink, reads, elapsed = self.gate_payload_read_fixture(("deny", "deny", "read"))
        self.assertTrue(result["completed"])
        self.assertEqual((len(reads), result["report_count"]), (3, 5))
        go = next(i for i, row in enumerate(sink.rows) if row["event"] == "controller_start_gate_go")
        first = next(i for i, row in enumerate(sink.rows) if row["event"] == "controller_report")
        self.assertLess(go, first)
        self.assertGreaterEqual(elapsed, .02)

    def test_start_gate_persistent_payload_denial_retains_original60s_deadline_and_cleanup(self):
        self.assertEqual(h.START_GATE_LIMIT_MS, 60000)
        result, _, reads, elapsed = self.gate_payload_read_fixture(("deny",), persistent=True)
        self.assertFalse(result["completed"])
        self.assertIn("Start-gate deadline/clock failed", result["issue"])
        self.assertEqual((len(reads), result["report_count"]), (2, 0))
        self.assertGreaterEqual(elapsed, 60)
        self.assertLess(elapsed, 60.01)

    def test_start_gate_payload_denial_still_checks_focus_escape_and_owner_after_read(self):
        for issue in ("Owned game lost foreground", "Escape abort", "Owned creation FILETIME changed"):
            with self.subTest(issue=issue):
                result, _, reads, _ = self.gate_payload_read_fixture(("deny", "read"), guard_issue=issue)
                self.assertFalse(result["completed"])
                self.assertIn(issue, result["issue"])
                self.assertEqual((len(reads), result["report_count"]), (1, 0))

    def test_start_gate_payload_denial_does_not_mask_malformed_mismatch_or_changed_next_read(self):
        wrong = dict(schema=1, event="bmx_virtual_gamepad_go", process_id=123,
                     process_creation_filetime="456", nonce="b" * 32)
        for payload, fault, issue in (("{", "read", "Malformed start trigger JSON"),
                                      (json.dumps(wrong), "read", "nonce mismatch"),
                                      (None, "changed", "changed during read")):
            with self.subTest(issue=issue):
                result, _, reads, _ = self.gate_payload_read_fixture(("deny", fault), payload=payload)
                self.assertFalse(result["completed"])
                self.assertIn(issue, result["issue"])
                self.assertEqual((len(reads), result["report_count"]), (2, 0))

    def test_start_gate_only_payload_permission_error_can_wait(self):
        for directory, fault, issue, count in ((True, "read", "gate directory permission denial", 0),
                                               (False, "other_error", "non-permission payload error", 1)):
            with self.subTest(directory=directory):
                result, _, reads, _ = self.gate_payload_read_fixture((fault,), directory_denied=directory)
                self.assertFalse(result["completed"])
                self.assertIn(issue, result["issue"])
                self.assertEqual((len(reads), result["report_count"]), (count, 0))

    def test_start_gate_neutral_ready_before_go_and_scenario_clock_after_go(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-gate-test-", dir=folder) as temporary:
            gate, backend, sink = self.new_gate(Path(temporary)), Backend(), Sink()
            test = self
            class GateClock(h.PreviewClock):
                triggered = False
                def sleep(self, seconds):
                    super().sleep(seconds)
                    if gate.ready.exists() and not self.triggered:
                        test.assertFalse(any(row["event"] == "controller_report" for row in sink.rows))
                        test.assertFalse(any(state.buttons for state in backend.states))
                        ready = json.loads(gate.ready.read_text())
                        test.assertEqual((ready["event"], ready["process_id"], ready["process_creation_filetime"], ready["nonce"]),
                                         ("bmx_virtual_gamepad_ready", 123, "456", "a" * 32))
                        test.assertTrue(ready["neutral_bootstrap_completed"])
                        pending = gate.path / "go.pending"
                        pending.write_text(json.dumps(gate.trigger_fields()))
                        pending.rename(gate.go)
                        self.triggered = True
            clock = GateClock()
            result = h.run(self.short(), Guard(clock), lambda: backend, sink, execute=True, clock=clock, start_gate=gate)
            self.assertTrue(result["completed"])
            self.assertTrue(clock.triggered)
            go_index = next(i for i, row in enumerate(sink.rows) if row["event"] == "controller_start_gate_go")
            first_report = next(i for i, row in enumerate(sink.rows) if row["event"] == "controller_report")
            self.assertLess(go_index, first_report)
            self.assertEqual(sink.rows[first_report]["elapsed_ms"], 0)
            self.assertEqual((result["report_count"], backend.closed), (5, 1))

    def test_start_gate_refuses_preexisting_directory_bad_nonce_and_path_escape(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-gate-test-", dir=folder) as temporary:
            directory = Path(temporary)
            self.new_gate(directory)
            with self.assertRaises(h.Refused):
                self.new_gate(directory)
            for nonce in ("a" * 31, "g" * 32, "", None):
                with self.subTest(nonce=nonce), self.assertRaises(h.Refused):
                    h.StartGate(directory / "unused", nonce, h.Owner(1, 2, "fake", "A" * 64), "native-y", "C" * 64)
            with self.assertRaises(h.Refused):
                h.StartGate(h.WORKSPACE / "outside-build-refused", "a" * 32, h.Owner(1, 2, "fake", "A" * 64), "native-y", "C" * 64)

    def test_start_gate_preexisting_ready_or_go_before_wait_sends_no_buttons(self):
        folder = h.WORKSPACE / "build" / "bmx"
        for filename in ("ready.json", "go.json"):
            with self.subTest(filename=filename), tempfile.TemporaryDirectory(prefix="virtual-pad-gate-test-", dir=folder) as temporary:
                gate = self.new_gate(Path(temporary))
                (gate.path / filename).write_text("{}")
                clock, backend, sink = h.PreviewClock(), Backend(), Sink()
                result = h.run(self.short(), Guard(clock), lambda: backend, sink, execute=True, clock=clock, start_gate=gate)
                self.assertFalse(result["completed"])
                self.assertEqual(result["report_count"], 0)
                self.assertFalse(any(state.buttons for state in backend.states))
                self.assertEqual((backend.states[-1], backend.closed), (h.NEUTRAL, 1))

    def test_start_gate_malformed_oversize_wrong_owner_or_nonce_cleans_up(self):
        folder = h.WORKSPACE / "build" / "bmx"
        for fault in ("json", "oversize", "schema", "pid", "filetime", "nonce", "event", "extra"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory(prefix="virtual-pad-gate-test-", dir=folder) as temporary:
                gate = self.new_gate(Path(temporary))
                class TriggerSink(Sink):
                    def write(self, event, **fields):
                        super().write(event, **fields)
                        if event == "controller_start_gate_wait":
                            value = gate.trigger_fields()
                            for field, name, bad in (("schema", "schema", True), ("pid", "process_id", 999),
                                                     ("filetime", "process_creation_filetime", "0456"),
                                                     ("nonce", "nonce", "b" * 32), ("event", "event", "wrong"),
                                                     ("extra", "extra", True)):
                                if fault == field:
                                    value[name] = bad
                            gate.go.write_text("{" if fault == "json" else "x" * 8193 if fault == "oversize" else json.dumps(value))
                clock, backend, sink = h.PreviewClock(), Backend(), TriggerSink()
                result = h.run(self.short(), Guard(clock), lambda: backend, sink, execute=True, clock=clock, start_gate=gate)
                self.assertFalse(result["completed"])
                self.assertEqual(result["report_count"], 0)
                self.assertFalse(any(state.buttons for state in backend.states))
                self.assertEqual((backend.states[-1], backend.closed), (h.NEUTRAL, 1))

    def test_start_gate_timeout_focus_escape_and_owner_abort_before_scenario(self):
        folder = h.WORKSPACE / "build" / "bmx"
        for fault in ("timeout", "Escape abort", "Owned game lost foreground", "Owned creation FILETIME changed"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory(prefix="virtual-pad-gate-test-", dir=folder) as temporary:
                gate, clock, backend, sink = self.new_gate(Path(temporary)), h.PreviewClock(), Backend(), Sink()
                guard = Guard(clock) if fault == "timeout" else Guard(clock, .05, fault)
                with patch.object(h, "START_GATE_LIMIT_MS", 60):
                    result = h.run(self.short(), guard, lambda: backend, sink, execute=True, clock=clock, start_gate=gate)
                self.assertFalse(result["completed"])
                self.assertEqual(result["report_count"], 0)
                self.assertFalse(any(state.buttons for state in backend.states))
                self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))

    def test_start_gate_requires_execute_and_both_cli_arguments_before_backend(self):
        with patch.object(h, "make_vgamepad", side_effect=AssertionError("No device")):
            for arguments in (["--start-gate", "unused"], ["--start-nonce", "a" * 32],
                              ["--start-gate", "unused", "--start-nonce", "a" * 32]):
                with self.subTest(arguments=arguments), self.assertRaises(SystemExit):
                    h.main(arguments)
        clock = h.PreviewClock()
        with self.assertRaises(h.Refused):
            h.run(self.short(), Guard(clock), lambda: self.fail("No device"), Sink(), clock=clock, start_gate=object())


class NeutralWindowTests(unittest.TestCase):
    """Fixed-window fake-clock tests; no driver import, device or game."""
    def test_exact_fixed_window_has1001_scheduled_zero_reports_and_cleanup(self):
        events = h.scenarios()["neutral-window-20s"]
        self.assertEqual(events, (h.Event(0, h.NEUTRAL), h.Event(20000, h.NEUTRAL)))
        h.validate_timeline(events)
        clock, backend, sink = h.PreviewClock(), Backend(), Sink()
        guard = Guard(clock)
        result = h.run(events, guard, lambda: backend, sink, execute=True, clock=clock)
        self.assertTrue(result["completed"])
        self.assertEqual((result["report_count"], result["driver_report_count"]), (1001, 1001))
        reports = [row for row in sink.rows if row["event"] == "controller_report"]
        self.assertEqual([row["planned_ms"] for row in reports], list(range(0, 20001, 20)))
        self.assertTrue(all(row["state"] == h.asdict(h.NEUTRAL) and row["raw_report_hex"] == "00" * 12 for row in reports))
        self.assertEqual(backend.states[:3], [h.State(left_x=1 / 32767), h.NEUTRAL, h.NEUTRAL])
        self.assertEqual(backend.states[3:], [h.NEUTRAL] * 1002)  # Scheduled1001 plus final release.
        self.assertEqual((backend.prime_count, backend.closed, guard.closed), (1, 1, 1))
        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
        self.assertIsNone(result["input_consumed"])
        self.assertIsNone(result["native_quality"])

    def test_only_exact_neutral_tuple_can_exceed_existing6s_limit(self):
        self.assertEqual((h.PERIOD_MS, h.POLL_MS, h.MAX_LATE_MS, h.MAX_DURATION_MS), (20, 10, 120, 6000))
        self.assertEqual((h.BOOTSTRAP_LIMIT_MS, h.START_GATE_LIMIT_MS), (1000, 60000))
        invalid = [
            (h.Event(0, h.NEUTRAL), h.Event(20, h.State(h.A)), h.Event(20000, h.NEUTRAL)),
            (h.Event(0, h.NEUTRAL), h.Event(10000, h.State(right_x=1)), h.Event(20000, h.NEUTRAL)),
            (h.Event(0, h.NEUTRAL), h.Event(20, h.State(left_trigger=1)), h.Event(20000, h.NEUTRAL)),
            (h.Event(0, h.NEUTRAL), h.Event(20000, h.State(h.Y))),
            (h.Event(0, h.NEUTRAL), h.Event(10000, h.NEUTRAL), h.Event(20000, h.NEUTRAL)),
            (h.Event(0, h.NEUTRAL), h.Event(6020, h.NEUTRAL)),
            (h.Event(0, h.NEUTRAL), h.Event(19980, h.NEUTRAL)),
            (h.Event(0, h.NEUTRAL), h.Event(20020, h.NEUTRAL)),
            [h.Event(0, h.NEUTRAL), h.Event(20000, h.NEUTRAL)],
        ]
        for events in invalid:
            with self.subTest(events=events), self.assertRaises(h.Refused):
                h.run(events, h.DryGuard(), lambda: self.fail("Invalid window reached backend"), Sink(), clock=h.PreviewClock())
        self.assertEqual(h.scenarios()["neutral-follow"], (h.Event(0, h.NEUTRAL), h.Event(6000, h.NEUTRAL)))
        old_names = {"neutral-follow", "native-y", "native-b", "ground-pump", "ground-pump-switch",
                     "equipment-switch", "bunnyhop-tailwhip", "quickhop-barspin"}
        self.assertEqual(set(h.scenarios()) - {"neutral-window-20s"}, old_names)
        for name in old_names:
            self.assertLessEqual(h.scenarios()[name][-1].at_ms, 6000)

    def test_default512_and_fixed1200_ledgers_are_bounded_without_rowcap_flag(self):
        events = h.scenarios()["neutral-window-20s"]
        with tempfile.TemporaryDirectory(prefix="neutral-window-ledger-test-") as temporary:
            for name, factory, limit in (("default", h.Ledger, 512),
                                         ("window", lambda path: h.NeutralWindowLedger(path, events), 1200)):
                path = Path(temporary) / (name + ".jsonl")
                ledger = factory(path)
                try:
                    for _ in range(limit):
                        ledger.write("bounded_test_row")
                    with self.assertRaises(h.Refused):
                        ledger.write("overflow_must_not_be_written")
                finally:
                    ledger.close()
                rows = [json.loads(line) for line in path.read_text().splitlines()]
                self.assertEqual(len(rows), limit)
                self.assertTrue(all(row["event"] == "bounded_test_row" for row in rows))
            refused = Path(temporary) / "wrong-window.jsonl"
            with self.assertRaises(h.Refused):
                h.NeutralWindowLedger(refused, h.scenarios()["neutral-follow"])
            self.assertFalse(refused.exists())

    def test_slow_bounded_bootstrap_and1001_reports_fit_fixed1200_budget(self):
        class SlowNeutral(Backend):
            reads = 0
            def readback(self):
                self.reads += 1
                return dict(available=True, slot=0, neutral=self.reads >= 49,
                            raw_report_hex="00" * 12 if self.reads >= 49 else "01" * 12)
        events = h.scenarios()["neutral-window-20s"]
        with tempfile.TemporaryDirectory(prefix="neutral-window-slow-test-") as temporary:
            path = Path(temporary) / "window.jsonl"
            ledger = h.NeutralWindowLedger(path, events)
            clock, backend = h.PreviewClock(), SlowNeutral()
            try:
                ledger.write("controller_session_start")
                result = h.run(events, Guard(clock), lambda: backend, ledger, execute=True, clock=clock)
            finally:
                ledger.close()
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertTrue(result["completed"])
            self.assertEqual((result["driver_report_count"], backend.reads), (1001, 50))
            self.assertGreater(len(rows), 1100)
            self.assertLessEqual(len(rows), 1200)
            self.assertEqual(rows[-2]["event"], "controller_neutral_release")
            self.assertEqual(rows[-1]["event"], "controller_session_end")

    def test_new_window_ledger_overflow_still_releases_and_disconnects(self):
        events = h.scenarios()["neutral-window-20s"]
        with tempfile.TemporaryDirectory(prefix="neutral-window-overflow-test-") as temporary:
            path = Path(temporary) / "overflow.jsonl"
            ledger = h.NeutralWindowLedger(path, events)
            clock, backend = h.PreviewClock(), Backend()
            guard = Guard(clock)
            try:
                for _ in range(240):
                    ledger.write("constructed_padding")
                result = h.run(events, guard, lambda: backend, ledger, execute=True, clock=clock)
            finally:
                ledger.close()
            self.assertFalse(result["completed"])
            self.assertIn("Bounded ledger row limit", result["issue"])
            self.assertGreater(result["report_count"], 301)
            self.assertLess(result["report_count"], 1001)
            self.assertEqual(len(path.read_text().splitlines()), 1200)
            self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))
            self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])

    def test_existing_abort_guards_remain_live_after6s_in_new_window(self):
        for issue in ("Escape abort", "Owned game lost foreground", "Owned creation FILETIME changed",
                      "Isolated game/runtime files changed", "Owned runtime module path changed"):
            with self.subTest(issue=issue):
                clock, backend, sink = h.PreviewClock(), Backend(), Sink()
                guard = Guard(clock, 12.05, issue)
                result = h.run(h.scenarios()["neutral-window-20s"], guard, lambda: backend, sink, execute=True, clock=clock)
                self.assertFalse(result["completed"])
                self.assertIn(issue, result["issue"])
                self.assertGreater(result["report_count"], 301)
                self.assertLess(result["report_count"], 1001)
                self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])

    def test_late_or_reversed_nonfinite_clocks_abort_after6s_without_guard_relaxation(self):
        for fault in ("late", -1, float("nan"), float("inf")):
            with self.subTest(fault=fault):
                class BrokenLater(h.PreviewClock):
                    def sleep(self, seconds):
                        super().sleep(seconds)
                        if self.value >= 12:
                            self.value = self.value + .2 if fault == "late" else fault
                clock, backend, sink = BrokenLater(), Backend(), Sink()
                guard = Guard(clock)
                result = h.run(h.scenarios()["neutral-window-20s"], guard, lambda: backend, sink, execute=True, clock=clock)
                self.assertFalse(result["completed"])
                self.assertIn("120ms" if fault == "late" else "clock", result["issue"])
                self.assertGreater(result["report_count"], 301)
                self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))

    def test_late_driver_failure_retains_unknown_delivery_and_still_cleans_up(self):
        clock, backend, sink = h.PreviewClock(), Backend(fail_at=605), Sink()
        guard = Guard(clock)
        result = h.run(h.scenarios()["neutral-window-20s"], guard, lambda: backend, sink, execute=True, clock=clock)
        self.assertFalse(result["completed"])
        self.assertIn("fake driver failure", result["issue"])
        self.assertGreater(result["report_count"], 301)
        self.assertLess(result["report_count"], 1001)
        self.assertIsNone(result["input_consumed"])
        self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))

    def test_cli_selects_extended_ledger_only_for_new_name_and_dry_run_never_imports_driver(self):
        folder = h.WORKSPACE / "build" / "bmx"
        real_default, real_window = h.Ledger, h.NeutralWindowLedger
        for name, count, limit in (("neutral-window-20s", 1001, 1200), ("neutral-follow", 301, 512)):
            with self.subTest(name=name), tempfile.TemporaryDirectory(prefix="neutral-window-cli-test-", dir=folder) as temporary:
                path = Path(temporary) / "dry.jsonl"
                with patch.object(h, "Ledger", wraps=real_default) as default, \
                        patch.object(h, "NeutralWindowLedger", wraps=real_window) as window, \
                        patch.object(h, "WindowsGuard", side_effect=AssertionError("No game inspection")), \
                        patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver import")), patch("builtins.print"):
                    self.assertEqual(h.main(["--scenario", name, "--ledger", str(path)]), 0)
                self.assertEqual((window.call_count, default.call_count), (1, 0) if count == 1001 else (0, 1))
                rows = [json.loads(line) for line in path.read_text().splitlines()]
                self.assertEqual(rows[-1]["report_count"], count)
                self.assertLessEqual(len(rows), limit)
                self.assertTrue(rows[0]["timing_simulated"])
                self.assertTrue(all(row.get("driver_submitted") is not True for row in rows))

    def test_actual_start_gate_binds_new_scenario_before1001_reports_with_same60s_limit(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="neutral-window-gate-test-", dir=folder) as temporary:
            gate = h.StartGate(Path(temporary) / "gate", "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                               "neutral-window-20s", "C" * 64)
            test = self
            class GoSink(Sink):
                def write(self, event, **fields):
                    super().write(event, **fields)
                    if event == "controller_start_gate_wait":
                        ready = json.loads(gate.ready.read_text())
                        test.assertEqual((ready["scenario"], ready["wait_limit_ms"]), ("neutral-window-20s", 60000))
                        test.assertTrue(ready["neutral_bootstrap_completed"])
                        test.assertFalse(any(row["event"] == "controller_report" for row in self.rows))
                        pending = gate.path / "go.pending"
                        pending.write_text(json.dumps(gate.trigger_fields()))
                        pending.rename(gate.go)
            clock, backend, sink = h.PreviewClock(), Backend(), GoSink()
            result = h.run(h.scenarios()["neutral-window-20s"], Guard(clock), lambda: backend, sink,
                           execute=True, clock=clock, start_gate=gate)
            self.assertTrue(result["completed"])
            self.assertEqual((result["report_count"], backend.closed, h.START_GATE_LIMIT_MS), (1001, 1, 60000))
            go = next(i for i, row in enumerate(sink.rows) if row["event"] == "controller_start_gate_go")
            first = next(i for i, row in enumerate(sink.rows) if row["event"] == "controller_report")
            self.assertLess(go, first)
            self.assertEqual(sink.rows[first]["elapsed_ms"], 0)


class PinnedPad:
    """A fake vgamepad target recording every SDK call the real backend mapping makes."""
    def __init__(self):
        self._devicep = self._busp = 1
        self.calls = []
    def __del__(self): pass
    def reset(self): self.calls.append(["reset"])
    def press_button(self, button): self.calls.append(["button", button])
    def left_joystick_float(self, x_value_float, y_value_float): self.calls.append(["left", x_value_float, y_value_float])
    def right_joystick_float(self, x_value_float, y_value_float): self.calls.append(["right", x_value_float, y_value_float])
    def left_trigger_float(self, value_float): self.calls.append(["lt", value_float])
    def right_trigger_float(self, value_float): self.calls.append(["rt", value_float])
    def update(self): self.calls.append(["update"])


PINNED_BUTTON_NAMES = ("A", "B", "Y", "LEFT_SHOULDER", "RIGHT_SHOULDER", "RIGHT_THUMB", "START")


def scenario_report_digest(events):
    """One SHA-256 over everything a scenario sends: its timeline, each scheduled report's
    time, state and raw bytes (struct-packed fake backend, executed), every state the backend
    saw including bootstrap and release, and every SDK call the real mapping makes (dry run)."""
    clock, backend, sink = h.PreviewClock(), Backend(), Sink()
    result = h.run(events, Guard(clock), lambda: backend, sink, execute=True, clock=clock)
    assert result["completed"], result
    reports = [[row["planned_ms"], row["elapsed_ms"], row["state"], row["raw_report_hex"]]
               for row in sink.rows if row["event"] == "controller_report"]
    module = types.SimpleNamespace(VX360Gamepad=PinnedPad, XUSB_BUTTON=types.SimpleNamespace(
        **{"XUSB_GAMEPAD_" + name: name for name in PINNED_BUTTON_NAMES}))
    real = h.VGamepadBackend(module, probe=object())
    dry_clock = h.PreviewClock()
    result = h.run(events, Guard(dry_clock), lambda: real, Sink(), clock=dry_clock)
    assert result["completed"], result
    payload = dict(timeline=[h.asdict(event) for event in events], reports=reports,
                   states=[h.asdict(state) for state in backend.states], sdk=real.pad.calls)
    text = json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return len(reports), hashlib.sha256(text.encode()).hexdigest().upper()


class FakePath:
    def __init__(self, value): self.value = PureWindowsPath(str(value))
    def __str__(self): return str(self.value)
    def __truediv__(self, child): return FakePath(self.value / child)
    def __eq__(self, other): return str(self).lower() == str(other).lower()
    @property
    def parent(self): return FakePath(self.value.parent)
    def is_symlink(self): return False
    def is_junction(self): return False
    def stat(self):
        return types.SimpleNamespace(st_dev=1, st_ino=2, st_size=3, st_mtime_ns=4, st_ctime_ns=5)


class Kernel:
    def __init__(self, clock):
        self.clock, self.calls, self.closed = clock, [], []
        self.runtime = str(FakePath(h.EXACT_WORKSPACE) / 'build' / 'bmx-game' / 'ReSkate.dll')
        self.target, self.foreign = 0x123456780000, 0x123456790000
        self.entries = [self.foreign, self.target]
        self.open_fail = self.enum_fail = self.name_fail = self.info_fail = False
        self.required = self.name_count = None
        self.image_size, self.base_delta, self.enum_cost = 4096, 0, 0
        for name in ('OpenProcess', 'CloseHandle', 'GetExitCodeProcess', 'GetProcessTimes',
                     'QueryFullProcessImageNameW', 'K32EnumProcessModulesEx',
                     'K32GetModuleFileNameExW', 'K32GetModuleInformation'):
            setattr(self, name, Call(getattr(self, '_' + name)))

    def _OpenProcess(self, rights, inherit, pid):
        self.calls.append(('open', rights, inherit, pid))
        return 0 if self.open_fail else 731

    def _CloseHandle(self, handle): self.closed.append(handle); return 1
    def _GetExitCodeProcess(self, handle, code): code._obj.value = 259; return 1
    def _GetProcessTimes(self, handle, created, *rest):
        created._obj.dwLowDateTime, created._obj.dwHighDateTime = 456, 0
        return 1
    def _QueryFullProcessImageNameW(self, handle, flags, name, length):
        name.value = str(FakePath(h.EXACT_WORKSPACE) / 'build' / 'bmx-game' / 'Skate.exe')
        return 1

    def _K32EnumProcessModulesEx(self, handle, modules, size, needed, flags):
        self.calls.append(('enum', handle, size, flags))
        self.clock.value += self.enum_cost
        needed._obj.value = len(self.entries) * ctypes.sizeof(h.wintypes.HMODULE) if self.required is None else self.required
        for index, module in enumerate(self.entries[:512]): modules[index] = module
        return not self.enum_fail

    def _K32GetModuleFileNameExW(self, handle, module, name, size):
        self.calls.append(('name', handle, module, size))
        if self.name_fail: return 0
        name.value = self.runtime if module == self.target else r'C:\Windows\System32\other.dll'
        return len(name.value) if self.name_count is None else self.name_count

    def _K32GetModuleInformation(self, handle, module, info, size):
        self.calls.append(('info', handle, module, size))
        info._obj.lpBaseOfDll = module + self.base_delta
        info._obj.SizeOfImage = self.image_size
        return not self.info_fail


class ModuleQueryTests(unittest.TestCase):
    def context(self, kernel, clock):
        owner = h.Owner(123, 456, str(FakePath(h.EXACT_WORKSPACE) / 'build' / 'bmx-game' / 'Skate.exe'), 'A' * 64)
        user = types.SimpleNamespace(GetAsyncKeyState=Call(lambda key: 0),
                                     GetForegroundWindow=Call(lambda: 1),
                                     GetWindowThreadProcessId=Call(lambda window, pid: self.foreground(pid)))
        dll = lambda name, **kwargs: kernel if name == 'kernel32' else user
        return owner, patch.multiple(h, WORKSPACE=FakePath(h.EXACT_WORKSPACE), Path=FakePath,
                                     sha256=lambda path: 'A' * 64 if str(path).endswith('ReSkate.dll') else h.GAME_SHA256), \
            patch.object(h.ctypes, 'WinDLL', side_effect=dll), patch.object(h.time, 'monotonic', side_effect=lambda: clock.value)

    @staticmethod
    def foreground(pid): pid._obj.value = 123; return 1

    def construct(self, kernel, clock):
        owner, files, dlls, timer = self.context(kernel, clock)
        with files, dlls, timer: return h.WindowsGuard(owner)

    def test_retained_handle_stronger_rights_exact_path_image_and_x64_base(self):
        clock = types.SimpleNamespace(value=1.0); kernel = Kernel(clock)
        guard = self.construct(kernel, clock)
        self.assertEqual(kernel.calls[0], ('open', 0x0410, False, 123))
        self.assertEqual([row for row in kernel.calls if row[0] == 'enum'], [('enum', 731, 4096, 3)])
        self.assertEqual([row for row in kernel.calls if row[0] == 'info'], [('info', 731, kernel.target, 24)])
        self.assertEqual(guard.kernel.K32EnumProcessModulesEx.restype, h.wintypes.BOOL)
        self.assertEqual(len(guard.kernel.K32EnumProcessModulesEx.argtypes), 5)
        self.assertEqual(kernel.closed, [])
        guard.close(); guard.close()
        self.assertEqual(kernel.closed, [731])  # No HMODULE is closed.

    def test_access_denial_has_no_fallback_or_resource_to_close(self):
        clock = types.SimpleNamespace(value=1.0); kernel = Kernel(clock); kernel.open_fail = True
        with self.assertRaises(h.Refused): self.construct(kernel, clock)
        self.assertEqual(kernel.calls, [('open', 0x0410, False, 123)])
        self.assertEqual(kernel.closed, [])

    def test_missing_exports_or_wrong_abi_fail_before_process_open(self):
        for name in ('K32EnumProcessModulesEx', 'K32GetModuleFileNameExW', 'K32GetModuleInformation'):
            with self.subTest(name=name):
                clock = types.SimpleNamespace(value=1.0); kernel = Kernel(clock); delattr(kernel, name)
                with self.assertRaises(AttributeError): self.construct(kernel, clock)
                self.assertEqual(kernel.calls, []); self.assertEqual(kernel.closed, [])
        clock = types.SimpleNamespace(value=1.0); kernel = Kernel(clock)
        class WrongInfo(ctypes.Structure): _fields_ = [('wrong', ctypes.c_uint32)]
        with patch.object(h.WindowsGuard, 'ModuleInfo', WrongInfo), self.assertRaises(h.Refused):
            self.construct(kernel, clock)
        self.assertEqual(kernel.calls, [])

    def test_enum_failure_empty_overflow_misalignment_or_null_entry_close_owned_handle(self):
        for fault in ('failure', 'empty', 'overflow', 'unaligned', 'null'):
            with self.subTest(fault=fault):
                clock = types.SimpleNamespace(value=1.0); kernel = Kernel(clock)
                if fault == 'failure': kernel.enum_fail = True
                if fault == 'empty': kernel.required = 0
                if fault == 'overflow': kernel.required = 4104
                if fault == 'unaligned': kernel.required = 9
                if fault == 'null': kernel.entries = [0]
                with self.assertRaises(h.Refused): self.construct(kernel, clock)
                self.assertEqual(kernel.closed, [731])
                self.assertFalse(any(row[0] in ('name', 'info') for row in kernel.calls))

    def test_exact_512_modules_are_bounded_and_accepted(self):
        clock = types.SimpleNamespace(value=1.0); kernel = Kernel(clock)
        kernel.entries = [kernel.foreign] * 511 + [kernel.target]
        guard = self.construct(kernel, clock)
        self.assertEqual(sum(row[0] == 'name' for row in kernel.calls), 512)
        guard.close(); self.assertEqual(kernel.closed, [731])

    def test_path_failure_truncation_absence_and_image_failure_refuse(self):
        for fault in ('name_failure', 'truncated', 'absent', 'info_failure', 'zero_image', 'base_changed'):
            with self.subTest(fault=fault):
                clock = types.SimpleNamespace(value=1.0); kernel = Kernel(clock)
                if fault == 'name_failure': kernel.name_fail = True
                if fault == 'truncated': kernel.name_count = 32768
                if fault == 'absent': kernel.entries = [kernel.foreign]
                if fault == 'info_failure': kernel.info_fail = True
                if fault == 'zero_image': kernel.image_size = 0
                if fault == 'base_changed': kernel.base_delta = 0x100000000
                with self.assertRaises(h.Refused): self.construct(kernel, clock)
                self.assertEqual(kernel.closed, [731])

    def test_current_query_has_no_cached_success_after_module_disappears(self):
        clock = types.SimpleNamespace(value=1.0); kernel = Kernel(clock)
        guard = self.construct(kernel, clock)
        kernel.entries = [kernel.foreign]
        with self.assertRaises(h.Refused): guard._runtime_loaded()
        self.assertEqual(sum(row[0] == 'enum' for row in kernel.calls), 2)
        guard.close(); self.assertEqual(kernel.closed, [731])

    def test_existing_200ms_cadence_uses_query_start_not_completion(self):
        clock = types.SimpleNamespace(value=1.0); kernel = Kernel(clock); kernel.enum_cost = .09
        owner, files, dlls, timer = self.context(kernel, clock)
        with files, dlls, timer:
            guard = h.WindowsGuard(owner)
            self.assertEqual(guard.last_modules, 1.0)
            clock.value = 1.199; guard.check()
            self.assertEqual(sum(row[0] == 'enum' for row in kernel.calls), 1)
            clock.value = 1.201; guard.check()
            self.assertEqual(sum(row[0] == 'enum' for row in kernel.calls), 2)
            self.assertEqual(guard.last_modules, 1.201)
            kernel.enum_fail = True; clock.value = 1.402
            with self.assertRaises(h.Refused): guard.check()
            self.assertEqual(guard.last_modules, 1.201)
            guard.close()
        self.assertEqual(kernel.closed, [731])


# Computed from driver B0B78C74 (before TOOL-1(b) and TOOL-2) by scenario_report_digest and
# dry_run_ledger_digest. A change to any of the nine scenarios' reports, their SDK calls or their
# dry-run ledger rows fails here.
PINNED_SCENARIO_REPORTS = {
    "neutral-follow": (301, "E9D4D82BA1DCD220316C2FEF2EE8F012481EEF2DE11D9100280DC80FE131A03A"),
    "neutral-window-20s": (1001, "A38DD2FA0BA983F9A754739AE8EF5F954B5240586B8B557B5B3B6B7E6EBC61D8"),
    "native-y": (181, "F0BB9F1D4A7C44BFBDEBB0C0DD63FE9ED17CBCB14A76AEB171FB4F7C17DDA4DE"),
    "native-b": (61, "976D01D2B7B9B2607A74D909B7D51B906431482F29B3DB5567A937373BCE51AF"),
    "ground-pump": (161, "2D120D24B5CD932B304229F4B33C182F613E4DA12F507E730ACA4C70455BBB9D"),
    "ground-pump-switch": (201, "64549B04DF7B6079D8D7FBE05F8B28C561FA8EFEF413CA48C2D51128B2F8243E"),
    "equipment-switch": (221, "B0ECCA451F37B8C428EF4F2F619C1D8D20889252F505E02E324CD99DB6D47E63"),
    "bunnyhop-tailwhip": (271, "0F5FC0F8B427A8C4872B91BC7824E0386221DFEFF3A2AEC901CE9AE751AAEA9D"),
    "quickhop-barspin": (261, "C2D01F0D9D9C6EB351BD025DF6AF510150F5D5FA670CB3501A9A41B476843A73"),
}
PINNED_DRY_RUN_LEDGERS = {
    "neutral-follow": (305, "21827719FC0AF487BB9DDD0CEED77B4D6D19A2788BB89C5CCDF891F02F362585"),
    "neutral-window-20s": (1005, "049E3B11421A818C2232FD8EA94F1C873D9792B87C374A1DAEB37749A62F1EAB"),
    "native-y": (185, "89AB93EDFDACAB15EDC9F9BAB01F596AF3047EBCA6D2A306FA10A4BB88CD423F"),
    "native-b": (65, "BDFB0C4D65618B5A7FA2FBB5F5868BE6E57D356DB233227C65BDDBCCC636AEF2"),
    "ground-pump": (165, "EE8B353112B558A715A84144F7A6DED3A7823C774AC0BE9061C36D80C28BF01B"),
    "ground-pump-switch": (205, "EA3604D35E4573C2CC3348D5CF4EDB646244970AA3387A4C9DD74F15E0EBD85D"),
    "equipment-switch": (225, "858C50A99E2F57A955CC631ECCD5CED9F8FDB03E120641E523CAD8E8463020F6"),
    "bunnyhop-tailwhip": (275, "315B111E996DFEE2425C92439B11CB4B555DF4E4763A744C82F1864EEB1AF787"),
    "quickhop-barspin": (265, "9B1F2677FF7ACD639C0EEF22AAF26A4190E8C4ACF1731DBB6012A315787CDC32"),
}
LEDGER_VOLATILE_FIELDS = ("utc", "host_monotonic_ns", "source_sha256")


def dry_run_ledger_digest(name, directory):
    path = Path(directory) / (name + ".jsonl")
    with patch("builtins.print"):
        code = h.main(["--scenario", name, "--ledger", str(path)])
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    stable = [{key: value for key, value in row.items() if key not in LEDGER_VOLATILE_FIELDS} for row in rows]
    text = json.dumps(stable, sort_keys=True, separators=(",", ":"))
    return code, len(rows), hashlib.sha256(text.encode()).hexdigest().upper()


def reports_of(sink):
    return [row for row in sink.rows if row["event"] == "controller_report"]


def raw_hex(state):
    return struct.pack("<HBBhhhh", state.buttons, round(state.left_trigger * 255), round(state.right_trigger * 255),
                       round(state.left_x * 32767), round(state.left_y * 32767), round(state.right_x * 32767),
                       round(state.right_y * 32767)).hex()


def real_check_guard(clock, fault=None, after_s=None):
    """The actual WindowsGuard.check and close bodies over fake Win32 metadata. From after_s on
    the clock, a fault is a real Escape key held or a real foreground window of another process."""
    guard = h.WindowsGuard.__new__(h.WindowsGuard)
    guard.owner = h.Owner(123, 456, "isolated-game", "A" * 64)
    guard.handle, guard.last_modules, guard.file_tokens = 9, 0, (1,)
    guard._file_tokens = lambda: (1,)
    guard._runtime_loaded = lambda: None
    keys = []
    active = lambda: fault is not None and clock.now() >= after_s

    def key_state(key):
        keys.append(key)
        return 0x8000 if fault == "escape" and active() else 0

    def foreground(window, pid):
        pid._obj.value = 999 if fault == "focus" and active() else 123
        return 1

    def exited(handle, code):
        code._obj.value = 259
        return 1

    def created(handle, value, *rest):
        value._obj.dwLowDateTime, value._obj.dwHighDateTime = 456, 0
        return 1

    def path(handle, flags, name, length):
        name.value = "isolated-game"
        return 1

    guard.user = types.SimpleNamespace(GetAsyncKeyState=key_state, GetForegroundWindow=lambda: 1,
                                      GetWindowThreadProcessId=foreground)
    guard.kernel = types.SimpleNamespace(GetExitCodeProcess=exited, GetProcessTimes=created,
                                        QueryFullProcessImageNameW=path, CloseHandle=lambda handle: 1)
    return guard, keys


class ExistingScenarioPinTests(unittest.TestCase):
    """The nine scenarios that predate TOOL-1(b) and TOOL-2 send exactly what they sent before."""
    def test_existing_scenario_reports_and_sdk_calls_are_byte_identical(self):
        self.assertEqual(set(h.scenarios()), set(PINNED_SCENARIO_REPORTS))
        for name, pinned in PINNED_SCENARIO_REPORTS.items():
            with self.subTest(name=name):
                self.assertEqual(scenario_report_digest(h.scenarios()[name]), pinned)
                self.assertEqual(h.scenario_timeline(name), h.scenarios()[name])

    def test_existing_scenario_dry_run_ledgers_are_unchanged(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-pin-test-", dir=folder) as temporary:
            for name, (rows, digest) in PINNED_DRY_RUN_LEDGERS.items():
                with self.subTest(name=name):
                    self.assertEqual(dry_run_ledger_digest(name, temporary), (0, rows, digest))

    def test_existing_limits_and_ledger_bounds_are_unchanged(self):
        self.assertEqual((h.PERIOD_MS, h.POLL_MS, h.MAX_LATE_MS, h.MAX_DURATION_MS), (20, 10, 120, 6000))
        self.assertEqual((h.BOOTSTRAP_LIMIT_MS, h.START_GATE_LIMIT_MS), (1000, 60000))
        self.assertEqual(h.ALLOWED_BUTTONS, h.A | h.B | h.Y | h.LB | h.RB | h.R3)
        self.assertEqual(h.Ledger.row_limit, 512)
        self.assertEqual(h.scenario_names()[:len(h.scenarios())], tuple(h.scenarios()))


class PedalLeadTests(unittest.TestCase):
    """The DEC-6 default stays unset unless a trial supplies an explicit lead."""
    def test_lead_is_one_unset_literal_in_tracked_source(self):
        self.assertIsNone(h.PEDAL_LEAD_MS)
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertEqual(re.findall(r"(?m)^PEDAL_LEAD_MS = .*$", source), ["PEDAL_LEAD_MS = None"])
        self.assertEqual((h.PEDAL_LEAD_MIN_MS, h.PEDAL_HOLD_MS, h.PEDAL_END_MS), (500, 1000, 6000))

    def test_every_lead_scenario_refuses_while_unset_and_others_still_resolve(self):
        self.assertEqual(h.LEAD_SCENARIO_NAMES,
                         ("pedal-straight", "ride-10s", "ride-s01-30s", "ride-steer-brake", "coast-long"))
        with patch.object(h, "PEDAL_LEAD_MS", None):
            for name in h.LEAD_SCENARIO_NAMES:
                with self.subTest(name=name), self.assertRaisesRegex(h.Refused, "PEDAL_LEAD_MS is unset.*DEC-6"):
                    h.scenario_timeline(name)
            self.assertEqual(set(h.tool_scenarios()), {"neutral-window-30s", "pause-menu-20s"})
            for name in set(h.scenario_names()) - set(h.LEAD_SCENARIO_NAMES):
                h.validate_timeline(h.scenario_timeline(name))
        with self.assertRaises(h.Refused):
            h.scenario_timeline("pedal-straight-unknown")

    def test_cli_refuses_lead_scenarios_before_owner_ledger_game_or_device(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-lead-test-", dir=folder) as temporary:
            path = Path(temporary) / "refused.jsonl"
            for name in h.LEAD_SCENARIO_NAMES:
                for argv in (["--scenario", name, "--ledger", str(path)],
                             ["--execute", "--owner", "stub-receipt", "--scenario", name, "--ledger", str(path)]):
                    with self.subTest(argv=argv), \
                            patch.object(h, "load_owner", side_effect=AssertionError("No owner read")), \
                            patch.object(h, "WindowsGuard", side_effect=AssertionError("No game inspection")), \
                            patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver import")), \
                            self.assertRaisesRegex(h.Refused, "PEDAL_LEAD_MS is unset"):
                        h.main(argv)
                    self.assertFalse(path.exists())

    def test_lead_must_be_whole_periods_from_500_to_4980ms(self):
        for bad in (True, False, 500.0, "500", 0, -20, 480, 490, 510, 4990, 5000, 10 ** 6):
            with self.subTest(bad=bad), patch.object(h, "PEDAL_LEAD_MS", bad):
                with self.assertRaisesRegex(h.Refused, "PEDAL_LEAD_MS must be"):
                    h.scenario_timeline("pedal-straight")
                self.assertEqual(set(h.tool_scenarios()), {"neutral-window-30s", "pause-menu-20s"})
                h.validate_timeline(h.scenarios()["native-y"])
        for good in (500, 4980):
            with self.subTest(good=good), patch.object(h, "PEDAL_LEAD_MS", good):
                h.validate_timeline(h.scenario_timeline("pedal-straight"))

    def test_pedal_straight_exact_reports_end_and_neutral_ending_with_injected_lead(self):
        for lead in (500, 1240, 4980):
            with self.subTest(lead=lead), patch.object(h, "PEDAL_LEAD_MS", lead):
                events = h.scenario_timeline("pedal-straight")
                self.assertEqual(events, (h.Event(0, h.NEUTRAL), h.Event(lead, h.State(h.A)),
                                          h.Event(lead + 1000, h.NEUTRAL), h.Event(6000, h.NEUTRAL)))
                clock, backend, sink = h.PreviewClock(), Backend(), Sink()
                guard = Guard(clock)
                result = h.run(events, guard, lambda: backend, sink, execute=True, clock=clock)
                self.assertTrue(result["completed"])
                self.assertEqual((result["report_count"], result["driver_report_count"]), (301, 301))
                reports = reports_of(sink)
                self.assertEqual([row["planned_ms"] for row in reports], list(range(0, 6001, 20)))
                expected = [h.State(h.A) if lead <= at < lead + 1000 else h.NEUTRAL for at in range(0, 6001, 20)]
                self.assertEqual([row["state"] for row in reports], [h.asdict(state) for state in expected])
                self.assertEqual([row["raw_report_hex"] for row in reports], [raw_hex(state) for state in expected])
                self.assertEqual(sum(state == h.State(h.A) for state in expected), 50)
                self.assertEqual(raw_hex(h.State(h.A)), "001000000000000000000000")
                self.assertEqual(reports[-1]["planned_ms"], 6000)
                self.assertEqual(reports[-1]["state"], h.asdict(h.NEUTRAL))
                self.assertEqual(backend.states[:3], [h.State(left_x=1 / 32767), h.NEUTRAL, h.NEUTRAL])
                self.assertEqual(backend.states[3:], expected + [h.NEUTRAL])
                self.assertEqual(sink.rows[-2]["event"], "controller_neutral_release")
                self.assertTrue(sink.rows[-2]["succeeded"])
                self.assertEqual((backend.closed, guard.closed), (1, 1))
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
                self.assertIsNone(result["input_consumed"])

    def test_pedal_straight_guards_abort_mid_pedal_and_release(self):
        with patch.object(h, "PEDAL_LEAD_MS", 1240):
            events = h.scenario_timeline("pedal-straight")
            for issue in ("Escape abort", "Owned game lost foreground", "late"):
                with self.subTest(issue=issue):
                    class Late(h.PreviewClock):
                        def sleep(self, seconds):
                            self.value += seconds + (.2 if issue == "late" and self.value >= 1.6 else 0)
                    clock, backend, sink = Late(), Backend(), Sink()
                    guard = Guard(clock, None if issue == "late" else 1.6, issue)
                    result = h.run(events, guard, lambda: backend, sink, execute=True, clock=clock)
                    self.assertFalse(result["completed"])
                    self.assertIn("120ms" if issue == "late" else issue, result["issue"])
                    self.assertTrue(any(state == h.State(h.A) for state in backend.states))
                    self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))

    def test_cli_dry_run_with_injected_lead_uses_default_ledger(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-lead-test-", dir=folder) as temporary, \
                patch.object(h, "PEDAL_LEAD_MS", 1240), patch.object(h, "Ledger", wraps=h.Ledger) as default, \
                patch.object(h, "WindowsGuard", side_effect=AssertionError("No game inspection")), \
                patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver import")), patch("builtins.print"):
            path = Path(temporary) / "pedal.jsonl"
            self.assertEqual(h.main(["--scenario", "pedal-straight", "--ledger", str(path)]), 0)
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual(default.call_count, 1)
            self.assertEqual(rows[0]["timeline"], [h.asdict(event) for event in h.scenario_timeline("pedal-straight")])
            self.assertEqual(rows[-1]["report_count"], 301)
            self.assertTrue(all(row.get("driver_submitted") is not True for row in rows))


class LongTimelineTests(unittest.TestCase):
    """TOOL-2(a) and the long-timeline ledger: exact 30s neutral, every guard unchanged."""
    def test_neutral_window_30s_exact_1501_zero_reports_and_cleanup(self):
        events = h.scenario_timeline("neutral-window-30s")
        self.assertEqual(events, (h.Event(0, h.NEUTRAL), h.Event(30000, h.NEUTRAL)))
        self.assertEqual(h.MAX_EXTENDED_DURATION_MS, 30000)
        clock, backend, sink = h.PreviewClock(), Backend(), Sink()
        guard = Guard(clock)
        result = h.run(events, guard, lambda: backend, sink, execute=True, clock=clock)
        self.assertTrue(result["completed"])
        self.assertEqual((result["report_count"], result["driver_report_count"]), (1501, 1501))
        reports = reports_of(sink)
        self.assertEqual([row["planned_ms"] for row in reports], list(range(0, 30001, 20)))
        self.assertTrue(all(row["state"] == h.asdict(h.NEUTRAL) and row["raw_report_hex"] == "00" * 12 for row in reports))
        self.assertEqual(backend.states[3:], [h.NEUTRAL] * 1502)
        self.assertEqual((backend.prime_count, backend.closed, guard.closed), (1, 1, 1))
        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])

    def test_only_exact_registered_tuples_run_past_6s(self):
        invalid = [
            (h.Event(0, h.NEUTRAL), h.Event(30020, h.NEUTRAL)),
            (h.Event(0, h.NEUTRAL), h.Event(29980, h.NEUTRAL)),
            (h.Event(0, h.NEUTRAL), h.Event(25000, h.NEUTRAL)),
            (h.Event(0, h.NEUTRAL), h.Event(15000, h.NEUTRAL), h.Event(30000, h.NEUTRAL)),
            (h.Event(0, h.NEUTRAL), h.Event(20, h.State(h.A)), h.Event(30000, h.NEUTRAL)),
            (h.Event(0, h.NEUTRAL), h.Event(30000, h.State(h.Y))),
            [h.Event(0, h.NEUTRAL), h.Event(30000, h.NEUTRAL)],
            (h.Event(0, h.NEUTRAL), h.Event(1240, h.State(h.A)), h.Event(10000, h.NEUTRAL), h.Event(20000, h.NEUTRAL)),
        ]
        for events in invalid:
            with self.subTest(events=events), self.assertRaises(h.Refused):
                h.run(events, h.DryGuard(), lambda: self.fail("Invalid long timeline reached backend"), Sink(), clock=h.PreviewClock())

    def test_guards_and_lateness_stay_live_late_in_30s_window(self):
        events = h.scenario_timeline("neutral-window-30s")
        for fault in ("Escape abort", "Owned game lost foreground", "Owned creation FILETIME changed", "late", float("nan")):
            with self.subTest(fault=fault):
                class Broken(h.PreviewClock):
                    def sleep(self, seconds):
                        super().sleep(seconds)
                        if self.value >= 25 and fault == "late":
                            self.value += .2
                        elif self.value >= 25 and not isinstance(fault, str):
                            self.value = fault
                clock, backend, sink = Broken(), Backend(), Sink()
                guard = Guard(clock, 25.05, fault) if isinstance(fault, str) and fault != "late" else Guard(clock)
                result = h.run(events, guard, lambda: backend, sink, execute=True, clock=clock)
                self.assertFalse(result["completed"])
                self.assertIn("120ms" if fault == "late" else "clock" if not isinstance(fault, str) else fault, result["issue"])
                self.assertGreater(result["report_count"], 1001)
                self.assertLess(result["report_count"], 1501)
                self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])

    def test_long_ledger_budget_is_reports_plus_fixed_margin_and_refuses_others(self):
        with tempfile.TemporaryDirectory(prefix="long-ledger-test-") as temporary, patch.object(h, "PEDAL_LEAD_MS", 1240):
            for name, limit in (("neutral-window-30s", 1700), ("pause-menu-20s", 1200), ("ride-10s", 1200),
                                ("ride-s01-30s", 1700), ("ride-steer-brake", 900), ("coast-long", 800)):
                with self.subTest(name=name):
                    path = Path(temporary) / (name + ".jsonl")
                    ledger = h.LongTimelineLedger(path, h.scenario_timeline(name))
                    try:
                        self.assertEqual(ledger.row_limit, limit)
                        for _ in range(limit):
                            ledger.write("bounded_test_row")
                        with self.assertRaises(h.Refused):
                            ledger.write("overflow_must_not_be_written")
                    finally:
                        ledger.close()
                    self.assertEqual(len(path.read_text().splitlines()), limit)
            for events in (h.scenarios()["neutral-follow"], h.NEUTRAL_WINDOW, h.scenario_timeline("pedal-straight"),
                           (h.Event(0, h.NEUTRAL), h.Event(15000, h.NEUTRAL), h.Event(30000, h.NEUTRAL))):
                refused = Path(temporary) / "refused.jsonl"
                with self.subTest(events=events), self.assertRaises(h.Refused):
                    h.LongTimelineLedger(refused, events)
                self.assertFalse(refused.exists())

    def test_slow_bootstrap_gate_and_1501_reports_fit_1700_rows(self):
        class SlowNeutral(Backend):
            reads = 0
            def readback(self):
                self.reads += 1
                return dict(available=True, slot=0, neutral=self.reads >= 49,
                            raw_report_hex="00" * 12 if self.reads >= 49 else "01" * 12)
        folder = h.WORKSPACE / "build" / "bmx"
        events = h.scenario_timeline("neutral-window-30s")
        with tempfile.TemporaryDirectory(prefix="long-ledger-slow-test-", dir=folder) as temporary:
            gate = h.StartGate(Path(temporary) / "gate", "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                               "neutral-window-30s", "C" * 64)
            path = Path(temporary) / "window.jsonl"
            ledger = h.LongTimelineLedger(path, events)

            class GoLedger:
                def write(self, event, **fields):
                    ledger.write(event, **fields)
                    if event == "controller_start_gate_wait":
                        pending = gate.path / "go.pending"
                        pending.write_text(json.dumps(gate.trigger_fields()))
                        pending.rename(gate.go)
            clock, backend = h.PreviewClock(), SlowNeutral()
            try:
                ledger.write("controller_session_start")
                result = h.run(events, Guard(clock), lambda: backend, GoLedger(), execute=True, clock=clock, start_gate=gate)
            finally:
                ledger.close()
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertTrue(result["completed"])
            self.assertEqual((result["driver_report_count"], backend.reads), (1501, 50))
            self.assertGreater(len(rows), 1600)
            self.assertLessEqual(len(rows), 1700)
            self.assertEqual([row["event"] for row in rows[-2:]], ["controller_neutral_release", "controller_session_end"])

    def test_cli_selects_long_ledger_for_long_names_only(self):
        folder = h.WORKSPACE / "build" / "bmx"
        real = h.LongTimelineLedger
        for name, count in (("neutral-window-30s", 1501), ("pause-menu-20s", 1001), ("ride-10s", 1001),
                            ("ride-s01-30s", 1501), ("pedal-straight", 301), ("neutral-window-20s", 1001),
                            ("ride-steer-brake", 701), ("coast-long", 601)):
            with self.subTest(name=name), tempfile.TemporaryDirectory(prefix="long-ledger-cli-test-", dir=folder) as temporary, \
                    patch.object(h, "PEDAL_LEAD_MS", 1240), patch.object(h, "LongTimelineLedger", wraps=real) as long_ledger, \
                    patch.object(h, "WindowsGuard", side_effect=AssertionError("No game inspection")), \
                    patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver import")), patch("builtins.print"):
                path = Path(temporary) / "dry.jsonl"
                self.assertEqual(h.main(["--scenario", name, "--ledger", str(path)]), 0)
                self.assertEqual(long_ledger.call_count, 1 if name in h.LONG_SCENARIO_NAMES else 0)
                rows = [json.loads(line) for line in path.read_text().splitlines()]
                self.assertEqual(rows[0]["scenario"], name)
                self.assertEqual(rows[-1]["report_count"], count)
                self.assertTrue(rows[0]["timing_simulated"])
                self.assertTrue(all(row.get("driver_submitted") is not True for row in rows))


class PauseMenuTests(unittest.TestCase):
    """TOOL-2(b): one scheduled virtual Start press, never a keyboard key; aborts stay live."""
    def test_one_start_press_at_3s_in_an_exact_20s_timeline(self):
        events = h.scenario_timeline("pause-menu-20s")
        self.assertEqual(events, (h.Event(0, h.NEUTRAL), h.Event(3000, h.State(h.START)),
                                  h.Event(3200, h.NEUTRAL), h.Event(20000, h.NEUTRAL)))
        self.assertEqual(h.START, 0x0010)  # vgamepad 0.1.0 XUSB_GAMEPAD_START
        self.assertFalse(h.ALLOWED_BUTTONS & h.START)
        self.assertEqual([event for event in events if event.state.buttons & h.START], [h.Event(3000, h.State(h.START))])
        self.assertTrue(all(event.state in (h.NEUTRAL, h.State(h.START)) for event in events))
        h.validate_timeline(events)

    def test_start_is_refused_in_every_other_timeline(self):
        S, N = h.State(h.START), h.NEUTRAL
        invalid = [
            (h.Event(0, N), h.Event(20, S), h.Event(40, N)),
            (h.Event(0, N), h.Event(3000, S), h.Event(3200, N), h.Event(6000, N)),
            (h.Event(0, N), h.Event(3020, S), h.Event(3220, N), h.Event(20000, N)),
            (h.Event(0, N), h.Event(3000, S), h.Event(3400, N), h.Event(20000, N)),
            (h.Event(0, N), h.Event(3000, h.State(h.START | h.A)), h.Event(3200, N), h.Event(20000, N)),
            (h.Event(0, N), h.Event(3000, h.State(h.START, left_y=-1)), h.Event(3200, N), h.Event(20000, N)),
            (h.Event(0, N), h.Event(3000, h.State(0x0020)), h.Event(3200, N), h.Event(20000, N)),
            (h.Event(0, N), h.Event(3000, S), h.Event(3200, N), h.Event(6000, S), h.Event(6200, N), h.Event(20000, N)),
            (h.Event(0, N), h.Event(3000, S), h.Event(3200, N), h.Event(30000, N)),
            list(h.PAUSE_MENU_WINDOW),
        ]
        for events in invalid:
            with self.subTest(events=events), self.assertRaises(h.Refused):
                h.run(events, h.DryGuard(), lambda: self.fail("Start outside the exact timeline reached backend"),
                      Sink(), clock=h.PreviewClock())
        for name, events in h.scenarios().items():
            self.assertFalse(any(event.state.buttons & h.START for event in events), name)

    def test_scheduled_start_reports_with_a_guard_check_before_each(self):
        log = []

        class Logged(Backend):
            def send(self, state):
                log.append(("send", state))
                super().send(state)

        class LoggedGuard(Guard):
            def check(self):
                log.append(("check",))
                super().check()
        clock, backend, sink = h.PreviewClock(), Logged(), Sink()
        guard = LoggedGuard(clock)
        result = h.run(h.scenario_timeline("pause-menu-20s"), guard, lambda: backend, sink, execute=True, clock=clock)
        self.assertTrue(result["completed"])
        self.assertEqual(result["report_count"], 1001)
        reports = reports_of(sink)
        start = [row["planned_ms"] for row in reports if row["state"]["buttons"] & h.START]
        self.assertEqual(start, list(range(3000, 3200, 20)))
        self.assertTrue(all(row["state"] == h.asdict(h.State(h.START)) and row["raw_report_hex"] == "100000000000000000000000"
                            for row in reports if row["planned_ms"] in start))
        self.assertTrue(all(row["state"] == h.asdict(h.NEUTRAL) for row in reports if row["planned_ms"] not in start))
        sends = [i for i, entry in enumerate(log) if entry == ("send", h.State(h.START))]
        self.assertEqual(len(sends), 10)
        self.assertTrue(all(log[i - 1] == ("check",) for i in sends))
        self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))

    def test_actual_guard_body_passes_virtual_start_and_reads_only_escape(self):
        clock, backend, sink = h.PreviewClock(), Backend(), Sink()
        guard, keys = real_check_guard(clock)
        result = h.run(h.scenario_timeline("pause-menu-20s"), guard, lambda: backend, sink, execute=True, clock=clock)
        self.assertTrue(result["completed"], result["issue"])
        self.assertEqual(result["report_count"], 1001)
        self.assertEqual(sum(state == h.State(h.START) for state in backend.states), 10)
        self.assertGreater(len(keys), 1001)
        self.assertEqual(set(keys), {0x1B})
        self.assertIsNone(guard.handle)

    def test_actual_guard_body_still_aborts_on_real_escape_or_focus_loss_after_start(self):
        for fault, after_s, issue in (("escape", 3.1, "Escape abort"), ("escape", 3.4, "Escape abort"),
                                      ("focus", 3.1, "Owned game lost foreground"), ("focus", 9.0, "Owned game lost foreground")):
            with self.subTest(fault=fault, after_s=after_s):
                clock, backend, sink = h.PreviewClock(), Backend(), Sink()
                guard, _ = real_check_guard(clock, fault, after_s)
                result = h.run(h.scenario_timeline("pause-menu-20s"), guard, lambda: backend, sink, execute=True, clock=clock)
                self.assertFalse(result["completed"])
                self.assertIn(issue, result["issue"])
                self.assertTrue(any(state == h.State(h.START) for state in backend.states))
                self.assertLess(result["report_count"], 1001)
                self.assertEqual(backend.states[-1], h.NEUTRAL)
                self.assertEqual(backend.closed, 1)
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
                self.assertIsNone(guard.handle)

    def test_real_backend_maps_start_to_the_xusb_start_button_only(self):
        module = types.SimpleNamespace(VX360Gamepad=PinnedPad, XUSB_BUTTON=types.SimpleNamespace(
            **{"XUSB_GAMEPAD_" + name: name for name in PINNED_BUTTON_NAMES}))
        backend = h.VGamepadBackend(module, probe=object())
        backend.send(h.State(h.START))
        self.assertEqual(backend.pad.calls, [["reset"], ["button", "START"], ["left", 0.0, 0.0], ["right", 0.0, 0.0],
                                             ["lt", 0.0], ["rt", 0.0], ["update"]])
        backend.send(h.NEUTRAL)
        self.assertNotIn(["button", "START"], backend.pad.calls[7:])
        backend.close()

    def test_driver_reads_keyboard_only_for_escape_and_injects_no_keyboard_input(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertEqual(set(re.findall(r"self\.user\.(\w+)", source)),
                         {"GetForegroundWindow", "GetWindowThreadProcessId", "GetAsyncKeyState"})
        self.assertEqual(re.findall(r"GetAsyncKeyState\((0x[0-9A-Fa-f]+)\)", source), ["0x1B"])
        for name in ("SendInput", "keybd_event", "mouse_event", "PostMessage", "SendMessage", "SetForegroundWindow",
                     "AttachThreadInput"):
            self.assertFalse(name in source, name)

    def test_start_gate_binds_pause_scenario_and_no_start_before_go(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="pause-menu-gate-test-", dir=folder) as temporary:
            gate = h.StartGate(Path(temporary) / "gate", "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                               "pause-menu-20s", "C" * 64)
            test, backend = self, Backend()

            class GoSink(Sink):
                def write(self, event, **fields):
                    super().write(event, **fields)
                    if event == "controller_start_gate_wait":
                        ready = json.loads(gate.ready.read_text())
                        test.assertEqual(ready["scenario"], "pause-menu-20s")
                        test.assertFalse(any(state.buttons for state in backend.states))
                        pending = gate.path / "go.pending"
                        pending.write_text(json.dumps(gate.trigger_fields()))
                        pending.rename(gate.go)
            clock, sink = h.PreviewClock(), GoSink()
            result = h.run(h.scenario_timeline("pause-menu-20s"), Guard(clock), lambda: backend, sink,
                           execute=True, clock=clock, start_gate=gate)
            self.assertTrue(result["completed"])
            go = next(i for i, row in enumerate(sink.rows) if row["event"] == "controller_start_gate_go")
            first_start = next(i for i, row in enumerate(sink.rows)
                               if row["event"] == "controller_report" and row["state"]["buttons"] & h.START)
            self.assertLess(go, first_start)
            self.assertEqual(sink.rows[first_start]["planned_ms"], 3000)


class RideTimelineTests(unittest.TestCase):
    """TOOL-2(c): fixed riding timelines to 30s, under the same unset-lead rule."""
    def phases(self, events):
        return [(event.at_ms, event.state) for event in events]

    def run_ride(self, name, lead):
        with patch.object(h, "PEDAL_LEAD_MS", lead):
            events = h.scenario_timeline(name)
            clock, backend, sink = h.PreviewClock(), Backend(), Sink()
            guard = Guard(clock)
            result = h.run(events, guard, lambda: backend, sink, execute=True, clock=clock)
        self.assertTrue(result["completed"])
        self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))
        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
        return events, result, reports_of(sink)

    def test_ride_10s_pedals_from_lead_to_10s_then_neutral_to_20s(self):
        for lead in (500, 1240, 4980):
            with self.subTest(lead=lead):
                events, result, reports = self.run_ride("ride-10s", lead)
                self.assertEqual(self.phases(events), [(0, h.NEUTRAL), (lead, h.State(h.A)), (10000, h.NEUTRAL), (20000, h.NEUTRAL)])
                self.assertEqual(result["report_count"], 1001)
                expected = [h.State(h.A) if lead <= at < 10000 else h.NEUTRAL for at in range(0, 20001, 20)]
                self.assertEqual([row["state"] for row in reports], [h.asdict(state) for state in expected])
                self.assertEqual([row["raw_report_hex"] for row in reports], [raw_hex(state) for state in expected])
                self.assertEqual(reports[-1]["planned_ms"], 20000)

    def test_ride_s01_30s_start_coast_brake_rest_restart_then_neutral(self):
        lead = 1240
        events, result, reports = self.run_ride("ride-s01-30s", lead)
        self.assertEqual(self.phases(events), [(0, h.NEUTRAL), (lead, h.State(h.A)), (lead + 6000, h.NEUTRAL),
                                               (lead + 9000, h.State(h.B)), (lead + 15000, h.NEUTRAL),
                                               (lead + 15500, h.State(h.A)), (lead + 17500, h.NEUTRAL), (30000, h.NEUTRAL)])
        self.assertEqual(result["report_count"], 1501)

        def expected(at):
            if lead <= at < lead + 6000 or lead + 15500 <= at < lead + 17500:
                return h.State(h.A)
            return h.State(h.B) if lead + 9000 <= at < lead + 15000 else h.NEUTRAL
        states = [expected(at) for at in range(0, 30001, 20)]
        self.assertEqual([row["state"] for row in reports], [h.asdict(state) for state in states])
        self.assertEqual([row["raw_report_hex"] for row in reports], [raw_hex(state) for state in states])
        self.assertEqual((states.count(h.State(h.A)), states.count(h.State(h.B))), (400, 300))
        for lead in (500, 4980):
            with self.subTest(lead=lead), patch.object(h, "PEDAL_LEAD_MS", lead):
                h.validate_timeline(h.scenario_timeline("ride-s01-30s"))

    def test_ride_exactness_follows_the_lead_literal(self):
        built = h.lead_scenarios(1240)
        with patch.object(h, "PEDAL_LEAD_MS", None):
            for name in ("ride-10s", "ride-s01-30s"):
                with self.subTest(name=name, lead=None), self.assertRaises(h.Refused):
                    h.validate_timeline(built[name])
        with patch.object(h, "PEDAL_LEAD_MS", 1260):
            for name in ("ride-10s", "ride-s01-30s"):
                with self.subTest(name=name, lead=1260), self.assertRaises(h.Refused):
                    h.validate_timeline(built[name])
        with patch.object(h, "PEDAL_LEAD_MS", 1240):
            for name in ("ride-10s", "ride-s01-30s"):
                h.validate_timeline(built[name])

    def test_ride_guards_abort_mid_ride_and_release(self):
        with patch.object(h, "PEDAL_LEAD_MS", 1240):
            for name, at_s, held in (("ride-10s", 6.0, h.State(h.A)), ("ride-s01-30s", 12.0, h.State(h.B))):
                for issue in ("Escape abort", "Owned game lost foreground"):
                    with self.subTest(name=name, issue=issue):
                        clock, backend, sink = h.PreviewClock(), Backend(), Sink()
                        guard = Guard(clock, at_s, issue)
                        result = h.run(h.scenario_timeline(name), guard, lambda: backend, sink, execute=True, clock=clock)
                        self.assertFalse(result["completed"])
                        self.assertIn(issue, result["issue"])
                        self.assertEqual(backend.states[-2], held)
                        self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))
                        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])


class TrialLeadTests(unittest.TestCase):
    def test_override_is_validated_and_does_not_change_the_default(self):
        for bad in (True, False, 500.0, "500", 0, -20, 480, 510, 4990, 5000, 10 ** 6):
            with self.subTest(bad=bad), self.assertRaises(h.Refused):
                h.pedal_lead_ms(bad)
        with patch.object(h, "PEDAL_LEAD_MS", 1240):
            for lead in (500, 1500, 4980):
                self.assertEqual(h.pedal_lead_ms(lead), lead)
                self.assertEqual(h.pedal_lead_ms(), 1240)
        self.assertIsNone(h.PEDAL_LEAD_MS)

    def test_bad_cli_leads_refuse_before_owner_ledger_game_or_device(self):
        for value in ("", "no", "true", "500.0", "nan", "inf", "-20", "0", "480", "510", "4990", "5000", "1000000"):
            for execute in ([], ["--execute", "--owner", "unused-owner"]):
                with self.subTest(value=value, execute=execute), \
                        patch.object(h, "load_owner", side_effect=AssertionError("No owner read")), \
                        patch.object(h, "inside_build", side_effect=AssertionError("No ledger or gate")), \
                        patch.object(h, "WindowsGuard", side_effect=AssertionError("No game inspection")), \
                        patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver import")), \
                        patch("sys.stderr", new_callable=io.StringIO), self.assertRaises((SystemExit, h.Refused)):
                    h.main(["--scenario", "ride-steer-brake", "--pedal-lead-ms", value, *execute])

    def test_cli_rejects_a_lead_for_scenarios_that_do_not_use_it(self):
        for name in set(h.scenario_names()) - set(h.LEAD_SCENARIO_NAMES):
            with self.subTest(name=name), patch.object(h, "inside_build", side_effect=AssertionError("No ledger")), \
                    patch("sys.stderr", new_callable=io.StringIO) as stderr, self.assertRaises(SystemExit):
                h.main(["--scenario", name, "--pedal-lead-ms", "1500"])
            self.assertIn("requires a lead-dependent scenario", stderr.getvalue())

    def test_cli_lead_dry_runs_all_lead_scenarios_and_does_not_leak_to_next_call(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="trial-lead-test-", dir=folder) as temporary, \
                patch.object(h, "WindowsGuard", side_effect=AssertionError("No game inspection")), \
                patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver import")), patch("builtins.print"):
            for lead in (500, 1500, 4980):
                for name in h.LEAD_SCENARIO_NAMES:
                    with self.subTest(name=name, lead=lead):
                        path = Path(temporary) / f"{name}-{lead}.jsonl"
                        self.assertEqual(h.main(["--scenario", name, "--pedal-lead-ms", str(lead), "--ledger", str(path)]), 0)
                        rows = [json.loads(line) for line in path.read_text().splitlines()]
                        events = h.scenario_timeline(name, lead)
                        self.assertEqual(rows[0]["pedal_lead_ms"], lead)
                        self.assertEqual(rows[0]["timeline"], [h.asdict(event) for event in events])
                        self.assertTrue(rows[0]["timing_simulated"])
                        self.assertEqual(rows[-1]["report_count"], events[-1].at_ms // 20 + 1)
                        self.assertTrue(rows[-1]["completed"])
                        self.assertTrue(all(row.get("driver_submitted") is not True for row in rows))
                        self.assertIsNone(h.PEDAL_LEAD_MS)
                        refused = Path(temporary) / "refused.jsonl"
                        with self.assertRaisesRegex(h.Refused, "PEDAL_LEAD_MS is unset"):
                            h.main(["--scenario", name, "--ledger", str(refused)])
                        self.assertFalse(refused.exists())


class SteerCoastTimelineTests(unittest.TestCase):
    def test_new_names_are_registered_once_as_lead_long_and_gated(self):
        for names in (h.LEAD_SCENARIO_NAMES, h.LONG_SCENARIO_NAMES, h.GATED_SCENARIO_NAMES, h.scenario_names()):
            self.assertEqual(len(names), len(set(names)))
            for name in ("ride-steer-brake", "coast-long"):
                self.assertIn(name, names)

    def run_trial(self, name, lead):
        clock, backend, sink = h.PreviewClock(), Backend(), Sink()
        guard = Guard(clock)
        events = h.scenario_timeline(name, lead)
        result = h.run(events, guard, lambda: backend, sink, execute=True, clock=clock, lead_ms=lead)
        self.assertTrue(result["completed"], result["issue"])
        self.assertEqual((backend.states[-1], backend.closed, guard.closed), (h.NEUTRAL, 1, 1))
        self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])
        self.assertIsNone(result["input_consumed"])
        return events, result, reports_of(sink)

    def test_steer_brake_reports_hold_only_the_requested_controls_for_each_phase(self):
        for lead in (500, 1240, 4980):
            with self.subTest(lead=lead):
                events, result, reports = self.run_trial("ride-steer-brake", lead)
                self.assertEqual([(e.at_ms, e.state) for e in events], [
                    (0, h.NEUTRAL), (240, h.State(h.B)), (lead - 240, h.NEUTRAL), (lead, h.State(h.A)), (lead + 1500, h.NEUTRAL),
                    (lead + 1740, h.State(left_x=-0.8)), (lead + 3740, h.NEUTRAL),
                    (lead + 3980, h.State(left_x=0.8)), (lead + 5980, h.NEUTRAL),
                    (lead + 6220, h.State(h.B)), (lead + 7220, h.NEUTRAL), (14000, h.NEUTRAL)])

                def expected(at):
                    if 240 <= at < lead - 240 or lead + 6220 <= at < lead + 7220:
                        return h.State(h.B)
                    if lead <= at < lead + 1500:
                        return h.State(h.A)
                    if lead + 1740 <= at < lead + 3740:
                        return h.State(left_x=-0.8)
                    if lead + 3980 <= at < lead + 5980:
                        return h.State(left_x=0.8)
                    return h.NEUTRAL
                states = [expected(at) for at in range(0, 14001, 20)]
                # A mapper first observed while B is held must see a later neutral sample
                # before A; do not rely on the pre-publication neutral interval at go.
                self.assertEqual(states[lead // 20 - 12:lead // 20], [h.NEUTRAL] * 12)
                self.assertEqual(states[lead // 20:lead // 20 + 75], [h.State(h.A)] * 75)
                self.assertGreater(lead - 240, 240)
                self.assertEqual((result["report_count"], result["driver_report_count"]), (701, 701))
                self.assertEqual([r["planned_ms"] for r in reports], list(range(0, 14001, 20)))
                self.assertEqual([r["state"] for r in reports], [h.asdict(state) for state in states])
                self.assertEqual([r["raw_report_hex"] for r in reports], [raw_hex(state) for state in states])
                self.assertEqual([states.count(state) for state in (h.State(h.A), h.State(left_x=-0.8), h.State(left_x=0.8))],
                                 [75, 100, 100])

    def test_coast_long_pedals_four_seconds_then_stays_neutral_to_twelve_seconds(self):
        for lead in (500, 1240, 4980):
            with self.subTest(lead=lead):
                events, result, reports = self.run_trial("coast-long", lead)
                self.assertEqual(events, (h.Event(0, h.NEUTRAL), h.Event(lead, h.State(h.A)),
                                          h.Event(lead + 4000, h.NEUTRAL), h.Event(12000, h.NEUTRAL)))
                states = [h.State(h.A) if lead <= at < lead + 4000 else h.NEUTRAL for at in range(0, 12001, 20)]
                self.assertEqual((result["report_count"], result["driver_report_count"]), (601, 601))
                self.assertEqual([r["planned_ms"] for r in reports], list(range(0, 12001, 20)))
                self.assertEqual([r["state"] for r in reports], [h.asdict(state) for state in states])
                self.assertEqual([r["raw_report_hex"] for r in reports], [raw_hex(state) for state in states])
                self.assertEqual(states.count(h.State(h.A)), 200)

    def test_altered_long_timelines_or_wrong_lead_refuse_before_backend_and_ledger(self):
        with tempfile.TemporaryDirectory(prefix="trial-exactness-test-") as temporary:
            path = Path(temporary) / "refused.jsonl"
            for name in ("ride-steer-brake", "coast-long"):
                events = h.scenario_timeline(name, 1500)
                altered = (events[:1] + (h.Event(20, h.NEUTRAL),) + events[1:],
                           events[:-1] + (h.Event(events[-1].at_ms + 20, h.NEUTRAL),),
                           events[:1] + (h.Event(events[1].at_ms, h.State(h.START)),) + events[2:])
                for candidate, lead in ((events, None), (events, 1520), *((e, 1500) for e in altered)):
                    with self.subTest(name=name, lead=lead, candidate=candidate):
                        with self.assertRaises(h.Refused):
                            h.run(candidate, h.DryGuard(), lambda: self.fail("No backend"), Sink(), lead_ms=lead)
                        with self.assertRaises(h.Refused):
                            h.LongTimelineLedger(path, candidate, lead_ms=lead)
                        self.assertFalse(path.exists())

    def test_abort_during_initial_brake_pedal_steering_final_brake_and_coast_releases(self):
        phases = (("ride-steer-brake", 0.8, h.State(h.B)), ("ride-steer-brake", 2.0, h.State(h.A)),
                  ("ride-steer-brake", 4.0, h.State(left_x=-0.8)), ("ride-steer-brake", 6.0, h.State(left_x=0.8)),
                  ("ride-steer-brake", 8.0, h.State(h.B)), ("coast-long", 3.0, h.State(h.A)),
                  ("coast-long", 9.0, h.NEUTRAL))
        for name, at_s, held in phases:
            for fault in ("escape", "focus", "late"):
                with self.subTest(name=name, at_s=at_s, fault=fault):
                    class Late(h.PreviewClock):
                        def sleep(self, seconds):
                            super().sleep(seconds)
                            if fault == "late" and self.value >= at_s:
                                self.value += .2
                    clock, backend, sink = Late(), Backend(), Sink()
                    guard, _ = real_check_guard(clock, fault, at_s)
                    result = h.run(h.scenario_timeline(name, 1500), guard, lambda: backend, sink,
                                   execute=True, clock=clock, lead_ms=1500)
                    self.assertFalse(result["completed"])
                    self.assertIn({"escape": "Escape", "focus": "foreground", "late": "120ms"}[fault], result["issue"])
                    self.assertEqual(backend.states[-2:], [held, h.NEUTRAL])
                    self.assertEqual(backend.closed, 1)
                    self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])

    def test_cli_lead_cannot_bypass_required_gate(self):
        for name in h.LEAD_SCENARIO_NAMES:
            with self.subTest(name=name), patch("sys.stderr", new_callable=io.StringIO) as stderr, \
                    patch.object(h, "load_owner", side_effect=AssertionError("No owner read")), \
                    patch.object(h, "inside_build", side_effect=AssertionError("No ledger or gate")), \
                    self.assertRaises(SystemExit):
                h.main(["--execute", "--owner", "unused-owner", "--scenario", name, "--pedal-lead-ms", "1500"])
            self.assertIn("requires --start-gate and --start-nonce", stderr.getvalue())

    def test_cli_new_scenarios_start_only_after_go_and_use_bounded_ledgers_with_fakes(self):
        folder = h.WORKSPACE / "build" / "bmx"
        for name, count, limit in (("ride-steer-brake", 701, 900), ("coast-long", 601, 800)):
            with self.subTest(name=name), tempfile.TemporaryDirectory(prefix="trial-gate-test-", dir=folder) as temporary:
                gate_path, ledger = Path(temporary) / "gate", Path(temporary) / "trial.jsonl"
                backend = Backend()
                owner = h.Owner(123, 456, "game", "A" * 64)
                test = self

                class GoClock(h.PreviewClock):
                    def sleep(self, seconds):
                        super().sleep(seconds)
                        ready, go = gate_path / "ready.json", gate_path / "go.json"
                        if ready.exists() and not go.exists():
                            test.assertEqual(backend.states, [h.State(left_x=1 / 32767), h.NEUTRAL, h.NEUTRAL])
                            evidence = json.loads(ready.read_text())
                            test.assertEqual((evidence["scenario"], evidence["pedal_lead_ms"]), (name, 1500))
                            test.assertIs(type(evidence["pedal_lead_ms"]), int)
                            if self.value >= 2:
                                pending = gate_path / "go.pending"
                                pending.write_text(json.dumps(dict(schema=1, event="bmx_virtual_gamepad_go",
                                    process_id=123, process_creation_filetime="456", nonce="a" * 32)))
                                pending.rename(go)
                clock = GoClock()
                with patch.object(h, "load_owner", return_value=owner), \
                        patch.object(h, "WindowsGuard", return_value=Guard(clock)), patch.object(h, "Clock", return_value=clock), \
                        patch.object(h, "make_vgamepad", return_value=backend), patch("builtins.print"):
                    code = h.main(["--execute", "--owner", "unused-owner", "--scenario", name, "--pedal-lead-ms", "1500",
                                   "--ledger", str(ledger), "--start-gate", str(gate_path), "--start-nonce", "a" * 32])
                self.assertEqual(code, 0)
                rows = [json.loads(line) for line in ledger.read_text().splitlines()]
                event_names = [row["event"] for row in rows]
                self.assertLess(event_names.index("controller_start_gate_go"), event_names.index("controller_report"))
                self.assertEqual(rows[0]["pedal_lead_ms"], 1500)
                self.assertEqual(rows[-1]["report_count"], count)
                self.assertEqual(rows[-1]["driver_report_count"], count)
                self.assertTrue(rows[-1]["completed"])
                self.assertLessEqual(len(rows), limit)
                reports = [r for r in rows if r["event"] == "controller_report"]
                self.assertEqual((reports[0]["planned_ms"], reports[0]["elapsed_ms"]), (0, 0))
                self.assertEqual(reports[0]["state"], h.asdict(h.NEUTRAL))
                self.assertEqual((backend.states[-1], backend.closed), (h.NEUTRAL, 1))
                self.assertIsNone(h.PEDAL_LEAD_MS)


class StartGateLeadEvidenceTests(unittest.TestCase):
    def test_invalid_lead_is_refused_before_start_gate_paths_are_touched(self):
        for name in ("ride-steer-brake", "coast-long"):
            for lead in (None, True, False, 500.0, "500", 0, 480, 510, 5000):
                with self.subTest(name=name, lead=lead), patch.object(h, "PEDAL_LEAD_MS", None), \
                        patch.object(h, "inside_build", side_effect=AssertionError("No gate path access")), \
                        self.assertRaises(h.Refused):
                    h.StartGate(Path("unused-gate"), "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                                name, "C" * 64, lead_ms=lead)

    def test_misplaced_lead_is_refused_before_start_gate_paths_are_touched(self):
        for name in ("native-y", "equipment-switch", "neutral-window-30s", "pause-menu-20s"):
            with self.subTest(name=name), \
                    patch.object(h, "inside_build", side_effect=AssertionError("No gate path access")), \
                    self.assertRaises(h.Refused):
                h.StartGate(Path("unused-gate"), "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                            name, "C" * 64, lead_ms=1240)

    def test_gate_lead_and_scenario_mismatch_refuse_before_backend_or_ready_publication(self):
        folder = h.WORKSPACE / "build" / "bmx"
        for name in ("ride-steer-brake", "coast-long"):
            other = "coast-long" if name == "ride-steer-brake" else "ride-steer-brake"
            for run_name, run_lead in ((name, 1500), (other, 1240)):
                with self.subTest(name=name, run_name=run_name, run_lead=run_lead), \
                        tempfile.TemporaryDirectory(prefix="gate-lead-mismatch-", dir=folder) as temporary:
                    gate = h.StartGate(Path(temporary) / "gate", "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                                       name, h.sha256(SCRIPT), lead_ms=1240)
                    clock, sink = h.PreviewClock(), Sink()
                    with self.assertRaises(h.Refused):
                        h.run(h.scenario_timeline(run_name, run_lead), Guard(clock),
                              lambda: self.fail("No backend before matching gate evidence"), sink,
                              execute=True, clock=clock, start_gate=gate, lead_ms=run_lead)
                    self.assertEqual(sink.rows, [])
                    self.assertFalse(gate.ready.exists() or gate.go.exists())

    def test_nonlead_gate_refuses_lead_timeline_before_backend_or_ready_publication(self):
        folder = h.WORKSPACE / "build" / "bmx"
        for name in ("ride-steer-brake", "coast-long", "pedal-straight"):
            for implicit_default in (False, True):
                with self.subTest(name=name, implicit_default=implicit_default), \
                        tempfile.TemporaryDirectory(prefix="gate-missing-lead-", dir=folder) as temporary, \
                        patch.object(h, "PEDAL_LEAD_MS", 1240 if implicit_default else None):
                    gate = h.StartGate(Path(temporary) / "gate", "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                                       "native-y", h.sha256(SCRIPT))
                    clock, sink = h.PreviewClock(), Sink()
                    with self.assertRaises(h.Refused):
                        h.run(h.scenario_timeline(name, 1240), Guard(clock),
                              lambda: self.fail("No backend when a lead timeline lacks matching gate evidence"), sink,
                              execute=True, clock=clock, start_gate=gate,
                              lead_ms=None if implicit_default else 1240)
                    self.assertEqual(sink.rows, [])
                    self.assertFalse(gate.ready.exists() or gate.go.exists())

    def test_nonlead_gate_mutation_refuses_before_backend_or_ready_publication(self):
        folder = h.WORKSPACE / "build" / "bmx"
        changes = (("scenario", "ride-steer-brake"), ("scenario", "coast-long"),
                   ("scenario", "pedal-straight"), ("lead_ms", 1240),
                   ("_ready_configuration", ("ride-steer-brake", 1240)))
        for field, value in changes:
            with self.subTest(field=field, value=value), \
                    tempfile.TemporaryDirectory(prefix="gate-mutated-lead-", dir=folder) as temporary, \
                    patch.object(h, "PEDAL_LEAD_MS", None):
                gate = h.StartGate(Path(temporary) / "gate", "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                                   "native-y", h.sha256(SCRIPT))
                setattr(gate, field, value)
                clock, sink = h.PreviewClock(), Sink()
                with self.assertRaises(h.Refused):
                    h.run(h.scenarios()["native-y"], Guard(clock),
                          lambda: self.fail("No backend after nonlead gate metadata changes"), sink,
                          execute=True, clock=clock, start_gate=gate)
                self.assertEqual(sink.rows, [])
                self.assertFalse(gate.ready.exists() or gate.go.exists())

    def test_nonlead_gate_mutation_after_bootstrap_refuses_before_ready_publication(self):
        folder = h.WORKSPACE / "build" / "bmx"
        changes = (("scenario", "coast-long"), ("lead_ms", 1240),
                   ("_ready_configuration", ("ride-steer-brake", 1240)))
        for field, value in changes:
            with self.subTest(field=field, value=value), \
                    tempfile.TemporaryDirectory(prefix="gate-mutated-before-ready-", dir=folder) as temporary, \
                    patch.object(h, "PEDAL_LEAD_MS", None):
                gate = h.StartGate(Path(temporary) / "gate", "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                                   "native-y", h.sha256(SCRIPT))

                class ChangedConfigSink(Sink):
                    def write(self, event, **fields):
                        super().write(event, **fields)
                        if event == "controller_bootstrap_complete":
                            setattr(gate, field, value)

                clock, backend, sink = h.PreviewClock(), Backend(), ChangedConfigSink()
                result = h.run(h.scenarios()["native-y"], Guard(clock), lambda: backend, sink,
                               execute=True, clock=clock, start_gate=gate)
                self.assertFalse(result["completed"])
                self.assertEqual(result["issue"], "Refused: Non-pedal start gate has stale pedal readiness configuration")
                self.assertEqual(sum(row["event"] == "controller_bootstrap_complete" for row in sink.rows), 1)
                self.assertFalse(any(row["event"].startswith("controller_start_gate_") for row in sink.rows))
                self.assertFalse(gate.ready.exists() or gate.go.exists())
                self.assertEqual((result["report_count"], result["driver_report_count"]), (0, 0))
                self.assertEqual(reports_of(sink), [])
                self.assertEqual(backend.states, [h.State(left_x=1 / 32767), h.NEUTRAL, h.NEUTRAL, h.NEUTRAL])
                self.assertEqual(backend.closed, 1)
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])

    def test_changed_implicit_default_cannot_replace_the_gate_lead(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="gate-default-mismatch-", dir=folder) as temporary, \
                patch.object(h, "PEDAL_LEAD_MS", 1240):
            gate = h.StartGate(Path(temporary) / "gate", "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                               "ride-steer-brake", h.sha256(SCRIPT))
            self.assertEqual(gate.lead_ms, 1240)
            sink = Sink()
            with patch.object(h, "PEDAL_LEAD_MS", 1500):
                events = h.scenario_timeline("ride-steer-brake")
                with self.assertRaises(h.Refused):
                    h.run(events, h.DryGuard(), lambda: self.fail("No backend with stale gate evidence"), sink,
                          execute=True, clock=h.PreviewClock(), start_gate=gate)
            self.assertEqual(sink.rows, [])
            self.assertFalse(gate.ready.exists() or gate.go.exists())

    def test_explicit_matching_lead_keeps_ready_evidence_when_default_changes(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="gate-frozen-lead-", dir=folder) as temporary, \
                patch.object(h, "PEDAL_LEAD_MS", 1240):
            gate = h.StartGate(Path(temporary) / "gate", "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                               "ride-steer-brake", h.sha256(SCRIPT))
            events, test = h.scenario_timeline("ride-steer-brake"), self

            class GoSink(Sink):
                def write(self, event, **fields):
                    super().write(event, **fields)
                    if event == "controller_start_gate_wait":
                        ready = json.loads(gate.ready.read_text())
                        test.assertEqual((ready["scenario"], ready["pedal_lead_ms"]), ("ride-steer-brake", 1240))
                        pending = gate.path / "go.pending"
                        pending.write_text(json.dumps(gate.trigger_fields()))
                        pending.rename(gate.go)
            clock, backend, sink = h.PreviewClock(), Backend(), GoSink()
            with patch.object(h, "PEDAL_LEAD_MS", 1500):
                result = h.run(events, Guard(clock), lambda: backend, sink, execute=True, clock=clock,
                               start_gate=gate, lead_ms=1240)
            self.assertTrue(result["completed"], result["issue"])
            pedal = [row for row in reports_of(sink) if row["state"]["buttons"] == h.A]
            self.assertEqual((pedal[0]["planned_ms"], len(pedal)), (1240, 75))
            self.assertEqual((backend.states[-1], backend.closed), (h.NEUTRAL, 1))

    def test_config_changed_during_gate_wait_refuses_before_scheduled_reports(self):
        folder = h.WORKSPACE / "build" / "bmx"
        for change in ("implicit_default", "gate_lead"):
            with self.subTest(change=change), tempfile.TemporaryDirectory(prefix="gate-late-config-", dir=folder) as temporary, \
                    patch.object(h, "PEDAL_LEAD_MS", 1240):
                gate = h.StartGate(Path(temporary) / "gate", "a" * 32, h.Owner(123, 456, "game", "A" * 64),
                                   "ride-steer-brake", h.sha256(SCRIPT))
                events, test = h.scenario_timeline("ride-steer-brake"), self

                class ChangedConfigSink(Sink):
                    def write(self, event, **fields):
                        super().write(event, **fields)
                        if event == "controller_start_gate_wait":
                            test.assertEqual(json.loads(gate.ready.read_text())["pedal_lead_ms"], 1240)
                            if change == "implicit_default":
                                h.PEDAL_LEAD_MS = 1500
                            else:
                                gate.lead_ms = 1500
                            pending = gate.path / "go.pending"
                            pending.write_text(json.dumps(gate.trigger_fields()))
                            pending.rename(gate.go)
                clock, backend, sink = h.PreviewClock(), Backend(), ChangedConfigSink()
                result = h.run(events, Guard(clock), lambda: backend, sink, execute=True, clock=clock,
                               start_gate=gate, lead_ms=None if change == "implicit_default" else 1240)
                self.assertFalse(result["completed"])
                self.assertTrue(result["issue"].startswith("Refused:"), result["issue"])
                self.assertIn("bound readiness configuration", result["issue"])
                self.assertEqual(sum(row["event"] == "controller_start_gate_go" for row in sink.rows), 1)
                self.assertEqual((result["report_count"], result["driver_report_count"]), (0, 0))
                self.assertEqual(reports_of(sink), [])
                self.assertEqual(backend.states, [h.State(left_x=1 / 32767), h.NEUTRAL, h.NEUTRAL, h.NEUTRAL])
                self.assertEqual(backend.closed, 1)
                self.assertTrue(result["neutral_release_succeeded"] and result["disconnect_succeeded"])

    def test_cli_resolves_default_lead_once_before_guard_callbacks(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="gate-cli-default-", dir=folder) as temporary, \
                patch.object(h, "PEDAL_LEAD_MS", 1240):
            gate_path, ledger = Path(temporary) / "gate", Path(temporary) / "trial.jsonl"
            owner, backend, test = h.Owner(123, 456, "game", "A" * 64), Backend(), self

            class GoClock(h.PreviewClock):
                def sleep(self, seconds):
                    super().sleep(seconds)
                    ready, go = gate_path / "ready.json", gate_path / "go.json"
                    if ready.exists() and not go.exists():
                        test.assertEqual(json.loads(ready.read_text())["pedal_lead_ms"], 1240)
                        pending = gate_path / "go.pending"
                        pending.write_text(json.dumps(dict(schema=1, event="bmx_virtual_gamepad_go",
                            process_id=123, process_creation_filetime="456", nonce="a" * 32)))
                        pending.rename(go)
            clock = GoClock()

            def changed_default(_owner):
                self.assertEqual(_owner, owner)
                h.PEDAL_LEAD_MS = 1500
                return Guard(clock)

            with patch.object(h, "load_owner", return_value=owner), patch.object(h, "WindowsGuard", side_effect=changed_default), \
                    patch.object(h, "Clock", return_value=clock), patch.object(h, "make_vgamepad", return_value=backend), \
                    patch("builtins.print"):
                code = h.main(["--execute", "--owner", "unused-owner", "--scenario", "coast-long",
                               "--ledger", str(ledger), "--start-gate", str(gate_path), "--start-nonce", "a" * 32])
            self.assertEqual(code, 0)
            rows = [json.loads(line) for line in ledger.read_text().splitlines()]
            self.assertEqual(rows[0]["pedal_lead_ms"], 1240)
            self.assertEqual(rows[0]["timeline"], [h.asdict(event) for event in h.scenario_timeline("coast-long", 1240)])
            self.assertTrue(rows[-1]["completed"])
            self.assertEqual((backend.states[-1], backend.closed), (h.NEUTRAL, 1))


class StartGateRequirementTests(unittest.TestCase):
    """A live run of a TOOL-1(b) or TOOL-2 scenario needs the start gate; the nine older ones do not."""
    def test_gated_names_are_exactly_the_new_scenarios(self):
        self.assertEqual(h.GATED_SCENARIO_NAMES, ("pedal-straight", *h.LONG_SCENARIO_NAMES))
        self.assertEqual(set(h.GATED_SCENARIO_NAMES), set(h.scenario_names()) - set(h.scenarios()))

    def test_live_new_scenario_without_gate_refuses_before_owner_ledger_game_or_device(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-gate-required-test-", dir=folder) as temporary, \
                patch.object(h, "PEDAL_LEAD_MS", 1240):
            path = Path(temporary) / "refused.jsonl"
            for name in h.GATED_SCENARIO_NAMES:
                with self.subTest(name=name):
                    with patch.object(h, "load_owner", side_effect=AssertionError("No owner read")), \
                            patch.object(h, "StartGate", side_effect=AssertionError("No gate directory")), \
                            patch.object(h, "WindowsGuard", side_effect=AssertionError("No game inspection")), \
                            patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver import")), \
                            patch("sys.stderr", new_callable=io.StringIO) as stderr, \
                            self.assertRaises(SystemExit) as error:
                        h.main(["--execute", "--owner", "stub-receipt", "--scenario", name, "--ledger", str(path)])
                    self.assertEqual(error.exception.code, 2)
                    self.assertIn(f"--scenario {name} requires --start-gate and --start-nonce", stderr.getvalue())
                    self.assertFalse(path.exists())

    def test_live_new_scenario_with_gate_passes_the_check_and_reaches_the_owner_receipt(self):
        with patch.object(h, "PEDAL_LEAD_MS", 1240):
            for name in h.GATED_SCENARIO_NAMES:
                with self.subTest(name=name), \
                        patch.object(h, "load_owner", side_effect=h.Refused("owner receipt reached")), \
                        patch.object(h, "WindowsGuard", side_effect=AssertionError("No game inspection")), \
                        patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver import")), \
                        self.assertRaisesRegex(h.Refused, "owner receipt reached"):
                    h.main(["--execute", "--owner", "stub-receipt", "--scenario", name,
                            "--start-gate", "unused-gate", "--start-nonce", "a" * 32])

    def test_older_scenarios_still_run_live_without_the_gate(self):
        for name in h.scenarios():
            with self.subTest(name=name), \
                    patch.object(h, "load_owner", side_effect=h.Refused("owner receipt reached")), \
                    patch.object(h, "make_vgamepad", side_effect=AssertionError("No driver import")), \
                    self.assertRaisesRegex(h.Refused, "owner receipt reached"):
                h.main(["--execute", "--owner", "stub-receipt", "--scenario", name])

    def test_gated_live_pause_run_through_main_completes_with_fakes(self):
        folder = h.WORKSPACE / "build" / "bmx"
        with tempfile.TemporaryDirectory(prefix="virtual-pad-gated-main-test-", dir=folder) as temporary:
            gate_path, ledger = Path(temporary) / "gate", Path(temporary) / "pause.jsonl"
            go_fields = dict(schema=1, event="bmx_virtual_gamepad_go", process_id=123,
                             process_creation_filetime="456", nonce="a" * 32)

            class GoClock(h.PreviewClock):
                def sleep(self, seconds):
                    super().sleep(seconds)
                    ready, go = gate_path / "ready.json", gate_path / "go.json"
                    if ready.exists() and not go.exists():
                        pending = gate_path / "go.pending"
                        pending.write_text(json.dumps(go_fields))
                        pending.rename(go)
            clock, backend = GoClock(), Backend()
            with patch.object(h, "load_owner", return_value=h.Owner(123, 456, "game", "A" * 64)), \
                    patch.object(h, "WindowsGuard", return_value=Guard(clock)), patch.object(h, "Clock", return_value=clock), \
                    patch.object(h, "make_vgamepad", return_value=backend), patch("builtins.print"):
                code = h.main(["--execute", "--owner", "stub-receipt", "--scenario", "pause-menu-20s", "--ledger", str(ledger),
                               "--start-gate", str(gate_path), "--start-nonce", "a" * 32])
            self.assertEqual(code, 0)
            rows = [json.loads(line) for line in ledger.read_text().splitlines()]
            events = [row["event"] for row in rows]
            self.assertLess(events.index("controller_start_gate_go"), events.index("controller_report"))
            self.assertEqual((rows[-1]["event"], rows[-1]["report_count"], rows[-1]["completed"]),
                             ("controller_session_end", 1001, True))
            self.assertEqual(sum(state == h.State(h.START) for state in backend.states), 10)
            self.assertEqual((backend.states[-1], backend.closed), (h.NEUTRAL, 1))


if __name__ == "__main__":
    unittest.main(verbosity=2)
