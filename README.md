# Face Bang — universal, zero-delay

A single self-contained Lua script. No external UI library, no key system, no
`loadstring` of someone else's code.

```
facebang/
  facebang.lua      the script (drop-in, ~800 lines)
  test/mock.lua     fake Roblox API used by the smoke test
  test/driver.lua   behavioural checks
  README.md
```

## Use

Paste the contents of `facebang.lua` into your executor and run it. Or host it
and use a one-liner:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/<you>/<repo>/main/facebang.lua"))()
```

GUI appears top-left. Keys:

| key | action |
| --- | --- |
| `B` | bang the nearest player (again to stop) |
| `L` | loop mode: auto-retarget the closest living player |
| `X` | stop and restore your character |
| `RightShift` | show / hide the panel |

Pick a specific target by clicking a name in the **TARGET** list first.

API (from the console or another script):

```lua
getgenv().FaceBang.Bang(game.Players:FindFirstChild("Name"))  -- or Bang() for nearest
getgenv().FaceBang.Stop()
getgenv().FaceBang.Config.Power = 20
getgenv().FaceBang.Capabilities  -- what this executor actually exposed
getgenv().FaceBang.Unload()
```

## How it works

The classic character-overlap bug: your `HumanoidRootPart` is written into the
target's `Head` every frame, together with a matching linear velocity. The
assemblies overlap, the physics step resolves it, the victim is launched.

Zero delay means:

- `RenderStepped` does the write, `Heartbeat` catches physics steps the render
  pass misses. Two writes per frame, no `task.wait`, no sleeps anywhere.
- Target references are cached and only re-resolved every 10 ticks.
- The hot path allocates nothing: no service lookups, no closures, no tables.

Impulse is `clamp(delta * Power, MinSpeed, MinSpeed * 5)`, so a hit that is
already locked on the head still carries momentum instead of collapsing to ~0.

## Requirements and honest limits

- Needs an executor that can write `CFrame` and `AssemblyLinearVelocity`
  (`Velocity` is used as a fallback), plus `RenderStepped`. That is all.
  Optional extras (`sethiddenproperty`, `setsimulationradius`, `gethui`,
  `cloneref`, `identifyexecutor`) are probed and used when present; every one
  of them is wrapped so a missing function cannot break the script.
- Client-side only. It does nothing in games where the server keeps network
  ownership, disables player-vs-player collision, or validates teleports.
  Those limits are the server's, not the script's.
- Voice-chat games sometimes stream character data from the server, so the
  victim may see the teleport in your own position briefly. Normal.
- You may launch yourself too. `X` restores your position, humanoid state and
  collisions; nothing else in your character is touched.

## Verifying it

```bash
cat test/mock.lua facebang.lua test/driver.lua > /tmp/smoke.lua
luau /tmp/smoke.lua
```

16 checks: script loads, registers itself, the hot path runs clean, the root
ends up on the victim's head, an impulse is written, hit detection fires, stop
restores position / state / collisions, dead targets are refused, and unload
destroys the GUI. All pass.
