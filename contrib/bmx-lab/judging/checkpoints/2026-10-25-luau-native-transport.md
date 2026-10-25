# Luau native transport checkpoint, October 25

The isolated supported Skate build completed one Luau-controlled owned-body and
zero-command cleanup trial. This qualifies a narrow SDK transport path. It does
not qualify riding or BMX Streets likeness. All BMX behavior in this trial is Lua;
the runtime supplies general permissioned input, body and Follow APIs.

The tested runtime was built from `8d29091a8add8b3f5d21414ffd3b6eab8008d0b3`:

- Runtime SHA-256: `4B7BD8D7C2D256D2C78315624E81FF50E105DFF6169547B324D5414C0D790D66`.
- Launcher SHA-256: `DF0589DB9A2FB1805967B43932A124DFB1F4284EB07FF573A71F574D02C467E6`.
- Both native BMX prototype build options were off.
- The merged checkpoint passed 46 selected normal test groups and five additional
  incoming-change groups. These results precede the later contact-test promotion.

The later contact promotion built the normal plugin target and passed CTest's
`plugins` group, including the exact 48-case/128-assertion Lua contact marker once.
The default 50 ms call and 2 ms average tick limits stayed unchanged. Fifteen
unavailable optional sample mods still earned no pass credit. The first attempt
stopped in an existing cold-import fixture before reaching the contact suite; its
failure remains preserved. After scheduling those imports across ticks, the fresh
run passed. The local result is `D92D5BD656D538BE9DBEBF7153530D009BD2C80DF8A35BD1C25B0C82BE07CACD`
in `contact-normal-host-20261025T061827729Z`. This is constructed Host integration,
not another native gameplay result.

## Observed in Skate

The private Force7 trial used UUID `5c1db549-702c-44ce-a61c-7a37403970a7`.
The controller first completed 301 neutral reports, then a separate 1,001-report
20-second window. Both runs had actual slot-zero neutral readbacks, final neutral
release and disconnect. The existing 120 ms lateness guard remained unchanged.

Lua acquired the observed input stream and capture, created one owned physics
body, and submitted exactly one zero-force/zero-torque command. Its receipt changed
from queued to applied: requested physics serial `140354`, produced serial `140355`.
Follow returned revision `1`, completed, observed a park and was acknowledged.
The force receipt was acknowledged as `parked_without_successor`; input and capture
finished without report debt. Eight visual-removal requests were accepted. No
Board action or equipment pulse was requested. The plugin was then unloaded with
cleanup clear.

These observations do not establish physical response to a nonzero force, engine
consumption beyond the reported setter path, native allocation destruction, rendered
grip/pedal alignment, repeated switching, fall recovery, sustained riding or tricks.
Accepted removal requests do not prove rendered absence. No likeness score is awarded.

## Evidence and remaining work

The local evidence case is `native-force-cleanup-trial-v7-20261025T055804419Z`
on the development drive. Its actual result hash is
`6132EC45E63319AF4563FFE3C967982CD0D5FA90328BCF5DA756810D152E337F`;
terminal storage is `AD17818D3280C53D151077E2CDEA7C76F3F099E90665205588D176D2A0EEA357`;
post-unload storage is `4CE179B0D2077FB6EA17F75B55874806AFAA1E02B6ED46140016539ADD7EDBDF`.
Independent actual-evidence review is `E906C8F6FEDB59AB80B143E1BCA4051A1A931214A9C3A4DA90E04C6D9C03F5F5`,
with post-unload addendum `4A36262B10D44E89585A5F558C7EF5A2B4ED00E579A56BC8D14D39E2FFB190EB`.
Earlier refused attempts remain preserved and earn no native-trial credit.

The next live check requests a 500 ms Follow interval using the new callback-entry
policy and a genuinely new active body. Force7 used the existing native-lifetime
motion policy, so it does not qualify that new branch. Actor-excluded native
contacts, measured nonzero-force response and rendered rider alignment remain open.
The Lua ride activation gates stay off.

The current World backend retains parked allocations and permits only eight
attempted allocations per process. Preparation alone spends no slot; this trial
spent one. A fresh allocation may be admitted after completed Follow acknowledgement,
but a parked body cannot be reused. Reliable repeated bike/board cycling still
needs a supported ownership/lifetime path; resetting counters or reviving retained
bodies would not establish one.
