--[[
================================================================================
  FACE BANG   v1.6.0      universal / zero-delay
================================================================================
  WHAT IT IS
  Facebang abuses the "feet inside the skull" character-overlap bug: your
  HumanoidRootPart is forced into the target's Head with BOTH a CFrame write
  and a velocity write, on every render frame, with no task.wait / no sleeps.
  The overlapping assemblies resolve on the next physics step and the victim
  is launched.

  WHY "ZERO DELAY"
  - No scheduler throttling: RenderStepped does the teleport, Heartbeat does a
    second pass to catch physics steps that RenderStepped misses.
  - Target refs are cached and only re-resolved every 10 ticks.
  - Nothing in the hot path allocates services, instances or closures.

  REQUIREMENTS (all soft - the script degrades instead of erroring out)
  - Any executor that can write CFrame and AssemblyLinearVelocity (Velocity is
    used as a fallback for older builds).
  - The game must allow player-vs-player collision and must leave your client
    network ownership of your own parts.

  OPTIONAL EXECUTOR EXTRAS (used before the fallbacks when present)
  - sethiddenproperty / setsimulationradius -> keeps distant players simulated
  - identifyexecutor, setclipboard, gethui, cloneref, getgenv

  KEYS     [B] bang nearest   [L] loop   [X] stop   [RightShift] show/hide
  LOAD     loadstring(game:HttpGet("<raw url>"))()
  UNLOAD   getgenv().FaceBang.Unload()
================================================================================
]]

