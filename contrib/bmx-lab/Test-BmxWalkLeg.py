"""Fake-only bounded walk checks; no native/Win32/controller operations."""
import contextlib, hashlib, importlib.util, io, json
from pathlib import Path
import sys, tempfile, unittest
from unittest.mock import patch
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(spec);sys.modules[name]=m;spec.loader.exec_module(m);return m
w=module('walk_author',ROOT/'contrib/bmx-lab/Bmx-WalkLeg.py')
f=module('walk_fake_helpers',ROOT/'contrib/bmx-lab/Test-BmxSwitchLeg.py')
class Tests(unittest.TestCase):
    def setUp(self):self.switch=w.load_switch();self.h=w.configure(self.switch)
    def run_fake(self,abort_at=None,fail_at=None,gate=None):
        h=self.h;c=h.PreviewClock();s=f.Sink();b=f.Backend(h,fail_at);g=f.Guard(h,c,abort_at)
        r=h.run(w.timeline(h),g,lambda:b,s,execute=True,clock=c,start_gate=gate)
        return r,b,g,s
    def test_exact_schedule_all_buttons_other_axes_zero_and_cleanup(self):
        h=self.h;self.assertEqual(set(h.scenarios()),{'ordinary-walk-right'})
        self.assertEqual(w.timeline(h),(h.Event(0,h.NEUTRAL),h.Event(240,h.State(left_x=.65)),h.Event(840,h.NEUTRAL),h.Event(3000,h.NEUTRAL)))
        r,b,g,s=self.run_fake();self.assertTrue(r['completed']);self.assertEqual(r['driver_report_count'],151)
        rows=[x for x in s.rows if x['event']=='controller_report']
        self.assertEqual([x['planned_ms'] for x in rows if x['state']['left_x']],list(range(240,840,20)))
        self.assertEqual(sum(x['state']['left_x']==0 for x in rows),121)
        for x in rows:
            p=x['state'];self.assertIn(p['left_x'],(0,.65));self.assertTrue(all(v==0 for k,v in p.items() if k!='left_x'))
        self.assertTrue(r['neutral_release_succeeded'] and r['disconnect_succeeded']);self.assertEqual(b.states[-1],h.NEUTRAL)
        self.assertEqual((b.closed,g.closed),(1,1));self.assertIsNone(r['input_consumed']);self.assertIsNone(r['native_quality'])
    def test_real_base_guard_run_limits_and_two_second_preflight_unchanged(self):
        sw=w.load_switch();raw=sw.load_driver();names=('main','run','WindowsGuard','bootstrap','make_vgamepad','validate_timeline');old={n:getattr(raw,n) for n in names};gate=raw.StartGate
        with patch.object(sw,'load_driver',return_value=raw):h=w.configure(sw)
        for n,v in old.items():self.assertIs(getattr(h,n),v)
        self.assertTrue(issubclass(h.StartGate,gate));self.assertEqual((h.MAX_LATE_MS,h.MAX_DURATION_MS,h.START_GATE_LIMIT_MS,h.PERIOD_MS),(120,6000,60000,20))
        ready=[]
        def original_wait(gate,guard,ledger,clock):guard.check();ready.append(clock.now())
        with patch.object(self.h.StartGate.__bases__[0],'wait',original_wait):r,_,_,_=self.run_fake(gate=f.nonlead_gate(self.h,w.SCENARIO))
        self.assertTrue(r['completed']);self.assertEqual(len(ready),1);self.assertGreaterEqual(ready[0],2)
    def test_missing_live_gate_including_abbreviations_before_source(self):
        for args in (['--execute'],['--exec'],['--e'],['--exec','--start-gate','fake'],['--execute','--start-nonce','a'*32]):
            with self.subTest(args=args),patch.object(w,'load_switch',side_effect=AssertionError('loaded before gate')):
                with self.assertRaisesRegex(w.Refused,'requires a fresh'):w.main(args)
    def test_unknown_scenario_rejected_before_loading_and_hash_fail_closed(self):
        for scenario in ('native-y','equipment-switch-observe','ordinary-approach-right','ordinary-walk-left','unknown'):
            with self.subTest(scenario=scenario),patch.object(w,'load_switch',side_effect=AssertionError('loaded unsupported')),contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as e:w.main(['--scen',scenario])
                self.assertEqual(e.exception.code,2)
        with patch.object(Path,'read_bytes',return_value=b'raise RuntimeError("must not execute")'),patch.object(w.types,'ModuleType',side_effect=AssertionError('allocated before hash')):
            with self.assertRaisesRegex(w.Refused,'source changed'):w.load_switch()
        self.assertEqual(hashlib.sha256(w.SWITCH_PATH.read_bytes()).hexdigest().upper(),w.APPROVED_SWITCH_SHA256)
        self.assertEqual(hashlib.sha256(self.switch.BASE_PATH.read_bytes()).hexdigest().upper(),self.switch.APPROVED_BASE_SHA256)
    def test_guard_loss_driver_failure_and_preflight_abort_cleanup(self):
        for options in ({'abort_at':.5},{'abort_at':1.1},{'fail_at':25}):
            with self.subTest(options=options):
                r,b,g,_=self.run_fake(**options);self.assertFalse(r['completed']);self.assertTrue(r['neutral_release_succeeded'] and r['disconnect_succeeded']);self.assertEqual(b.states[-1],self.h.NEUTRAL);self.assertEqual((b.closed,g.closed),(1,1))
        with patch.object(self.h.StartGate.__bases__[0],'wait',side_effect=AssertionError('ready after guard loss')):
            r,b,_,_=self.run_fake(abort_at=1,gate=f.nonlead_gate(self.h,w.SCENARIO))
        self.assertFalse(r['completed']);self.assertEqual(r['driver_report_count'],0);self.assertTrue(r['neutral_release_succeeded'] and r['disconnect_succeeded'])
    def test_owner_before_backend_and_actual_default_dryrun_driver_free(self):
        h=self.h
        with patch.object(w,'configure',return_value=h),patch.object(h,'WindowsGuard',side_effect=AssertionError('Win32 before owner')),patch.object(h,'make_vgamepad',side_effect=AssertionError('backend before owner')),contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as e:w.main(['--exec','--start-gate','fake','--start-nonce','a'*32])
            self.assertEqual(e.exception.code,2)
        scratch=ROOT/'build/bmx'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as tmp,contextlib.redirect_stdout(io.StringIO()):
            ledger=Path(tmp)/'walk.jsonl';self.assertEqual(w.main(['--ledger',str(ledger)]),0)
            rows=[json.loads(x) for x in ledger.read_text().splitlines()];reports=[x for x in rows if x['event']=='controller_report']
            self.assertEqual(len(reports),151);self.assertTrue(all(x['driver_submitted'] is False for x in reports))
        self.assertFalse(any(n=='vgamepad' or n.startswith('vgamepad.') for n in sys.modules))
if __name__=='__main__':unittest.main(verbosity=2)
