# Body follow ownership policy

`Engine/Game/Skater/body_follow.h` is an internal, allocation-free ownership
model for a future general rider-to-body translation service. It has no native
adapter, hook, actuator or plugin API. Compiling its tests does not activate
following in Skate. BMX behavior and offsets remain a Lua plugin concern.

A session uses the caller's existing process-wide `actor_control::Arbiter`.
It reserves one `follow` ticket before admission and publishes that same ticket
only after actor, body and competing-writer qualifications succeed. The caller
must serialize the model and keep the arbiter alive through every native call.
There is one retained receipt per session; it prevents replacement until a
terminal, released claim is acknowledged.

Actor/body identifiers are opaque qualification tokens, not pointers or proof
that a native allocation is still alive. A future adapter must compare actual
world bindings before assigning the common world token; its independent actor
and body generation counters cannot be assumed interchangeable.

The adapter supplies an immutable measured sample with its original body
generation, serial, observation time and native time. A sample can be at most
100 ms old. An active publication has a 200 ms lease. Repeating the identical
sample does not renew it; new samples must advance serial and native time and
cannot move observation time backwards. The model never predicts a pose,
relabels an old sample, computes forces or chooses rider offsets.

Accepted native scopes borrow the shared ticket through `actor_control::Call`.
Expiry, qualification loss, an explicit release or VM unload stop new scopes.
A saved publication must still match the current revision and qualification at
each use edge. Returning from the original native function drains a scope; it
does not establish that a pending native write was consumed.

After publication, release requires both independently qualified barriers:
native consumption/retirement of the final writer, and the owned body parked.
Each witness binds the complete release revision, actor, body, ticket and
revocation stamp. It must be observed strictly after revocation and after all
accepted scopes have drained. Merely clearing arbiter bits, advancing a timer
or observing a zero callback count cannot substitute for either witness.
Unknown cleanup retains a quarantined claim. Unpublished admission can instead
be abandoned because it has not supplied a native publication.

A contended revoke stops local publication immediately. Later cleanup may retry
the transition of that exact retained ticket, without a new reservation or
publication. The release record is sealed only when the actual gate reaches
revoking; retry cannot replace an existing record or prepay either witness.
Lease creation requires enough clock headroom for its deadline, while later
monotonic cleanup timestamps do not need room to create another lease.

The current `owned_bodies::release()` permanently retires its allocation and
retains its slot; it is not reusable parking. A native adapter still needs a
qualified body-sample borrow, shared actor-ticket binding, exclusive dispatch
against other native writers, and a concrete pending-write retirement witness.
Repeated attach/detach also needs a distinct body park/resume contract. None of
these native capabilities is supplied or demonstrated by this policy checkpoint.

With `DINGOSDK_BUILD_PLUGIN_TESTS=ON`, `dingosdk_body_follow_tests` checks the
model's shared-domain exclusion, stale and regressing samples, publication
revisions, in-flight release, separate cleanup witnesses, VM unload, lost
ownership and bounded identifier exhaustion. These are constructed policy
tests with zero native actions; in-game alignment remains unverified. Production
`Session` binds the real arbiter. The generic `BasicSession` test seam permits a
wrapper that refuses one revoke and otherwise delegates to that same real
arbiter, including actual in-flight scopes; it supplies no native cleanup facts.
