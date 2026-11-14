--[[
================================================================================
  FACE BANG   v1.0.0      universal / zero-delay
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
	local function alive(plr)
		if not plr or plr == LP or plr.Parent ~= Players then return false end
		local char = plr.Character
		if not char or not char.Parent then return false end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return false end
		local head = char:FindFirstChild("Head")
		local hrp = char:FindFirstChild("HumanoidRootPart")
		return head ~= nil and hrp ~= nil
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
			Engine.head = char:FindFirstChild("Head")
			if not Engine.head then return end
		end

		local head = Engine.head
		local jitter = (Engine.tick % 2 == 0) and Config.Offset or -Config.Offset
		local from = hrp.CFrame.Position
		local dest = head.CFrame * CFrame.new(jitter, Config.Height, 0)

		-- the teleport is what causes the overlap; the impulse carries momentum into it
		hrp.CFrame = dest

		local dx = dest.Position - from
		local speed = math.clamp(dx.Magnitude * Config.Power, Config.MinSpeed, Config.MinSpeed * 5)
		local dir = dx.Magnitude > 1e-4 and dx.Unit or Vector3.new(jitter, Config.Height, 0).Unit
		setVel(hrp, dir * speed)

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
			notify("Face Bang", "No valid player")
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
		if not Engine.head then
			notify("Face Bang", "Target has no Head")
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

	-- ==========================================================================
	-- interface
	-- ==========================================================================
	local Theme = {
		bg = Color3.fromRGB(14, 14, 17),
		panel = Color3.fromRGB(20, 20, 24),
		row = Color3.fromRGB(26, 26, 31),
		accent = Color3.fromRGB(120, 90, 255),
		text = Color3.fromRGB(232, 232, 238),
		dim = Color3.fromRGB(138, 138, 150),
		good = Color3.fromRGB(80, 210, 140),
	}
	local Font = Enum.Font.Gotham

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
		local s = new("UIStroke", {
			Color = color or Color3.fromRGB(46, 46, 56),
			Thickness = thick or 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, obj)
		return s
	end

	-- stateful tween helper: interrupted tweens always resume from the live value
	local tweens = {}
	local pool = {}
	local conns = {}
	local function tweenObj(obj, prop, goal, time)
		local key = obj
		tweens[key] = (tweens[key] or 0) + 1
		local myKey = tweens[key]
		local t = TweenService:Create(obj, TweenInfo.new(time or 0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { [prop] = goal })
		t:Play()
		t.Completed:Connect(function()
			if tweens[key] == myKey then tweens[key] = nil end
		end)
	end

	local function mkButton(parent, text, size, pos, color)
		local b = new("TextButton", {
			Size = size,
			Position = pos,
			BackgroundColor3 = color or Theme.row,
			Text = text,
			TextColor3 = Theme.text,
			Font = Font,
			TextSize = 13,
			AutoButtonColor = false,
			BorderSizePixel = 0,
		}, parent)
		corner(b, 7)
		stroke(b)
		-- hover feedback is mouse-only; on touch nothing fires, which is correct
		b.MouseEnter:Connect(function() tweenObj(b, "BackgroundColor3", Theme.accent, 0.12) end)
		b.MouseLeave:Connect(function() tweenObj(b, "BackgroundColor3", color or Theme.row, 0.12) end)
		return b
	end

	------------------------------------------------------------------- building
	local gui = new("ScreenGui", {
		Name = "FaceBangUI",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 200,
	})

	local parent = (function()
		if CAP.gethui then
			local ok, h = pcall(ENV.gethui)
			if ok and h then return h end
		end
		return LP:FindFirstChildOfClass("PlayerGui") or LP:WaitForChild("PlayerGui")
	end)()
	gui.Parent = parent

	local win = new("Frame", {
		Name = "Window",
		Size = UDim2.fromOffset(272, 432),
		Position = UDim2.new(0, 24, 0.5, -216),
		BackgroundColor3 = Theme.bg,
		BorderSizePixel = 0,
	}, gui)
	win.AnchorPoint = Vector2.new(0, 0)

	-- fit the panel inside the safe area: touch phones have less room and the
	-- top of the screen can sit under the notch, so scale down and clamp
	local BASE_W, BASE_H = 272, 432
	local function fitPanel()
		local vp = viewport()
		local pad = 16
		local scale = math.clamp(math.min((vp.X - pad * 2) / BASE_W, (vp.Y - pad * 2) / BASE_H), 0.62, 1)
		win.Size = UDim2.fromOffset(BASE_W, BASE_H)

		local uiScale = win:FindFirstChildOfClass("UIScale")
		if not uiScale then
			uiScale = Instance.new("UIScale")
			uiScale.Parent = win
		end
		-- UIScale shrinks the contents, so the frame's own size must be divided
		uiScale.Scale = scale
		win.Size = UDim2.fromOffset(BASE_W * scale, BASE_H * scale)

		local cur = win.Position
		local maxX = math.max(pad, vp.X - win.Size.X.Offset - pad)
		local maxY = math.max(pad, vp.Y - win.Size.Y.Offset - pad)
		win.Position = UDim2.fromOffset(
			math.clamp(cur.X.Offset, pad, maxX),
			math.clamp(cur.Y.Offset, pad, maxY))
		return scale
	end

	corner(win, 12)
	stroke(win, Color3.fromRGB(52, 52, 64))
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.panel, Theme.bg),
	}, win)

	local header = new("Frame", {
		Size = UDim2.new(1, 0, 0, 44),
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
		Size = UDim2.new(1, -18, 1, 0),
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
		Position = UDim2.new(1, -66, 0.5, -3),
		BackgroundColor3 = Theme.dim,
		BorderSizePixel = 0,
	}, header)
	corner(stateDot, 4)

	local overlay = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundTransparency = 1,
		Text = "",
	}, win)
	local dragStart, dragOrigin, dragging = nil, nil, false
	overlay.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			dragOrigin = win.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInput.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch) and dragStart then
			local d = input.Position - dragStart
			win.Position = UDim2.new(dragOrigin.X.Scale, dragOrigin.X.Offset + d.X, dragOrigin.Y.Scale, dragOrigin.Y.Offset + d.Y)
		end
	end)

	----------------------------------------------------------------- status row
	local status = new("TextLabel", {
		Size = UDim2.new(1, -24, 0, 18),
		Position = UDim2.fromOffset(12, 50),
		BackgroundTransparency = 1,
		Text = "idle",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.dim,
		Font = Font,
		TextSize = 12,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, win)

	----------------------------------------------------------------- main buttons
	local bangBtn = mkButton(win, "BANG", UDim2.new(1, -24, 0, 34), UDim2.fromOffset(12, 72), Theme.accent)
	bangBtn.Font = Enum.Font.GothamBold
	bangBtn.TextSize = 14

	local loopBtn = mkButton(win, "LOOP", UDim2.fromOffset(120, 30), UDim2.fromOffset(12, 112))
	local stopBtn = mkButton(win, "STOP", UDim2.fromOffset(120, 30), UDim2.new(1, -132, 0, 112))

	----------------------------------------------------------------- player list
	new("TextLabel", {
		Size = UDim2.new(1, -24, 0, 16),
		Position = UDim2.fromOffset(12, 152),
		BackgroundTransparency = 1,
		Text = "TARGET",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.dim,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
	}, win)

	local list = new("ScrollingFrame", {
		Size = UDim2.new(1, -24, 1, -262),
		Position = UDim2.fromOffset(12, 170),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Theme.accent,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ClipsDescendants = true,
	}, win)
	corner(list, 8)

	local empty = new("TextLabel", {
		Size = UDim2.new(1, -16, 0, 32),
		Position = UDim2.fromOffset(8, 8),
		BackgroundTransparency = 1,
		Text = "no other players",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.dim,
		Font = Font,
		TextSize = 12,
	}, list)

	local layout = new("UIListLayout", {
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, list)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
	}, list)

	----------------------------------------------------------------- settings
	local settings = new("Frame", {
		Size = UDim2.new(1, -24, 0, 66),
		Position = UDim2.new(0, 12, 1, -78),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
	}, win)
	corner(settings, 8)

	local function mkSetting(y, label, prop, min, max, suffix)
		local row = new("Frame", {
			Size = UDim2.new(1, -16, 0, 18),
			Position = UDim2.fromOffset(8, y),
			BackgroundTransparency = 1,
		}, settings)
		new("TextLabel", {
			Size = UDim2.new(1, -70, 1, 0),
			BackgroundTransparency = 1,
			Text = label,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.dim,
			Font = Font,
			TextSize = 11,
		}, row)
		local value = new("TextLabel", {
			Size = UDim2.fromOffset(64, 18),
			Position = UDim2.new(1, -64, 0, 0),
			BackgroundColor3 = Theme.row,
			Text = tostring(math.floor(Config[prop] * 10 + 0.5) / 10) .. (suffix or ""),
			TextColor3 = Theme.text,
			Font = Font,
			TextSize = 11,
			BorderSizePixel = 0,
		}, row)
		corner(value, 5)
		value.InputBegan:Connect(function(input)
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
			local step = (max - min) / 10
			Config[prop] = Config[prop] + step
			if Config[prop] > max + step * 0.5 then Config[prop] = min end
			value.Text = tostring(math.floor(Config[prop] * 10 + 0.5) / 10) .. (suffix or "")
		end)
	end
	mkSetting(12, "power", "Power", 2, 42)
	mkSetting(39, "vertical offset", "Height", 0, 1.2)

	----------------------------------------------------------------- footer
	local footer = new("TextLabel", {
		Size = UDim2.new(1, -24, 0, 12),
		Position = UDim2.new(0, 12, 1, -12),
		BackgroundTransparency = 1,
		Text = string.format("[%s] bang  [%s] loop  [%s] stop  [%s] hide",
			Config.KeyBang.Name, Config.KeyLoop.Name, Config.KeyStop.Name, Config.KeyUI.Name),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(96, 96, 108),
		Font = Font,
		TextSize = 10,
	}, win)

	----------------------------------------------------------------- ui api
	UI = {}

	function UI.status(text)
		status.Text = text
	end

	function UI.state(on)
		stateDot.BackgroundColor3 = on and Theme.good or Theme.dim
		bangBtn.Text = on and "BANGING" or "BANG"
		loopBtn.Text = Engine.loop and "LOOP ON" or "LOOP"
	end

	function UI.markList()
		for _, row in ipairs(pool) do
			if row.Parent then
				local isTarget = Engine.target ~= nil and row.Name == Engine.target.Name
				row.BackgroundColor3 = isTarget and Theme.accent or Theme.row
				row.TextColor3 = isTarget and Color3.new(1, 1, 1) or Theme.text
			end
		end
	end

	function UI.refresh()
		for _, row in ipairs(pool) do row:Destroy() end
		table.clear(pool)
		local count = 0
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= LP then
				count += 1
				local row = mkButton(list, plr.Name, UDim2.new(1, 0, 0, 26), UDim2.new(), Theme.row)
				row.Name = plr.Name
				row.TextXAlignment = Enum.TextXAlignment.Left
				row.TextSize = 12
				new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, row)
				row.LayoutOrder = plr.UserId
				row.MouseButton1Click:Connect(function()
					Engine.target = plr
					UI.markList()
					out("target " .. plr.Name)
				end)
				pool[#pool + 1] = row
			end
		end
		empty.Visible = count == 0
		UI.markList()
	end

	----------------------------------------------------------------- wiring
	bangBtn.MouseButton1Click:Connect(function() Engine.toggle() end)
	stopBtn.MouseButton1Click:Connect(function() Engine.stop() end)
	loopBtn.MouseButton1Click:Connect(function()
		Engine.loop = not Engine.loop
		if Engine.loop and not Engine.running then Engine.start() end
		UI.state(Engine.running)
	end)

	local keyBinds = {
		[Config.KeyBang] = function() Engine.toggle() end,
		[Config.KeyLoop] = function()
			Engine.loop = not Engine.loop
			if Engine.loop and not Engine.running then Engine.start() end
			UI.state(Engine.running)
		end,
		[Config.KeyStop] = function() Engine.stop() end,
		[Config.KeyUI] = function()
			win.Visible = not win.Visible
		end,
	}
	conns[#conns + 1] = UserInput.InputBegan:Connect(function(input, processed)
		if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		local fn = keyBinds[input.KeyCode]
		if fn then fn() end
	end)

	conns[#conns + 1] = Players.PlayerAdded:Connect(function(plr)
		plr.CharacterAdded:Connect(function() task.delay(0.5, UI.refresh) end)
		UI.refresh()
	end)
	conns[#conns + 1] = Players.PlayerRemoving:Connect(function(plr)
		if Engine.target == plr then
			Engine.target = nil
			if not Config.AutoRetarget then Engine.stop() end
		end
		task.defer(UI.refresh)
	end)
	conns[#conns + 1] = LP.CharacterAdded:Connect(function()
		Engine.running = false
		Engine.root, Engine.head = nil, nil
		UI.state(false)
		task.spawn(function()
			task.wait(1)
			if Engine.loop then Engine.start() end
		end)
	end)

	task.spawn(function()
		while gui.Parent do
			task.wait(0.4)
			if Engine.running and not alive(Engine.target) then
				if Engine.loop and Config.AutoRetarget then
					local nxt = nearest()
					if nxt then Engine.start(nxt) end
				elseif not Config.AutoRetarget then
					Engine.stop()
				end
			end
			if Engine.running and not myRoot() then Engine.stop() end
		end
	end)

	----------------------------------------------------------------- unload
	local function unload()
		Engine.running = false
		pcall(restore)
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		if gui then gui:Destroy() end
		if ENV.FaceBang then ENV.FaceBang = nil end
		notify("Face Bang", "Unloaded")
	end

	ENV.FaceBang = {
		Engine = Engine,
		Config = Config,
		UI = UI,
		Capabilities = CAP,
		Unload = unload,
		Bang = function(plr) return Engine.toggle(plr) end,
		Stop = function() Engine.stop() end,
	}

	UI.refresh()
	UI.state(false)
	notify("Face Bang", string.format(
		"Loaded - %s | [%s] bang  [%s] stop  [%s] hide",
		CAP.executor, Config.KeyBang.Name, Config.KeyStop.Name, Config.KeyUI.Name), 5)
end
