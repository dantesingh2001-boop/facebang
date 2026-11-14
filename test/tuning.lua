-- Bang tuning, measured in Studio, pinned here so a refactor cannot quietly
-- drop back to a speed that sits in a tunnelling dead zone.
local API = GAME_ENV.FaceBang
local RenderStepped = GAME_SERVICES.RunService.RenderStepped
local myRootT = lp.Character:FindFirstChild("HumanoidRootPart")

local fails = 0
local function R(name, ok, detail)
	if not ok then fails = fails + 1 end
	print(string.format("[%s] %-46s %s", ok and "PASS" or "FAIL", name, detail or ""))
end

local v = newInst("Player")
v.Name = "tuneTarget"
v.UserId = 91
v.Parent = GAME_SERVICES.Players
v.CharacterAdded = signal()
mkChar(v, V3.new(0, 0, -30))
myRootT.CFrame = CFrame.new(V3.new(0, 0, 0))

R("target has a character", v.Character ~= nil)
R("target has a head", v.Character ~= nil and v.Character:FindFirstChild("Head") ~= nil)
R("bang starts against a fresh target", API.Bang(v) == true)

local mags = {}
for _ = 1, 6 do
	RenderStepped:Fire(1/60)
	mags[#mags + 1] = math.floor(API.Engine.root.AssemblyLinearVelocity.Magnitude)
end

local lo, hi = math.huge, -math.huge
for _, m in ipairs(mags) do
	if m < lo then lo = m end
	if m > hi then hi = m end
end
R("bang cycles the speed instead of holding one value", hi - lo > 200,
	table.concat(mags, "/"))
R("bang applies the measured strongest speed", hi >= 2900 and lo >= 1700,
	("range %d-%d"):format(lo, hi))

local aim = v.Character:FindFirstChild("Head").CFrame.Position - myRootT.CFrame.Position
local dot = API.Engine.root.AssemblyLinearVelocity.Unit:Dot(aim.Unit)
R("bang aims at the target", dot > 0.95, string.format("dot=%.2f", dot))

API.Stop()
R("stop clears the target", API.Engine.target == nil)
print(string.format("== tuning: %d failed", fails))