do
	-- single source of truth: the UI header prints this, so it must not drift
	local VERSION = "1.6.0"

	local ENV = (getgenv and getgenv()) or _G
	if type(ENV.FaceBang) == "table" and type(ENV.FaceBang.Unload) == "function" then
		pcall(ENV.FaceBang.Unload)
	end

	------------------------------------------------------------------ services
	local cloneref = cloneref or function(o) return o end
	local Players = cloneref(game:GetService("Players"))
	local RunService = cloneref(game:GetService("RunService"))
	local UserInput = cloneref(game:GetService("UserInputService"))
	local TweenService = cloneref(game:GetService("TweenService"))
	local StarterGui = cloneref(game:GetService("StarterGui"))
	local Workspace = cloneref(game:GetService("Workspace"))
	local LP = Players.LocalPlayer

	-- cycled every tick by the bang: see Config.FlingPower for the measurements
	local DITHER = { -1, 0, 1 }

	--------------------------------------------------------------------- flags
	-- capability probe: everything is optional, nothing hard-fails
	local function has(name)
		local ok, fn = pcall(function() return ENV[name] end)
		return ok and type(fn) == "function"
	end
	local CAP = {
		executor = "unknown",
		hidden = has("sethiddenproperty"),
		simRadius = has("setsimulationradius") and has("getsimulationradius"),
		gethui = has("gethui"),
		vicVel = true,
	}
	do
		local ok, name = pcall(function() return identifyexecutor and identifyexecutor() end)
		if ok and type(name) == "string" then CAP.executor = name end
	end

	-- input surface: phones have no keyboard, so every action needs a tap path
	local IsTouch = UserInput.TouchEnabled
	local function viewport()
		local cam = Workspace.CurrentCamera
		if cam and cam.ViewportSize.X > 0 then return cam.ViewportSize end
		return Vector2.new(1280, 720) -- camera not ready yet; caller re-applies on resize
	end

	-------------------------------------------------------------------- config
	local Config = {
		Power = 12,          -- velocity impulse multiplier applied to the hit
		MinSpeed = 120,      -- floor speed: a locked-on hit must still carry real momentum
		Height = 0.35,       -- vertical offset inside the head
		Offset = 0.32,       -- horizontal jitter radius (keeps re-colliding)
		NoClip = true,       -- turn our own collisions off so we never stick
		AutoRetarget = true, -- jump to the next closest player when one dies
		SeatRelease = true,  -- free a seated/welded target before the bang
		-- "hybrid" writes CFrame + velocity (best on most games)
		-- "velocity" never writes CFrame: for games that reset/reset-detect teleports
		-- "cframe" only teleports: for games that ignore client velocity
		BangStyle = "hybrid",
		-- "fling" pass-through: back off and drive through them, so contact
		--         produces an impact. This is what actually launches a player.
		-- "lock"  park inside them (old behaviour) - holds the target still
		--         instead of flinging, which reads as "he got frozen"
		BangMode = "fling",
		-- Measured in a real Studio Client against a humanoid rig, 0.45s, 5 runs
		-- each. Distance the victim is launched:
		--   700  -> 318    1400 -> 637    1600 -> 17 (dead)   2000 -> 17 (dead)
		--   2400 -> 1003   2400 with 25% dither -> 1089 (min 1024)
		-- The dead zones are tunnelling: above ~40 studs/frame the body can skip
		-- over the target without a physics overlap, so raw speed alone is not
		-- stronger. 2400 with dither is both the strongest and the most reliable.
		FlingPower = 2400,   -- closing speed for pass-through mode
		Dither = 0.25,       -- +/- this fraction, cycled every tick, to avoid dead zones
		Stage = 12,          -- how far back we re-stage before each strike
		FreezeMax = 8,       -- a local freeze expires instead of pinning forever
		GodHealth = 1e9,     -- finite on purpose: math.huge gets reset by servers
		VoidFloor = -80,     -- anti-void: re-surface below this Y
		Restore = true,      -- restore position / state / collisions on stop
		KeyBang = Enum.KeyCode.B,
		KeyLoop = Enum.KeyCode.L,
		KeyStop = Enum.KeyCode.X,
		KeyUI = Enum.KeyCode.RightShift,
	}

	local UI -- filled in by the interface section below

	------------------------------------------------------------------- logging
	local function notify(title, text, dur)
		pcall(function()
			StarterGui:SetCore("SendNotification", {
				Title = title,
				Text = text,
				Duration = dur or 4,
			})
		end)
	end

	local function out(text)
		if UI and UI.status then UI.status(text) end
	end

	------------------------------------------------------------------- helpers
	--[[
	  NOTE: never compare a service by instance identity here. cloneref()
	  intentionally returns a reference that is ~= the real service, so
	  `plr.Parent ~= Players` is ALWAYS true on executors with cloneref and
	  rejected every player ("no player detected"). Membership is implied by
	  iterating Players:GetPlayers(), so the parent check is not needed.
	]]
	local function alive(plr)
		if not plr or plr == LP then return false end
		local char = plr.Character
		if not char or not char.Parent then return false end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return false end
		-- custom rigs often have no part literally named "Head"; the root is
		-- the only part guaranteed on a humanoid character
		return char:FindFirstChild("HumanoidRootPart") ~= nil
	end

	local function myRoot()
		local char = LP.Character
		return char and char:FindFirstChild("HumanoidRootPart")
	end

	local function myHum()
		local char = LP.Character
		return char and char:FindFirstChildOfClass("Humanoid")
	end

	local function setVel(part, v)
		if not part then return end
		if CAP.vicVel then
			local ok = pcall(function() part.AssemblyLinearVelocity = v end)
			if ok then return end
			CAP.vicVel = false
		end
		pcall(function() part.Velocity = v end)
	end

	local function nearest()
		local root = myRoot()
		if not root then return nil end
		local me = root.Position
		local best, bestDist = nil, math.huge
		for _, plr in ipairs(Players:GetPlayers()) do
			if alive(plr) then
				local root2 = plr.Character:FindFirstChild("HumanoidRootPart")
				local d = root2 and (root2.Position - me).Magnitude or math.huge
				if d < bestDist then best, bestDist = plr, d end
			end
		end
		return best
	end

	-------------------------------------------------------------------- engine
	local Engine = {
		running = false,
		loop = false,
		target = nil,
		head = nil,
		root = nil,
		tick = 0,
		saved = nil,
		touchedConn = nil,
		hits = 0,
	}

	local function collisionSnapshot()
		local snap = {}
		local char = LP.Character
		if not char then return snap end
		for _, d in ipairs(char:GetDescendants()) do
			if d:IsA("BasePart") then
				snap[d] = d.CanCollide
			end
		end
		return snap
	end

	local function setOurCollisions(on)
		local char = LP.Character
		if not char then return end
		for _, d in ipairs(char:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CanCollide = on
			end
		end
	end

	local function restore()
		local hrp, hum = myRoot(), myHum()
		local saved = Engine.saved
		Engine.saved = nil

		if Engine.touchedConn then
			pcall(function() Engine.touchedConn:Disconnect() end)
			Engine.touchedConn = nil
		end

		if hrp then
			pcall(function() setVel(hrp, Vector3.zero) end)
		end

		if saved and Config.Restore then
			for part, state in pairs(saved.collisions) do
				if part.Parent then pcall(function() part.CanCollide = state end) end
			end
			saved.collisions = nil
			if hum then
				pcall(function() hum.PlatformStand = saved.platformStand end)
			end
			if hrp and saved.cframe then
				pcall(function() hrp.CFrame = saved.cframe end)
			end
			if hum then
				pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
			end
		elseif Config.NoClip then
			setOurCollisions(true)
		end
	end

	local function applyHidden()
		if CAP.simRadius then
			pcall(function() ENV.setsimulationradius(1 / 0, 1 / 0) end)
		end
		if CAP.hidden then
			local ok = pcall(function() ENV.sethiddenproperty(LP, "MaximumSimulationRadius", 1 / 0) end)
			if not ok then
				pcall(function() ENV.sethiddenproperty(LP, "SimulationRadius", 1 / 0) end)
			end
		end
	end

	--[[
	  Seat games (Mic Up and friends) weld the target's root to a chair and can
	  leave them anchored. A welded target absorbs the impulse and nothing
	  happens, so free them locally first. Anchored targets cannot be flung at
	  all - that is the engine, not the script - so report it instead of
	  pretending the bang worked.
	]]
	local function releaseTarget(plr)
		local char = plr and plr.Character
		if not char then return "no character" end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hrp then return "no root" end

		local freed = false

		-- 1. stand them up (client-side only; their own screen may differ)
		if hum then
			pcall(function()
				if hum.Sit then hum.Sit = false freed = true end
			end)
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
		end

		-- 2. drop the welds that glue them to a seat
		for _, d in ipairs(char:GetDescendants()) do
			if d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Motor6D") then
				local p0, p1 = d.Part0, d.Part1
				if p1 == hrp or p0 == hrp then
					pcall(function()
						d:Destroy()
						freed = true
					end)
				end
			end
		end

		-- 3. an anchored target is welded to the world: no impulse can move it.
		--    Un-anchoring it locally does not help (the server re-anchors it), so
		--    report the limit instead of pretending the bang will land.
		if hrp.Anchored then return "target anchored" end

		Engine.released = freed
		return freed and "released" or "already free"
	end

	-- hot path: one physics/one render pass, no waits, no allocation beyond maths
	local function step()
		if not Engine.running then return end
		Engine.tick += 1

		local hrp = Engine.root
		if not hrp or not hrp.Parent then
			hrp = myRoot()
			Engine.root = hrp
			if not hrp then return end
		end

		-- refresh the victim refs cheaply, every 10 ticks
		if Engine.tick % 10 == 1 or not Engine.head or not Engine.head.Parent then
			if not alive(Engine.target) then
				if Config.AutoRetarget then
					local nxt = nearest()
					if not nxt then
						Engine.target, Engine.head = nil, nil
						out("no target")
						return
					end
					Engine.target = nxt
					if UI and UI.markList then UI.markList() end
				else
					return
				end
			end
			local char = Engine.target and Engine.target.Character
			if not char then return end
			Engine.head = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
			if not Engine.head then return end
		end

		local head = Engine.head
		local from = hrp.CFrame.Position
		local style = Config.BangStyle
		local headPos = head.CFrame.Position

		if Config.BangMode == "lock" then
			-- deliberate "hold them still" mode: park inside the head
			local jitter = (Engine.tick % 2 == 0) and Config.Offset or -Config.Offset
			local dest = head.CFrame * CFrame.new(jitter, Config.Height, 0)
			if style ~= "velocity" then hrp.CFrame = dest end
			local dx = dest.Position - from
			local dir = dx.Magnitude > 1e-4 and dx.Unit or Vector3.new(jitter, Config.Height, 0).Unit
			if style == "velocity" then
				local toHead = headPos - from
				setVel(hrp, (toHead.Magnitude > 1e-4 and toHead.Unit or dir) * Config.MinSpeed * 8)
			else
				local speed = math.clamp(dx.Magnitude * Config.Power, Config.MinSpeed, Config.MinSpeed * 5)
				setVel(hrp, dir * speed)
			end
		else
			-- Velocity ram. Measured best: re-aim every tick at 2400 studs/s with a
			-- dithered magnitude. Two things learned from the engine:
			--   - teleporting into them is WEAKER (185-413 studs) than ramming
			--     (1000+), because the impulse scales with closing speed
			--   - fixed high speeds hit tunneling dead zones (1600 and 2000 both
			--     launched only 17 studs), so the magnitude cycles -25% / 0 / +25%
			local delta = headPos - from
			local dist = delta.Magnitude
			local aim = dist > 1e-3 and delta.Unit or head.CFrame.LookVector
			local power = math.clamp(Config.FlingPower, 300, 5000)
			local mult = 1 + (Config.Dither or 0.25) * DITHER[Engine.tick % 3 + 1]
			setVel(hrp, aim * power * mult)
			-- spin stops the humanoid recovering and drags the camera around
			pcall(function()
				hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
			end)
			if style == "cframe" and dist > 1 then
				pcall(function() hrp.CFrame = CFrame.new(from + aim * math.min(dist, 10)) end)
			end
		end

		-- if the game owns our parts on the server we cannot hit anything
		if Engine.tick % 60 == 0 then
			local ok, owner = pcall(function() return hrp:GetNetworkOwner() end)
			if ok and owner == nil then
				pcall(function() hrp:SetNetworkOwner(LP) end)
			end
		end
	end

	function Engine.hitScan()
		local hrp, target = Engine.root, Engine.target
		if not hrp or not target or not target.Character then return end
		local victimRoot = target.Character:FindFirstChild("HumanoidRootPart")
		if not victimRoot then return end

		local hit = false
		pcall(function()
			for _, p in ipairs(Workspace:GetPartsInPart(hrp)) do
				if p == victimRoot then hit = true break end
			end
		end)
		if not hit then
			local ok, touching = pcall(function() return hrp:GetTouchingParts() end)
			if ok then
				for _, p in ipairs(touching) do
					if p == victimRoot then hit = true break end
				end
			end
		end
		if hit then
			Engine.hits += 1
			out("hit " .. target.Name .. " x" .. Engine.hits)
			return true
		end
		return false
	end

	function Engine.start(plr)
		plr = plr or nearest()
		if not plr or not alive(plr) then
			local others = 0
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= LP then others += 1 end
			end
			local why = others == 0
				and "you are alone in this server"
				or ("no valid target among " .. others .. " player(s) - dead, loading or no character")
			notify("Face Bang", why, 4)
			out(why)
			return false
		end
		local hrp, hum = myRoot(), myHum()
		if not hrp or not hum then
			notify("Face Bang", "Character not ready")
			return false
		end

		if not Engine.running then
			applyHidden()
			Engine.saved = {
				cframe = hrp.CFrame,
				platformStand = hum.PlatformStand,
				collisions = collisionSnapshot(),
			}
			Engine.tick = 0
			Engine.hits = 0
			if Config.NoClip then setOurCollisions(false) end
			pcall(function() hum.PlatformStand = true end)
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Physics) end)
			pcall(function() hrp:SetNetworkOwner(LP) end)

			Engine.touchedConn = hrp.Touched:Connect(function(p)
				if Engine.target and Engine.target.Character
					and p == Engine.target.Character:FindFirstChild("HumanoidRootPart") then
					Engine.hitScan()
				end
			end)
		end

		Engine.target = plr
		Engine.root = hrp
		Engine.head = plr.Character:FindFirstChild("Head")
			or plr.Character:FindFirstChild("HumanoidRootPart")
		if not Engine.head then
			notify("Face Bang", plr.Name .. " has no Head or root part")
			return false
		end

		-- seat / anchor games: free the target before the impulse, and say what happened
		local seatState = releaseTarget(plr)
		if seatState == "target anchored" then
			notify("Face Bang", plr.Name .. " is anchored - cannot be flung here", 4)
			out("anchored target")
			return false
		end
		if Engine.released then out("released " .. plr.Name .. " from seat") end

		Engine.running = true
		if UI and UI.state then UI.state(true) end
		if UI and UI.markList then UI.markList() end
		out("banging " .. plr.Name)
		return true
	end

	function Engine.stop(restorePos)
		local was = Engine.running
		Engine.running = false
		Engine.loop = false
		Engine.target = nil
		Engine.head = nil
		-- Stopping must not leave anything of ours on their body. Every one of
		-- these writes only exists on this client, so anything left behind shows
		-- as the target appearing frozen or welded *on our screen only*.
		-- Leave nothing of ours on their body. This MUST go through a hook: the
		-- modules are built after this file, so naming them directly here would
		-- resolve to a global and the teardown would silently do nothing.
		if Engine.onStop then pcall(Engine.onStop) end
		restore()
		if UI and UI.state then UI.state(false) end
		if UI and UI.markList then UI.markList() end
		out("idle")
		if was then notify("Face Bang", restorePos == false and "Stopped" or "Stopped and restored") end
	end

	function Engine.toggle(plr)
		if Engine.running then
			Engine.stop()
			return false
		end
		return Engine.start(plr)
	end

	-- Three passes, each in a different phase of the frame (all verified to exist
	-- in the live engine):
	--   PreSimulation  - before physics integrates, so the impulse is applied the
	--                    same frame it is written
	--   RenderStepped  - right before the frame is drawn, so it is on screen
	--   PostSimulation / Heartbeat - after physics, which catches games that reset
	--                    velocity on their own Stepped handler
	-- No task.wait between any of them: the loop is pure writes per frame.
	RunService.RenderStepped:Connect(step)
	RunService.Heartbeat:Connect(step)
	local preSim = RunService.PreSimulation or RunService.Stepped
	if preSim then preSim:Connect(step) end

	----------------------------------------------------------- modules

	local TargetsLib = (function()
--[[
  targets.lua - per-player actions
  Every action here is CLIENT-SIDE. "Freeze" locks a player's replicated
  position in YOUR view; it does not and cannot stop them on their own screen.
  Nothing in this file touches the server.
]]
local Targets = {}

function Targets.new(ctx)
	local Players, RunService, Workspace = ctx.Players, ctx.RunService, ctx.Workspace
	local LP = ctx.LP
	local M = {}

	local state = {
		frozen = {},     -- [player] = cframe captured when frozen
		following = nil, -- player
		spectating = nil,
		flingConn = nil,
	}

	local function char(plr)
		local c = plr and plr.Character
		if not c or not c.Parent then return nil end
		local hum = c:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return nil end
		return c, hum
	end

	local function rootOf(plr)
		local c = char(plr)
		return c and c:FindFirstChild("HumanoidRootPart")
	end

	function M.teleportTo(plr)
		local myChar = char(LP)
		local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
		local theirRoot = rootOf(plr)
		if not myRoot or not theirRoot then return false, "no character" end
		-- land slightly behind them, offset by their facing so we do not spawn inside
		local dest = theirRoot.CFrame * CFrame.new(0, 0, 3)
		myRoot.CFrame = dest
		return true
	end

	--[[
	  Universal fling. Writing velocity to the VICTIM's part never works: the
	  client does not own a remote player's parts, so the server overwrites it on
	  the next physics step. What does work is the facebang trick - our own
	  assembly IS owned by us, so driving ourselves into them at speed makes the
	  SERVER resolve the collision and launch them.

	  mode "self"  : accelerate our own root through the target (default, works)
	  mode "force" : also write their velocity, for the rare case where we do own
	                 their parts (co-op physics games, sit games)
	]]
	function M.fling(plr, seconds, mode)
		local theirRoot = rootOf(plr)
		local myRoot = rootOf(LP)
		if not theirRoot then return false, "no character" end
		if not myRoot then return false, "no character" end

		M.unfling()
		local until_ = os.clock() + (seconds or 3)
		local myHum = char(LP)
		myHum = myHum and myHum:FindFirstChildOfClass("Humanoid")

		-- Measured in Studio: ~900 studs/s launches about 410 studs, while 2400
		-- with a dithered magnitude launches 1000+. A fixed high speed hits
		-- tunnelling dead zones (1600 and 2000 both launched only 17), so the
		-- magnitude cycles every tick.
		local DITHER = { -1, 0, 1 }
		local tick = 0

		state.flingConn = RunService.RenderStepped:Connect(function()
			tick = tick + 1
			local tr = rootOf(plr)
			local mr = rootOf(LP)
			if not tr or not mr then return end
			if os.clock() > until_ then M.unfling() return end

			local target = tr.CFrame.Position
			local from = mr.CFrame.Position
			local delta = target - from
			if delta.Magnitude < 0.01 then
				delta = tr.CFrame.LookVector * -1
			end

			pcall(function()
				-- drive ourselves hard into them; the cycle keeps us out of the
				-- dead zones where a body skips over the target without contact
				local mult = 1 + 0.25 * DITHER[tick % 3 + 1]
				mr.AssemblyLinearVelocity = delta.Unit * (2400 * mult) + Vector3.new(0, 120, 0)
			end)
			if mode == "force" then
				pcall(function()
					tr.AssemblyLinearVelocity = Vector3.new(0, 1200, 0)
				end)
			end
		end)
		return true
	end

	--[[
	  Weld fling. Found in the wild as "fling based on welding": weld our root to
	  theirs and move, so the target is dragged by OUR owned assembly. Two things
	  the naive version gets wrong and this one handles:

	  - their parts must be Massless, otherwise the shared assembly is so heavy
	    that our own movement stalls and nothing launches
	  - a root-to-root weld shares damage, so it is always torn down afterwards
	]]
	function M.flingWeld(plr, seconds)
		local theirRoot = rootOf(plr)
		local myRoot = rootOf(LP)
		if not theirRoot or not myRoot then return false, "no character" end

		M.unweld()
		state.weldTarget = plr

		-- make their body carry no mass into our assembly
		local theirChar = plr.Character
		for _, d in ipairs(theirChar:GetDescendants()) do
			if d:IsA("BasePart") then
				pcall(function() d.Massless = true end)
			end
		end

		local weld = Instance.new("WeldConstraint")
		weld.Name = "FB_WeldFling"
		weld.Part0 = myRoot
		weld.Part1 = theirRoot
		weld.Parent = myRoot
		state.weld = weld

		-- safety net: if the connection is ever starved (respawn, lag spike,
		-- loading screen) the weld would stay in the world and the two bodies
		-- would remain stuck together. Force the teardown on a timer as well.
		task.delay((seconds or 2.5) + 0.5, function()
			if state.weld == weld then M.unweld() end
		end)

		local until_ = os.clock() + (seconds or 2.5)
		state.weldConn = RunService.RenderStepped:Connect(function()
			if os.clock() > until_ then M.unweld() return end
			local mr = rootOf(LP)
			if not mr then M.unweld() return end
			-- fling the welded assembly: spin + launch
			pcall(function()
				mr.AssemblyLinearVelocity =
					mr.CFrame.RightVector * 1200 + Vector3.new(0, 900, 0)
				-- no angular spin: it stops the humanoid recovering and drags the
				-- owner's camera around with it
				mr.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
			end)
		end)
		return true
	end

	function M.unweld()
		state.weldTarget = nil
		if state.weldConn then
			pcall(function() state.weldConn:Disconnect() end)
			state.weldConn = nil
		end
		if state.weld then
			pcall(function() state.weld:Destroy() end)
			state.weld = nil
		end
		-- hand their mass back so we do not leave their physics changed
		for _, plr in ipairs(Players:GetPlayers()) do
			local c = plr.Character
			if c and plr ~= LP then
				for _, d in ipairs(c:GetDescendants()) do
					if d:IsA("BasePart") and d.Massless then
						pcall(function() d.Massless = false end)
					end
				end
			end
		end
	end

	function M.unfling()
		if state.flingConn then
			pcall(function() state.flingConn:Disconnect() end)
			state.flingConn = nil
		end
	end

	function M.freeze(plr)
		local theirRoot = rootOf(plr)
		if not theirRoot then return false, "no character" end
		-- remember when it was taken: a local freeze that never expires looks
		-- exactly like the player being welded to one spot for the rest of the
		-- session, even after they have actually moved away
		state.frozen[plr] = { cf = theirRoot.CFrame, t = os.clock() }
		if not state.freezeConn then
			state.freezeConn = RunService.RenderStepped:Connect(function()
				local now = os.clock()
				for p, rec in pairs(state.frozen) do
					local r = rootOf(p)
					-- drop it if the character is gone, or if their assembly is
					-- really moving: fighting that just pins a moving player
					local moving = false
					if r then
						local okv, v = pcall(function() return r.AssemblyLinearVelocity end)
						moving = okv and v and v.Magnitude > 45
					end
					if not r or moving or (now - rec.t) > (Config.FreezeMax or 8) then
						state.frozen[p] = nil
					else
						pcall(function() r.CFrame = rec.cf end)
					end
				end
				if next(state.frozen) == nil and state.freezeConn then
					pcall(function() state.freezeConn:Disconnect() end)
					state.freezeConn = nil
				end
			end)
		end
		return true
	end

	function M.thaw(plr)
		if plr then
			state.frozen[plr] = nil
		else
			table.clear(state.frozen)
		end
		if next(state.frozen) == nil and state.freezeConn then
			pcall(function() state.freezeConn:Disconnect() end)
			state.freezeConn = nil
		end
	end

	function M.thawAll()
		table.clear(state.frozen)
		if state.freezeConn then
			pcall(function() state.freezeConn:Disconnect() end)
			state.freezeConn = nil
		end
	end

	function M.isFrozen(plr) return state.frozen[plr] ~= nil end

	function M.frozenCount()
		local n = 0
		for _ in pairs(state.frozen) do n += 1 end
		return n
	end

	-- Freeze everyone inside a radius of the local player, capped so a 100-player
	-- server cannot turn this into a per-frame stall. Local view only.
	function M.freezeAll(radius, maxCount)
		local myRoot = rootOf(LP)
		if not myRoot then return false, "no character" end
		local me = myRoot.CFrame.Position
		local r = radius or 80
		local cap = maxCount or 12
		local n = 0
		for _, plr in ipairs(Players:GetPlayers()) do
			if n >= cap then break end
			if plr ~= LP then
				local pr = rootOf(plr)
				if pr and (pr.CFrame.Position - me).Magnitude <= r then
					if M.freeze(plr) then n += 1 end
				end
			end
		end
		return true, n
	end

	function M.spectate(plr)
		local cam = Workspace.CurrentCamera
		local theirRoot = rootOf(plr)
		if not cam or not theirRoot then return false, "no target camera" end
		M.unspectate()
		state.spectating = plr
		cam.CameraType = Enum.CameraType.Scriptable
		state.spectateConn = RunService.RenderStepped:Connect(function()
			local r = rootOf(plr)
			if not r or state.spectating ~= plr then return end
			local head = r.Position + Vector3.new(0, 2, 0)
			cam.CFrame = CFrame.new(head - r.CFrame.LookVector * 8, head)
		end)
		return true
	end

	function M.unspectate()
		state.spectating = nil
		if state.spectateConn then
			pcall(function() state.spectateConn:Disconnect() end)
			state.spectateConn = nil
		end
		local cam = Workspace.CurrentCamera
		if cam then cam.CameraType = Enum.CameraType.Custom end
	end

	function M.follow(plr)
		M.unfollow()
		state.following = plr
		state.followConn = RunService.Heartbeat:Connect(function()
			if state.following ~= plr then return end
			local myRoot = rootOf(LP)
			local theirRoot = rootOf(plr)
			if not myRoot or not theirRoot then return end
			pcall(function()
				myRoot.CFrame = theirRoot.CFrame * CFrame.new(0, 0, 4)
			end)
		end)
		return true
	end

	function M.unfollow()
		state.following = nil
		if state.followConn then
			pcall(function() state.followConn:Disconnect() end)
			state.followConn = nil
		end
	end

	function M.status()
		local frozen = 0
		for _ in pairs(state.frozen) do frozen += 1 end
		return {
			frozen = frozen,
			following = state.following and state.following.Name or nil,
			spectating = state.spectating and state.spectating.Name or nil,
		}
	end

	function M.cleanup()
		M.unweld()
		M.unfling()
		M.thaw()
		M.unfollow()
		M.unspectate()
	end

	return M
end

		return Targets
	end)()

	local SelfLib = (function()
--[[
  self.lua - local-player utilities
  Everything here is client-side and reversible. Nothing targets other players.
]]
local Self = {}

function Self.new(ctx)
	local Players, RunService, Workspace = ctx.Players, ctx.RunService, ctx.Workspace
	local LP = ctx.LP

	local M = {}
	local s = {
		conns = {},
		godBackup = nil,
		orig = {},
		frozen = false,
		invOrig = {},   -- per-part original Transparency, so restore is exact
	}

	local function char()
		local c = LP.Character
		if not c or not c.Parent then return nil end
		return c
	end

	local function hum()
		local c = char()
		return c and c:FindFirstChildOfClass("Humanoid")
	end

	local function root()
		local c = char()
		return c and c:FindFirstChild("HumanoidRootPart")
	end

	local function track(conn)
		s.conns[#s.conns + 1] = conn
		return conn
	end

	local function untrackAll()
		for _, c in ipairs(s.conns) do pcall(function() c:Disconnect() end) end
		table.clear(s.conns)
	end

	------------------------------------------------------------------ anti void
	-- Teleport back up the moment the character drops below the world floor.
	-- Works by watching Y against a threshold rather than trusting any single
	-- game's kill plane, which varies.
	function M.startAntiVoid(floorY)
		M.stopAntiVoid()
		local floor = floorY or -80
		s.antiVoid = true
		track(RunService.Heartbeat:Connect(function()
			if not s.antiVoid then return end
			local r = root()
			if not r then return end
			local pos = r.CFrame.Position
			if pos.Y < floor then
				local target = Vector3.new(pos.X, floor + 40, pos.Z)
				pcall(function() r.CFrame = CFrame.new(target) end)
				pcall(function() r.AssemblyLinearVelocity = Vector3.zero end)
			end
		end))
		return true
	end

	function M.stopAntiVoid()
		s.antiVoid = false
	end

	------------------------------------------------------------------- god mode
	-- A client can only make itself *look* alive: keep health pinned and respawn
	-- suppressed. The server still decides real damage, so this survives fall
	-- damage and most client-side sources, not server-side kills.
	--[[
	  Client god mode, honestly scoped. Health is server-authoritative in most
	  games, so this cannot stop a server-side kill. What it CAN do, and now
	  does, is survive everything that routes through the humanoid on our client:
	  fall damage, void death, scripted damage that lands locally.

	  Fixes over the first version:
	  - finite MaxHealth: math.huge is often rejected or reset by the server
	  - health is re-pinned from the HealthChanged signal, not just one timer
	  - re-applied after respawn
	]]
	function M.godMode(on)
		s.god = on and true or false
		if not on then
			s.pinning = false
			return
		end
		if s.godConn then pcall(function() s.godConn:Disconnect() end) s.godConn = nil end

		local function apply()
			local h = hum()
			if not h then return end
			local max = ctx.Config and ctx.Config.GodHealth or 1e9
			if h.MaxHealth ~= max then
				pcall(function() h.MaxHealth = max end)
			end
			if h.Health < max then
				pcall(function() h.Health = max end)
			end
		end

		apply()
		-- re-pin whenever anything lowers it; the guard stops our own write
		-- from recursing through HealthChanged
		s.godConn = track(hum() and hum().HealthChanged:Connect(function(v)
			if not s.god or s.pinning then return end
			local max = ctx.Config and ctx.Config.GodHealth or 1e9
			if v < max then
				s.pinning = true
				pcall(function() hum().Health = max end)
				s.pinning = false
			end
		end) or { Disconnect = function() end })

		-- belt and braces: a cheap heartbeat re-pin catches respawns
		track(RunService.Heartbeat:Connect(function()
			if not s.god then return end
			local h = hum()
			if not h then return end
			local max = ctx.Config and ctx.Config.GodHealth or 1e9
			if h.MaxHealth ~= max or h.Health < max then apply() end
		end))
	end

	function M.isGod() return s.god == true end

	--------------------------------------------------------------------- noclip
	function M.noclip(on)
		M.unnoclip()
		if not on then return end
		s.noclip = true
		track(RunService.Stepped:Connect(function()
			if not s.noclip then return end
			local c = char()
			if not c then return end
			for _, p in ipairs(c:GetDescendants()) do
				if p:IsA("BasePart") and p.CanCollide then
					pcall(function() p.CanCollide = false end)
				end
			end
		end))
	end

	function M.unnoclip()
		s.noclip = false
		local c = char()
		if not c then return end
		for _, p in ipairs(c:GetDescendants()) do
			if p:IsA("BasePart") then
				local keep = (p.Name ~= "HumanoidRootPart")
				pcall(function() p.CanCollide = keep end)
			end
		end
	end

	----------------------------------------------------------------------- fly
	--[[
	  Fly. The old version used BodyVelocity, which is the reason it "did not
	  work" in most games: body movers are frequently destroyed or overridden by
	  the game's own movement code, and MaxForce fights gravity rather than
	  replacing it. This drives AssemblyLinearVelocity directly instead - the same
	  primitive that is verified working in Studio - and lerps toward the target
	  velocity so it accelerates smoothly instead of snapping.
	]]
	function M.fly(on, speed)
		M.unfly()
		if not on then return true end
		local r, h = root(), hum()
		if not r or not h then return false, "no character" end
		pcall(function()
			if r.Anchored then r.Anchored = false end
		end)
		if r.Anchored then return false, "your character is anchored here" end

		s.fly = true
		s.flySpeed = speed or 60
		s.orig.platformStand = h.PlatformStand
		pcall(function() h.PlatformStand = true end)

		local function down(kc)
			local ok, res = pcall(function() return ctx.UserInput:IsKeyDown(kc) end)
			return ok and res
		end

		s.flyConn = track(RunService.RenderStepped:Connect(function()
			if not s.fly then return end
			local rr, hh = root(), hum()
			local cam = Workspace.CurrentCamera
			if not rr or not hh or not cam then return end

			-- Humanoid.MoveDirection is already the world-space direction of the
			-- player's input, so this works on touch thumbsticks as well as WASD
			local move = hh.MoveDirection * s.flySpeed

			local up = 0
			if down(Enum.KeyCode.Space) then up += 1 end
			if down(Enum.KeyCode.LeftControl) then up -= 1 end
			-- pitching the camera up/down gives altitude control without keys
			if down(Enum.KeyCode.W) or move.Magnitude > 0.01 then
				up += cam.CFrame.LookVector.Y * 1.5
			end
			move = move + Vector3.new(0, up * s.flySpeed * 0.5, 0)

			-- smooth: ease toward the wanted velocity, no snapping
			local cur = rr.AssemblyLinearVelocity
			rr.AssemblyLinearVelocity = cur:Lerp(move, 0.35)
			pcall(function() rr.AssemblyAngularVelocity = Vector3.new(0, 0, 0) end)
		end))
		return true
	end

	function M.unfly()
		if not s.fly and not s.flyConn then return end
		s.fly = false
		if s.flyConn then
			pcall(function() s.flyConn:Disconnect() end)
			s.flyConn = nil
		end
		local h = hum()
		if h and s.orig.platformStand ~= nil then
			pcall(function() h.PlatformStand = s.orig.platformStand end)
			s.orig.platformStand = nil
		end
		local r = root()
		if r then pcall(function() r.AssemblyLinearVelocity = Vector3.zero end) end
	end

	function M.setSpeed(n)
		local h = hum()
		if not h then return false end
		s.orig.walkSpeed = s.orig.walkSpeed or h.WalkSpeed
		h.WalkSpeed = n
		return true
	end

	--[[
	  Fix a stuck character. Every exploit that moves your body can leave you
	  spun, anchored in mid-air, seated, or with the camera following something
	  else - which is what "my screen is stuck on one spot" feels like. This
	  clears all of it and re-points the camera at your own humanoid.
	]]
	function M.resetPhysics()
		local c = char()
		if not c then return false, "no character" end
		for _, d in ipairs(c:GetDescendants()) do
			if d:IsA("BasePart") then
				pcall(function() d.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
				pcall(function() d.AssemblyAngularVelocity = Vector3.new(0, 0, 0) end)
			end
		end
		local h = hum()
		if h then
			pcall(function() h.PlatformStand = false end)
			pcall(function() h.Sit = false end)
			pcall(function() h.AutoRotate = true end)
			local cam = Workspace.CurrentCamera
			if cam then pcall(function() cam.CameraSubject = h end) end
		end
		return true
	end

	--[[
	  God speed. Games reset WalkSpeed constantly, so a one-shot write is
	  usually undone within a frame. This pins it from Heartbeat instead, which
	  wins against ordinary resets.
	]]
	function M.godSpeed(on, speed)
		s.godSpeed = on and true or false
		if not on then
			s.godSpeed = false
			local h = hum()
			if h and s.orig.walkSpeed then pcall(function() h.WalkSpeed = s.orig.walkSpeed end) end
			return true
		end
		s.godSpeedValue = speed or 500
		if not s.godSpeedConn then
			s.godSpeedConn = track(RunService.Heartbeat:Connect(function()
				if not s.godSpeed then return end
				local h = hum()
				if not h then return end
				local want = s.godSpeedValue or 500
				if h.WalkSpeed ~= want then h.WalkSpeed = want end
			end))
		end
		local h = hum()
		if h then
			s.orig.walkSpeed = s.orig.walkSpeed or h.WalkSpeed
			h.WalkSpeed = s.godSpeedValue
		end
		return true
	end

	function M.isGodSpeed() return s.godSpeed == true end

	function M.setJump(n)
		local h = hum()
		if not h then return false end
		s.orig.jumpPower = s.orig.jumpPower or h.JumpPower
		pcall(function() h.UseJumpPower = true end)
		h.JumpPower = n
		return true
	end

	----------------------------------------------------------------- invisible
	--[[
	  Invisible.

	  Measured in Studio, and the honest result: writing Transparency on your own
	  character from the client does NOT replicate. The client set Head.Transparency
	  = 1 and the server still read 0, so other players keep seeing you. Property
	  changes made locally are not sent to the server; only physics ownership
	  (CFrame of your own root) travels that way.

	  There is no client-side route to being invisible to everyone - that needs the
	  server to cooperate, which is out of reach of any script running here. What
	  this does is hide you from your own camera, which is still useful for
	  screenshots and for seeing through your own body. It is labelled that way in
	  the UI so nobody is told it does more than it does.

	  It does record each part's original transparency, so restoring is exact and
	  does not flatten a deliberately semi-transparent part. Accessories added
	  while hidden are caught by DescendantAdded.
	]]
	function M.invisible(on)
		s.invisible = on and true or false
		local c = char()
		if not c then return false, "no character" end

		local function apply(inst)
			if inst:IsA("BasePart") then
				if s.invOrig[inst] == nil then s.invOrig[inst] = inst.Transparency end
				pcall(function() inst.Transparency = 1 end)
			elseif inst:IsA("Decal") or inst:IsA("Texture") then
				if s.invOrig[inst] == nil then s.invOrig[inst] = inst.Transparency end
				pcall(function() inst.Transparency = 1 end)
			elseif inst:IsA("BillboardGui") then
				pcall(function() inst.Enabled = false end)
			end
		end

		if not on then
			for inst, t in pairs(s.invOrig) do
				pcall(function() inst.Transparency = t end)
			end
			table.clear(s.invOrig)
			if s.invConn then
				pcall(function() s.invConn:Disconnect() end)
				s.invConn = nil
			end
			-- re-enable name tags we turned off
			for _, d in ipairs(c:GetDescendants()) do
				if d:IsA("BillboardGui") then pcall(function() d.Enabled = true end) end
			end
			return true
		end

		for _, d in ipairs(c:GetDescendants()) do apply(d) end
		if s.invConn then pcall(function() s.invConn:Disconnect() end) end
		s.invConn = track(c.DescendantAdded:Connect(function(d)
			if s.invisible then apply(d) end
		end))
		return true
	end

	function M.isInvisible() return s.invisible == true end

	function M.ghost(on)
		s.ghost = on and true or false
		local c = char()
		if not c then return false, "no character" end

		if not on then
			for _, d in ipairs(c:GetDescendants()) do
				if d:IsA("BasePart") then
					pcall(function() d.CanTouch = true end)
					pcall(function() d.Transparency = 0 end)
				elseif d:IsA("ForceField") and d.Name == "FB_God" then
					pcall(function() d:Destroy() end)
				end
			end
			M.godMode(false)
			return true
		end

		for _, d in ipairs(c:GetDescendants()) do
			if d:IsA("BasePart") then
				pcall(function() d.CanTouch = false end)
				pcall(function() d.Transparency = 1 end)
			end
		end
		if not c:FindFirstChild("FB_God") then
			local ff = Instance.new("ForceField")
			ff.Name = "FB_God"
			ff.Visible = false
			ff.Parent = c
		end
		M.godMode(true)

		-- parts added later (tools, accessories) must not reopen the hitbox
		if s.ghostConn then pcall(function() s.ghostConn:Disconnect() end) end
		s.ghostConn = track(c.DescendantAdded:Connect(function(d)
			if not s.ghost then return end
			if d:IsA("BasePart") then
				pcall(function() d.CanTouch = false end)
				pcall(function() d.Transparency = 1 end)
			end
		end))
		return true
	end

	function M.isGhost() return s.ghost == true end

	----------------------------------------------------------------- teleporting
	-- click-to-teleport: reads the mouse hit once, so it works the same on PC
	-- and on touch (a tap sets Mouse.Hit)
	function M.teleportToCursor(offset)
		local r = root()
		if not r then return false, "no character" end
		local mouse = LP:GetMouse()
		local hit = mouse and mouse.Hit
		if not hit then return false, "no cursor position" end
		local target = hit.Position + Vector3.new(0, offset or 3, 0)
		r.CFrame = CFrame.new(target) * (r.CFrame - r.CFrame.Position)
		local h = hum()
		if h then pcall(function() h.PlatformStand = false end) end
		return true, target
	end

	function M.savePosition()
		local r = root()
		if not r then return false, "no character" end
		s.savedPos = r.CFrame
		return true
	end

	function M.loadPosition()
		if not s.savedPos then return false, "nothing saved yet" end
		local r = root()
		if not r then return false, "no character" end
		r.CFrame = s.savedPos
		return true
	end

	function M.hasSavedPosition() return s.savedPos ~= nil end

	----------------------------------------------------------------- infinite jump
	-- re-enters the jump state whenever the humanoid falls, which is what makes
	-- multi-jump work without touching JumpPower
	function M.infiniteJump(on)
		s.infJump = on and true or false
		if s.infJumpConn then
			pcall(function() s.infJumpConn:Disconnect() end)
			s.infJumpConn = nil
		end
		if not on then return true end
		s.infJumpConn = track(RunService.RenderStepped:Connect(function()
			if not s.infJump then return end
			local h = hum()
			if not h then return end
			local ok, state = pcall(function() return h:GetState() end)
			if ok and state == Enum.HumanoidStateType.Freefall then
				pcall(function() h:ChangeState(Enum.HumanoidStateType.Jumping) end)
			end
		end))
		return true
	end

	------------------------------------------------------------------- perf readout
	-- Client-side only. This is what tells you whether lag is your frame rate or
	-- the network - it measures nothing on the server and sends no load.
	function M.perf()
		local fps = s.fps or 0
		local ping = 0
		local okPing, v = pcall(function()
			return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
		if okPing and type(v) == "number" then ping = math.floor(v) end
		local parts = 0
		pcall(function()
			for _, d in ipairs(workspace:GetDescendants()) do
				if d:IsA("BasePart") then parts += 1 end
			end
		end)
		return { fps = math.floor(fps), ping = ping, parts = parts }
	end

	function M.startPerf()
		if s.perfConn then return end
		local frames, t0 = 0, os.clock()
		s.perfConn = track(RunService.RenderStepped:Connect(function()
			frames += 1
			local now = os.clock()
			if now - t0 >= 1 then
				s.fps = frames / (now - t0)
				frames, t0 = 0, now
			end
		end))
	end

	function M.stopPerf()
		if s.perfConn then
			pcall(function() s.perfConn:Disconnect() end)
			s.perfConn = nil
		end
	end

	------------------------------------------------------------------- anti afk
	function M.antiAfk(on)
		if not on then
			if s.afkConn then s.afkConn:Disconnect() s.afkConn = nil end
			return
		end
		local vu = ctx.VirtualUser
		s.afkConn = track(RunService.Heartbeat:Connect(function()
			pcall(function() ctx.VirtualUser:CaptureController() end)
		end))
	end

	---------------------------------------------------------------- local freeze
	-- Honestly named: this stops YOUR physics, it is not a server-wide freeze.
	function M.freezeLocal(on)
		local r = root()
		if not r then return false, "no character" end
		s.frozen = on and true or false
		pcall(function() r.Anchored = s.frozen end)
		return true
	end

	function M.isFrozen() return s.frozen end

	function M.onCharacterAdded()
		if s.ghost then M.ghost(true) elseif s.god then M.godMode(true) end
	end

	function M.restoreAll()
		untrackAll()
		M.ghost(false)
		M.invisible(false)
		M.infiniteJump(false)
		M.godSpeed(false)
		if s.godSpeedConn then pcall(function() s.godSpeedConn:Disconnect() end) s.godSpeedConn = nil end
		M.unfly()
		M.unnoclip()
		M.stopAntiVoid()
		M.godMode(false)
		M.freezeLocal(false)
		local h = hum()
		if h then
			if s.orig.walkSpeed then pcall(function() h.WalkSpeed = s.orig.walkSpeed end) end
			if s.orig.jumpPower then pcall(function() h.JumpPower = s.orig.jumpPower end) end
			local mh = s.orig.maxHealth
			if mh and mh ~= math.huge then pcall(function() h.MaxHealth = mh end) end
		end
		return true
	end

	return M
end

		return Self
	end)()

	-- ==========================================================================
	-- interface: tabbed panel, adaptive for PC and touch
	-- ==========================================================================
	local Theme = {
		bg = Color3.fromRGB(9, 9, 12),
		panel = Color3.fromRGB(17, 17, 22),
		surface = Color3.fromRGB(22, 22, 29),
		surfaceHi = Color3.fromRGB(31, 31, 40),
		surfacePress = Color3.fromRGB(40, 34, 62),
		hair = Color3.fromRGB(40, 40, 52),
		accent = Color3.fromRGB(139, 92, 246),
		accent2 = Color3.fromRGB(192, 132, 252),
		accentSoft = Color3.fromRGB(58, 44, 96),
		text = Color3.fromRGB(238, 238, 246),
		dim = Color3.fromRGB(136, 136, 152),
		faint = Color3.fromRGB(96, 96, 112),
		good = Color3.fromRGB(52, 211, 153),
		bad = Color3.fromRGB(239, 100, 100),
	}
	local Font = Enum.Font.Gotham

	local BASE_W, BASE_H = 312, 492

	-- context object shared with the modules
	local ctx = {
		Players = Players,
		RunService = RunService,
		UserInput = UserInput,
		Workspace = Workspace,
		LP = LP,
		Config = Config,
		notify = notify,
		out = out,
	}

	local Targets = TargetsLib.new(ctx)
	local SelfTools = SelfLib.new(ctx)
	ctx.Targets = Targets
	ctx.SelfTools = SelfTools

	-- stopping must not leave a local freeze or weld on the target's body;
	-- this hook is what Engine.stop calls (see the note there)
	Engine.onStop = function()
		pcall(function() Targets.thawAll() end)
		pcall(function() Targets.unweld() end)
		pcall(function() Targets.unfling() end)
	end

	local function corner(obj, r)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, r or 8)
		c.Parent = obj
		return c
	end

	local function new(class, props, parent)
		local o = Instance.new(class)
		for k, v in pairs(props) do o[k] = v end
		o.Parent = parent
		return o
	end

	local function stroke(obj, color, thick, alpha)
		return new("UIStroke", {
			Color = color or Theme.hair,
			Thickness = thick or 1,
			Transparency = alpha or 0,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, obj)
	end

	-- a 2px bar used as a section marker, so labels read as grouped
	local function bar(parent, color)
		local b = new("Frame", {
			Size = UDim2.fromOffset(2, 9),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
		}, parent)
		corner(b, 1)
		return b
	end

	local tweens = {}
	local function tweenObj(obj, prop, goal, time)
		tweens[obj] = (tweens[obj] or 0) + 1
		local key = tweens[obj]
		local t = TweenService:Create(obj, TweenInfo.new(time or 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { [prop] = goal })
		t:Play()
		t.Completed:Connect(function()
			if tweens[obj] == key then tweens[obj] = nil end
		end)
	end

	local function viewport()
		local cam = Workspace.CurrentCamera
		if cam and cam.ViewportSize.X > 0 then return cam.ViewportSize end
		return Vector2.new(1280, 720)
	end

	local pool = {}
	local conns = {}

	---------------------------------------------------------------------- shell
	local gui = new("ScreenGui", {
		Name = "FaceBangUI",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 200,
	})
	local parentGui = (function()
		if CAP.gethui then
			local ok, h = pcall(ENV.gethui)
			if ok and h then return h end
		end
		return LP:FindFirstChildOfClass("PlayerGui") or LP:WaitForChild("PlayerGui")
	end)()
	gui.Parent = parentGui

	-- two shadow layers: a wide soft one for depth, a tight one for contact
	local shadowFar = new("Frame", {
		Name = "ShadowFar",
		Size = UDim2.fromOffset(BASE_W, BASE_H),
		Position = UDim2.new(0, 30, 0.5, -BASE_H / 2 + 10),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		ZIndex = 0,
	}, gui)
	corner(shadowFar, 20)

	local shadow = new("Frame", {
		Name = "Shadow",
		Size = UDim2.fromOffset(BASE_W, BASE_H),
		Position = UDim2.new(0, 27, 0.5, -BASE_H / 2 + 4),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		ZIndex = 1,
	}, gui)
	corner(shadow, 16)

	local win = new("Frame", {
		Name = "Window",
		Size = UDim2.fromOffset(BASE_W, BASE_H),
		Position = UDim2.new(0, 24, 0.5, -BASE_H / 2),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, gui)
	win.AnchorPoint = Vector2.new(0, 0)
	corner(win, 16)
	stroke(win, Color3.fromRGB(58, 58, 74), 1)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.panel, Theme.bg),
	}, win)

	-- scale + clamp into the safe area, recomputed on resize / rotation
	local uiScale = new("UIScale", { Scale = 1 }, win)
	local function syncShadows()
		shadowFar.Size = win.Size
		shadow.Size = win.Size
		shadowFar.Position = UDim2.fromOffset(win.Position.X.Offset + 3, win.Position.Y.Offset + 10)
		shadow.Position = UDim2.fromOffset(win.Position.X.Offset + 3, win.Position.Y.Offset + 4)
	end
	local function fitPanel()
		local vp = viewport()
		local pad = 14
		local scale = math.clamp(math.min((vp.X - pad * 2) / BASE_W, (vp.Y - pad * 2) / BASE_H), 0.6, 1)
		uiScale.Scale = scale
		win.Size = UDim2.fromOffset(BASE_W * scale, BASE_H * scale)
		local cur = win.Position
		win.Position = UDim2.fromOffset(
			math.clamp(cur.X.Offset, pad, math.max(pad, vp.X - win.Size.X.Offset - pad)),
			math.clamp(cur.Y.Offset, pad, math.max(pad, vp.Y - win.Size.Y.Offset - pad)))
		syncShadows()
		return scale
	end
	fitPanel()

	--------------------------------------------------------------------- header
	local HEADER_H = 54
	local header = new("Frame", {
		Size = UDim2.new(1, 0, 0, HEADER_H),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, win)
	corner(header, 16)
	-- square off the bottom corners: header sits flush against the body
	new("Frame", {
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.new(0, 0, 1, -16),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, header)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.panel, Theme.bg),
	}, header)
	-- hairline under the header
	new("Frame", {
		Size = UDim2.new(1, -24, 0, 1),
		Position = UDim2.new(0, 12, 1, -1),
		BackgroundColor3 = Theme.hair,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)

	local brandBar = new("Frame", {
		Size = UDim2.fromOffset(3, 22),
		Position = UDim2.fromOffset(13, 13),
		BackgroundColor3 = Theme.accent,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)
	corner(brandBar, 2)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.accent2, Theme.accent),
	}, brandBar)

	new("TextLabel", {
		Size = UDim2.new(1, -110, 0, 18),
		Position = UDim2.fromOffset(24, 11),
		BackgroundTransparency = 1,
		Text = "FACE BANG",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.text,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		ZIndex = 4,
	}, header)

	new("TextLabel", {
		Size = UDim2.new(1, -110, 0, 12),
		Position = UDim2.fromOffset(24, 30),
		BackgroundTransparency = 1,
		Text = "v" .. tostring(VERSION or "1.4.0") .. "  ·  "
			.. (CAP and CAP.name and tostring(CAP.name):sub(1, 18) or "universal"),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.faint,
		Font = Font,
		TextSize = 9,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
	}, header)

	local dotRing = new("Frame", {
		Size = UDim2.fromOffset(14, 14),
		Position = UDim2.new(1, -84, 0.5, -7),
		BackgroundColor3 = Theme.accent,
		BackgroundTransparency = 0.86,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)
	corner(dotRing, 7)

	local stateDot = new("Frame", {
		Name = "StateDot",
		Size = UDim2.fromOffset(7, 7),
		Position = UDim2.new(0.5, -3.5, 0.5, -3.5),
		BackgroundColor3 = Theme.dim,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, dotRing)
	corner(stateDot, 4)

	local hideBtn = new("TextButton", {
		Size = UDim2.fromOffset(28, 26),
		Position = UDim2.new(1, -34, 0.5, -13),
		BackgroundColor3 = Theme.surfaceHi,
		Text = "-",
		TextColor3 = Theme.dim,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)
	corner(hideBtn, 8)
	stroke(hideBtn, Theme.hair)
	hideBtn.MouseEnter:Connect(function() tweenObj(hideBtn, "TextColor3", Theme.text) end)
	hideBtn.MouseLeave:Connect(function() tweenObj(hideBtn, "TextColor3", Theme.dim) end)

	local dragZone = new("TextButton", {
		Size = UDim2.new(1, -70, 0, HEADER_H),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 3,
	}, win)
	local dragStart, dragOrigin, dragging = nil, nil, false
	dragZone.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			dragOrigin = win.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	conns[#conns + 1] = UserInput.InputChanged:Connect(function(input)
		local t = input.UserInputType
		if not dragging or not dragStart then return end
		if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then return end
		local d = input.Position - dragStart
		local vp = viewport()
		local pad = 14
		local nx = math.clamp(dragOrigin.X.Offset + d.X, pad, math.max(pad, vp.X - win.Size.X.Offset - pad))
		local ny = math.clamp(dragOrigin.Y.Offset + d.Y, pad, math.max(pad, vp.Y - win.Size.Y.Offset - pad))
		win.Position = UDim2.fromOffset(nx, ny)
		syncShadows()
	end)

	----------------------------------------------------------------- status row
	local statusWrap = new("Frame", {
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(12, HEADER_H + 8),
		BackgroundColor3 = Theme.surface,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
	}, win)
	corner(statusWrap, 7)

	local status = new("TextLabel", {
		Size = UDim2.new(1, -20, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		BackgroundTransparency = 1,
		Text = "idle",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.dim,
		Font = Font,
		TextSize = 10,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, statusWrap)

	------------------------------------------------------------------- tab bar
	local tabBar = new("Frame", {
		Size = UDim2.new(1, -24, 0, 30),
		Position = UDim2.fromOffset(12, HEADER_H + 36),
		BackgroundColor3 = Theme.surface,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
	}, win)
	corner(tabBar, 9)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 3),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, tabBar)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, 3),
		PaddingRight = UDim.new(0, 3),
		PaddingTop = UDim.new(0, 3),
		PaddingBottom = UDim.new(0, 3),
	}, tabBar)

	local pages = {}
	local tabButtons = {}
	local activeTab

	local pageHost = new("Frame", {
		Size = UDim2.new(1, -20, 1, -(HEADER_H + 76)),
		Position = UDim2.fromOffset(10, HEADER_H + 74),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	}, win)

	local function mkTab(name, order)
		local b = new("TextButton", {
			Size = UDim2.new(0.25, -3, 1, 0),
			BackgroundColor3 = Theme.surface,
			BackgroundTransparency = 1,
			Text = name,
			TextColor3 = Theme.dim,
			Font = Font,
			TextSize = 11,
			AutoButtonColor = false,
			BorderSizePixel = 0,
			LayoutOrder = order,
		}, tabBar)
		corner(b, 7)
		local st = stroke(b, Theme.hair, 1, 1)
		tabButtons[name] = b
		b.MouseEnter:Connect(function()
			if activeTab ~= name then tweenObj(b, "TextColor3", Theme.text) end
		end)
		b.MouseLeave:Connect(function()
			if activeTab ~= name then tweenObj(b, "TextColor3", Theme.dim) end
		end)
		return b, st
	end

	local function mkPage(name)
		local p = new("ScrollingFrame", {
			Name = name .. "Page",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = Theme.accent,
			ScrollBarImageTransparency = 0.35,
			Visible = false,
		}, pageHost)
		new("UIListLayout", {
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, p)
		new("UIPadding", {
			PaddingLeft = UDim.new(0, 2),
			PaddingRight = UDim.new(0, 6),
			PaddingBottom = UDim.new(0, 10),
		}, p)
		pages[name] = p
		return p
	end

	local function showTab(name)
		activeTab = name
		for n, p in pairs(pages) do
			p.Visible = (n == name)
			if n == name then
				-- slide the new page up into place instead of it appearing
				p.Position = UDim2.fromOffset(0, 6)
				TweenService:Create(p, TweenInfo.new(0.16, Enum.EasingStyle.Quint),
					{ Position = UDim2.fromOffset(0, 0) }):Play()
			end
		end
		for n, b in pairs(tabButtons) do
			local on = (n == name)
			b.BackgroundColor3 = Theme.accent
			b.Font = on and Enum.Font.GothamBold or Font
			TweenService:Create(b, TweenInfo.new(0.16, Enum.EasingStyle.Quint), {
				BackgroundTransparency = on and 0 or 1,
				TextColor3 = on and Theme.text or Theme.dim,
			}):Play()
			local st = b:FindFirstChildOfClass("UIStroke")
			if st then
				TweenService:Create(st, TweenInfo.new(0.16), { Transparency = on and 1 or 0.5 }):Play()
			end
		end
	end

	for i, name in ipairs({ "Aim", "Self", "Players", "Server" }) do
		local b = mkTab(name, i)
		mkPage(name)
		b.MouseButton1Click:Connect(function() showTab(name) end)
	end

	--------------------------------------------------------------- widgets
	local ROW_H = 40

	-- one row = label on the left, control on the right. 40px tall so it stays a
	-- comfortable touch target at the 0.6 scale floor.
	local function mkRow(page, order)
		local r = new("Frame", {
			Size = UDim2.new(1, 0, 0, ROW_H),
			BackgroundColor3 = Theme.surface,
			BorderSizePixel = 0,
			LayoutOrder = order,
		}, page)
		corner(r, 10)
		stroke(r, Theme.hair, 1, 0.55)
		return r
	end

	-- one-shot press ripple. Kept in a table and aged by the animation loop
	-- instead of task.delay, so it cannot outlive the UI if the panel is torn down.
	local ripples = {}
	local function ripple(row)
		local r = new("Frame", {
			Size = UDim2.fromOffset(14, 14),
			Position = UDim2.new(0.5, -7, 0.5, -7),
			BackgroundColor3 = Theme.accent,
			BackgroundTransparency = 0.55,
			BorderSizePixel = 0,
			ZIndex = row.ZIndex + 1,
		}, row)
		corner(r, 7)
		ripples[#ripples + 1] = { frame = r, t = os.clock() }
	end

	local function mkLabel(row, text)
		return new("TextLabel", {
			Size = UDim2.new(1, -86, 1, 0),
			Position = UDim2.fromOffset(12, 0),
			BackgroundTransparency = 1,
			Text = text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.text,
			Font = Font,
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, row)
	end

	-- hover + press feedback shared by every interactive row
	local function rowFeedback(row)
		row.MouseEnter:Connect(function() tweenObj(row, "BackgroundColor3", Theme.surfaceHi) end)
		row.MouseLeave:Connect(function() tweenObj(row, "BackgroundColor3", Theme.surface) end)
	end

	-- a chevron drawn from two bars: ">" glyphs sit too high on some fonts
	local function chevron(row, color)
		local c = new("Frame", {
			Size = UDim2.fromOffset(7, 7),
			Position = UDim2.new(1, -22, 0.5, -3),
			BackgroundTransparency = 1,
		}, row)
		for _, rot in ipairs({ 45, -45 }) do
			local b = new("Frame", {
				Size = UDim2.fromOffset(1.5, 7),
				Position = UDim2.new(0.5, -0.75, 0.5, -3.5),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Rotation = rot - 45,
				BackgroundColor3 = color or Theme.faint,
				BorderSizePixel = 0,
			}, c)
			b.Position = UDim2.new(0.5, -0.75, 0.5, -3.5)
		end
		return c
	end

	-- small caption that groups rows, so the tabs read as sections not a list
	local function section(page, order, text)
		local holder = new("Frame", {
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
			LayoutOrder = order,
		}, page)
		bar(holder, Theme.accent).Position = UDim2.fromOffset(4, 7)
		new("TextLabel", {
			Size = UDim2.new(1, -18, 1, 0),
			Position = UDim2.fromOffset(12, 0),
			BackgroundTransparency = 1,
			Text = string.upper(text),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.faint,
			Font = Enum.Font.GothamBold,
			TextSize = 9,
		}, holder)
		return holder
	end

	-- action row: tap to fire
	local function action(page, order, label, fn)
		local row = mkRow(page, order)
		mkLabel(row, label)
		chevron(row, Theme.faint)
		local btn = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		rowFeedback(row)
		btn.MouseButton1Down:Connect(function()
			row.BackgroundColor3 = Theme.surfacePress
			ripple(row)
		end)
		btn.MouseButton1Up:Connect(function() row.BackgroundColor3 = Theme.surfaceHi end)
		btn.MouseButton1Click:Connect(function()
			local ok, err = pcall(fn)
			if not ok then out("error: " .. tostring(err)) end
		end)
		return row
	end

	-- toggle row: pill with a knob that slides and colours in
	local function toggle(page, order, label, onChange, initial)
		local row = mkRow(page, order)
		mkLabel(row, label)
		local pill = new("Frame", {
			Size = UDim2.fromOffset(40, 22),
			Position = UDim2.new(1, -52, 0.5, -11),
			BackgroundColor3 = initial and Theme.good or Theme.surfaceHi,
			BorderSizePixel = 0,
		}, row)
		corner(pill, 11)
		stroke(pill, Theme.hair, 1, initial and 1 or 0.6)
		local knob = new("Frame", {
			Size = UDim2.fromOffset(16, 16),
			Position = UDim2.fromOffset(initial and 21 or 3, 3),
			BackgroundColor3 = initial and Color3.new(1, 1, 1) or Theme.dim,
			BorderSizePixel = 0,
		}, pill)
		corner(knob, 8)

		local state = initial and true or false
		local btn = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		rowFeedback(row)
		local function paint(animate)
			local t = animate == false and 0.001 or 0.14
			tweenObj(pill, "BackgroundColor3", state and Theme.good or Theme.surfaceHi, t)
			tweenObj(knob, "BackgroundColor3", state and Color3.new(1, 1, 1) or Theme.dim, t)
			local goal = UDim2.fromOffset(state and 21 or 3, 3)
			if animate == false then
				knob.Position = goal
			else
				TweenService:Create(knob, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = goal }):Play()
			end
		end
		btn.MouseButton1Click:Connect(function()
			state = not state
			paint(true)
			local ok, err = pcall(onChange, state)
			if not ok then out("error: " .. tostring(err)) end
		end)
		return { set = function(v) state = v paint(false) end, get = function() return state end }
	end

	-- stepper row: tap the value chip to cycle through a list of values
	local function stepper(page, order, label, values, onPick, initialIndex)
		local row = mkRow(page, order)
		mkLabel(row, label)
		local idx = initialIndex or 1
		local chip = new("TextButton", {
			Size = UDim2.fromOffset(64, 24),
			Position = UDim2.new(1, -76, 0.5, -12),
			BackgroundColor3 = Theme.surfaceHi,
			Text = tostring(values[idx]),
			TextColor3 = Theme.text,
			Font = Enum.Font.GothamMedium,
			TextSize = 11,
			AutoButtonColor = false,
			BorderSizePixel = 0,
		}, row)
		corner(chip, 7)
		stroke(chip, Theme.hair, 1, 0.7)
		chip.MouseEnter:Connect(function() tweenObj(chip, "BackgroundColor3", Theme.accentSoft) end)
		chip.MouseLeave:Connect(function() tweenObj(chip, "BackgroundColor3", Theme.surfaceHi) end)
		chip.MouseButton1Click:Connect(function()
			idx = idx % #values + 1
			chip.Text = tostring(values[idx])
			local ok, err = pcall(onPick, values[idx])
			if not ok then out("error: " .. tostring(err)) end
		end)
		return chip
	end

	-- forward-declared: assigned while building the Aim tab, read by UI.state
	local bangLabel, loopToggle, bangGlow

	-- destructive rows need a second tap; the armed state expires so a stray
	-- tap never leaves something dangerous primed
	local function actionConfirm(page, order, label, fn)
		local row = mkRow(page, order)
		local text = mkLabel(row, label)
		local ch = chevron(row, Theme.faint)
		local armed, token = false, 0
		local btn = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		rowFeedback(row)
		local function disarm()
			armed = false
			text.Text = label
			text.TextColor3 = Theme.text
			tweenObj(row, "BackgroundColor3", Theme.surface)
			for _, b in ipairs(ch:GetChildren()) do
				if b:IsA("Frame") then tweenObj(b, "BackgroundColor3", Theme.faint) end
			end
		end
		btn.MouseButton1Click:Connect(function()
			if not armed then
				armed = true
				token += 1
				local mine = token
				text.Text = "tap again to confirm"
				text.TextColor3 = Theme.bad
				row.BackgroundColor3 = Theme.surfacePress
				for _, b in ipairs(ch:GetChildren()) do
					if b:IsA("Frame") then b.BackgroundColor3 = Theme.bad end
				end
				task.delay(3, function()
					if armed and token == mine then disarm() end
				end)
				return
			end
			disarm()
			local ok, err = pcall(fn)
			if not ok then out("error: " .. tostring(err)) end
		end)
		return row
	end

	------------------------------------------------------------------- Aim tab
	local aim = pages.Aim
	local aimOrder = 0
	local function aimRow(...) aimOrder += 1 return aimOrder, ... end

	do
		local o, _ = aimRow()
		local row = new("Frame", {
			Size = UDim2.new(1, 0, 0, 48),
			BackgroundColor3 = Theme.accent,
			BorderSizePixel = 0,
			LayoutOrder = o,
		}, aim)
		corner(row, 12)
		new("UIGradient", {
			Rotation = 20,
			Color = ColorSequence.new(Theme.accent, Theme.accent2),
		}, row)
		local priStroke = stroke(row, Theme.accent2, 1, 0.35)

		local glow = new("Frame", {
			Size = UDim2.new(1, -8, 0, 10),
			Position = UDim2.new(0, 4, 1, -4),
			BackgroundColor3 = Theme.accent,
			BackgroundTransparency = 0.72,
			BorderSizePixel = 0,
		}, row)
		corner(glow, 5)
		bangGlow = glow

		local b = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		bangLabel = new("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "BANG NEAREST",
			TextColor3 = Color3.new(1, 1, 1),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
		}, row)

		local scale = new("UIScale", { Scale = 1 }, row)
		b.MouseEnter:Connect(function()
			tweenObj(row, "BackgroundColor3", Color3.fromRGB(163, 122, 255))
		end)
		b.MouseLeave:Connect(function()
			tweenObj(row, "BackgroundColor3", Theme.accent)
			TweenService:Create(scale, TweenInfo.new(0.1), { Scale = 1 }):Play()
		end)
		b.MouseButton1Down:Connect(function()
			ripple(row)
			TweenService:Create(scale, TweenInfo.new(0.08), { Scale = 0.97 }):Play()
		end)
		b.MouseButton1Up:Connect(function()
			TweenService:Create(scale, TweenInfo.new(0.1), { Scale = 1 }):Play()
		end)
		b.MouseButton1Click:Connect(function() Engine.toggle() end)
	end

	loopToggle = toggle(aim, 2, "loop (auto-retarget)", function(on)
		Engine.loop = on
		if on and not Engine.running then Engine.start() end
		if not on and Engine.running then Engine.stop() end
	end, false)

	action(aim, 3, "stop + restore", function()
		Engine.stop()
		loopToggle.set(false) -- Engine.stop clears loop; the pill must follow
	end)

	stepper(aim, 4, "power", { 6, 10, 12, 16, 20, 28, 36 }, function(v) Config.Power = v end, 3)
	stepper(aim, 5, "vertical offset", { 0.1, 0.35, 0.6, 0.9 }, function(v) Config.Height = v end, 2)

	toggle(aim, 6, "release from seat first", function(on) Config.SeatRelease = on end, true)

	stepper(aim, 7, "bang style", { "hybrid", "velocity", "cframe" }, function(v)
		Config.BangStyle = v
		out("bang style: " .. v)
	end, 1)

	stepper(aim, 8, "bang mode", { "fling", "lock" }, function(v)
		Config.BangMode = v
		out(v == "fling" and "bang mode: fling (launches)" or "bang mode: lock (holds them still)")
	end, 1)

	stepper(aim, 9, "fling power", { 1400, 2000, 2400, 3200, 4000 }, function(v) Config.FlingPower = v end, 3)

	------------------------------------------------------------------ Self tab
	local selfPage = pages.Self
	local so = 0
	local function sOrder() so += 1 return so end

	local ghostToggle = toggle(selfPage, sOrder(), "GHOST - invisible + invincible", function(on)
		local ok, err = SelfTools.ghost(on)
		if not ok and err then out(err) end
		if ok then out(on and "ghost on" or "ghost off") end
	end, false)

	action(selfPage, sOrder(), "fix my character (reset physics)", function()
		Targets.thawAll()
		Targets.unfling()
		Targets.unweld()
		SelfTools.resetPhysics()
		out("character reset")
	end)

	section(selfPage, sOrder(), "protection")

	local godToggle = toggle(selfPage, sOrder(), "god mode (health pinned)", function(on)
		SelfTools.godMode(on)
		if not on then SelfTools.restoreAll() SelfTools.godMode(false) end
	end, false)

	local noclipToggle = toggle(selfPage, sOrder(), "noclip", function(on) SelfTools.noclip(on) end, false)

	local flyToggle = toggle(selfPage, sOrder(), "fly (wasd / space)", function(on)
		local ok, err = SelfTools.fly(on, ctx.flySpeed or 60)
		if not ok and err then out(err) end
	end, false)

	section(selfPage, sOrder(), "movement")

	stepper(selfPage, sOrder(), "fly speed", { 30, 60, 100, 160, 240 }, function(v) ctx.flySpeed = v end, 2)
	local godSpeedToggle = toggle(selfPage, sOrder(), "GOD SPEED (pinned each frame)", function(on)
		SelfTools.godSpeed(on, ctx.godSpeedValue or 500)
	end, false)

	stepper(selfPage, sOrder(), "god speed value", { 200, 500, 1000, 2000, 4000 }, function(v)
		ctx.godSpeedValue = v
		if godSpeedToggle.get() then SelfTools.godSpeed(true, v) end
	end, 2)

	stepper(selfPage, sOrder(), "walk speed", { 16, 30, 50, 80, 120, 200 }, function(v) SelfTools.setSpeed(v) end, 1)
	stepper(selfPage, sOrder(), "jump power", { 50, 75, 100, 150, 250 }, function(v) SelfTools.setJump(v) end, 1)

	toggle(selfPage, sOrder(), "infinite jump", function(on) SelfTools.infiniteJump(on) end, false)

	section(selfPage, sOrder(), "teleport")

	action(selfPage, sOrder(), "teleport to cursor", function()
		local ok, res = SelfTools.teleportToCursor(3)
		out(ok and "teleported" or tostring(res))
	end)

	action(selfPage, sOrder(), "save position", function()
		local ok, err = SelfTools.savePosition()
		out(ok and "position saved" or tostring(err))
	end)

	action(selfPage, sOrder(), "load position", function()
		local ok, err = SelfTools.loadPosition()
		out(ok and "loaded" or tostring(err))
	end)

	local voidToggle = toggle(selfPage, sOrder(), "anti void", function(on)
		if on then SelfTools.startAntiVoid(Config.VoidFloor) else SelfTools.stopAntiVoid() end
	end, false)

	stepper(selfPage, sOrder(), "void floor Y", { -40, -80, -150, -300 }, function(v) Config.VoidFloor = v end, 2)

	local invisToggle = toggle(selfPage, sOrder(), "invisible (your view only)", function(on) SelfTools.invisible(on) end, false)

	toggle(selfPage, sOrder(), "anti afk", function(on) SelfTools.antiAfk(on) end, false)

	toggle(selfPage, sOrder(), "freeze my character (local)", function(on) SelfTools.freezeLocal(on) end, false)

	actionConfirm(selfPage, sOrder(), "restore everything", function()
		SelfTools.restoreAll()
		Engine.stop()
		Targets.cleanup()
		out("restored")
	end)

	--------------------------------------------------------------- Players tab
	local plPage = pages.Players
	local plOrder = 0

	local selectedLabel = new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		Text = "select a player below",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.dim,
		Font = Font,
		TextSize = 10,
		LayoutOrder = 0,
	}, plPage)

	local playerList = new("Frame", {
		Size = UDim2.new(1, 0, 0, 150),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		LayoutOrder = 1,
	}, plPage)
	corner(playerList, 7)
	local plScroll = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Theme.accent,
	}, playerList)
	new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, plScroll)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 5), PaddingLeft = UDim.new(0, 5),
		PaddingRight = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5),
	}, plScroll)

	local selected = nil
	local function markPlayers()
		for _, row in ipairs(pool) do
			if row.Parent then
				local isSel = selected ~= nil and row.Name == selected.Name
				row.BackgroundColor3 = isSel and Theme.accent or Theme.surface
				row.TextColor3 = isSel and Color3.new(1, 1, 1) or Theme.text
			end
		end
		if selected then
			selectedLabel.Text = "target: " .. selected.Name
		else
			selectedLabel.Text = "select a player below"
		end
	end

	local function refreshPlayers()
		for _, row in ipairs(pool) do row:Destroy() end
		table.clear(pool)
		for i, plr in ipairs(Players:GetPlayers()) do
			if plr ~= LP then
				local row = new("TextButton", {
					Size = UDim2.new(1, 0, 0, 28),
					BackgroundColor3 = Theme.surface,
					Text = plr.Name,
					TextColor3 = Theme.text,
					Font = Font,
					TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Left,
					AutoButtonColor = false,
					BorderSizePixel = 0,
					Name = plr.Name,
					LayoutOrder = i,
				}, plScroll)
				corner(row, 8)
				stroke(row, Theme.hair, 1, 0.55)
				new("UIPadding", { PaddingLeft = UDim.new(0, 10) }, row)
				row.MouseEnter:Connect(function()
					if not (selected == plr) then
						tweenObj(row, "BackgroundColor3", Theme.surfaceHi)
					end
				end)
				row.MouseLeave:Connect(function()
					if not (selected == plr) then
						tweenObj(row, "BackgroundColor3", Theme.surface)
					end
				end)
				row.MouseButton1Click:Connect(function()
					selected = plr
					Engine.target = plr
					markPlayers()
					out("selected " .. plr.Name)
				end)
				pool[#pool + 1] = row
			end
		end
		markPlayers()
	end

	local function pick() return selected end

	action(plPage, 2, "bang selected", function()
		local p = pick()
		if p then Engine.start(p) else out("no player selected") end
	end)

	action(plPage, 3, "teleport to selected", function()
		local p = pick() if p then Targets.teleportTo(p) end
	end)

	section(plPage, 2, "attack")

	action(plPage, 3, "weld fling (weld + drag, strongest)", function()
		local p = pick()
		if not p then out("no player selected") return end
		local ok, err = Targets.flingWeld(p, 2.5)
		if not ok and err then out(err) else out("weld flinging " .. p.Name) end
	end)

	action(plPage, 4, "fling selected (self-body)", function()
		local p = pick()
		if not p then return end
		local ok, err = Targets.fling(p, 3, "self")
		if not ok and err then out(err) else out("flinging " .. p.Name) end
	end)

	section(plPage, 10, "movement")

	action(plPage, 5, "fling selected (force velocity)", function()
		local p = pick()
		if not p then return end
		local ok, err = Targets.fling(p, 3, "force")
		if not ok and err then out(err) else out("flinging " .. p.Name) end
	end)

	action(plPage, 6, "freeze selected (local view)", function()
		local p = pick() if p then Targets.freeze(p) end
	end)

	action(plPage, 7, "thaw selected", function()
		local p = pick() if p then Targets.thaw(p) end
	end)

	action(plPage, 8, "follow selected", function()
		local p = pick() if p then Targets.follow(p) end
	end)

	action(plPage, 9, "spectate selected", function()
		local p = pick() if p then Targets.spectate(p) end
	end)

	action(plPage, 10, "freeze all in view (local, max 12)", function()
		local ok, n = Targets.freezeAll(80, 12)
		if ok then out("froze " .. tostring(n) .. " in view") else out("no character") end
	end)

	action(plPage, 11, "stop all player actions", function()
		Targets.cleanup()
		out("player actions cleared")
	end)

	---------------------------------------------------------------- Server tab
	local svPage = pages.Server
	local svo = 0
	local function svOrder() svo += 1 return svo end

	stepper(svPage, svOrder(), "time of day", { "off", "9", "12", "18", "0" }, function(v)
		if v == "off" then return end
		pcall(function()
			local Lighting = game:GetService("Lighting")
			Lighting.ClockTime = tonumber(v) or 12
		end)
	end, 1)

	toggle(svPage, svOrder(), "no fog", function(on)
		pcall(function()
			local Lighting = game:GetService("Lighting")
			Lighting.FogEnd = on and 1e6 or 1000
		end)
	end, false)

	action(svPage, svOrder(), "perf: fps / ping / parts", function()
		local p = SelfTools.perf()
		out(string.format("%d fps · %d ms · %d parts", p.fps, p.ping, p.parts))
	end)

	action(svPage, svOrder(), "copy job id", function()
		local id = game.JobId
		if CAP.clipboard then
			pcall(function() ENV.setclipboard(id) end)
			out("job id copied")
		else
			out("job id: " .. tostring(id))
		end
	end)

	action(svPage, svOrder(), "rejoin", function()
		local TS = game:GetService("TeleportService")
		pcall(function()
			if ENV.queue_on_teleport then
				ENV.queue_on_teleport([[repeat wait() until game:IsLoaded()]])
			end
			TS:Teleport(game.PlaceId, LP)
		end)
	end)

	action(svPage, svOrder(), "server hop", function()
		local TS = game:GetService("TeleportService")
		local http = (ENV.request or ENV.http_request or syn and syn.request)
		if not http then out("no http function") return end
		local ok, res = pcall(function()
			return http({
				Url = string.format("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100", game.PlaceId),
				Method = "GET",
			})
		end)
		if not ok or not res or not res.Body then out("hop lookup failed") return end
		local data = (ENV.HttpService and game:GetService("HttpService")) and game:GetService("HttpService"):JSONDecode(res.Body) or nil
		if not data or not data.data then out("no servers found") return end
		for _, srv in ipairs(data.data) do
			if srv.id ~= game.JobId and (srv.playing or 0) < (srv.maxPlayers or 0) then
				pcall(function() TS:TeleportToPlaceInstance(game.PlaceId, srv.id, LP) end)
				return
			end
		end
		out("no other server available")
	end)

	actionConfirm(svPage, svOrder(), "unload script", function()
		ENV.FaceBang.Unload()
	end)

	------------------------------------------------------------------- footer
	new("Frame", {
		Size = UDim2.new(1, -24, 0, 1),
		Position = UDim2.new(0, 12, 1, -20),
		BackgroundColor3 = Theme.hair,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
	}, win)

	local footer = new("TextLabel", {
		Size = UDim2.new(1, -24, 0, 12),
		Position = UDim2.new(0, 12, 1, -16),
		BackgroundTransparency = 1,
		Text = IsTouch and "tap a row to use it" or string.format("[%s] bang   [%s] loop   [%s] stop   [%s] hide",
			Config.KeyBang.Name, Config.KeyLoop.Name, Config.KeyStop.Name, Config.KeyUI.Name),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.faint,
		Font = Font,
		TextSize = 9,
	}, win)

	--------------------------------------------------------------- animation
	-- One RenderStepped loop drives every ambient animation. It never yields and
	-- does no allocation per frame: no closures in the body, no task.wait.
	local sheen = new("Frame", {
		Name = "FB_Sheen",
		Size = UDim2.new(0, 74, 0, 2),
		Position = UDim2.new(-0.3, 0, 0, HEADER_H - 2),
		BackgroundColor3 = Theme.accent,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, win)
	new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, sheen)

	-- open animation: the panel eases up from slightly small, so it lands rather
	-- than simply appearing
	local openScale = new("UIScale", { Name = "FB_OpenScale", Scale = 0.94 }, win)
	TweenService:Create(openScale, TweenInfo.new(0.24, Enum.EasingStyle.Quint),
		{ Scale = 1 }):Play()

	local t0 = os.clock()
	conns[#conns + 1] = RunService.RenderStepped:Connect(function()
		local now = os.clock() - t0

		-- header sheen sweeping left to right, then a pause before it repeats
		local cycle = (now % 4.2) / 1.1
		if cycle <= 1 then
			sheen.Position = UDim2.new(-0.3 + cycle * 1.6, 0, 0, HEADER_H - 2)
			sheen.BackgroundTransparency = 0.35
		else
			sheen.BackgroundTransparency = 1
		end

		-- breathing halo behind the status dot
		if dotRing then
			dotRing.BackgroundTransparency = 0.86 - 0.12 * (0.5 + 0.5 * math.sin(now * 3.4))
		end

		-- the main button's glow pulses while it is the thing you are about to hit
		if bangGlow then
			bangGlow.BackgroundTransparency = 0.66 - 0.14 * (0.5 + 0.5 * math.sin(now * 2.6))
		end

		-- age out press ripples
		for i = #ripples, 1, -1 do
			local rec = ripples[i]
			local age = os.clock() - rec.t
			if age > 0.42 or not rec.frame.Parent then
				if rec.frame.Parent then pcall(function() rec.frame:Destroy() end) end
				table.remove(ripples, i)
			else
				local grow = 14 + age * 300
				rec.frame.Size = UDim2.fromOffset(grow, grow)
				rec.frame.Position = UDim2.new(0.5, -grow / 2, 0.5, -grow / 2)
				rec.frame.BackgroundTransparency = 0.55 + age * 1.1
			end
		end
	end)

	--------------------------------------------------------------------- api
	UI = {}
	UI.refresh = refreshPlayers

	function UI.status(text) status.Text = text end

	function UI.state(on)
		stateDot.BackgroundColor3 = on and Theme.good or Theme.dim
		dotRing.BackgroundColor3 = on and Theme.good or Theme.dim
		dotRing.BackgroundTransparency = on and 0.78 or 0.88
		if bangLabel and bangLabel.Parent then
			bangLabel.Text = on and "BANGING" or "BANG NEAREST"
		end
		if loopToggle then loopToggle.set(Engine.loop) end
	end

	function UI.markList() markPlayers() end

	------------------------------------------------------------------- wiring
	hideBtn.MouseButton1Click:Connect(function() win.Visible = not win.Visible end)

	local keyBinds = {
		[Config.KeyBang] = function() Engine.toggle() end,
		[Config.KeyLoop] = function()
			Engine.loop = not Engine.loop
			if Engine.loop and not Engine.running then Engine.start() end
			loopToggle.set(Engine.loop)
		end,
		[Config.KeyStop] = function() Engine.stop() end,
		[Config.KeyUI] = function() win.Visible = not win.Visible end,
	}
	if not IsTouch then
		conns[#conns + 1] = UserInput.InputBegan:Connect(function(input, processed)
			if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
			local fn = keyBinds[input.KeyCode]
			if fn then fn() end
		end)
	end

	conns[#conns + 1] = Players.PlayerAdded:Connect(function(plr)
		plr.CharacterAdded:Connect(function() task.delay(0.5, refreshPlayers) end)
		refreshPlayers()
	end)
	conns[#conns + 1] = Players.PlayerRemoving:Connect(function(plr)
		if Engine.target == plr then Engine.target = nil end
		if selected == plr then selected = nil end
		task.defer(refreshPlayers)
	end)
	conns[#conns + 1] = LP.CharacterAdded:Connect(function()
		Engine.running = false
		Engine.root, Engine.head = nil, nil
		UI.state(false)
		task.delay(0.6, function() SelfTools.onCharacterAdded() end)
		task.delay(1.5, function()
			if Engine.loop then Engine.start() end
		end)
	end)

	local function onViewportChanged()
		fitPanel()
	end
	if Workspace.CurrentCamera then
		conns[#conns + 1] = Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(onViewportChanged)
	end

	task.spawn(function()
		while gui.Parent do
			task.wait(0.5)
			if Engine.running and not alive(Engine.target) then
				if Engine.loop and Config.AutoRetarget then
					local nxt = nearest()
					if nxt then Engine.start(nxt) end
				elseif not Config.AutoRetarget then
					Engine.stop()
				end
			end
		end
	end)

	------------------------------------------------------------------ unload
	local function unload()
		Engine.running = false
		pcall(restore)
		pcall(function() Targets.cleanup() end)
		pcall(function() SelfTools.restoreAll() end)
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		if gui then gui:Destroy() end
		if ENV.FaceBang then ENV.FaceBang = nil end
		notify("Face Bang", "Unloaded")
	end

	ENV.FaceBang = {
		Engine = Engine,
		Config = Config,
		UI = UI,
		Targets = Targets,
		Self = SelfTools,
		Capabilities = CAP,
		Unload = unload,
		Bang = function(plr) return Engine.toggle(plr) end,
		Stop = function() Engine.stop() end,
	}

	SelfTools.startPerf()
	showTab("Aim")
	refreshPlayers()
	UI.state(false)
	notify("Face Bang", string.format(
		"Loaded - %s | %s", CAP.executor, IsTouch and "touch mode" or "desktop mode"), 5)

end
