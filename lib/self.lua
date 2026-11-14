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
