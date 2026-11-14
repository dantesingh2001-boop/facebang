-- minimal Roblox mock, only what facebang touches; used for the smoke test
local ERR = {}
local function rec(e) ERR[#ERR + 1] = tostring(e) end

-- datatypes ---------------------------------------------------------------
local V3 = {}
V3.__add = function(a, b) return V3.new(a.x + b.x, a.y + b.y, a.z + b.z) end
V3.__sub = function(a, b) return V3.new(a.x - b.x, a.y - b.y, a.z - b.z) end
V3.__mul = function(a, b)
	if type(a) == "number" then return V3.new(a * b.x, a * b.y, a * b.z) end
	if type(b) == "number" then return V3.new(a.x * b, a.y * b, a.z * b) end
	return V3.new(a.x * b.x, a.y * b.y, a.z * b.z)
end
V3.__tostring = function(v) return ("(%.3f, %.3f, %.3f)"):format(v.x, v.y, v.z) end
-- Magnitude and Unit are properties in the Roblox API, not methods
V3.__index = function(t, k)
	local raw = rawget(t, "_v")[k]
	if raw ~= nil then return raw end
	if k == "Magnitude" then
		local x, y, z = t.x, t.y, t.z
		return math.sqrt(x * x + y * y + z * z)
	elseif k == "Unit" then
		local m = t.Magnitude
		if m == 0 then return V3.new(0, 0, 0) end
		return V3.new(t.x / m, t.y / m, t.z / m)
	elseif k == "Dot" then
		return function(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
	elseif k == "Cross" then
		return function(a, b)
			return V3.new(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
		end
	end
	return nil
end
function V3.new(x, y, z)
	return setmetatable({ _v = { x = x or 0, y = y or 0, z = z or 0 } }, {
		__index = function(t, k)
			local r = rawget(t, "_v")[k]
			if r ~= nil then return r end
			-- Roblox exposes X/Y/Z as well as x/y/z
			if k == "X" then return rawget(t, "_v").x end
			if k == "Y" then return rawget(t, "_v").y end
			if k == "Z" then return rawget(t, "_v").z end
			if k == "Magnitude" then
				local v = rawget(t, "_v")
				return math.sqrt(v.x ^ 2 + v.y ^ 2 + v.z ^ 2)
			elseif k == "Unit" then
				local v = rawget(t, "_v")
				local m = math.sqrt(v.x ^ 2 + v.y ^ 2 + v.z ^ 2)
				if m == 0 then return V3.new(0, 0, 0) end
				return V3.new(v.x / m, v.y / m, v.z / m)
			elseif k == "Dot" then
				return function(a, b)
					local av, bv = rawget(a, "_v"), rawget(b, "_v")
					return av.x * bv.x + av.y * bv.y + av.z * bv.z
				end
			elseif k == "Lerp" then
				return function(a, b, t)
					local av, bv = rawget(a, "_v"), rawget(b, "_v")
					return V3.new(av.x + (bv.x - av.x) * t, av.y + (bv.y - av.y) * t,
						av.z + (bv.z - av.z) * t)
				end
			elseif k == "Cross" then
				return function(a, b)
					local av, bv = rawget(a, "_v"), rawget(b, "_v")
					return V3.new(av.y * bv.z - av.z * bv.y,
						av.z * bv.x - av.x * bv.z, av.x * bv.y - av.y * bv.x)
				end
			end
			return nil
		end,
		__add = function(a, b) local av, bv = rawget(a, "_v"), rawget(b, "_v") return V3.new(av.x + bv.x, av.y + bv.y, av.z + bv.z) end,
		__sub = function(a, b) local av, bv = rawget(a, "_v"), rawget(b, "_v") return V3.new(av.x - bv.x, av.y - bv.y, av.z - bv.z) end,
		__mul = function(a, b)
			if type(a) == "number" then local bv = rawget(b, "_v") return V3.new(a * bv.x, a * bv.y, a * bv.z) end
			if type(b) == "number" then local av = rawget(a, "_v") return V3.new(av.x * b, av.y * b, av.z * b) end
			local av, bv = rawget(a, "_v"), rawget(b, "_v")
			return V3.new(av.x * bv.x, av.y * bv.y, av.z * bv.z)
		end,
		__tostring = function(t)
			local v = rawget(t, "_v")
			return ("(%.3f, %.3f, %.3f)"):format(v.x, v.y, v.z)
		end,
	})
end
Vector3 = V3
Vector3.zero = V3.new(0, 0, 0)
Vector3.new = V3.new

CFrame = {}
CFrame.__index = CFrame
function CFrame.new(x, y, z)
	local pos = (type(x) == "table") and x or V3.new(x or 0, y or 0, z or 0)
	return setmetatable({
		Position = pos,
		LookVector = V3.new(0, 0, -1),
		RightVector = V3.new(1, 0, 0),
		UpVector = V3.new(0, 1, 0),
	}, CFrame)
end
CFrame.__mul = function(a, b)
	-- offsets only in this mock: compose positions
	return CFrame.new(a.Position + (b.Position or V3.new(0, 0, 0)))
end
CFrame.__sub = function(a, b)
	if typeof(b) ~= "Vector3" and not (type(b) == "table" and rawget(b, "_v")) then
		error("CFrame - " .. tostring(b))
	end
	local bx = rawget(b, "_v") or b
	return CFrame.new(a.Position - V3.new(bx.x, bx.y, bx.z))
end

function CFrame:__tostring() return "CFrame" .. tostring(self.Position) end

Vector2 = {
	new = function(x, y) return { X = x or 0, Y = y or 0 } end,
}
Color3 = { fromRGB = function(r, g, b) return { R = r, G = g, B = b } end }
Color3.new = function(r, g, b) return { R = r, G = g, B = b } end
ColorSequence = { new = function(...) return { ... } end }
UDim = { new = function(s, o) return { Scale = s, Offset = o } end }
UDim2 = {
	new = function(a, b, c, d) return { X = UDim.new(a, b), Y = UDim.new(c, d) } end,
	fromOffset = function(x, y) return { X = UDim.new(0, x), Y = UDim.new(0, y) } end,
	fromScale = function(x, y) return { X = UDim.new(x, 0), Y = UDim.new(y, 0) } end,
}
TweenInfo = { new = function(...) return { ... } end }
NumberSequenceKeypoint = { new = function(t, v) return { Time = t, Value = v } end }
NumberSequence = { new = function(a, b)
	if type(a) == "table" then return { Keypoints = a } end
	return { Keypoints = { a, b } }
end }

Enum = setmetatable({}, {
	__index = function(t, ns)
		local out = setmetatable({}, { __index = function(_, name) return { Name = name, Value = 0 } end })
		t[ns] = out
		return out
	end,
})

Enum.HumanoidStateType = {
	Freefall = { Name = "Freefall" },
	Jumping = { Name = "Jumping" },
	Running = { Name = "Running" },
	Landed = { Name = "Landed" },
}

-- instances ---------------------------------------------------------------
local function signal()
	local s = { fns = {}, connected = 0 }
	function s:Connect(fn)
		self.connected += 1
		local entry = { fn = fn }
		self.fns[#self.fns + 1] = entry
		-- a real Disconnect stops the callback; a no-op here would hide every
		-- cleanup bug in the script (and did: leftover loops kept running)
		return {
			Disconnect = function()
				for i, e in ipairs(self.fns) do
					if e == entry then table.remove(self.fns, i) break end
				end
				entry.fn = nil
			end,
		}
	end
	function s:Fire(...)
		local snapshot = {}
		for _, e in ipairs(self.fns) do snapshot[#snapshot + 1] = e end
		for _, e in ipairs(snapshot) do
			if e.fn then
				local ok, err = pcall(e.fn, ...)
				if not ok then rec(err) end
			end
		end
	end
	return s
end

local Inst = {}
Inst.__index = function(t, k)
	local v = rawget(t, "_p")[k]
	if v ~= nil then return v end
	local m = Inst[k]
	if m then return m end
	-- Roblox lets you index a child by name
	if k == "Children" or k == "Parent" then return nil end
	if k == "Position" then
		local cf = rawget(t, "_p").CFrame
		if cf then return cf.Position end
		return nil
	end
	local c = Inst.FindFirstChild(t, k)
	if c then return c end
	return nil
end
CFRAME_WRITES = {}
Inst.__newindex = function(t, k, v)
	if k == "CFrame" then CFRAME_WRITES[#CFRAME_WRITES + 1] = { t = t, v = v } end
	rawget(t, "_p")[k] = v
	if k == "Parent" and v then
		v.Children = v.Children or {}
		local found = false
		for _, c in ipairs(v.Children) do if c == t then found = true break end end
		if not found then table.insert(v.Children, t) end
		-- the real engine fires these on every reparent; the invisibility code
		-- relies on DescendantAdded to hide accessories added later
		if v.ChildAdded then pcall(function() v.ChildAdded:Fire(t) end) end
		local node = v
		while node do
			if node.DescendantAdded then pcall(function() node.DescendantAdded:Fire(t) end) end
			node = rawget(node, "_p")
		end
	end
end

local CLASS_EVENTS = {
	Touched = true,
	InputBegan = true,
	InputChanged = true,
	MouseEnter = true,
	MouseLeave = true,
	MouseButton1Click = true,
	MouseButton1Down = true,
	MouseButton1Up = true,
	DescendantAdded = true,
	ChildAdded = true,
}


local function newInst(class, parent)
	local p = {}
	for k in pairs(CLASS_EVENTS) do p[k] = signal() end
	local o = setmetatable({ _p = p, ClassName = class }, Inst)
	if parent then parent.Children = parent.Children or {} table.insert(parent.Children, o) p.Parent = parent end
	return o
end

function Inst:IsA(c)
	return self.ClassName == c
		or (c == "BasePart" and (self.ClassName == "Part" or self.ClassName == "MeshPart"))
		or (c == "TextButton" and self.ClassName == "TextButton")
		or (c == "Humanoid" and self.ClassName == "Humanoid")
end
function Inst:FindFirstChild(name)
	for _, c in ipairs(self.Children or {}) do
		if c.Name == name then return c end
	end
	return nil
end
function Inst:FindFirstChildOfClass(class)
	if self.ClassName == class then return self end
	for _, c in ipairs(self.Children or {}) do
		if c.ClassName == class then return c end
	end
	return nil
end
function Inst:GetChildren() return self.Children or {} end
function Inst:GetDescendants()
	local o = {}
	local function walk(p)
		for _, c in ipairs(p.Children or {}) do o[#o + 1] = c walk(c) end
	end
	walk(self)
	return o
end
function Inst:GetTouchingParts() return self._touching or {} end
function Inst:GetNetworkOwner() return nil end
function Inst:SetNetworkOwner() end
function Inst:Destroy()
	local p = self.Parent
	if p and p.Children then
		for i, c in ipairs(p.Children) do
			if c == self then table.remove(p.Children, i) break end
		end
	end
	self.Parent = nil
end
function Inst:WaitForChild(n) return self:FindFirstChild(n) end
function Inst:GetService(n) return GAME_SERVICES[n] end

Instance = { new = function(class, parent) return newInst(class, parent) end }

-- game/services -----------------------------------------------------------
local svc = {}
local function mkService(name) svc[name] = newInst(name) return svc[name] end
local Players = mkService("Players")
local RunService = mkService("RunService")
local UserInput = mkService("UserInputService")
local Tween = mkService("TweenService")
-- tween: apply the goal immediately so tests observe the settled state
Tween.Create = function(_, obj, _info, goal)
	local t = { Played = false }
	function t:Play()
		self.Played = true
		for k, v in pairs(goal) do pcall(function() obj[k] = v end) end
	end
	t.Completed = { Connect = function() end }
	return t
end
local SGui = mkService("StarterGui")
local WS = mkService("Workspace")
workspace = WS
Workspace = WS -- engine globals the script relies on
GAME_SERVICES = svc
game = { GetService = function(_, n) return GAME_SERVICES[n] end, FindService = function(_, n) return GAME_SERVICES[n] end }
Players.PlayerAdded = signal()
Players.PlayerRemoving = signal()
RunService.RenderStepped = signal()
RunService.PreSimulation = signal()
RunService.Stepped = signal()
RunService.Heartbeat = signal()
UserInput.InputBegan = signal()
UserInput.InputChanged = signal()
SGui.SetCore = function() end
WS.GetPartsInPart = function(_, part) return part._touching or {} end
function Inst:GetPropertyChangedSignal() return signal() end
WS.CurrentCamera = { CameraSubject = nil, ViewportSize = V3.new(1280, 720, 0),
	CFrame = CFrame.new(V3.new(0, 0, 0)),
	GetPropertyChangedSignal = function() return signal() end }

local lp = newInst("Player") lp.Name = "me" lp.UserId = 1 lp.CharacterAdded = signal()
Players.LocalPlayer = lp
local pgui = newInst("PlayerGui") pgui.Parent = lp lp.Children = { pgui }
Enum.HumanoidStateType = {
	Freefall = { name = "Freefall" },
	Jumping = { name = "Jumping" },
	Running = { name = "Running" },
	Landed = { name = "Landed" },
}

local MOUSE = { Hit = CFrame.new(V3.new(10, 5, 10)) }
lp.GetMouse = function() return MOUSE end

local STATS_VALUE = { GetValue = function() return 42 end }
local STATS = mkService("Stats")
STATS.Network = { ServerStatsItem = setmetatable({}, {
	__index = function() return STATS_VALUE end,
}) }

local function mkChar(plr, pos)
	local model = newInst("Model") model.Name = plr.Name model.Parent = plr
	local head = newInst("Part", model) head.Name = "Head" head.CFrame = CFrame.new(pos)
	head.Transparency = 0 head.CanTouch = true head.Massless = false
	local hrp = newInst("Part", model) hrp.Name = "HumanoidRootPart" hrp.CFrame = CFrame.new(pos) hrp.CanCollide = true
	hrp.Transparency = 0 hrp.CanTouch = true hrp.Massless = false
	model.DescendantAdded = signal()
	local hum = newInst("Humanoid", model)
	hum.Health = 100
	hum.MaxHealth = 100
	hum.PlatformStand = false
	hum.HealthChanged = signal()
	hum.MoveDirection = V3.new(0, 0, 0)
	hum._state = nil
	hum.GetState = function(self) return self._state end
	hum.ChangeState = function(self, st) self._state = st end
	model.Children = { head, hrp, hum }
	plr.Character = model
	return model
end

local target = newInst("Player") target.Name = "victim" target.UserId = 2 target.Parent = Players target.CharacterAdded = signal()
mkChar(target, V3.new(10, 0, 0))
mkChar(lp, V3.new(0, 0, 0))
PlayerList = { lp, target }
function Players:GetPlayers() return { lp, target } end

-- Faithful cloneref: delegates like the instance but is NOT == to it, which is
-- what real executors do. This is what broke "no player detected".
cloneref = function(obj)
	if type(obj) ~= "table" then return obj end
	return setmetatable({}, { __index = function(_, k) return obj[k] end })
end

getgenv = function() return GAME_ENV end
GAME_ENV = {}
identifyexecutor = function() return "MockExecutor" end

-- task scheduler mock: jobs run from a queue, task.wait() suspends a job
-- (it is never resumed here, which is exactly what a real while-loop yield does)
local STOP = { stop = true }
local queue = {}
local function runJob(fn)
	local ok, e = pcall(fn)
	if not ok and e ~= STOP then rec(e) end
end
task = {
	spawn = function(fn, ...)
		local args = { ... }
		queue[#queue + 1] = { fn = fn, args = args }
		runJob(function() fn(table.unpack(args)) end)
	end,
	defer = function(fn, ...)
		queue[#queue + 1] = { fn = fn, args = { ... } }
	end,
	delay = function(_, fn, ...)
		queue[#queue + 1] = { fn = fn, args = { ... } }
	end,
	wait = function() error(STOP, 0) end,
}
-- luau has no table.unpack for arbitrary lengths? it does: table.unpack
wait = function() error(STOP, 0) end
function Drain()
	for _ = 1, 8 do
		if #queue == 0 then return end
		local job = table.remove(queue, 1)
		runJob(function() job.fn(table.unpack(job.args)) end)
	end
end

ERRORS = ERR
function Report(label, ok, extra)
	print(("%-34s %s %s"):format(label, ok and "PASS" or "FAIL", extra or ""))
end
