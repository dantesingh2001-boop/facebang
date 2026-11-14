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
