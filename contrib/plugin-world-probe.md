# A world ray with an explicit query result

`reskate.world.probe(from, to)` needs the existing `world.raycast` permission.
Both arguments are Luau vectors in world metres. There are no optional native
handles, ignored bodies or entity arguments.

The result is a table with one of three statuses:

| `status` | Meaning | Other fields |
|---|---|---|
| `unavailable` | This call did not establish a valid query result. | None |
| `clear` | The query completed without a collision on this segment. | None |
| `hit` | The query completed with a valid closest hit. | `position` (vector), `fraction` (number from0 to1) |

```lua
local result = reskate.world.probe(from, to)
if result.status == "hit" then
    reskate.log(tostring(result.position) .. " at " .. tostring(result.fraction))
elseif result.status == "unavailable" then
    -- Defer a decision that requires actual collision evidence.
end
```

Normals and surface velocity are not available from this query and are omitted
(`result.normal` and `result.surface_velocity` are nil). No world epoch, owner,
entity ID, body reference or native address is exposed. A successful query does
not prove that collision for the whole surrounding region has streamed.

The two positions must be finite and within100km of the map centre, and the
segment must be at most1000m long under the default host limits. Invalid
arguments raise a Lua error. A degenerate segment (squared length below1e-10m²)
returns `unavailable` without calling the backend. It still spends a query.
Each call shares the existing per-plugin ray budget with `world.raycast` and
`world.pick`:64 total calls per tick under the default limits. Exceeding the
budget raises a Lua error before reaching the backend.

Only a finite hit within the map bounds, with fraction in[0,1] and position
consistent with that segment/fraction within25mm per coordinate, is exported.
Malformed hit data is `unavailable`, never a clear ray. These checks validate the
result representation;25mm is not a claim of collision accuracy.

The runtime uses the existing client-thread `probe_local_surface` path under
its native mutex. It resolves the current client TLS context/world each call.
This adapter supplies no exclusions, so that path makes at most one native cast
and may hit any collision the native query includes. It does not claim a
post-query world/owner-generation fence. A missing context/world, unavailable
native contract or malformed native result remains `unavailable`.

The existing `world.raycast` and `world.pick` interfaces are unchanged. This
observation primitive provides no force, impulse, body creation, actor motion,
pose write or gameplay activation service.
