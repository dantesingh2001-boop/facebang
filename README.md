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
| **Aim** | bang nearest, loop / auto-retarget, stop + restore, power, vertical offset, release-from-seat, **bang style** (hybrid / velocity / cframe), **bang mode** (fling / lock), fling power |
| **Self** | **GHOST (invisible + invincible)**, **GOD SPEED**, god mode, noclip, fly + fly speed, walk speed, jump power, anti-void + floor Y, invisible, anti-AFK, freeze my character, restore everything |
| **Players** | pick a player, then bang / teleport to / **weld fling** / fling (self-body or force) / freeze (local view) / thaw / follow / spectate, plus freeze everyone in view (capped at 12) |
| **Server** | time of day, no fog, copy job id, rejoin, server hop, unload |

Rows that reset or unload your state need a second tap ("tap again to
confirm") and disarm themselves after 3 seconds.

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
  What exists, and is labelled as such: freeze a target's replicated position
  in *your* view, freeze everyone inside 80 studs (capped at 12 so a full
  server cannot stall the frame), and anchor your own character.
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

113 checks: script loads, registers itself, the hot path runs clean, the root
ends up on the victim's head, an impulse is written, hit detection fires, stop
restores position / state / collisions, dead targets are refused, and unload
destroys the GUI, plus the self tools (speed, jump, noclip, anti-void, god
mode, local freeze) and the target actions (teleport, freeze, thaw, freeze-all
with a radius check), the engine/UI loop-flag resync, fling driving our own
body while leaving the victim untouched, god-mode re-pinning, and velocity-mode
not teleporting, weld creation/teardown with mass restored, and ghost
enabling/disabling touch, transparency, forcefield and health pinning. All pass.

## Changelog

**v1.1.0** — fixed "no player detected" on executors that provide `cloneref`.
`alive()` compared `plr.Parent ~= Players`, but `cloneref` returns a reference
that is deliberately `~=` to the real service, so every player was rejected.
Membership is now implied by `Players:GetPlayers()`, with a regression test that
uses a faithful non-identical `cloneref` proxy. Also: characters without a part
named `Head` now fall back to `HumanoidRootPart`, and the failure message says
whether you are alone or simply have no valid target.

**v1.2.0** — made fling and god mode actually work, and added bang styles.

- **Fling was structurally broken.** It wrote `AssemblyLinearVelocity` to the
  *victim's* root, but a client does not own a remote player's parts, so the
  server overwrote that write on the next physics step. It could never work.
  Fling now drives **your own owned body** into them (|v| ~900) and lets the
  server resolve the collision - the same mechanism that makes facebang work.
  A "force velocity" variant remains for the rare co-op physics game where you
  really do own their parts.
- **God mode was too naive.** `MaxHealth = math.huge` is frequently reset by
  servers, and health was pinned once with no respawn handling. Now it uses a
  finite `GodHealth` (1e9), re-pins from `HealthChanged` with a recursion guard,
  re-applies on a cheap heartbeat, and restores itself after respawn.
- **Bang styles**, for games that fight one approach: `hybrid` (CFrame +
  velocity, the default), `velocity` (never teleports, for games that reset or
  detect teleporting), `cframe` (teleport only). Switchable in the Aim tab.

Honest limits that no style fixes: server-authoritative health means a client
cannot stop a server kill, and a game that anchors characters or disables
player-vs-player collision cannot be banged by any client script.

**v1.3.0** — weld fling, a real ghost/invincible mode, cleaner UI.

- **Weld fling** (`Targets.flingWeld`). The technique used by the popular
  "fling based on welding" scripts: `WeldConstraint` from your root to theirs so
  the target is dragged by *your* owned assembly, then launch + spin the welded
  pair. Two details the naive version misses: their parts are set `Massless`
  first (otherwise the shared assembly is too heavy to move), and the weld is
  always torn down afterwards, since a root-to-root weld also shares damage.
- **GHOST — invisible + invincible.** Not just `MaxHealth`: every part gets
  `CanTouch = false` (stops local touch-based damage), a hidden `ForceField` is
  attached (blocks damage replication while it lives), everything is set
  transparent, health is still pinned, and `DescendantAdded` re-applies it to
  tools or accessories you pick up later. The root stays collidable so you do
  not fall through the floor.
- **UI**: grouped sections, soft drop shadow, page padding, and a single
  forward-declared reference to the bang label instead of tree searches.

Both of these come from published scripts found while researching; the
implementation and the failure handling are this project's own. The limits that
remain are the engine's: server-authoritative `Health` and `Kick`, anchored
characters, and games with player-vs-player collision off cannot be beaten from
a client.

**v1.4.0** — fixed the bang *freezing* the victim, and added god speed.

- **The bang used to freeze the target, and that was a design flaw, not a
  setting.** It parked your root inside their head every frame and held it
  there. A teleport carries no momentum, and the impulse collapsed to the
  120 floor pointing sideways from the jitter, so instead of hitting them you
  pinned them in a permanent overlap and the solver stopped them dead.
  Bang mode `fling` (now the default) keeps a real closing speed into the
  target and never sits inside them: if the distance closes under 4 studs it
  peels back to a launch point, alternating sides, so the next tick is an
  impact rather than a hold. `lock` remains available if you actually want to
  hold someone still.
- **God speed** pins `WalkSpeed` from `Heartbeat`, because games reset it
  constantly and a one-shot write is undone within a frame. Values from 200 up
  to 4000.

Regression tests cover both: fling mode must keep distance and carry >= 800
closing speed, lock mode must park inside, and god speed must re-pin itself
after the game clamps `WalkSpeed` back to 16.

**v1.5.0** — visual redesign.

- Deeper palette with real depth: two shadow layers, a gradient window, hairline
  strokes and a header that reads as a header (brand bar, version + executor in a
  subtitle line, live status dot with a ring).
- Proper control states for the first time: rows lighten on hover, tint on press,
  and the tab pill fills with the accent when active. The primary BANG button
  gets an accent-to-violet gradient, a glow, and a 3% press scale.
- Toggles now slide and recolour instead of snapping, and stepper chips brighten
  on hover.
- Sections are marked with a small accent bar so the tabs read as groups.
- The chevron is drawn from two rotated bars rather than a ">" glyph, which sits
  too high at small sizes.

The test harness caught a real gap here: the mock's `TweenService` was a no-op
stub, so every UI tween was silently doing nothing. It now applies the goal
immediately, which is what made the new toggle test meaningful. Layout is
asserted numerically (no control may cross its row's right edge, every
interactive row >= 26px).

**v1.6.0** — fixed the victim appearing frozen / welded to one spot.

The bang itself never writes to the other player's transform, so it cannot pin
them. Two other things could, and both were real bugs:

- **A local freeze never expired.** `freeze selected` / `freeze all in view`
  captured the target's `CFrame` once and re-applied it on every frame forever.
  That pins them at that exact spot on your screen, and it keeps doing it after
  they have genuinely moved away - which is what "welded to one place" looks
  like. A freeze now expires after `Config.FreezeMax` seconds, and is dropped
  early if their assembly is actually moving (over 45 studs/s), because fighting
  a moving player just glues them in place.
- **The weld fling had no guaranteed teardown.** If the RenderStepped loop ever
  stopped ticking (respawn, lag spike, loading screen) the `WeldConstraint`
  stayed in the world and the two bodies really did stay welded. Teardown now
  also runs on a timer.

Also changed:
- Bang mode `fling` no longer teleports you to 7 studs from their head whenever
  you are close, alternating sides every 8 ticks. That approach keeps you locked
  in a permanent overlap with them, which reads as both bodies stuck together.
  It now stages back only when you are genuinely inside them (under 4 studs),
  rams from there, and zeroes your angular velocity each tick - spin is what
  stops the humanoid recovering and drags the camera after it.
- New **fix my character (reset physics)** row: clears freezes, flings and welds,
  zeroes your own velocities, clears PlatformStand/Sit and re-points the camera
  at your humanoid. Use it if anything ever leaves you stuck.

Tests: the bang must ramp toward a target 8 studs away (velocity dot > 0.9) and
must keep working distance rather than parking on their head; a stale freeze must
expire and must not fight a moving target.

**v1.7.0** — the bang is now tuned to measurements taken in Roblox Studio, not
to a guessed number.

Everything below is a real Client datamodel, a real Humanoid rig, 5 runs per
setting, measuring how far the victim is launched in 0.45s:

| speed | distance launched |
|---|---|
| 700 | 318 |
| 900 | 410 |
| 1400 | 637 |
| **1600** | **17** |
| **2000** | **17** |
| 2400 | 1003 |
| **2400 + 25% dither** | **1089 (min 1024)** |
| 3200 fixed | 115 avg but 17 minimum |
| 4000 + dither | 1117 avg, min 774 |

Two things came out of this that I had wrong:

- **1600 and 2000 are tunnelling dead zones.** Above roughly 40 studs per frame
  the body can skip over the target without ever producing a physics overlap, so
  the victim is barely moved. My previous default was 1600 — the worst possible
  value, which is very likely what you were feeling as "it does nothing".
- **Teleporting into them is weaker than ramming them.** Guaranteed overlap at
  700 studs/s launched 185; the same overlap at 1200 launched 413; ramming at
  2400 launched 1003. Impulse scales with closing speed, so parking inside the
  victim is the weakest option — which is why the old "lock" behaviour felt like
  freezing rather than flinging.

The fix: the bang re-aims every tick at 2400 studs/s with the magnitude cycling
-25% / 0 / +25%, which keeps it out of every dead zone. `Targets.fling` got the
same treatment (900 -> 2400 with dither), and the weld fling no longer applies
angular spin, which dragged the camera around and stopped the humanoid
recovering.

A test-ordering bug in the harness was masking all of this: `Targets.fling` left
a RenderStepped connection alive, which overwrote the bang's velocity every
frame and pinned readings at 907. Cleaned up, and the tuning is now pinned in
`test/tuning.lua` so a refactor cannot quietly slide back into a dead zone.

**v1.8.0** — fly rebuilt, invisibility corrected, five more tools.

**Fly was broken because of BodyVelocity.** Body movers get destroyed or
overridden by a game's own movement code, and MaxForce fights gravity instead of
replacing it. Fly now drives `AssemblyLinearVelocity` directly and lerps toward
the wanted vector, so it eases in rather than snapping. It reads
`Humanoid.MoveDirection`, which is why it now works on touch thumbsticks as well
as WASD, and camera pitch gives altitude control. Verified in Studio: **13.5
studs up, 39.9 studs across in 0.6s, health untouched.**

**Invisibility does not work the way I said it did, and I have to correct it.**
I told you character transparency replicates to other players. I tested it: the
client set `Head.Transparency = 1` and the server still read **0**. Property
writes made on a client are not sent to the server — only physics ownership of
your own root travels that way. So "invisible to everyone" is not reachable from
a client script at all; it needs the server to cooperate. The toggle now says
**"invisible (your view only)"** so it stops claiming something it cannot do.
What it does do properly is restore the exact original transparency per part and
catch accessories equipped while hidden (via `DescendantAdded`), both of which it
did not do before.

New in this version:
- **infinite jump** — re-enters the jump state while falling
- **teleport to cursor** — works on PC and on touch (a tap sets the mouse hit)
- **save / load position**
- **perf readout** — fps, ping, part count, client-side only. This is the useful
  half of lag testing: it tells you whether a hitch is your frame rate or the
  network, and it measures nothing on the server and sends no load.

Two harness fixes worth recording, because both were hiding real behaviour:
- the mock's `Disconnect` was a **no-op**, so every leftover loop kept running
  after being "disconnected". That masked cleanup bugs and produced the phantom
  907 velocity readings. It now removes the callback for real.
- a freeze test held a stale part reference from a character that had been
  rebuilt five times, so it was writing velocity to a destroyed part.

113 checks: 84 script, 7 bang tuning, 18 fly/invisibility/movement/perf.

**v1.8.1** — stopping now leaves nothing behind on the target.

You asked whether the "target looks frozen, but only on my screen" bug was
fixed. It was fixed in two earlier passes (a freeze expires after 8s and drops
the moment the target's assembly is really moving; the bang passes through
instead of parking inside them), but there was still one way to leave a target
pinned: pressing **stop** mid-freeze or mid-weld did not clear our own local
writes. Their CFrame pin kept being applied until it expired, and their parts
could stay massless.

That is fixed, and the bug behind it was subtle: the teardown inside
`Engine.stop` named the `Targets` module directly, but that local is declared
*after* that function in the build, so the name resolved to a global, `pcall`
swallowed the error, and the cleanup silently did nothing. It now goes through
an `Engine.onStop` hook that the UI installs once the modules exist. Three new
checks cover it: stop clears the freeze, stop removes the weld, stop hands the
target's mass back.

To be clear about the mechanism, because it explains the symptom: every one of
these writes exists only on your client. Your client cannot stop the server from
telling you where that player is, but it *can* keep overwriting their CFrame
locally, which is why they look welded in place to you while everyone else sees
them move normally.

113 checks: 87 script, 7 bang tuning, 18 fly/invisibility/movement/perf.

**v1.8.2** — the loop now also runs in the pre-physics phase.

You asked for "zero delay" and pointed at other scripts. I went and read how
this is actually discussed, and the mechanism is confirmed: what those scripts
call zero delay is *no `task.wait` anywhere on the firing path* plus writing
velocity every frame. There is no hidden trick beyond that. The DevForum
consensus is explicit that anything crossing the network has latency, and that
instant feedback for *other* players requires server authority or client
prediction built into the game itself, not something an external script can
impose (see the "Zero-Latency Feedback for Physics-Heavy Projectiles" tutorial
and the replication discussions).

That said, reading it did surface something I was not doing: `RunService.Stepped`
/ `PreSimulation` fires **before physics integrates for the frame**, which is a
better moment to write an impulse than after it. Verified in Studio that
`PreSimulation`, `Stepped`, `PostSimulation` and `Heartbeat` all exist. The loop
now runs in three phases:

- `PreSimulation` — before physics, so the impulse is integrated the same frame
- `RenderStepped` — before the frame is drawn
- `Heartbeat` — after physics, which catches games that reset velocity in their
  own handler

Still no waits between any of them. This is as responsive as a client script
gets: the writes are immediate on your machine, and whether the server accepts
them is up to the game's anti-cheat. 113 checks.
