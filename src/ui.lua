	-- ==========================================================================
	-- interface: tabbed panel, adaptive for PC and touch
	-- ==========================================================================
	local Theme = {
		bg = Color3.fromRGB(9, 9, 12),
		panel = Color3.fromRGB(17, 17, 22),
		surface = Color3.fromRGB(22, 22, 29),
		surfaceHi = Color3.fromRGB(31, 31, 40),
		surfacePress = Color3.fromRGB(40, 34, 62),
		hair = Color3.fromRGB(40, 40, 52),
		accent = Color3.fromRGB(139, 92, 246),
		accent2 = Color3.fromRGB(192, 132, 252),
		accentSoft = Color3.fromRGB(58, 44, 96),
		text = Color3.fromRGB(238, 238, 246),
		dim = Color3.fromRGB(136, 136, 152),
		faint = Color3.fromRGB(96, 96, 112),
		good = Color3.fromRGB(52, 211, 153),
		bad = Color3.fromRGB(239, 100, 100),
	}
	local Font = Enum.Font.Gotham

	local BASE_W, BASE_H = 312, 492

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

	-- stopping must not leave a local freeze or weld on the target's body;
	-- this hook is what Engine.stop calls (see the note there)
	Engine.onStop = function()
		pcall(function() Targets.thawAll() end)
		pcall(function() Targets.unweld() end)
		pcall(function() Targets.unfling() end)
	end

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

	local function stroke(obj, color, thick, alpha)
		return new("UIStroke", {
			Color = color or Theme.hair,
			Thickness = thick or 1,
			Transparency = alpha or 0,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, obj)
	end

	-- a 2px bar used as a section marker, so labels read as grouped
	local function bar(parent, color)
		local b = new("Frame", {
			Size = UDim2.fromOffset(2, 9),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
		}, parent)
		corner(b, 1)
		return b
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

	-- two shadow layers: a wide soft one for depth, a tight one for contact
	local shadowFar = new("Frame", {
		Name = "ShadowFar",
		Size = UDim2.fromOffset(BASE_W, BASE_H),
		Position = UDim2.new(0, 30, 0.5, -BASE_H / 2 + 10),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		ZIndex = 0,
	}, gui)
	corner(shadowFar, 20)

	local shadow = new("Frame", {
		Name = "Shadow",
		Size = UDim2.fromOffset(BASE_W, BASE_H),
		Position = UDim2.new(0, 27, 0.5, -BASE_H / 2 + 4),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		ZIndex = 1,
	}, gui)
	corner(shadow, 16)

	local win = new("Frame", {
		Name = "Window",
		Size = UDim2.fromOffset(BASE_W, BASE_H),
		Position = UDim2.new(0, 24, 0.5, -BASE_H / 2),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, gui)
	win.AnchorPoint = Vector2.new(0, 0)
	corner(win, 16)
	stroke(win, Color3.fromRGB(58, 58, 74), 1)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.panel, Theme.bg),
	}, win)

	-- scale + clamp into the safe area, recomputed on resize / rotation
	local uiScale = new("UIScale", { Scale = 1 }, win)
	local function syncShadows()
		shadowFar.Size = win.Size
		shadow.Size = win.Size
		shadowFar.Position = UDim2.fromOffset(win.Position.X.Offset + 3, win.Position.Y.Offset + 10)
		shadow.Position = UDim2.fromOffset(win.Position.X.Offset + 3, win.Position.Y.Offset + 4)
	end
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
		syncShadows()
		return scale
	end
	fitPanel()

	--------------------------------------------------------------------- header
	local HEADER_H = 54
	local header = new("Frame", {
		Size = UDim2.new(1, 0, 0, HEADER_H),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, win)
	corner(header, 16)
	-- square off the bottom corners: header sits flush against the body
	new("Frame", {
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.new(0, 0, 1, -16),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, header)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.panel, Theme.bg),
	}, header)
	-- hairline under the header
	new("Frame", {
		Size = UDim2.new(1, -24, 0, 1),
		Position = UDim2.new(0, 12, 1, -1),
		BackgroundColor3 = Theme.hair,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)

	local brandBar = new("Frame", {
		Size = UDim2.fromOffset(3, 22),
		Position = UDim2.fromOffset(13, 13),
		BackgroundColor3 = Theme.accent,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)
	corner(brandBar, 2)
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.accent2, Theme.accent),
	}, brandBar)

	new("TextLabel", {
		Size = UDim2.new(1, -110, 0, 18),
		Position = UDim2.fromOffset(24, 11),
		BackgroundTransparency = 1,
		Text = "FACE BANG",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.text,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		ZIndex = 4,
	}, header)

	new("TextLabel", {
		Size = UDim2.new(1, -110, 0, 12),
		Position = UDim2.fromOffset(24, 30),
		BackgroundTransparency = 1,
		Text = "v" .. tostring(VERSION or "1.4.0") .. "  ·  "
			.. (CAP and CAP.name and tostring(CAP.name):sub(1, 18) or "universal"),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.faint,
		Font = Font,
		TextSize = 9,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
	}, header)

	local dotRing = new("Frame", {
		Size = UDim2.fromOffset(14, 14),
		Position = UDim2.new(1, -84, 0.5, -7),
		BackgroundColor3 = Theme.accent,
		BackgroundTransparency = 0.86,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)
	corner(dotRing, 7)

	local stateDot = new("Frame", {
		Name = "StateDot",
		Size = UDim2.fromOffset(7, 7),
		Position = UDim2.new(0.5, -3.5, 0.5, -3.5),
		BackgroundColor3 = Theme.dim,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, dotRing)
	corner(stateDot, 4)

	local hideBtn = new("TextButton", {
		Size = UDim2.fromOffset(28, 26),
		Position = UDim2.new(1, -34, 0.5, -13),
		BackgroundColor3 = Theme.surfaceHi,
		Text = "-",
		TextColor3 = Theme.dim,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, header)
	corner(hideBtn, 8)
	stroke(hideBtn, Theme.hair)
	hideBtn.MouseEnter:Connect(function() tweenObj(hideBtn, "TextColor3", Theme.text) end)
	hideBtn.MouseLeave:Connect(function() tweenObj(hideBtn, "TextColor3", Theme.dim) end)

	local dragZone = new("TextButton", {
		Size = UDim2.new(1, -70, 0, HEADER_H),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 3,
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
		syncShadows()
	end)

	----------------------------------------------------------------- status row
	local statusWrap = new("Frame", {
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(12, HEADER_H + 8),
		BackgroundColor3 = Theme.surface,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
	}, win)
	corner(statusWrap, 7)

	local status = new("TextLabel", {
		Size = UDim2.new(1, -20, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		BackgroundTransparency = 1,
		Text = "idle",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.dim,
		Font = Font,
		TextSize = 10,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, statusWrap)

	------------------------------------------------------------------- tab bar
	local tabBar = new("Frame", {
		Size = UDim2.new(1, -24, 0, 30),
		Position = UDim2.fromOffset(12, HEADER_H + 36),
		BackgroundColor3 = Theme.surface,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
	}, win)
	corner(tabBar, 9)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 3),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, tabBar)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, 3),
		PaddingRight = UDim.new(0, 3),
		PaddingTop = UDim.new(0, 3),
		PaddingBottom = UDim.new(0, 3),
	}, tabBar)

	local pages = {}
	local tabButtons = {}
	local activeTab

	local pageHost = new("Frame", {
		Size = UDim2.new(1, -20, 1, -(HEADER_H + 76)),
		Position = UDim2.fromOffset(10, HEADER_H + 74),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	}, win)

	local function mkTab(name, order)
		local b = new("TextButton", {
			Size = UDim2.new(0.25, -3, 1, 0),
			BackgroundColor3 = Theme.surface,
			BackgroundTransparency = 1,
			Text = name,
			TextColor3 = Theme.dim,
			Font = Font,
			TextSize = 11,
			AutoButtonColor = false,
			BorderSizePixel = 0,
			LayoutOrder = order,
		}, tabBar)
		corner(b, 7)
		local st = stroke(b, Theme.hair, 1, 1)
		tabButtons[name] = b
		b.MouseEnter:Connect(function()
			if activeTab ~= name then tweenObj(b, "TextColor3", Theme.text) end
		end)
		b.MouseLeave:Connect(function()
			if activeTab ~= name then tweenObj(b, "TextColor3", Theme.dim) end
		end)
		return b, st
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
			ScrollBarImageTransparency = 0.35,
			Visible = false,
		}, pageHost)
		new("UIListLayout", {
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, p)
		new("UIPadding", {
			PaddingLeft = UDim.new(0, 2),
			PaddingRight = UDim.new(0, 6),
			PaddingBottom = UDim.new(0, 10),
		}, p)
		pages[name] = p
		return p
	end

	local function showTab(name)
		activeTab = name
		for n, p in pairs(pages) do
			p.Visible = (n == name)
			if n == name then
				-- slide the new page up into place instead of it appearing
				p.Position = UDim2.fromOffset(0, 6)
				TweenService:Create(p, TweenInfo.new(0.16, Enum.EasingStyle.Quint),
					{ Position = UDim2.fromOffset(0, 0) }):Play()
			end
		end
		for n, b in pairs(tabButtons) do
			local on = (n == name)
			b.BackgroundColor3 = Theme.accent
			b.Font = on and Enum.Font.GothamBold or Font
			TweenService:Create(b, TweenInfo.new(0.16, Enum.EasingStyle.Quint), {
				BackgroundTransparency = on and 0 or 1,
				TextColor3 = on and Theme.text or Theme.dim,
			}):Play()
			local st = b:FindFirstChildOfClass("UIStroke")
			if st then
				TweenService:Create(st, TweenInfo.new(0.16), { Transparency = on and 1 or 0.5 }):Play()
			end
		end
	end

	for i, name in ipairs({ "Aim", "Self", "Players", "Server" }) do
		local b = mkTab(name, i)
		mkPage(name)
		b.MouseButton1Click:Connect(function() showTab(name) end)
	end

	--------------------------------------------------------------- widgets
	local ROW_H = 40

	-- one row = label on the left, control on the right. 40px tall so it stays a
	-- comfortable touch target at the 0.6 scale floor.
	local function mkRow(page, order)
		local r = new("Frame", {
			Size = UDim2.new(1, 0, 0, ROW_H),
			BackgroundColor3 = Theme.surface,
			BorderSizePixel = 0,
			LayoutOrder = order,
		}, page)
		corner(r, 10)
		stroke(r, Theme.hair, 1, 0.55)
		return r
	end

	-- one-shot press ripple. Kept in a table and aged by the animation loop
	-- instead of task.delay, so it cannot outlive the UI if the panel is torn down.
	local ripples = {}
	local function ripple(row)
		local r = new("Frame", {
			Size = UDim2.fromOffset(14, 14),
			Position = UDim2.new(0.5, -7, 0.5, -7),
			BackgroundColor3 = Theme.accent,
			BackgroundTransparency = 0.55,
			BorderSizePixel = 0,
			ZIndex = row.ZIndex + 1,
		}, row)
		corner(r, 7)
		ripples[#ripples + 1] = { frame = r, t = os.clock() }
	end

	local function mkLabel(row, text)
		return new("TextLabel", {
			Size = UDim2.new(1, -86, 1, 0),
			Position = UDim2.fromOffset(12, 0),
			BackgroundTransparency = 1,
			Text = text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.text,
			Font = Font,
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, row)
	end

	-- hover + press feedback shared by every interactive row
	local function rowFeedback(row)
		row.MouseEnter:Connect(function() tweenObj(row, "BackgroundColor3", Theme.surfaceHi) end)
		row.MouseLeave:Connect(function() tweenObj(row, "BackgroundColor3", Theme.surface) end)
	end

	-- a chevron drawn from two bars: ">" glyphs sit too high on some fonts
	local function chevron(row, color)
		local c = new("Frame", {
			Size = UDim2.fromOffset(7, 7),
			Position = UDim2.new(1, -22, 0.5, -3),
			BackgroundTransparency = 1,
		}, row)
		for _, rot in ipairs({ 45, -45 }) do
			local b = new("Frame", {
				Size = UDim2.fromOffset(1.5, 7),
				Position = UDim2.new(0.5, -0.75, 0.5, -3.5),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Rotation = rot - 45,
				BackgroundColor3 = color or Theme.faint,
				BorderSizePixel = 0,
			}, c)
			b.Position = UDim2.new(0.5, -0.75, 0.5, -3.5)
		end
		return c
	end

	-- small caption that groups rows, so the tabs read as sections not a list
	local function section(page, order, text)
		local holder = new("Frame", {
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
			LayoutOrder = order,
		}, page)
		bar(holder, Theme.accent).Position = UDim2.fromOffset(4, 7)
		new("TextLabel", {
			Size = UDim2.new(1, -18, 1, 0),
			Position = UDim2.fromOffset(12, 0),
			BackgroundTransparency = 1,
			Text = string.upper(text),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.faint,
			Font = Enum.Font.GothamBold,
			TextSize = 9,
		}, holder)
		return holder
	end

	-- action row: tap to fire
	local function action(page, order, label, fn)
		local row = mkRow(page, order)
		mkLabel(row, label)
		chevron(row, Theme.faint)
		local btn = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		rowFeedback(row)
		btn.MouseButton1Down:Connect(function()
			row.BackgroundColor3 = Theme.surfacePress
			ripple(row)
		end)
		btn.MouseButton1Up:Connect(function() row.BackgroundColor3 = Theme.surfaceHi end)
		btn.MouseButton1Click:Connect(function()
			local ok, err = pcall(fn)
			if not ok then out("error: " .. tostring(err)) end
		end)
		return row
	end

	-- toggle row: pill with a knob that slides and colours in
	local function toggle(page, order, label, onChange, initial)
		local row = mkRow(page, order)
		mkLabel(row, label)
		local pill = new("Frame", {
			Size = UDim2.fromOffset(40, 22),
			Position = UDim2.new(1, -52, 0.5, -11),
			BackgroundColor3 = initial and Theme.good or Theme.surfaceHi,
			BorderSizePixel = 0,
		}, row)
		corner(pill, 11)
		stroke(pill, Theme.hair, 1, initial and 1 or 0.6)
		local knob = new("Frame", {
			Size = UDim2.fromOffset(16, 16),
			Position = UDim2.fromOffset(initial and 21 or 3, 3),
			BackgroundColor3 = initial and Color3.new(1, 1, 1) or Theme.dim,
			BorderSizePixel = 0,
		}, pill)
		corner(knob, 8)

		local state = initial and true or false
		local btn = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		rowFeedback(row)
		local function paint(animate)
			local t = animate == false and 0.001 or 0.14
			tweenObj(pill, "BackgroundColor3", state and Theme.good or Theme.surfaceHi, t)
			tweenObj(knob, "BackgroundColor3", state and Color3.new(1, 1, 1) or Theme.dim, t)
			local goal = UDim2.fromOffset(state and 21 or 3, 3)
			if animate == false then
				knob.Position = goal
			else
				TweenService:Create(knob, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = goal }):Play()
			end
		end
		btn.MouseButton1Click:Connect(function()
			state = not state
			paint(true)
			local ok, err = pcall(onChange, state)
			if not ok then out("error: " .. tostring(err)) end
		end)
		return { set = function(v) state = v paint(false) end, get = function() return state end }
	end

	-- stepper row: tap the value chip to cycle through a list of values
	local function stepper(page, order, label, values, onPick, initialIndex)
		local row = mkRow(page, order)
		mkLabel(row, label)
		local idx = initialIndex or 1
		local chip = new("TextButton", {
			Size = UDim2.fromOffset(64, 24),
			Position = UDim2.new(1, -76, 0.5, -12),
			BackgroundColor3 = Theme.surfaceHi,
			Text = tostring(values[idx]),
			TextColor3 = Theme.text,
			Font = Enum.Font.GothamMedium,
			TextSize = 11,
			AutoButtonColor = false,
			BorderSizePixel = 0,
		}, row)
		corner(chip, 7)
		stroke(chip, Theme.hair, 1, 0.7)
		chip.MouseEnter:Connect(function() tweenObj(chip, "BackgroundColor3", Theme.accentSoft) end)
		chip.MouseLeave:Connect(function() tweenObj(chip, "BackgroundColor3", Theme.surfaceHi) end)
		chip.MouseButton1Click:Connect(function()
			idx = idx % #values + 1
			chip.Text = tostring(values[idx])
			local ok, err = pcall(onPick, values[idx])
			if not ok then out("error: " .. tostring(err)) end
		end)
		return chip
	end

	-- forward-declared: assigned while building the Aim tab, read by UI.state
	local bangLabel, loopToggle, bangGlow

	-- destructive rows need a second tap; the armed state expires so a stray
	-- tap never leaves something dangerous primed
	local function actionConfirm(page, order, label, fn)
		local row = mkRow(page, order)
		local text = mkLabel(row, label)
		local ch = chevron(row, Theme.faint)
		local armed, token = false, 0
		local btn = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		rowFeedback(row)
		local function disarm()
			armed = false
			text.Text = label
			text.TextColor3 = Theme.text
			tweenObj(row, "BackgroundColor3", Theme.surface)
			for _, b in ipairs(ch:GetChildren()) do
				if b:IsA("Frame") then tweenObj(b, "BackgroundColor3", Theme.faint) end
			end
		end
		btn.MouseButton1Click:Connect(function()
			if not armed then
				armed = true
				token += 1
				local mine = token
				text.Text = "tap again to confirm"
				text.TextColor3 = Theme.bad
				row.BackgroundColor3 = Theme.surfacePress
				for _, b in ipairs(ch:GetChildren()) do
					if b:IsA("Frame") then b.BackgroundColor3 = Theme.bad end
				end
				task.delay(3, function()
					if armed and token == mine then disarm() end
				end)
				return
			end
			disarm()
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
			Size = UDim2.new(1, 0, 0, 48),
			BackgroundColor3 = Theme.accent,
			BorderSizePixel = 0,
			LayoutOrder = o,
		}, aim)
		corner(row, 12)
		new("UIGradient", {
			Rotation = 20,
			Color = ColorSequence.new(Theme.accent, Theme.accent2),
		}, row)
		local priStroke = stroke(row, Theme.accent2, 1, 0.35)

		local glow = new("Frame", {
			Size = UDim2.new(1, -8, 0, 10),
			Position = UDim2.new(0, 4, 1, -4),
			BackgroundColor3 = Theme.accent,
			BackgroundTransparency = 0.72,
			BorderSizePixel = 0,
		}, row)
		corner(glow, 5)
		bangGlow = glow

		local b = new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
		}, row)
		bangLabel = new("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "BANG NEAREST",
			TextColor3 = Color3.new(1, 1, 1),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
		}, row)

		local scale = new("UIScale", { Scale = 1 }, row)
		b.MouseEnter:Connect(function()
			tweenObj(row, "BackgroundColor3", Color3.fromRGB(163, 122, 255))
		end)
		b.MouseLeave:Connect(function()
			tweenObj(row, "BackgroundColor3", Theme.accent)
			TweenService:Create(scale, TweenInfo.new(0.1), { Scale = 1 }):Play()
		end)
		b.MouseButton1Down:Connect(function()
			ripple(row)
			TweenService:Create(scale, TweenInfo.new(0.08), { Scale = 0.97 }):Play()
		end)
		b.MouseButton1Up:Connect(function()
			TweenService:Create(scale, TweenInfo.new(0.1), { Scale = 1 }):Play()
		end)
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

	stepper(aim, 9, "fling power", { 1400, 2000, 2400, 3200, 4000 }, function(v) Config.FlingPower = v end, 3)

	------------------------------------------------------------------ Self tab
	local selfPage = pages.Self
	local so = 0
	local function sOrder() so += 1 return so end

	local ghostToggle = toggle(selfPage, sOrder(), "GHOST - invisible + invincible", function(on)
		local ok, err = SelfTools.ghost(on)
		if not ok and err then out(err) end
		if ok then out(on and "ghost on" or "ghost off") end
	end, false)

	action(selfPage, sOrder(), "fix my character (reset physics)", function()
		Targets.thawAll()
		Targets.unfling()
		Targets.unweld()
		SelfTools.resetPhysics()
		out("character reset")
	end)

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

	toggle(selfPage, sOrder(), "infinite jump", function(on) SelfTools.infiniteJump(on) end, false)

	section(selfPage, sOrder(), "teleport")

	action(selfPage, sOrder(), "teleport to cursor", function()
		local ok, res = SelfTools.teleportToCursor(3)
		out(ok and "teleported" or tostring(res))
	end)

	action(selfPage, sOrder(), "save position", function()
		local ok, err = SelfTools.savePosition()
		out(ok and "position saved" or tostring(err))
	end)

	action(selfPage, sOrder(), "load position", function()
		local ok, err = SelfTools.loadPosition()
		out(ok and "loaded" or tostring(err))
	end)

	local voidToggle = toggle(selfPage, sOrder(), "anti void", function(on)
		if on then SelfTools.startAntiVoid(Config.VoidFloor) else SelfTools.stopAntiVoid() end
	end, false)

	stepper(selfPage, sOrder(), "void floor Y", { -40, -80, -150, -300 }, function(v) Config.VoidFloor = v end, 2)

	local invisToggle = toggle(selfPage, sOrder(), "invisible (your view only)", function(on) SelfTools.invisible(on) end, false)

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
				row.BackgroundColor3 = isSel and Theme.accent or Theme.surface
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
					Size = UDim2.new(1, 0, 0, 28),
					BackgroundColor3 = Theme.surface,
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
				corner(row, 8)
				stroke(row, Theme.hair, 1, 0.55)
				new("UIPadding", { PaddingLeft = UDim.new(0, 10) }, row)
				row.MouseEnter:Connect(function()
					if not (selected == plr) then
						tweenObj(row, "BackgroundColor3", Theme.surfaceHi)
					end
				end)
				row.MouseLeave:Connect(function()
					if not (selected == plr) then
						tweenObj(row, "BackgroundColor3", Theme.surface)
					end
				end)
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

	action(svPage, svOrder(), "perf: fps / ping / parts", function()
		local p = SelfTools.perf()
		out(string.format("%d fps · %d ms · %d parts", p.fps, p.ping, p.parts))
	end)

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
	new("Frame", {
		Size = UDim2.new(1, -24, 0, 1),
		Position = UDim2.new(0, 12, 1, -20),
		BackgroundColor3 = Theme.hair,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
	}, win)

	local footer = new("TextLabel", {
		Size = UDim2.new(1, -24, 0, 12),
		Position = UDim2.new(0, 12, 1, -16),
		BackgroundTransparency = 1,
		Text = IsTouch and "tap a row to use it" or string.format("[%s] bang   [%s] loop   [%s] stop   [%s] hide",
			Config.KeyBang.Name, Config.KeyLoop.Name, Config.KeyStop.Name, Config.KeyUI.Name),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.faint,
		Font = Font,
		TextSize = 9,
	}, win)

	--------------------------------------------------------------- animation
	-- One RenderStepped loop drives every ambient animation. It never yields and
	-- does no allocation per frame: no closures in the body, no task.wait.
	local sheen = new("Frame", {
		Name = "FB_Sheen",
		Size = UDim2.new(0, 74, 0, 2),
		Position = UDim2.new(-0.3, 0, 0, HEADER_H - 2),
		BackgroundColor3 = Theme.accent,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, win)
	new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, sheen)

	-- open animation: the panel eases up from slightly small, so it lands rather
	-- than simply appearing
	local openScale = new("UIScale", { Name = "FB_OpenScale", Scale = 0.94 }, win)
	TweenService:Create(openScale, TweenInfo.new(0.24, Enum.EasingStyle.Quint),
		{ Scale = 1 }):Play()

	local t0 = os.clock()
	conns[#conns + 1] = RunService.RenderStepped:Connect(function()
		local now = os.clock() - t0

		-- header sheen sweeping left to right, then a pause before it repeats
		local cycle = (now % 4.2) / 1.1
		if cycle <= 1 then
			sheen.Position = UDim2.new(-0.3 + cycle * 1.6, 0, 0, HEADER_H - 2)
			sheen.BackgroundTransparency = 0.35
		else
			sheen.BackgroundTransparency = 1
		end

		-- breathing halo behind the status dot
		if dotRing then
			dotRing.BackgroundTransparency = 0.86 - 0.12 * (0.5 + 0.5 * math.sin(now * 3.4))
		end

		-- the main button's glow pulses while it is the thing you are about to hit
		if bangGlow then
			bangGlow.BackgroundTransparency = 0.66 - 0.14 * (0.5 + 0.5 * math.sin(now * 2.6))
		end

		-- age out press ripples
		for i = #ripples, 1, -1 do
			local rec = ripples[i]
			local age = os.clock() - rec.t
			if age > 0.42 or not rec.frame.Parent then
				if rec.frame.Parent then pcall(function() rec.frame:Destroy() end) end
				table.remove(ripples, i)
			else
				local grow = 14 + age * 300
				rec.frame.Size = UDim2.fromOffset(grow, grow)
				rec.frame.Position = UDim2.new(0.5, -grow / 2, 0.5, -grow / 2)
				rec.frame.BackgroundTransparency = 0.55 + age * 1.1
			end
		end
	end)

	--------------------------------------------------------------------- api
	UI = {}
	UI.refresh = refreshPlayers

	function UI.status(text) status.Text = text end

	function UI.state(on)
		stateDot.BackgroundColor3 = on and Theme.good or Theme.dim
		dotRing.BackgroundColor3 = on and Theme.good or Theme.dim
		dotRing.BackgroundTransparency = on and 0.78 or 0.88
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

	SelfTools.startPerf()
	showTab("Aim")
	refreshPlayers()
	UI.state(false)
	notify("Face Bang", string.format(
		"Loaded - %s | %s", CAP.executor, IsTouch and "touch mode" or "desktop mode"), 5)
