-- Fly, invisibility, infinite jump, teleport and the perf readout.
local API = GAME_ENV.FaceBang
local RS = GAME_SERVICES.RunService.RenderStepped
local S = API.Self
local myRootF = lp.Character:FindFirstChild("HumanoidRootPart")
local myHumF = lp.Character:FindFirstChildOfClass("Humanoid")

local fails = 0
local function R(name, ok, detail)
	if not ok then fails = fails + 1 end
	print(string.format("[%s] %-52s %s", ok and "PASS" or "FAIL", name, detail or ""))
end

-- fly -----------------------------------------------------------------------
S.fly(false)
myRootF.AssemblyLinearVelocity = V3.new(0, 0, 0)
Report = R
R("fly starts", S.fly(true, 60) == true)
myHumF.MoveDirection = V3.new(1, 0, 0)
RS:Fire(1/60)
local v1 = myRootF.AssemblyLinearVelocity
RS:Fire(1/60)
local v2 = myRootF.AssemblyLinearVelocity
R("fly accelerates you", v2.Magnitude > 10, string.format("|v|=%.0f", v2.Magnitude))
R("fly eases in instead of snapping", v2.Magnitude > v1.Magnitude and v1.Magnitude < 60,
	string.format("%.0f -> %.0f", v1.Magnitude, v2.Magnitude))
R("fly cancels gravity", math.abs(v2.Y) < 5 or v2.Y > 0, string.format("y=%.0f", v2.Y))
myHumF.MoveDirection = V3.new(0, 0, 0)
S.fly(false)
R("fly off stops the loop", API.Self.perf ~= nil and myRootF.AssemblyLinearVelocity.Magnitude < 200)

-- invisibility --------------------------------------------------------------
local head = lp.Character:FindFirstChild("Head")
head.Transparency = 0.4   -- deliberately semi-transparent, must come back
R("invisible on", S.invisible(true) == true)
R("body becomes fully transparent", head.Transparency == 1,
	string.format("t=%.1f", head.Transparency))
local hat = newInst("Part")
hat.Name = "Handle"
hat.Transparency = 0
hat.Parent = lp.Character
R("hat equipped while invisible is hidden too", hat.Transparency == 1,
	string.format("t=%.1f", hat.Transparency))
S.invisible(false)
R("restores the exact original transparency", math.abs(head.Transparency - 0.4) < 0.01,
	string.format("t=%.1f", head.Transparency))
R("restores a hat that was visible", hat.Transparency == 0,
	string.format("t=%.1f", hat.Transparency))

-- infinite jump -------------------------------------------------------------
myHumF._state = Enum.HumanoidStateType.Freefall
S.infiniteJump(true)
RS:Fire(1/60)
R("infinite jump re-enters jump while falling",
	myHumF._state == Enum.HumanoidStateType.Jumping, tostring(myHumF._state))
S.infiniteJump(false)
myHumF._state = Enum.HumanoidStateType.Freefall
RS:Fire(1/60)
R("infinite jump off leaves you falling",
	myHumF._state == Enum.HumanoidStateType.Freefall, tostring(myHumF._state))

-- teleport / saved position -------------------------------------------------
myRootF.CFrame = CFrame.new(V3.new(0, 0, 0))
local okTp = S.teleportToCursor(3)
R("teleport to cursor moves you", okTp == true and myRootF.CFrame.Position.Magnitude > 5,
	string.format("|p|=%.0f", myRootF.CFrame.Position.Magnitude))
R("save position", S.savePosition() == true)
myRootF.CFrame = CFrame.new(V3.new(50, 50, 50))
R("load position returns you", S.loadPosition() == true
	and myRootF.CFrame.Position.Magnitude < 30,
	string.format("|p|=%.0f", myRootF.CFrame.Position.Magnitude))

-- perf ----------------------------------------------------------------------
local probePart = newInst("Part")
probePart.Parent = GAME_SERVICES.Workspace
local p = S.perf()
R("perf reports a ping", p.ping == 42, string.format("ping=%d", p.ping))
R("perf counts parts", p.parts > 0, string.format("parts=%d", p.parts))
R("perf reports a frame rate after sampling", type(p.fps) == "number")

print(string.format("== features: %d failed", fails))
