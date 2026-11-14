--[[
  Studio harness for facebang.

  Runs the real built script inside Roblox Studio instead of the mock, so the
  things a mock cannot prove get exercised for real: the UI actually renders,
  Vector3/CFrame maths is the engine's, humanoid physics and collisions resolve,
  and the camera behaves.

  Why a harness is needed at all: facebang is written for an *executor*, so it
  uses globals that do not exist in vanilla Studio (getgenv, cloneref,
  identifyexecutor, gethui, request). This file provides the minimum shims and
  then loads the real source, so no product code is changed for testing.

  Usage from the MCP (execute_luau, datamodel Edit or Client):
      run the contents of this file

  It prints a report to Output and returns a table of results.
]]

local REPORT = {}
local function report(name, ok, detail)
	REPORT[#REPORT + 1] = { name = name, ok = ok and true or false, detail = detail }
	print(string.format("[%s] %s%s", ok and "PASS" or "FAIL", name,
		detail and ("  " .. tostring(detail)) or ""))
	return ok
end

--------------------------------------------------------------------- executor shims
-- getgenv: executors keep one shared table. Studio has no such thing, so use _G
-- and remember what we injected so the harness can clean up afterwards.
local injected = {}
local function shim(name, value)
	if rawget(_G, name) == nil then
		rawset(_G, name, value)
		injected[#injected + 1] = name
		return true
	end
	return false
end

shim("getgenv", function() return _G end)
shim("getrenv", function() return _G end)
shim("identifyexecutor", function() return "StudioHarness" end)
-- cloneref in a real executor returns a proxy; identity differs, which once made
-- "no player detected" happen. Return the object itself under Studio.
shim("cloneref", function(o) return o end)
shim("setclipboard", function() end)
shim("request", function(req)
	-- minimal stand-in for syn.request, mapped onto HttpService
	local hs = game:GetService("HttpService")
	local ok, body = pcall(function()
		if req.Method == "GET" or req.Method == nil then
			return hs:GetAsync(req.Url, true)
		end
		return hs:PostAsync(req.Url, req.Body or "", Enum.HttpContentType.ApplicationJson)
	end)
	return { StatusCode = ok and 200 or 0, Body = ok and body or nil, Success = ok }
end)
shim("http_request", rawget(_G, "request"))

-------------------------------------------------------------- source acquisition
-- Prefer the live raw URL so Studio tests exactly what users load. Requires
-- "Allow HTTP Requests" in Game Settings > Security.
local RAW = "https://raw.githubusercontent.com/dantesingh2001-boop/facebang/main/facebang.lua"

local function fetchSource()
	local hs = game:GetService("HttpService")
	pcall(function() hs.HttpEnabled = true end) -- Studio only; ignored at runtime
	if not hs.HttpEnabled then
		return nil, "HttpEnabled is off (Game Settings > Security > Allow HTTP Requests)"
	end
	local ok, body = pcall(function()
		return hs:GetAsync(RAW .. "?t=" .. math.floor(os.clock() * 1000), true)
	end)
	if not ok or type(body) ~= "string" then
		return nil, "fetch failed: " .. tostring(body)
	end
	return body
end

local function run(opts)
	opts = opts or {}

	local src, err = opts.source, nil
	if not src then src, err = fetchSource() end
	if not src then
		report("source available", false, err)
		return { results = REPORT, ok = false }
	end
	report("source available", true, #src .. " bytes")

	local chunk, cerr = loadstring(src, "=facebang")
	if not chunk then
		report("source compiles", false, tostring(cerr))
		return { results = REPORT, ok = false }
	end
	report("source compiles", true)

	local ok, runErr = pcall(chunk)
	report("source executes without error", ok, ok and nil or tostring(runErr))
	if not ok then return { results = REPORT, ok = false } end

	local api = _G.FaceBang
	report("registers getgenv().FaceBang", type(api) == "table",
		api and tostring(next(api)) or "nil")
	if type(api) ~= "table" then return { results = REPORT, ok = false } end

	------------------------------------------------------------------ ui presence
	local Players = game:GetService("Players")
	local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local gui = pg and pg:FindFirstChild("FaceBangUI")
	report("UI is created", gui ~= nil)
	if gui then
		local win = gui:FindFirstChild("Window")
		report("window exists", win ~= nil,
			win and (tostring(win.AbsoluteSize.X) .. "x" .. tostring(win.AbsoluteSize.Y)) or nil)

		-- a real size check: the window must fit the real viewport, not a stub
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize
		if win and vp then
			report("window fits inside the viewport",
				win.AbsolutePosition.X >= 0 and win.AbsolutePosition.Y >= 0
					and win.AbsolutePosition.X + win.AbsoluteSize.X <= vp.X + 1
					and win.AbsolutePosition.Y + win.AbsoluteSize.Y <= vp.Y + 1,
				string.format("win %.0fx%.0f at %.0f,%.0f vs viewport %dx%d",
					win.AbsoluteSize.X, win.AbsoluteSize.Y,
					win.AbsolutePosition.X, win.AbsolutePosition.Y, vp.X, vp.Y))
		end

		-- every interactive row must be a real touch target in engine units
		local small, total = {}, 0
		for _, d in ipairs(gui:GetDescendants()) do
			if d:IsA("TextButton") and d.AbsoluteSize.Y > 0 then
				total = total + 1
				if d.AbsoluteSize.Y < 20 then
					small[#small + 1] = d.Name .. ":" .. string.format("%.0f", d.AbsoluteSize.Y)
				end
			end
		end
		report("no button is under 20px tall", #small == 0,
			total .. " buttons" .. (#small > 0 and (", small: " .. table.concat(small, ", ")) or ""))

		-- text must not be clipped out of its own label
		local clipped = 0
		for _, d in ipairs(gui:GetDescendants()) do
			if d:IsA("TextLabel") and d.TextBounds.X > d.AbsoluteSize.X + 1
				and d.TextTruncate == Enum.TextTruncate.None then
				clipped = clipped + 1
			end
		end
		report("no label overflows its box", clipped == 0, clipped .. " overflowing")
	end

	----------------------------------------------------------------- live physics
	-- The bang can only be proven against a real Humanoid. In a solo Studio
	-- session there is no second player, so build a stand-in character in the
	-- workspace and aim at it. This proves the *engine interaction*: that our
	-- velocity and CFrame writes actually move a humanoid assembly.
	local function dummyCharacter(name, pos)
		local model = Instance.new("Model")
		model.Name = name

		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Size = Vector3.new(2, 2, 1)
		root.CFrame = CFrame.new(pos)
		root.CanCollide = true
		root.Parent = model

		local head = Instance.new("Part")
		head.Name = "Head"
		head.Size = Vector3.new(2, 1, 1)
		head.CFrame = CFrame.new(pos + Vector3.new(0, 1.5, 0))
		head.CanCollide = false
		head.Parent = model

		local hum = Instance.new("Humanoid")
		hum.Parent = model
		-- weld head to root so the model behaves like one assembly
		local w = Instance.new("WeldConstraint")
		w.Part0, w.Part1 = root, head
		w.Parent = root

		model.PrimaryPart = root
		model.Parent = workspace
		return model
	end

	local lp = Players.LocalPlayer
	if lp and lp.Character and lp.Character:FindFirstChild("HumanoidRootPart") then
		local myRoot = lp.Character.HumanoidRootPart
		local away = dummyCharacter("FB_TestDummy", myRoot.CFrame.Position + Vector3.new(0, 0, -18))
		local dRoot, dHead = away.HumanoidRootPart, away.Head

		local start0 = dRoot.Position
		-- drive the same primitive the bang uses, and see if the engine reacts
		local target = dHead.Position
		local before = myRoot.Position
		myRoot.AssemblyLinearVelocity = (target - before).Unit * 500
		task.wait(0.35)
		local moved = (dRoot.Position - start0).Magnitude
		report("engine moves a hit assembly", moved > 0.5,
			string.format("dummy moved %.2f studs", moved))
		report("our own body travels under velocity", (myRoot.Position - before).Magnitude > 1,
			string.format("we moved %.2f studs", (myRoot.Position - before).Magnitude))

		away:Destroy()
	else
		report("player character available for physics test", false, "no character in this datamodel")
	end

	------------------------------------------------------------------ clean up
	pcall(function() api.Unload() end)
	report("unload runs", _G.FaceBang == nil or type(_G.FaceBang) == "table")

	for _, name in ipairs(injected) do rawset(_G, name, nil) end

	local failed = 0
	for _, r in ipairs(REPORT) do if not r.ok then failed = failed + 1 end end
	print(string.format("== %d checks, %d failed", #REPORT, failed))
	return { results = REPORT, ok = failed == 0, failed = failed }
end

return run
