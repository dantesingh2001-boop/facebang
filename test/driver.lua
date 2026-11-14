-- smoke test driver: runs after mock.lua + facebang.lua are concatenated
local API = GAME_ENV.FaceBang
Report("script registered getgenv().FaceBang", type(API) == "table")
if not API then
	for _, e in ipairs(ERRORS) do print("  err: " .. e) end
	return
end

local lp = GAME_SERVICES.Players.LocalPlayer
local victim = PlayerList[2]
local myRoot = lp.Character:FindFirstChild("HumanoidRootPart")
local victimHead = victim.Character:FindFirstChild("Head")
local victimRoot = victim.Character:FindFirstChild("HumanoidRootPart")
local startPos = myRoot.CFrame.Position

-- 1. start the bang
local ok = API.Bang(victim)
Report("Bang() starts", ok == true)
Report("running flag", API.Engine.running == true)

do
	local P = GAME_SERVICES.Players
	print("  target.Parent is Players =", victim.Parent == P, " char =", victim.Character ~= nil)
	local ch = victim.Character
	print("  char.Parent =", ch.Parent ~= nil, " hum =", ch:FindFirstChildOfClass("Humanoid") ~= nil, " head =", ch:FindFirstChild("Head") ~= nil, " hrp =", ch:FindFirstChild("HumanoidRootPart") ~= nil)
	print("  engine target =", tostring(API.Engine.target and API.Engine.target.Name), " head =", tostring(API.Engine.head ~= nil))
end
local okp, ep = pcall(function() GAME_SERVICES.RunService.RenderStepped.fns[1](1/60) end)
print("  direct call err =", okp and "none" or tostring(ep), " tick =", API.Engine.tick)
-- 2. drive the two render/heartbeat connections like the engine would
local ticks = 0
for _ = 1, 12 do
	GAME_SERVICES.RunService.RenderStepped:Fire(1 / 60)
	GAME_SERVICES.RunService.Heartbeat:Fire(1 / 60)
	ticks += 2
