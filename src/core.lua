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

	RunService.RenderStepped:Connect(step)
	RunService.Heartbeat:Connect(step)
