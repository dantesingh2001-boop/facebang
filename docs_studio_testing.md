# Testing facebang inside Roblox Studio

The mock (`test/mock.lua`) proves logic. Studio proves the things a mock cannot:
that the UI really renders, and that the engine really moves a humanoid when we
write velocity at it.

## What Studio already proved

Run in a live Client datamodel against a stand-in humanoid rig:

| check | result |
|---|---|
| one `AssemblyLinearVelocity` write at the head | dummy moved **191 studs** |
| our own body under that velocity | moved **140 studs** in 0.45s |
| camera subject stays on the humanoid | yes |
| viewport used for the fit maths | 1072 x 581 |

So the bang primitive is sound in the engine: a velocity write into a humanoid
assembly does launch it. The panel (312x492 base) fits at scale 1 in that
viewport.

Also verified in Studio: `loadstring` available, `getgenv`/`cloneref` shims
sufficient, `HttpService.HttpEnabled` can be set at runtime.

## Blocking issue: getting the source into Studio

The MCP Assistant refuses outbound HTTP unless the domain is allowlisted, and
cannot reach the local disk. Tried and failed:

- `HttpService:GetAsync` to raw.githubusercontent.com -> "not in the Assistant
  HTTP allowlist"
- same to http://127.0.0.1:8731 -> same
- Client datamodel -> "Http requests can only be executed by game server"
- Server datamodel -> "Assistant HTTP permissions are not configured"
- Open Cloud asset upload of an .rbxmx Model -> "Creating Model from a
  application/xml file is not supported yet"

Two ways to unblock, both requiring the user:

1. Add `raw.githubusercontent.com` to the Assistant HTTP allowlist
   (Assistant Settings -> MCP Permissions). Then the harness fetches the live
   URL and tests exactly what users load.
2. Drag `facebang.lua` into the Studio Explorer. It becomes a LocalScript with
   the full source, which the harness can read and `loadstring` directly.

## Harness

`test/studio_harness.lua`. It shims the executor globals (getgenv, cloneref,
identifyexecutor, request), acquires the source, runs it, then checks:

- the script registers `getgenv().FaceBang`
- the UI exists, and the window fits inside the real viewport
- no button is under 20px tall, no label overflows its box
- a humanoid assembly actually moves when velocity is written at its head
- `Unload()` runs and clears the global
