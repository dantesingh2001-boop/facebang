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
