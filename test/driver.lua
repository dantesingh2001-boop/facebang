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

print("  render conns =", #GAME_SERVICES.RunService.RenderStepped.fns, " heartbeat conns =", #GAME_SERVICES.RunService.Heartbeat.fns)
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
print("  root pos =", tostring(myRoot.CFrame.Position), " head pos =", tostring(victimHead.CFrame.Position))
print("  CFrame writes =", #CFRAME_WRITES, " last =", #CFRAME_WRITES > 0 and tostring(CFRAME_WRITES[#CFRAME_WRITES].v.Position) or "-")
print("  same table as driver root =", #CFRAME_WRITES > 0 and CFRAME_WRITES[#CFRAME_WRITES].t == myRoot)
Report("root is on the victim's head", d < 1.5, ("dist=%.3f"):format(d))

-- 4. an impulse must be present after a tick
local v = myRoot.AssemblyLinearVelocity
Report("impulse written to root", v ~= nil and v.Magnitude >= 55, v and ("|v|=" .. v.Magnitude) or "nil")

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
