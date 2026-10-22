# Stationary rider diagnostic checkpoint

This adds a passive, manually armed diagnostic for the exact isolated stationary
profile. Ordinary riding and the retained airborne ramp capture keep their prior
selection. A console request queues one attempt; 30 consecutive stable native
samples precede at most 128 source/solved/native-readback pose records. Arm and
capture have finite wall-clock limits. Ownership, native clock, motion lease and
existing pose-write/readback checks remain mandatory.

The report includes all finger chain indices, the requested handlebar matrix and
the current publication identity. It measures CPU data and SDK requests; it does
not prove rendered skin contact or GPU consumption. No physics, pose or controller
writes are added by the observer.

Independent architecture review found and closed a duplicate-clock validation
hole. A fresh checkpoint judge subsequently found no blocker and scored bounded
engineering correctness 9.0. Likeness remains unrated. Full judge records and
source pins are retained in `build/bmx/overnight-review20261021/`.

The MSVC Release build passes all 89 CTests, including the new 1,349-check policy
fixture and 89-check selector fixture. Runtime SHA-256:
`4225408E4FB304AAE88DB51EB0FB25ED498DE3A9E53FCCAAD2D1C1D46911105B`.
The build first exposed a shadowed local under MSVC warning-as-error; the variable
was renamed and the fresh complete build/suite passed.

Native run 285 on that build accepted its 5.3883 m/s side impact, native fall and
detached bike with the diagnostic disabled. Computer Use app approval timed out
before foreground control, recording or the candidate recovery input. That run
therefore provides no controller GetUp or visual diagnostic acceptance. Its exact
owned process was subsequently closed and absence verified twice. A useful close
view and an armed complete stationary report remain required.

The adaptive neutral-stance candidate, the baseline pedaling/steering anatomy
repair, and the recovery-controller harness are separate work.
