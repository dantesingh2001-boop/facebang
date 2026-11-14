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