end
Report("hot path ran without errors", #ERRORS == 0, #ERRORS > 0 and ("first: " .. tostring(ERRORS[1])) or "")

-- 3. we must now be inside the victim's head, not at spawn
local d = (myRoot.CFrame.Position - victimHead.CFrame.Position).Magnitude
Report("fling mode does not park inside the target", d > 3, ("dist=%.3f"):format(d))

-- 4. an impulse must be present after a tick
local v = myRoot.AssemblyLinearVelocity
Report("impulse is a real closing speed", v ~= nil and v.Magnitude >= 800, v and ("|v|=" .. v.Magnitude) or "nil")

-- 5. hit detection sees the victim root
myRoot._touching = { victimRoot }
Report("hitScan detects victim", API.Engine.hitScan() == true)

-- 6. stop restores position, state and collisions
API.Stop()
Report("stop clears running/loop", API.Engine.running == false and API.Engine.loop == false)
local back = (myRoot.CFrame.Position - startPos).Magnitude
Report("position restored", back < 0.01, ("drift=%.4f"):format(back))
Report("collisions restored", myRoot.CanCollide == true)
local hum = lp.Character:FindFirstChildOfClass("Humanoid")
Report("platform stand cleared", hum.PlatformStand == false)

-- 7. no-target path must not throw
local only = true
victim.Character = nil
local ok2 = API.Bang(victim)
Report("Bang() on dead/missing char is refused", ok2 == false)
Report("no errors overall", #ERRORS == 0)
for i, e in ipairs(ERRORS) do
	if i <= 3 then print("  err: " .. e) end
end

-- 8. unload destroys the gui and clears the global
local gui = lp:FindFirstChildOfClass("PlayerGui"):FindFirstChild("FaceBangUI")
Report("gui parented", gui ~= nil, gui and gui.Name or "")
API.Unload()
Report("unload clears global", GAME_ENV.FaceBang == nil)
Report("unload destroys gui", gui.Parent == nil)

-- 9. seat games: a seated+w welded target must be released before the bang
local seatVictim = newInst("Player") seatVictim.Name = "seated" seatVictim.UserId = 3
seatVictim.Parent = GAME_SERVICES.Players
seatVictim.CharacterAdded = signal()
local sc = mkChar(seatVictim, V3.new(30, 5, 0))
local sHum = sc:FindFirstChildOfClass("Humanoid")
local sRoot = sc:FindFirstChild("HumanoidRootPart")
sHum.Sit = true
local chairWeld = newInst("Weld") chairWeld.Name = "SeatWeld" chairWeld.Part0 = sRoot
chairWeld.Parent = sc
table.insert(PlayerList, seatVictim)
local okSeat = API.Bang(seatVictim)
Report("bang works on a seated target", okSeat == true)
Report("seat weld broken locally", chairWeld.Parent == nil)
Report("released flag set", API.Engine.released == true)
API.Stop()

-- 10. anchored targets are refused rather than silently doing nothing
sRoot.Anchored = true
local okAnchor = API.Bang(seatVictim)
Report("anchored target refused", okAnchor == false)
sRoot.Anchored = false

-- 11. self tools
local Self = API.Self
local Targets = API.Targets
Report("Self module exposed", type(Self) == "table")
Report("Targets module exposed", type(Targets) == "table")

local myHum = lp.Character:FindFirstChildOfClass("Humanoid")
Self.setSpeed(80)
Report("walk speed set", myHum.WalkSpeed == 80, "ws=" .. tostring(myHum.WalkSpeed))
Self.setJump(150)
Report("jump power set", myHum.JumpPower == 150)

Self.noclip(true)
GAME_SERVICES.RunService.Stepped:Fire(1/60)
local colliding = 0
for _, d in ipairs(lp.Character:GetDescendants()) do
	if d:IsA("BasePart") and d.CanCollide then colliding += 1 end
end
Report("noclip disables collisions", colliding == 0, "colliding=" .. colliding)
Self.unnoclip()

Self.startAntiVoid(-80)
myRoot.CFrame = CFrame.new(V3.new(0, -200, 0))
GAME_SERVICES.RunService.Heartbeat:Fire(1/60)
Report("anti void re-surfaces the character", myRoot.CFrame.Position.Y > -80,
	"y=" .. myRoot.CFrame.Position.Y)
Self.stopAntiVoid()

Self.godMode(true)
myHum.Health = 1
GAME_SERVICES.RunService.Heartbeat:Fire(1/60)
Report("god mode restores health", myHum.Health == myHum.MaxHealth, "hp=" .. tostring(myHum.Health))
Self.godMode(false)

Self.freezeLocal(true)
Report("local freeze anchors", myRoot.Anchored == true)
Self.freezeLocal(false)
Report("local freeze releases", myRoot.Anchored == false)

-- 12. target actions
victim.Character = mkChar(victim, V3.new(20, 0, 0))
local vRoot = victim.Character:FindFirstChild("HumanoidRootPart")
local okT = Targets.teleportTo(victim)
Report("teleport to target", okT == true and (myRoot.CFrame.Position - vRoot.CFrame.Position).Magnitude < 5,
	("d=%.2f"):format((myRoot.CFrame.Position - vRoot.CFrame.Position).Magnitude))

Targets.freeze(victim)
GAME_SERVICES.RunService.RenderStepped:Fire(1/60)
Report("freeze target captured", Targets.isFrozen(victim) == true)
Targets.thaw(victim)
Report("thaw clears freeze", Targets.isFrozen(victim) == false)

Report("cleanup runs", pcall(Targets.cleanup) == true)
Report("restoreAll runs", pcall(Self.restoreAll) == true)

-- 13. freeze-all in view
myRoot.CFrame = CFrame.new(V3.new(0, 0, 0))
victim.Character = mkChar(victim, V3.new(10, 0, 0))
Targets.thaw()
local okAll, nAll = Targets.freezeAll(80, 12)
Report("freezeAll succeeds", okAll == true)
Report("freezeAll froze nearby player", (nAll or 0) >= 1, "n=" .. tostring(nAll))
Report("frozenCount matches", Targets.frozenCount() >= 1, "count=" .. Targets.frozenCount())

-- far away players must not be picked up
victim.Character = mkChar(victim, V3.new(5000, 0, 0))
Targets.thaw()
local okFar, nFar = Targets.freezeAll(80, 12)
Report("freezeAll respects radius", (nFar or 0) == 0, "n=" .. tostring(nFar))

-- 14. engine loop flag and UI stay in sync after stop
API.Engine.loop = true
API.Stop()
Report("stop clears loop flag", API.Engine.loop == false)
Report("UI.state resyncs after stop", pcall(API.UI.state, false) == true)

-- 15. fling must drive OUR owned body, never the victim's (that never works)
victim.Character = mkChar(victim, V3.new(6, 0, 0))
local vRoot2 = victim.Character:FindFirstChild("HumanoidRootPart")
myRoot.CFrame = CFrame.new(V3.new(0, 0, 0))
myRoot.AssemblyLinearVelocity = Vector3.zero
Targets.fling(victim, 3, "self")
GAME_SERVICES.RunService.RenderStepped:Fire(1/60)
Report("fling drives our own body", myRoot.AssemblyLinearVelocity.Magnitude > 300,
	"|v|=" .. tostring(myRoot.AssemblyLinearVelocity.Magnitude))
Report("fling leaves victim velocity alone", vRoot2.AssemblyLinearVelocity == nil
	or vRoot2.AssemblyLinearVelocity.Magnitude == 0)
Targets.unfling()

-- force mode is opt-in and does touch the victim
Targets.fling(victim, 3, "force")
GAME_SERVICES.RunService.RenderStepped:Fire(1/60)
Report("force mode writes victim velocity", vRoot2.AssemblyLinearVelocity ~= nil
	and vRoot2.AssemblyLinearVelocity.Magnitude > 100)
Targets.unfling()

-- 16. god mode survives a direct health drop (server-authoritative games aside)
Self.godMode(true)
myHum.Health = 1
myHum.HealthChanged:Fire(1)
Report("god mode re-pins on HealthChanged", myHum.Health == myHum.MaxHealth,
	"hp=" .. tostring(myHum.Health) .. " max=" .. tostring(myHum.MaxHealth))
Report("god health is finite", myHum.MaxHealth < math.huge and myHum.MaxHealth >= 1e6,
	"max=" .. tostring(myHum.MaxHealth))
Self.godMode(false)
Report("god mode off stops pinning", Self.isGod() == false)

-- 17. bang style: velocity mode must not teleport
local Cfg = API.Config
Cfg.BangStyle = "velocity"
myRoot.CFrame = CFrame.new(V3.new(0, 0, 0))
API.Engine.tick = 0
API.Bang(victim)
local before = myRoot.CFrame.Position
GAME_SERVICES.RunService.RenderStepped:Fire(1/60)
Report("velocity style does not teleport",
	(myRoot.CFrame.Position - before).Magnitude < 0.01,
	("moved=%.3f"):format((myRoot.CFrame.Position - before).Magnitude))
Report("velocity style still applies speed", myRoot.AssemblyLinearVelocity.Magnitude > 300,
	"|v|=" .. tostring(myRoot.AssemblyLinearVelocity.Magnitude))
API.Stop()
Cfg.BangStyle = "hybrid"

-- 18. weld fling: weld exists while active, torn down after, mass restored
victim.Character = mkChar(victim, V3.new(5, 0, 0))
local vRoot3 = victim.Character:FindFirstChild("HumanoidRootPart")
Targets.flingWeld(victim, 2.5)
local weld = nil
for _, c in ipairs(myRoot:GetChildren()) do
	if c.ClassName == "WeldConstraint" then weld = c end
end
Report("weld fling creates a weld", weld ~= nil)
Report("weld connects our root to theirs", weld ~= nil and weld.Part0 == myRoot and weld.Part1 == vRoot3)
Report("target parts made massless", vRoot3.Massless == true)
GAME_SERVICES.RunService.RenderStepped:Fire(1/60)
Report("weld fling launches the assembly", myRoot.AssemblyLinearVelocity.Magnitude > 300,
	"|v|=" .. tostring(myRoot.AssemblyLinearVelocity.Magnitude))
Targets.unweld()
Report("unweld removes the weld", weld.Parent == nil)
Report("unweld restores mass", vRoot3.Massless == false)

-- 19. ghost / invincible
local okG = Self.ghost(true)
local head = lp.Character:FindFirstChild("Head")
Report("ghost turns on", okG == true and Self.isGhost() == true)
Report("ghost disables touch damage", head.CanTouch == false)
Report("ghost makes invisible", head.Transparency == 1)
local ff = lp.Character:FindFirstChild("FB_God")
Report("ghost adds a hidden forcefield", ff ~= nil and ff.Visible == false)
Report("ghost also pins health", lp.Character:FindFirstChildOfClass("Humanoid").MaxHealth >= 1e6)
Self.ghost(false)
Report("ghost off restores touch", head.CanTouch == true and head.Transparency == 0)
Report("ghost off removes forcefield", lp.Character:FindFirstChild("FB_God") == nil)

-- 20. lock mode is the opposite: deliberately holds them still
local Cfg2 = API.Config
API.Engine.running = false
Cfg2.BangMode = "lock"
victim.Character = mkChar(victim, V3.new(8, 0, 0))
myRoot.CFrame = CFrame.new(V3.new(0, 0, 0))
API.Bang(victim)
for _ = 1, 6 do GAME_SERVICES.RunService.RenderStepped:Fire(1/60) end
local dLock = (myRoot.CFrame.Position - victim.Character:FindFirstChild("Head").CFrame.Position).Magnitude
Report("lock mode parks inside the target", dLock < 1.5, ("dist=%.3f"):format(dLock))
API.Stop()
Cfg2.BangMode = "fling"

-- 21. god speed survives a game resetting WalkSpeed
Self.godSpeed(true, 1000)
Report("god speed sets walkspeed", myHum.WalkSpeed == 1000, "ws=" .. tostring(myHum.WalkSpeed))
myHum.WalkSpeed = 16
GAME_SERVICES.RunService.Heartbeat:Fire(1/60)
Report("god speed re-pins after a reset", myHum.WalkSpeed == 1000, "ws=" .. tostring(myHum.WalkSpeed))
Self.godSpeed(false)
Report("god speed off", Self.isGodSpeed() == false)
