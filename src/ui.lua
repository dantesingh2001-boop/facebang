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

	local shadow = new("Frame", {
		Name = "Shadow",
		Size = UDim2.fromOffset(BASE_W, BASE_H),
		Position = UDim2.new(0, 30, 0.5, -BASE_H / 2 + 6),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		ZIndex = 0,
	}, gui)
	corner(shadow, 14)

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
		shadow.Size = win.Size
		local cur = win.Position
		win.Position = UDim2.fromOffset(
			math.clamp(cur.X.Offset, pad, math.max(pad, vp.X - win.Size.X.Offset - pad)),
			math.clamp(cur.Y.Offset, pad, math.max(pad, vp.Y - win.Size.Y.Offset - pad)))
		shadow.Position = UDim2.fromOffset(win.Position.X.Offset + 6, win.Position.Y.Offset + 6)
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
		shadow.Position = UDim2.fromOffset(win.Position.X.Offset + 6, win.Position.Y.Offset + 6)
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
		new("UIPadding", { PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8) }, p)
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

	-- small caption that groups rows, so the tabs read as sections not a list
	local function section(page, order, text)
		local l = new("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Text = string.upper(text),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.dim,
			Font = Enum.Font.GothamBold,
			TextSize = 9,
			LayoutOrder = order,
		}, page)
		return l
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

	stepper(aim, 8, "bang mode", { "fling", "lock" }, function(v)
		Config.BangMode = v
		out(v == "fling" and "bang mode: fling (launches)" or "bang mode: lock (holds them still)")
	end, 1)

	stepper(aim, 9, "fling power", { 800, 1600, 2500, 4000 }, function(v) Config.FlingPower = v end, 2)

	------------------------------------------------------------------ Self tab
	local selfPage = pages.Self
	local so = 0
	local function sOrder() so += 1 return so end

	local ghostToggle = toggle(selfPage, sOrder(), "GHOST - invisible + invincible", function(on)
		local ok, err = SelfTools.ghost(on)
		if not ok and err then out(err) end
		if ok then out(on and "ghost on" or "ghost off") end
	end, false)

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
