"""Synthetic classifier checks only; these are never native game evidence."""
import copy
import json
from pathlib import Path

from analyze_phase import OFFSETS, analyze, f32


def synthetic(delay=2, gravity=9.8, constant=False):
    h = f32(1/60)
    forces = {100+i: [0., f32(117.6 + (0 if constant else OFFSETS[i % 7])), 0.] for i in range(120)}
    samples, speed, height = {}, 0., 1.5
    for n in range(100, 222):
        if n > 100:
            speed += (forces.get(n-delay, [0., 0., 0.])[1]/12-gravity)*h
            height += speed*h
        samples[n] = {"serial": str(n), "time": 2+(n-100)*h, "seconds": h,
                      "mass": 12, "position": [0., height, 0.],
                      "velocity": [0., speed, 0.], "angular_velocity": [0., 0., 0.],
                      "inertia": [f32(.4), f32(.1), f32(.4)], "rotation": [0., 0., 0., 1.]}
    rows = [{"index": i+1, "sequence": str(i+1), "force": forces[100+i],
             "before": copy.deepcopy(samples[100+i]), "accepted": True,
             "outcome": "applied", "acknowledged": True, "force_attempted": True,
             "torque_attempted": True, "retained": False, "quarantined": False,
             "produced_serial": str(101+i), "successor": copy.deepcopy(samples[102+i])}
            for i in range(120)]
    return {"phase_native_v1": {"summary": {"submitted": 120, "acknowledged": 120,
            "released": True, "profile": "seven_step_vertical_v1",
            "last": copy.deepcopy(samples[220])}, "records": rows}}


def main():
    checks = []
    for delay in (1, 2, 3):
        result = analyze(synthetic(delay))
        assert result["qualified"] and result["delay_epochs"] == delay
        checks.append({"case": f"known synthetic delay {delay}", "pass": True})
    result = analyze(synthetic(0))
    assert not result["qualified"] and result["candidates"][0]["within_tolerance"]
    checks.append({"case": "acausal zero-delay negative control rejected", "pass": True})
    result = analyze(synthetic(gravity=9.7))
    assert not result["qualified"]
    checks.append({"case": "wrong gravity cannot be fitted away", "pass": True})
    payload = synthetic()
    payload["phase_native_v1"]["records"][10]["successor"]["velocity"][1] += .001
    result = analyze(payload)
    assert not result["qualified"] and result["same_epoch_conflicts"]
    checks.append({"case": "same-epoch velocity conflict prevents admission", "pass": True})
    payload = synthetic()
    payload["phase_native_v1"]["records"][10]["successor"]["position"][0] += .001
    result = analyze(payload)
    assert not result["qualified"] and result["same_epoch_conflicts"]
    checks.append({"case": "same-epoch pose conflict prevents admission", "pass": True})
    payload = synthetic()
    payload["phase_native_v1"]["summary"]["last"]["velocity"][1] += .001
    result = analyze(payload)
    assert not result["qualified"] and result["same_epoch_conflicts"]
    checks.append({"case": "summary final sample conflict prevents admission", "pass": True})
    payload = synthetic()
    for row in payload["phase_native_v1"]["records"]:
        for key in ("before", "successor"):
            n = int(row[key]["serial"])
            row[key]["velocity"][1] += .001*(n % 2)
    n = int(payload["phase_native_v1"]["summary"]["last"]["serial"])
    payload["phase_native_v1"]["summary"]["last"]["velocity"][1] += .001*(n % 2)
    result = analyze(payload)
    assert not result["qualified"] and not result["same_epoch_conflicts"]
    checks.append({"case": "consistent but incorrect measured response rejected", "pass": True})
    for case, mutate in (
        ("wrong force profile rejected", lambda p: p["phase_native_v1"]["records"][10]["force"].__setitem__(1, 117.6)),
        ("late producer rejected", lambda p: p["phase_native_v1"]["records"][10].__setitem__("produced_serial", "113")),
        ("partial command rejected", lambda p: p["phase_native_v1"]["records"][10].__setitem__("outcome", "partial")),
        ("incomplete command stream rejected", lambda p: p["phase_native_v1"]["summary"].__setitem__("acknowledged", 119)),
        ("duplicate service sequence rejected", lambda p: p["phase_native_v1"]["records"][10].__setitem__("sequence", "10")),
        ("noncanonical producer string rejected", lambda p: p["phase_native_v1"]["records"][10].__setitem__("produced_serial", "0111")),
        ("negative native time rejected", lambda p: p["phase_native_v1"]["records"][0]["before"].__setitem__("time", -1)),
    ):
        payload = synthetic()
        mutate(payload)
        try:
            analyze(payload)
        except ValueError:
            checks.append({"case": case, "pass": True})
        else:
            raise AssertionError(case)
    out = {"kind": "synthetic offline classifier checks only", "checks": checks,
           "native_evidence": False}
    Path(__file__).with_name("analysis-test-results.json").write_text(json.dumps(out, indent=2)+"\n", encoding="utf-8")
    print(f"{len(checks)} synthetic classifier checks passed; no native evidence")


if __name__ == "__main__":
    main()
