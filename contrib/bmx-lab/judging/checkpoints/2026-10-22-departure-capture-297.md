# Left departure capture and ordinary park — run 297

Run 297 submitted one bounded left-departure request, followed later by a fresh
plain-Y dismount in ordinary `Ride -NativeChassis -HumanNativeSwitch` mode.
PID `45052`, creation FILETIME `134371568383983748`, used runtime SHA256
`B087931D6BE6656EE7D3DC0BE0829A1083DCA60A6D77B2A4D429357ABC0B59C4`.

The executed departure was `ordinary-departure-left`: 201 scheduled reports,
including 50 A reports with left-stick X `-.45` for one second, 200ms neutral
coast, 50 B reports for one second, and otherwise neutral. The later Y session
submitted 301 reports: ten Y and 291 neutral. Owner/runtime/source identities,
distinct ready/GO nonces, session separation, final neutral, disconnect and
parent-observed worker exit passed review. Bootstrap operations are additional.
Straight and malformed drafts were held; their preserved sources are not live results.

The native log records ordinary dismount at `15:42:35.781 UTC`. Its token1 ride
export contains only the last 240 samples, native seconds
`450.399973154068..454.38330624997616`, with raw and sampled pedal/brake all zero.
This later four-second tail excludes the earlier departure; it cannot establish
pedal, steering or brake force application during that request.

The preserved video source/copy SHA256 is
`0F33F9598F0040BCAADDDC2C689785C3DBB615F8B456010F7C10D12C06AAA8E4`.
Three bounded windows supply 52 selected frames from 909 locally decoded frames.
They show a brief leftward lean/steering change with little visible travel,
then ordinary Y step-off and standing beside the upright bike at the final endpoint.
Sustained ride-away, braking response and force consumption remain unqualified.
The [visual review](../../../../build/bmx/human-controller297/video/human297-targeted-visual-review.json)
pins exact PTS/frame hashes; no full-file PTS validation or exact native-clock join is claimed.

The guardian closed the original held process at `15:44:00.5601821 UTC`; two later
CIM observations found no isolated process. The [independent audit](../../../../build/bmx/overnight-review20261021/human-controller297-fresh-judge.json),
SHA256 `F9B1C30EC0BDAB6B9597318B196BBBF3B6F4E10BAFDBB0DBFD018157B82A24BB`,
passed 208 checks against the 64 files actually listed in manifest
`D73101CE3684766B8B6642F3CB371CFDE511549D3944995566DF5E7826F142AE`,
including 20 frozen source entries. Later wrapper supplements have separate pins.
This does not qualify fall/GetUp/remount, physical-controller feel or 9.5 likeness.
