--[[
================================================================================
  FACE BANG   v1.1.0      universal / zero-delay
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
		local jitter = (Engine.tick % 2 == 0) and Config.Offset or -Config.Offset
		local from = hrp.CFrame.Position
		local dest = head.CFrame * CFrame.new(jitter, Config.Height, 0)

		local style = Config.BangStyle
		local dx = dest.Position - from
		local dir = dx.Magnitude > 1e-4 and dx.Unit or Vector3.new(jitter, Config.Height, 0).Unit

		if style ~= "velocity" then
			-- overlap bug: this is what causes the collision
			hrp.CFrame = dest
		end

		if style == "velocity" then
			-- no teleport: fly ourselves at the target hard enough that the
			-- server resolves the collision on the next step
			local toHead = head.CFrame.Position - from
			local aim = toHead.Magnitude > 1e-4 and toHead.Unit or dir
			setVel(hrp, aim * Config.MinSpeed * 8)
		else
			local speed = math.clamp(dx.Magnitude * Config.Power, Config.MinSpeed, Config.MinSpeed * 5)
			setVel(hrp, dir * speed)
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

		state.flingConn = RunService.RenderStepped:Connect(function()
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
				-- drive ourselves hard into them, alternating so we keep colliding
				mr.AssemblyLinearVelocity = delta.Unit * 900 + Vector3.new(0, 120, 0)
			end)
			if mode == "force" then
				pcall(function()
					tr.AssemblyLinearVelocity = Vector3.new(0, 1200, 0)
				end)
			end
		end)
		return true
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
		state.frozen[plr] = theirRoot.CFrame
		if not state.freezeConn then
			state.freezeConn = RunService.RenderStepped:Connect(function()
				for p, cf in pairs(state.frozen) do
					local r = rootOf(p)
					if r then
						pcall(function() r.CFrame = cf end)
					else
						state.frozen[p] = nil
					end
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
	function M.fly(on, speed)
		M.unfly()
		if not on then return end
		local r, h = root(), hum()
		if not r or not h then return false, "no character" end
		s.fly = true
		s.flySpeed = speed or 60
		s.orig.flyAnchored = r.Anchored

		local bodyVel = Instance.new("BodyVelocity")
		bodyVel.Name = "FB_Fly"
		bodyVel.MaxForce = Vector3.new(1e6, 1e6, 1e6)
		bodyVel.Velocity = Vector3.zero
		bodyVel.Parent = r
		pcall(function() h.PlatformStand = true end)

		local cam = Workspace.CurrentCamera
		track(RunService.RenderStepped:Connect(function()
			if not s.fly then return end
			local rr = root()
			if not rr or not cam then return end
			local move = Vector3.zero
			-- keyboard
			local function down(kc)
				local ok, res = pcall(function() return ctx.UserInput:IsKeyDown(kc) end)
				return ok and res
			end
			if down(Enum.KeyCode.W) then move += cam.CFrame.LookVector end
			if down(Enum.KeyCode.S) then move -= cam.CFrame.LookVector end
			if down(Enum.KeyCode.A) then move -= cam.CFrame.RightVector end
			if down(Enum.KeyCode.D) then move += cam.CFrame.RightVector end
			if down(Enum.KeyCode.Space) then move += Vector3.new(0, 1, 0) end
			if down(Enum.KeyCode.LeftControl) then move -= Vector3.new(0, 1, 0) end
			if move.Magnitude > 0 then move = move.Unit end
			bodyVel.Velocity = move * s.flySpeed
		end))
		s.flyMover = bodyVel
		return true
	end

	function M.unfly()
		s.fly = false
		if s.flyMover then
			pcall(function() s.flyMover:Destroy() end)
			s.flyMover = nil
		end
		local h = hum()
		if h then pcall(function() h.PlatformStand = false end) end
	end

	--------------------------------------------------------------------- speed
	function M.setSpeed(n)
		local h = hum()
		if not h then return false end
		s.orig.walkSpeed = s.orig.walkSpeed or h.WalkSpeed
		h.WalkSpeed = n
		return true
	end

	function M.setJump(n)
		local h = hum()
		if not h then return false end
		s.orig.jumpPower = s.orig.jumpPower or h.JumpPower
		pcall(function() h.UseJumpPower = true end)
		h.JumpPower = n
		return true
	end

	----------------------------------------------------------------- invisible
	function M.invisible(on)
		local c = char()
		if not c then return false end
		for _, p in ipairs(c:GetDescendants()) do
			if p:IsA("BasePart") or p:IsA("Decal") then
				pcall(function() p.Transparency = on and 1 or 0 end)
			elseif p:IsA("BillboardGui") or p:IsA("ParticleEmitter") then
				pcall(function() p.Enabled = not on end)
			end
		end
		return true
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
		if s.god then M.godMode(true) end
	end

	function M.restoreAll()
		untrackAll()
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
		bg = Color3.fromRGB(13, 13, 16),
		panel = Color3.fromRGB(20, 20, 25),
		row = Color3.fromRGB(27, 27, 33),
		rowHi = Color3.fromRGB(38, 38, 47),
		accent = Color3.fromRGB(124, 92, 255),
		accentDim = Color3.fromRGB(70, 55, 130),
		text = Color3.fromRGB(234, 234, 241),
		dim = Color3.fromRGB(140, 140, 154),
		good = Color3.fromRGB(72, 208, 138),
		bad = Color3.fromRGB(226, 92, 92),
	}
	local Font = Enum.Font.Gotham

	local BASE_W, BASE_H = 300, 470

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

	local function stroke(obj, color, thick)
		return new("UIStroke", {
			Color = color or Color3.fromRGB(46, 46, 58),
			Thickness = thick or 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, obj)
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

	local win = new("Frame", {
		Name = "Window",
		Size = UDim2.fromOffset(BASE_W, BASE_H),
		Position = UDim2.new(0, 24, 0.5, -BASE_H / 2),
		BackgroundColor3 = Theme.bg,
		BorderSizePixel = 0,
	}, gui)
	win.AnchorPoint = Vector2.new(0, 0)
	corner(win, 12)
	stroke(win, Color3.fromRGB(52, 52, 66))
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Theme.panel, Theme.bg) }, win)

	-- scale + clamp into the safe area, recomputed on resize / rotation
	local uiScale = new("UIScale", { Scale = 1 }, win)
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
		return scale
	end
	fitPanel()

	--------------------------------------------------------------------- header
	local header = new("Frame", {
		Size = UDim2.new(1, 0, 0, 42),
		BackgroundColor3 = Theme.accent,
		BorderSizePixel = 0,
	}, win)
	corner(header, 12)
	new("Frame", {
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.new(0, 0, 1, -14),
		BackgroundColor3 = Theme.accent,
		BorderSizePixel = 0,
	}, header)

	new("TextLabel", {
		Size = UDim2.new(1, -90, 1, 0),
		Position = UDim2.fromOffset(14, 0),
		BackgroundTransparency = 1,
		Text = "FACE BANG",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 15,
	}, header)

	local stateDot = new("Frame", {
		Size = UDim2.fromOffset(7, 7),
		Position = UDim2.new(1, -74, 0.5, -3),
		BackgroundColor3 = Theme.dim,
		BorderSizePixel = 0,
	}, header)
	corner(stateDot, 4)

	-- on touch there is no RightShift, so the header itself toggles the panel
	local hideBtn = new("TextButton", {
		Size = UDim2.fromOffset(26, 22),
		Position = UDim2.new(1, -34, 0.5, -11),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.82,
		Text = "-",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		BorderSizePixel = 0,
	}, header)
	corner(hideBtn, 6)

	local dragZone = new("TextButton", {
		Size = UDim2.new(1, -70, 0, 42),
		BackgroundTransparency = 1,
		Text = "",
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
	end)

	----------------------------------------------------------------- status row
	local status = new("TextLabel", {
		Size = UDim2.new(1, -24, 0, 16),
		Position = UDim2.fromOffset(12, 46),
		BackgroundTransparency = 1,
		Text = "idle",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.dim,
		Font = Font,
		TextSize = 11,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, win)

	------------------------------------------------------------------- tab bar
	local tabBar = new("Frame", {
		Size = UDim2.new(1, -24, 0, 26),
		Position = UDim2.fromOffset(12, 64),
		BackgroundTransparency = 1,
	}, win)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, tabBar)

	local pages = {}
	local tabButtons = {}
	local activeTab

	local pageHost = new("Frame", {
		Size = UDim2.new(1, -24, 1, -140),
		Position = UDim2.fromOffset(12, 96),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	}, win)

	local function mkTab(name, order)
		local b = new("TextButton", {
			Size = UDim2.new(0.25, -3, 1, 0),
			BackgroundColor3 = Theme.row,
			Text = name,
			TextColor3 = Theme.dim,
			Font = Enum.Font.GothamMedium,
			TextSize = 11,
			AutoButtonColor = false,
			BorderSizePixel = 0,
			LayoutOrder = order,
		}, tabBar)
		corner(b, 6)
		stroke(b)
		tabButtons[name] = b
		return b
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
			Visible = false,
		}, pageHost)
		new("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, p)
		pages[name] = p
		return p
	end

	local function showTab(name)
		activeTab = name
		for n, p in pairs(pages) do p.Visible = (n == name) end
		for n, b in pairs(tabButtons) do
			b.BackgroundColor3 = (n == name) and Theme.accent or Theme.row
			b.TextColor3 = (n == name) and Color3.new(1, 1, 1) or Theme.dim
		end
	end

	for i, name in ipairs({ "Aim", "Self", "Players", "Server" }) do
		local b = mkTab(name, i)
		mkPage(name)
		b.MouseButton1Click:Connect(function() showTab(name) end)
	end

	--------------------------------------------------------------- widgets
	-- one row = label on the left, control on the right; 34px tall so it is a
	-- comfortable touch target at 0.6-1.0 scale
	local function mkRow(page, order)
		local r = new("Frame", {
			Size = UDim2.new(1, 0, 0, 34),
			BackgroundColor3 = Theme.row,
			BorderSizePixel = 0,
			LayoutOrder = order,
		}, page)
		corner(r, 7)
		stroke(r, Color3.fromRGB(42, 42, 52))
		return r
	end

	local function mkLabel(row, text)
		return new("TextLabel", {
			Size = UDim2.new(1, -80, 1, 0),
			Position = UDim2.fromOffset(10, 0),
			BackgroundTransparency = 1,
			Text = text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.text,
			Font = Font,
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, row)
	end

	-- action row: tap to fire
	local function action(page, order, label, fn)
		local row = mkRow(page, order)
		mkLabel(row, label)
		new("TextLabel", {
			Size = UDim2.fromOffset(18, 18),
			Position = UDim2.new(1, -28, 0.5, -9),
			BackgroundTransparency = 1,
			Text = ">",
			TextColor3 = Theme.accent,
			Font = Enum.Font.GothamBold,
			TextSize = 13,
		}, row)
		local btn = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		btn.MouseButton1Click:Connect(function()
			local ok, err = pcall(fn)
			if not ok then out("error: " .. tostring(err)) end
		end)
		row.MouseEnter:Connect(function() tweenObj(row, "BackgroundColor3", Theme.rowHi) end)
		row.MouseLeave:Connect(function() tweenObj(row, "BackgroundColor3", Theme.row) end)
		return row
	end

	-- toggle row: pill that reflects state
	local function toggle(page, order, label, onChange, initial)
		local row = mkRow(page, order)
		mkLabel(row, label)
		local pill = new("Frame", {
			Size = UDim2.fromOffset(34, 18),
			Position = UDim2.new(1, -44, 0.5, -9),
			BackgroundColor3 = initial and Theme.good or Theme.rowHi,
			BorderSizePixel = 0,
		}, row)
		corner(pill, 9)
		local knob = new("Frame", {
			Size = UDim2.fromOffset(14, 14),
			Position = UDim2.fromOffset(initial and 18 or 2, 2),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, pill)
		corner(knob, 7)

		local state = initial and true or false
		local btn = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "" }, row)
		local function paint()
			tweenObj(pill, "BackgroundColor3", state and Theme.good or Theme.rowHi)
			knob.Position = UDim2.fromOffset(state and 18 or 2, 2)
		end
		btn.MouseButton1Click:Connect(function()
			state = not state
			paint()
			local ok, err = pcall(onChange, state)
			if not ok then out("error: " .. tostring(err)) end
		end)
		return { set = function(v) state = v paint() end, get = function() return state end }
	end

	-- stepper row: tap the value to cycle through a list of values
	local function stepper(page, order, label, values, onPick, initialIndex)
		local row = mkRow(page, order)
		mkLabel(row, label)
		local idx = initialIndex or 1
		local chip = new("TextButton", {
			Size = UDim2.fromOffset(56, 20),
			Position = UDim2.new(1, -66, 0.5, -10),
			BackgroundColor3 = Theme.rowHi,
			Text = tostring(values[idx]),
			TextColor3 = Theme.text,
			Font = Font,
			TextSize = 11,
			AutoButtonColor = false,
			BorderSizePixel = 0,
		}, row)
		corner(chip, 5)
		chip.MouseButton1Click:Connect(function()
			idx = idx % #values + 1
			chip.Text = tostring(values[idx])
			local ok, err = pcall(onPick, values[idx])
			if not ok then out("error: " .. tostring(err)) end
		end)
		return chip
	end

	-- forward-declared: assigned while building the Aim tab, read by UI.state
	local bangLabel, loopToggle

	-- destructive rows need a second tap; the armed state expires so a stray
	-- tap never leaves something dangerous primed
	local function actionConfirm(page, order, label, fn)
		local row = mkRow(page, order)
		local text = mkLabel(row, label)
		local arrow = new("TextLabel", {
			Size = UDim2.fromOffset(18, 18),
			Position = UDim2.new(1, -28, 0.5, -9),
			BackgroundTransparency = 1,
			Text = ">",
			TextColor3 = Theme.accent,
			Font = Enum.Font.GothamBold,
			TextSize = 13,
		}, row)
		local armed, token = false, 0
		local btn = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "" }, row)
		btn.MouseButton1Click:Connect(function()
			if not armed then
				armed = true
				token += 1
				local mine = token
				text.Text = "tap again to confirm"
				tweenObj(row, "BackgroundColor3", Theme.bad)
				arrow.TextColor3 = Theme.bad
				task.delay(3, function()
					if armed and token == mine then
						armed = false
						text.Text = label
						tweenObj(row, "BackgroundColor3", Theme.row)
						arrow.TextColor3 = Theme.accent
					end
				end)
				return
			end
			armed = false
			text.Text = label
			tweenObj(row, "BackgroundColor3", Theme.row)
			arrow.TextColor3 = Theme.accent
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
			Size = UDim2.new(1, 0, 0, 38),
			BackgroundColor3 = Theme.accent,
			BorderSizePixel = 0,
			LayoutOrder = o,
		}, aim)
		corner(row, 8)
		local b = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "" }, row)
		bangLabel = new("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "BANG NEAREST",
			TextColor3 = Color3.new(1, 1, 1),
			Font = Enum.Font.GothamBold,
			TextSize = 13,
		}, row)
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

	------------------------------------------------------------------ Self tab
	local selfPage = pages.Self
	local so = 0
	local function sOrder() so += 1 return so end

	local godToggle = toggle(selfPage, sOrder(), "god mode (health pinned)", function(on)
		SelfTools.godMode(on)
		if not on then SelfTools.restoreAll() SelfTools.godMode(false) end
	end, false)

	local noclipToggle = toggle(selfPage, sOrder(), "noclip", function(on) SelfTools.noclip(on) end, false)

	local flyToggle = toggle(selfPage, sOrder(), "fly (wasd / space)", function(on)
		local ok, err = SelfTools.fly(on, ctx.flySpeed or 60)
		if not ok and err then out(err) end
	end, false)

	stepper(selfPage, sOrder(), "fly speed", { 30, 60, 100, 160, 240 }, function(v) ctx.flySpeed = v end, 2)
	stepper(selfPage, sOrder(), "walk speed", { 16, 30, 50, 80, 120, 200 }, function(v) SelfTools.setSpeed(v) end, 1)
	stepper(selfPage, sOrder(), "jump power", { 50, 75, 100, 150, 250 }, function(v) SelfTools.setJump(v) end, 1)

	local voidToggle = toggle(selfPage, sOrder(), "anti void", function(on)
		if on then SelfTools.startAntiVoid(Config.VoidFloor) else SelfTools.stopAntiVoid() end
	end, false)

	stepper(selfPage, sOrder(), "void floor Y", { -40, -80, -150, -300 }, function(v) Config.VoidFloor = v end, 2)

	local invisToggle = toggle(selfPage, sOrder(), "invisible", function(on) SelfTools.invisible(on) end, false)

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
				row.BackgroundColor3 = isSel and Theme.accent or Theme.row
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
					Size = UDim2.new(1, 0, 0, 24),
					BackgroundColor3 = Theme.row,
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
				corner(row, 5)
				new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, row)
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

	action(plPage, 4, "fling selected (self-body)", function()
		local p = pick()
		if not p then return end
		local ok, err = Targets.fling(p, 3, "self")
		if not ok and err then out(err) else out("flinging " .. p.Name) end
	end)

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
	local footer = new("TextLabel", {
		Size = UDim2.new(1, -24, 0, 12),
		Position = UDim2.new(0, 12, 1, -14),
		BackgroundTransparency = 1,
		Text = IsTouch and "tap a row to use it" or string.format("[%s] bang  [%s] loop  [%s] stop  [%s] hide",
			Config.KeyBang.Name, Config.KeyLoop.Name, Config.KeyStop.Name, Config.KeyUI.Name),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(96, 96, 110),
		Font = Font,
		TextSize = 9,
	}, win)

	--------------------------------------------------------------------- api
	UI = {}
	UI.refresh = refreshPlayers

	function UI.status(text) status.Text = text end

	function UI.state(on)
		stateDot.BackgroundColor3 = on and Theme.good or Theme.dim
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

	showTab("Aim")
	refreshPlayers()
	UI.state(false)
	notify("Face Bang", string.format(
		"Loaded - %s | %s", CAP.executor, IsTouch and "touch mode" or "desktop mode"), 5)

end
