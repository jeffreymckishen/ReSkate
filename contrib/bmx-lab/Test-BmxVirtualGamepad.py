"""Focused fake-backend/clock/Win32 metadata tests. Never imports vgamepad."""
import ctypes
import importlib.util
import json
from pathlib import Path, PureWindowsPath
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
        names = ["A", "B", "Y", "LEFT_SHOULDER", "RIGHT_SHOULDER", "RIGHT_THUMB"]
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
