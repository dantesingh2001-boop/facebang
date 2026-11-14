# Face Bang — universal, zero-delay

A single self-contained Lua script. No external UI library, no key system, no
`loadstring` of someone else's code.

```
facebang/
  facebang.lua      the built, single-file deliverable (~1700 lines)
  build.sh          concatenates src/ + lib/ into facebang.lua
  src/core.lua      facebang engine + capability probing
  src/ui.lua        tabbed panel, PC + touch sizing
  src/main.lua      closes the wrapper
  lib/targets.lua   per-player actions
  lib/self.lua      local-player utilities
  test/mock.lua     fake Roblox API used by the smoke test
  test/driver.lua   behavioural checks
```

## Use

Paste the contents of `facebang.lua` into your executor and run it, or:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/dantesingh2001-boop/facebang/main/facebang.lua"))()
```

A tabbed panel opens. It scales itself down and clamps into the safe area on
phones and small windows, so it works on PC and mobile without two layouts.

| tab | what is in it |
| --- | --- |
| **Aim** | bang nearest, loop / auto-retarget, stop + restore, power, vertical offset, release-from-seat |
| **Self** | god mode, noclip, fly + fly speed, walk speed, jump power, anti-void + floor Y, invisible, anti-AFK, freeze my character, restore everything |
| **Players** | pick a player, then bang / teleport to / fling / freeze (local view) / thaw / follow / spectate |
| **Server** | time of day, no fog, copy job id, rejoin, server hop, unload |

Desktop hotkeys: `B` bang, `L` loop, `X` stop, `RightShift` show/hide. On touch,
tap rows and use the `-` button in the header to hide the panel.

API:

```lua
local F = getgenv().FaceBang
F.Bang()                      -- nearest, or F.Bang(player)
F.Stop()
F.Config.Power = 20
F.Self.godMode(true)
F.Targets.teleportTo(game.Players:FindFirstChild("Name"))
F.Capabilities                -- what this executor actually exposed
F.Unload()
```

## What this deliberately does not do

- **No game-crash payloads.** Crashing a server is a denial-of-service against
  every player in it. The classic "crash" scripts also target engine bugs that
  are patched, so they mostly do nothing today.
- **No server-wide freeze.** A client cannot stop another client's rendering.
  "Freeze" here locks a target's replicated position in *your* view, and
  "freeze my character" anchors only you. Both are labelled that way in the UI.
- **No anchored-target flinging.** If a game anchors characters, no client-side
  physics can move them. The script says so instead of silently failing.

## Seat games (Mic Up and similar)

Voice/seat games were the main place facebang silently did nothing, for three
reasons, all handled now:

1. A seated target's root is welded to a chair, so the impulse went into the
   chair. The script sets `Sit = false` and drops the root's weld before
   banging. This is client-side; their own screen may still show them seated.
2. The humanoid is in the `Seated` state; it is pushed to `GettingUp` first.
3. Anchored characters are refused with a message rather than a quiet no-op.

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
bash build.sh
cat test/mock.lua facebang.lua test/driver.lua > /tmp/smoke.lua
luau /tmp/smoke.lua
```

34 checks: script loads, registers itself, the hot path runs clean, the root
ends up on the victim's head, an impulse is written, hit detection fires, stop
restores position / state / collisions, dead targets are refused, and unload
destroys the GUI, plus the self tools (speed, jump, noclip, anti-void, god
mode, local freeze) and the target actions (teleport, freeze, thaw). All pass.
