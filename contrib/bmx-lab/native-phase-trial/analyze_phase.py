"""Identify force-to-measured-velocity delay without inventing a native state.

Consumes the complete persisted diagnostic ledger. Every candidate uses the
same native mass, interval and fixed 9.8 m/s^2 gravity. No fitted acceleration,
gain, clock offset or integrated replacement trajectory enters the admission.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct


OFFSETS = (-48, 48, 24, -24, 48, -48, 0)
ABSOLUTE_VELOCITY_TOLERANCE = 2e-5


def f32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


def require(value, reason):
    if not value:
        raise ValueError(reason)


def exact_serial(value):
    require(isinstance(value, str) and value.isascii() and value.isdecimal()
            and value[0] != "0" and 0 < int(value) < 2**64,
            "invalid canonical uint64 decimal serial or sequence")
    return int(value)


def analyze(payload):
    ledger = payload["phase_native_v1"]
    summary, rows = ledger["summary"], ledger["records"]
    require(summary["submitted"] == summary["acknowledged"] == len(rows) == 120,
            "incomplete 120-command transport")
    require(summary["released"] is True, "release not accepted")
    require(summary["profile"] == "seven_step_vertical_v1", "unknown force profile")
    observations, forces, conflicts = {}, {}, []

    def observe(sample, label):
        serial = sample["serial"]
        exact_serial(serial)
        require(sample["mass"] == 12 and abs(sample["seconds"] - 1/60) < 1e-7,
                "mass or native clock changed")
        require(type(sample["time"]) in (int, float) and math.isfinite(sample["time"]) and sample["time"] >= 0,
                "invalid measured time")
        for key in ("position", "velocity", "angular_velocity", "inertia"):
            require(len(sample[key]) == 3 and all(type(v) in (int, float)
                    and math.isfinite(v) for v in sample[key]), "invalid measured vector")
        require(len(sample["rotation"]) == 4 and all(type(v) in (int, float)
                and math.isfinite(v) for v in sample["rotation"])
                and abs(sum(v*v for v in sample["rotation"])-1) < .001,
                "invalid measured rotation")
        require(sample["inertia"] == [f32(.4), f32(.1), f32(.4)], "configured inertia changed")
        key = int(serial)
        if key in observations and sample != observations[key]:
            conflicts.append({"serial": serial, "source": label,
                              "first": observations[key], "later": sample})
        else:
            observations[key] = sample

    first, last_sequence = exact_serial(rows[0]["before"]["serial"]), 0
    for index, row in enumerate(rows):
        n = first + index
        sequence = exact_serial(row["sequence"])
        require(sequence > last_sequence, "service sequences are not unique and increasing")
        last_sequence = sequence
        require(row["index"] == index + 1 and exact_serial(row["before"]["serial"]) == n,
                "requested observations are not consecutive")
        if index:
            before = rows[index-1]["before"]
            require(abs(row["before"]["time"] - before["time"] - before["seconds"]) < 1e-7,
                    "requested observation times are not consecutive")
        require(row["accepted"] is True and row["outcome"] == "applied"
                and row["acknowledged"] is True and row["force_attempted"] is True
                and row["torque_attempted"] is True and row["retained"] is False
                and row["quarantined"] is False, "unqualified command outcome")
        require(exact_serial(row["produced_serial"]) == n + 1
                and exact_serial(row["successor"]["serial"]) == n + 2,
                "application or first successor lost exact epoch pairing")
        expected = [0.0, f32(117.6 + OFFSETS[index % len(OFFSETS)]), 0.0]
        require(row["force"] == expected, "published force differs from frozen profile")
        require(abs(row["successor"]["time"] - row["before"]["time"]
                    - 2*row["before"]["seconds"]) < 1e-7, "successor time changed")
        forces[n] = row["force"]
        observe(row["before"], f"row {index + 1} before")
        observe(row["successor"], f"row {index + 1} successor")
    observe(summary["last"], "summary last measured state")
    require(not summary.get("serial_conflict"), "fixture reported a same-serial native state conflict")

    result = {"transport_complete": True, "unique_measured_epochs": len(observations),
              "same_epoch_conflicts": conflicts, "velocity_tolerance": ABSOLUTE_VELOCITY_TOLERANCE,
              "candidates": [], "qualified": False,
              "boundaries": ["One isolated capsule and one short varying-force burst only",
                             "Identifies velocity visibility, not a global native world barrier",
                             "No closed-loop BMX controller or rider/input/equipment proof"]}
    if conflicts:
        result["reason"] = "same-epoch measured states differ; no stable serial-only phase"
        return result

    # Use the same interior transitions for every delay, including an acausal
    # zero-delay negative control. A seven-step excitation distinguishes them.
    serials = [s for s in sorted(observations)
               if s-1 in observations and all(s-d in forces for d in range(4))]
    require(len(serials) >= 100, "too few common excited measured transitions")
    for delay in range(4):
        residuals, predictions = [], []
        for n in serials:
            before, after = observations[n-1], observations[n]
            h = before["seconds"]
            require(abs(after["time"] - before["time"] - h) < 1e-7,
                    "nonconsecutive measured native time")
            force = forces[n-delay]
            expected = [(force[axis]/before["mass"] - (9.8 if axis == 1 else 0))*h
                        for axis in range(3)]
            actual = [after["velocity"][axis] - before["velocity"][axis] for axis in range(3)]
            residuals.extend(actual[axis] - expected[axis] for axis in range(3))
            predictions.append(expected[1])
        maximum = max(abs(v) for v in residuals)
        result["candidates"].append({"requested_to_velocity_sample_delay_epochs": delay,
            "transitions": len(serials), "maximum_velocity_residual": maximum,
            "rms_velocity_residual": math.sqrt(sum(v*v for v in residuals)/len(residuals)),
            "excitation_range": max(predictions)-min(predictions),
            "within_tolerance": maximum <= ABSOLUTE_VELOCITY_TOLERANCE})
    passed = [candidate for candidate in result["candidates"] if candidate["within_tolerance"]]
    if len(passed) == 1 and passed[0]["requested_to_velocity_sample_delay_epochs"] in (1, 2, 3):
        chosen = passed[0]
        others = [c for c in result["candidates"] if c is not chosen]
        if chosen["excitation_range"] > .1 and min(c["maximum_velocity_residual"] for c in others) > 100*ABSOLUTE_VELOCITY_TOLERANCE:
            result["qualified"] = True
            result["delay_epochs"] = chosen["requested_to_velocity_sample_delay_epochs"]
            result["reason"] = "one causal delay matches fixed mass/gravity physics; shifted negative controls fail"
            return result
    result["reason"] = "velocity visibility is ambiguous or violates the fixed-physics residual bound"
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ledger", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    raw = args.ledger.read_bytes()
    result = analyze(json.loads(raw))
    result["ledger"] = {"path": str(args.ledger.resolve()), "bytes": len(raw),
                        "sha256": hashlib.sha256(raw).hexdigest().upper()}
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: result[k] for k in ("qualified", "reason", "unique_measured_epochs")}))
    return 0 if result["qualified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
