# Private uphill forearm repair

The captured native rig has twelve existing uphill pose rejections at full
pedaling and steering +/-0.4. Each original full/half/zero posture proposal
passes contacts but exceeds the retained 10 cm elbow-to-wrist height limit.
The uphill cue already reduces that gap; the existing private repair excludes
this posture route. The reference for a correction is its own same-strength
proposal, rather than the uncommitted source pose returned after rejection.

This follow-up uses the existing default-off `ForearmRepairCandidate` profile.
Inside the already validated ordinary posture block, it first completes the
original 1/0.5/0 search. Every valid original winner, including reduced-strength
fallbacks, returns unchanged. Only an exhausted search can enter the private
correction pass. Invalid source/frame/root/rig data cannot enter through a
generic failed-solve retry.

Each correction starts from the same prepared source and compares against the
retained proposal at that strength. All native positions, scales and unrelated
rotations remain identical. The original 3 mm contact, finite-output and anatomy
gates remain required. The extra clavicle aim drop stays capped at 1 cm, with
one endpoint and eight midpoint evaluations per strength. Retaining the three
original proposals bounds the complete search at 14 candidate solves: three
originals, two failed endpoints and a final nine-evaluation success. The observed
first-strength success uses 12 solves. Diagnostics separate original attempts,
extra evaluations and actual winning posture strength.

Admission also requires mounted ownership, enabled ordinary posture capability,
valid uphill/gaze lanes and steering within +/-0.4. Spring, coupled/observed
posture, entry, carry, airborne, load, trick and released-contact routes stay
excluded. The existing private launch selection and native write permissions
are unchanged.

Validation on the frozen production source:

- MSVC Release builds and passes all 95 CTests in 25.71 seconds.
- An independent MSVC comparison against the preserved `90b0cda` pose header
  and repair policy passes 87,001 checks across 43,200 paired cases. All 21,600
  unselected routes and 21,000 originally valid selected routes preserve every
  result field and all 395 bone records exactly. The remaining 600 reachable
  failures are repaired under the unchanged gates.
- The new fixture suite exercises the 21,600-frame reachable matrix, synthetic
  half/zero fallback witnesses, exclusion/invalid-source cases, retry bounds and
  six sampled forward/reverse transitions. In the reachable matrix, maximum extra
  aim drop is 5.195312 mm and maximum hand/foot errors are 0.068239/0.052858 mm.
  Across the six transitions, maximum adjacent change
  attributable to the repair is 0.253498 mm. These are CPU fixture measurements
  on one captured rig and synthetic policy witnesses.
- The existing 13,321-case regression retains all 264 original failures in its
  accounting: 252 neutral/pedaling repairs plus the twelve newly admitted uphill
  repairs. All 13,057 valid outputs remain byte-identical.

The MSVC CPU benchmark uses 100 warmups and 1,000 samples per mode. The observed
first-strength repair takes 2.3044 ms median / 2.4155 ms p95, versus 1.2947 /
1.4094 ms for the unselected original refusal. Its measured cumulative C++
allocation traffic is 558 calls / 6,684,234 bytes per solve. A valid selected
posture takes 0.2166 ms median, versus 0.4476 ms unselected, due to the scoped
transform cache. These measurements include the complete solver but are not
native callback/frame timings. Allocation traffic remains high, and the solver
may run in both animation and render callbacks.

Runtime SHA-256:
`AE0DC907BEA9C505A952FCCE4CF9F92601DB1CE91215B1497BBB4DEF1D2C6076`.
Source, frozen comparisons, binaries, CSVs and receipts are retained locally
under `build/bmx/overnight-review20261021/uphill-production-integration/`.
The separately frozen wider scratch matrix includes stress-only failures above
the current steering limit; they do not justify enlarging this candidate's
admission range or correction cap.

Native rendered alignment, callback cost and normal controller get-up remain
unverified on this runtime. The pending Computer Use app-access approval still
prevents a foreground-owned controller trial. No current likeness score or
ordinary adoption follows from this private checkpoint.

Later follow-up on 22 October: Computer Use app access was granted, and the
same runtime's three scripted game-facing controller GetUp observations are
recorded in the [controller recovery checkpoint](2026-10-22-controller-getup.md).
Those trials used the Default rider pose with private forearm repair unselected.
Native rendering and callback cost of this private repair remain unverified;
the earlier approval/coverage statement above is preserved as checkpoint history.
