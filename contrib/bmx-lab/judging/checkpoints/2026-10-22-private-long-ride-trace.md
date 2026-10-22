# Private capture window for ordinary controller trials

The four-second ride tail in runs 297 and 301 excluded earlier pedal inputs
by the time screen inspection and parking finished. `-LongRideTrace` now selects
up to 3,600 accepted samples in the exact isolated ordinary human-native test
profile. The default remains 240 samples. This changes diagnostics, not physics
or controller timing limits.

The private mode allocates two fixed buffers before chassis activation. Sealing
exchanges pointers rather than copying a large history. Allocation failure
disables the selected capture with a warning; it does not claim a short fallback.
Eight captures are allowed per process. Existing token/serial admission,
pending-report preservation and idle-only serialization gates remain in force.

MSVC optimized measurements give a 7,256-byte sample and two 26,121,656-byte
long histories: 49.82 MiB of selected buffer storage, in addition to existing
runtime storage. A detailed 3,600-row JSON export may approach 40 MB based on
the earlier 240-row export; that estimate is not a measured new export size.
Retention metadata reports accepted/overwritten counts and actual first/last
native clocks. A sample limit does not guarantee 60 seconds or a complete action.

The Release build passed and all 97 configured CTests passed in 21.55 seconds,
including fake controller and private selector coverage. The built runtime is
`E073F373BA936E6259FBDA4F596B635AD31955ECA68FAC80222AF122AA3302DD`.
The [build receipt](../../../../build/bmx/overnight-review20261021/long-ride-trace-release-build-receipt.json)
pins six selected sources and the build/test logs; it is not a complete compiler
input manifest. Native capture, serialization cost, fall recovery and BMX Streets
likeness remain unqualified at this checkpoint.
