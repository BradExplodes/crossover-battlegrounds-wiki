local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

-- CompletedCharacterModels policy:
-- - Server: templates live under ServerStorage.CompletedCharacterModels (mounted by RuntimeBootstrap).
-- - Client: templates are replicated on-demand into ReplicatedStorage.CompletedCharacterModelCache.
local COMPLETED_CHAR_MODELS_WAIT_SEC = 90
local characters = nil
if RunService:IsServer() then
	characters = ServerStorage:WaitForChild("CompletedCharacterModels", COMPLETED_CHAR_MODELS_WAIT_SEC)
else
	-- Do not wait for a full folder (it may never exist); clients request individual models as needed.
	characters = ReplicatedStorage:FindFirstChild("CompletedCharacterModelCache")
end
if characters and not (characters:IsA("Folder") or characters:IsA("Model")) then
	characters = nil
end
if RunService:IsServer() and not characters then
	warn(("[GameModule] ServerStorage.CompletedCharacterModels not ready within %ds — unit .model will be nil (check RuntimeBootstrap mounting)"):format(
		COMPLETED_CHAR_MODELS_WAIT_SEC
	))
end
local mapModelID = 103944624243153
local statBlock = {
	name = "",
	health = 0,
	dmg = 0,
	as = 0,
	range = 0,
	cost = 0,
	move_speed = 0,
	model = nil,
	category = ""
}

-- ============================================================
-- Roster + stat generation (driven by Characters.txt)
-- ============================================================

local function normalizeUnitId(id)
	if type(id) ~= "string" then
		return ""
	end
	return id:lower():gsub("%s+", ""):gsub("%-", ""):gsub("%.", ""):gsub("'", "")
end

local function titleCaseWord(w)
	if w == "" then
		return ""
	end
	return w:sub(1, 1):upper() .. w:sub(2):lower()
end

local function displayNameFromUnitId(unitId)
	unitId = tostring(unitId or "")

	-- Preserve common styles / acronyms.
	local fixed = {
		cid = "Cid",
		ksi = "KSI",
		mrbeast = "MrBeast",
		omniman = "Omniman",
		tracer = "Tracer",
		yuji = "Yuji",
		gojo = "Gojo",
	}
	if fixed[unitId] then
		return fixed[unitId]
	end

	local parts = {}
	for p in unitId:gmatch("[^_]+") do
		table.insert(parts, p)
	end

	-- Form suffix: base_2/base_3/base_4...
	local maybeForm = tonumber(parts[#parts] or "")
	if maybeForm and #parts >= 2 then
		parts[#parts] = nil
	end

	for i, p in ipairs(parts) do
		if p:match("^%d+$") then
			parts[i] = p
		else
			parts[i] = titleCaseWord(p)
		end
	end

	local name = table.concat(parts, " ")
	if maybeForm then
		name ..= " (Form " .. tostring(maybeForm) .. ")"
	end
	return name
end

local function resolveModelForUnitId(unitId)
	if not characters or type(unitId) ~= "string" or unitId == "" then
		return nil
	end
	local m = characters:FindFirstChild(unitId) or characters:FindFirstChild(unitId:lower())
	if m then
		return m
	end
	-- Case-insensitive match (Rigs sometimes use different casing than unit ids.)
	local want = unitId:lower()
	for _, child in ipairs(characters:GetChildren()) do
		if typeof(child.Name) == "string" and child.Name:lower() == want then
			return child
		end
	end
	return nil
end

-- Wave NPC unit ids vs model names under CompletedCharacterModels often diverge.
-- Try canonical id first (handled by caller), then explicit alternates, then sensible fallbacks.
-- Used only when `FindFirstChild(unitId)` fails (missing/wrong rig name in CompletedCharacterModels).
-- Do not map mercenary → soldier: that rig is the playable Trooper and reads wrong on Ocean Walkway.
local WAVE_NPC_MODEL_CANDIDATES = {
	mercenary2 = { "mercenary" },
	mercenary3 = { "mercenary" },
}

local function resolveWaveNpcTemplateForUnitId(normalizedId)
	local extras = WAVE_NPC_MODEL_CANDIDATES[normalizedId]
	if type(extras) ~= "table" then
		return nil
	end
	for _, name in ipairs(extras) do
		local m = resolveModelForUnitId(name)
		if m then
			return m
		end
	end
	return nil
end

local function resolveModelForUnitDef(unitId, def)
	def = def or {}
	local desired = def.modelName
	if type(desired) ~= "string" or desired == "" then
		desired = unitId
	end
	return resolveModelForUnitId(desired)
end

local ARCHETYPE_TO_ABILITY = {
	money_farm = "base_money_farm",
	assassin = "base_assassin_burst",
	bruiser = "base_bruiser_sustain",
	tank = "base_tank_heal",
	buff = "base_buff_round",
	healer = "base_healer_aoe",
}

local STAR_TO_CATEGORY = {
	[1] = "one_star",
	[2] = "two_star",
	[3] = "three_star",
	[4] = "four_star",
}

-- Blanket melee tuning: roster uses range 5 for melee hit radius; bump survivability.
local MELEE_RANGE_HP_BUFF_THRESHOLD = 5
local MELEE_RANGE_HP_BUFF_MULT = 1.25

-- Placement cost tuning (remap old per-star band → new target band).
-- We remap then clamp so the maximum never exceeds the requested cap.
local PLACEMENT_COST_TUNING = {
	[2] = { oldMin = 239, oldMax = 286, newMin = 200, newMax = 250 },
	[3] = { oldMin = 412, oldMax = 526, newMin = 350, newMax = 450 },
}

local function remapAndClampCost(cost, star)
	local t = PLACEMENT_COST_TUNING[star]
	if type(cost) ~= "number" or not t then
		return cost
	end
	local oldMin, oldMax = t.oldMin, t.oldMax
	local newMin, newMax = t.newMin, t.newMax
	if oldMax <= oldMin then
		return math.clamp(math.floor(cost + 0.5), newMin, newMax)
	end
	local alpha = (cost - oldMin) / (oldMax - oldMin)
	local mapped = newMin + alpha * (newMax - newMin)
	return math.clamp(math.floor(mapped + 0.5), newMin, newMax)
end

-- Canonical roster list (forms are separate unitIds as *_2/_3/_4).
-- Every entry includes an explicit `stats` + `displayName` for GUIs (editable per character).
local ROSTER = {
	-- 4 star
	{ id = "cyd", modelName = "cid", displayName = "Cyd", stars = 4, archetype = "assassin", rangeMode = "melee", stats = { health = 776, dmg = 176, as = 2.1, range = 5, cost = 758, move_speed = 12.1 } },
	{ id = "uchirawarlord", modelName = "madarauchiha", displayName = "Uchira Warlord", stars = 4, archetype = "assassin", rangeMode = "melee", stats = { health = 675, dmg = 155, as = 2, range = 5, cost = 722, move_speed = 11.7 } },
	{ id = "freyren", modelName = "frieren", displayName = "Freyren", stars = 4, archetype = "assassin", rangeMode = "ranged", stats = { health = 663, dmg = 151, as = 2.1, range = 20, cost = 747, move_speed = 12 } },
	{ id = "gojin2", modelName = "gojo2", displayName = "Gojin (Form 2)", stars = 4, archetype = "assassin", rangeMode = "ranged", stats = { health = 707, dmg = 160, as = 2.1, range = 20, cost = 765, move_speed = 12.2 } },
	{ id = "recall", modelName = "tracer", displayName = "Recall", stars = 4, archetype = "assassin", rangeMode = "ranged", stats = { health = 624, dmg = 143, as = 2, range = 19, cost = 732, move_speed = 11.8 } },
	{ id = "doku", modelName = "deku", displayName = "Doku", stars = 4, archetype = "bruiser", rangeMode = "melee", stats = { health = 1189, dmg = 139, as = 1.9, range = 5, cost = 740, move_speed = 11.2 } },
	{ id = "ichiro4", modelName = "ichigo4", displayName = "Ichiro (Form 4)", stars = 4, archetype = "bruiser", rangeMode = "melee", stats = { health = 1124, dmg = 132, as = 1.9, range = 5, cost = 725, move_speed = 11.1 } },
	{ id = "luffi4", modelName = "luffy4", displayName = "Luffi (Form 4)", stars = 4, archetype = "bruiser", rangeMode = "melee", stats = { health = 1069, dmg = 126, as = 1.8, range = 5, cost = 712, move_speed = 10.9 } },
	{ id = "natsudraygneel", modelName = "natsudragneel", displayName = "Natsu Draygneel", stars = 4, archetype = "bruiser", rangeMode = "melee", stats = { health = 1093, dmg = 129, as = 1.8, range = 5, cost = 718, move_speed = 11 } },
	{ id = "miku4", modelName = "miku4", displayName = "Miku (Mesmerizer)", stars = 4, archetype = "buff", rangeMode = "ranged", stats = { health = 858, dmg = 80, as = 1.8, range = 19, cost = 665, move_speed = 10.2 } },
	{ id = "furyna", modelName = "furina", displayName = "Furyna", stars = 4, archetype = "healer", rangeMode = "ranged", stats = { health = 1032, dmg = 79, as = 1.8, range = 26, cost = 734, move_speed = 10.6 } },
	{ id = "omnifather", modelName = "omniman", displayName = "Omni-Father", stars = 4, archetype = "tank", rangeMode = "melee", stats = { health = 2115, dmg = 106, as = 1.6, range = 5, cost = 782, move_speed = 10.1 } },
	{ id = "jotaru", modelName = "jotaro", displayName = "Jotaru", stars = 4, archetype = "tank", rangeMode = "melee", stats = { health = 1764, dmg = 90, as = 1.5, range = 5, cost = 733, move_speed = 9.7 } },
	{ id = "onepalm", modelName = "saitama", displayName = "One-Palm", stars = 4, archetype = "tank", rangeMode = "melee", stats = { health = 1668, dmg = 85, as = 1.5, range = 5, cost = 720, move_speed = 9.6 } },
	{ id = "struggler2", modelName = "guts2", displayName = "Struggler (Armored)", stars = 4, archetype = "bruiser", rangeMode = "melee", stats = { health = 896, dmg = 134, as = 1.85, range = 5, cost = 724, move_speed = 11 } },
	{ id = "koku4", modelName = "goku4", displayName = "Koku (Super Blue)", stars = 4, archetype = "bruiser", rangeMode = "ranged", stats = { health = 648, dmg = 142, as = 1.85, range = 19, cost = 738, move_speed = 11.3 } },
	{ id = "nightwaltz", modelName = "alucard", displayName = "Nightwaltz", stars = 4, archetype = "bruiser", rangeMode = "ranged", stats = { health = 638, dmg = 150, as = 1.95, range = 20, cost = 742, move_speed = 11.4 } },
	{ id = "redknight", modelName = "soulofcinder", displayName = "Red Knight", stars = 4, archetype = "bruiser", rangeMode = "melee", stats = { health = 900, dmg = 131, as = 1.88, range = 5, cost = 718, move_speed = 11 } },
	{ id = "2a", modelName = "a2", displayName = "2A", stars = 4, archetype = "bruiser", rangeMode = "melee", stats = { health = 884, dmg = 128, as = 1.9, range = 5, cost = 714, move_speed = 11.2 } },
	{ id = "stellaronhunter", modelName = "kafka", displayName = "Stellaron Hunter", stars = 4, archetype = "assassin", rangeMode = "melee", stats = { health = 712, dmg = 170, as = 2.05, range = 5, cost = 752, move_speed = 12.1 } },
	{ id = "lutao", modelName = "hutao", displayName = "Lutao", stars = 4, archetype = "assassin", rangeMode = "melee", stats = { health = 712, dmg = 170, as = 2.05, range = 5, cost = 752, move_speed = 12.1 } },
	{ id = "blue_revenant", modelName = "vergil", displayName = "Blue Revenant", stars = 4, archetype = "assassin", rangeMode = "melee", stats = { health = 776, dmg = 176, as = 2.1, range = 5, cost = 758, move_speed = 12.1 } },
	{ id = "blazer", modelName = "rengoku", displayName = "Blazer", stars = 4, archetype = "assassin", rangeMode = "melee", stats = { health = 675, dmg = 155, as = 2, range = 5, cost = 722, move_speed = 11.7 } },
	{ id = "medallion2", modelName = "meliodas2", displayName = "Medallion (Assault)", stars = 4, archetype = "assassin", rangeMode = "melee", stats = { health = 707, dmg = 160, as = 2.1, range = 5, cost = 765, move_speed = 12.2 } },
	{ id = "dokarun", modelName = "okarun", displayName = "Dokarun", stars = 4, archetype = "assassin", rangeMode = "melee", stats = { health = 712, dmg = 170, as = 2.05, range = 5, cost = 752, move_speed = 12.1 } },
	{ id = "first_emperor", modelName = "qinshihuang", displayName = "First Emperor", stars = 4, archetype = "bruiser", rangeMode = "melee", stats = { health = 1189, dmg = 139, as = 1.9, range = 5, cost = 740, move_speed = 11.2 } },
	{ id = "galactal", modelName = "garou", displayName = "Galactal", stars = 4, archetype = "bruiser", rangeMode = "melee", stats = { health = 1124, dmg = 132, as = 1.9, range = 5, cost = 725, move_speed = 11.1 } },
	{ id = "crimson_commander", modelName = "benimaru", displayName = "Crimson Commander", stars = 4, archetype = "bruiser", rangeMode = "ranged", stats = { health = 648, dmg = 142, as = 1.85, range = 19, cost = 738, move_speed = 11.3 } },
	{ id = "denjiro2", modelName = "denji2", displayName = "Denjiro (Transformed)", stars = 4, archetype = "assassin", rangeMode = "melee", stats = { health = 707, dmg = 160, as = 2.1, range = 5, cost = 765, move_speed = 12.2 } },
	{ id = "regent", modelName = "thragg", displayName = "Regent", stars = 4, archetype = "bruiser", rangeMode = "melee", stats = { health = 1093, dmg = 129, as = 1.8, range = 5, cost = 718, move_speed = 11 } },
	{ id = "spiral_colossus", modelName = "gurrenlagann", displayName = "Spiral Colossus", stars = 4, archetype = "tank", rangeMode = "melee", stats = { health = 1900, dmg = 95, as = 1.55, range = 5, cost = 760, move_speed = 9.8 } },
	{ id = "lava_hearth", modelName = "mavuika", displayName = "Lava Hearth", stars = 4, archetype = "bruiser", rangeMode = "melee", stats = { health = 1069, dmg = 126, as = 1.8, range = 5, cost = 712, move_speed = 10.9 } },

	-- 3 star
	{ id = "voidknight", modelName = "hollowknight", displayName = "Void Knight", stars = 3, archetype = "assassin", rangeMode = "melee", stats = { health = 503, dmg = 113, as = 2.1, range = 5, cost = 526, move_speed = 12.4 } },
	{ id = "wildcard", modelName = "joker", displayName = "Wild Card", stars = 3, archetype = "assassin", rangeMode = "melee", stats = { health = 423, dmg = 97, as = 2, range = 5, cost = 482, move_speed = 11.8 } },
	{ id = "kiritoe", modelName = "kirito", displayName = "Kiri-To", stars = 3, archetype = "assassin", rangeMode = "melee", stats = { health = 425, dmg = 97, as = 2, range = 5, cost = 484, move_speed = 11.9 } },
	{ id = "leviackren", modelName = "leviackerman", displayName = "Levi Ackren", stars = 3, archetype = "assassin", rangeMode = "melee", stats = { health = 477, dmg = 108, as = 2, range = 5, cost = 512, move_speed = 12.2 } },
	{ id = "reza", modelName = "reze", displayName = "Reza", stars = 3, archetype = "assassin", rangeMode = "melee", stats = { health = 489, dmg = 110, as = 2.1, range = 5, cost = 518, move_speed = 12.3 } },
	{ id = "jinwoosung", modelName = "sungjinwoo", displayName = "Jin-Woo Sung", stars = 3, archetype = "assassin", rangeMode = "melee", stats = { health = 437, dmg = 100, as = 2, range = 5, cost = 490, move_speed = 11.9 } },
	{ id = "tojin", modelName = "toji", displayName = "Tojin", stars = 3, archetype = "assassin", rangeMode = "melee", stats = { health = 422, dmg = 97, as = 2, range = 5, cost = 482, move_speed = 11.8 } },
	{ id = "zolo2", modelName = "zoro2", displayName = "Zolo (Form 2)", stars = 3, archetype = "assassin", rangeMode = "melee", stats = { health = 437, dmg = 100, as = 2, range = 5, cost = 490, move_speed = 11.9 } },
	{ id = "gojin", modelName = "gojo", displayName = "Gojin", stars = 3, archetype = "assassin", rangeMode = "ranged", stats = { health = 446, dmg = 100, as = 2.1, range = 22, cost = 525, move_speed = 12.4 } },
	{ id = "yujiro", modelName = "yuji", displayName = "Yujiro", stars = 3, archetype = "bruiser", rangeMode = "melee", stats = { health = 620, dmg = 73, as = 1.7, range = 5, cost = 465, move_speed = 10.8 } },
	{ id = "hellcleaver", modelName = "doomslayer", displayName = "Hellcleaver", stars = 3, archetype = "bruiser", rangeMode = "melee", stats = { health = 621, dmg = 74, as = 1.7, range = 5, cost = 466, move_speed = 10.8 } },
	{ id = "edricelrik", modelName = "edwardelric", displayName = "Edric Elrik", stars = 3, archetype = "bruiser", rangeMode = "melee", stats = { health = 717, dmg = 84, as = 1.8, range = 5, cost = 500, move_speed = 11.2 } },
	{ id = "luffi3", modelName = "luffy3", displayName = "Luffi (Form 3)", stars = 3, archetype = "bruiser", rangeMode = "melee", stats = { health = 690, dmg = 81, as = 1.8, range = 5, cost = 491, move_speed = 11.1 } },
	{ id = "peaches", modelName = "clementine", displayName = "Peaches", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 550, dmg = 65, as = 1.7, range = 14, cost = 465, move_speed = 10.8 } },
	{ id = "dyo", modelName = "dio", displayName = "Dyo", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 604, dmg = 71, as = 1.8, range = 16, cost = 487, move_speed = 11.1 } },
	{ id = "doctorzombie", modelName = "edwardrichtofen", displayName = "Doctor Zombie", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 605, dmg = 71, as = 1.8, range = 16, cost = 487, move_speed = 11.1 } },
	{ id = "ichiro3", modelName = "ichigo3", displayName = "Ichiro (Form 3)", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 582, dmg = 69, as = 1.8, range = 15, cost = 478, move_speed = 11 } },
	{ id = "hextech", modelName = "jinx", displayName = "Hextech", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 630, dmg = 74, as = 1.8, range = 16, cost = 497, move_speed = 11.2 } },
	{ id = "leonis", modelName = "leon", displayName = "Leonis", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 576, dmg = 68, as = 1.7, range = 15, cost = 475, move_speed = 10.9 } },
	{ id = "sprinter", modelName = "neon", displayName = "Sprinter", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 562, dmg = 66, as = 1.7, range = 14, cost = 470, move_speed = 10.9 } },
	{ id = "phoenix", modelName = "phoenix", displayName = "Pidgeon", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 538, dmg = 64, as = 1.7, range = 13, cost = 460, move_speed = 10.8 } },
	{ id = "ronaldo", modelName = "ronaldo", displayName = "Goalnaldo", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 620, dmg = 73, as = 1.8, range = 16, cost = 493, move_speed = 11.2 } },
	{ id = "miku3", modelName = "miku3", displayName = "Miku (Monitoring)", stars = 3, archetype = "buff", rangeMode = "ranged", stats = { health = 552, dmg = 51, as = 1.8, range = 20, cost = 454, move_speed = 10.4 } },
	{ id = "philza", modelName = "philza", displayName = "Philza", stars = 3, archetype = "buff", rangeMode = "ranged", stats = { health = 608, dmg = 56, as = 1.8, range = 22, cost = 476, move_speed = 10.7 } },
	{ id = "tsunami", modelName = "nami", displayName = "Tsunami", stars = 3, archetype = "money_farm", rangeMode = "ranged", stats = { health = 479, dmg = 38, as = 1.5, range = 18, cost = 412, move_speed = 10.2 } },
	{ id = "slimefarmer", modelName = "beatrixlebeau", displayName = "Slime Farmer", stars = 3, archetype = "tank", rangeMode = "ranged", stats = { health = 1048, dmg = 53, as = 1.5, range = 15, cost = 509, move_speed = 9.9 } },
	{ id = "meta", modelName = "megaknight", displayName = "Meta", stars = 3, archetype = "tank", rangeMode = "melee", stats = { health = 736, dmg = 44, as = 1.35, range = 5, cost = 488, move_speed = 9.5 } },
	{ id = "viscount", modelName = "mina", displayName = "Viscount", stars = 3, archetype = "assassin", rangeMode = "ranged", stats = { health = 438, dmg = 99, as = 2.05, range = 21, cost = 508, move_speed = 12.2 } },
	{ id = "hollowvessel", modelName = "kris", displayName = "Hollow Vessel", stars = 3, archetype = "bruiser", rangeMode = "melee", stats = { health = 688, dmg = 80, as = 1.68, range = 5, cost = 488, move_speed = 10.8 } },
	{ id = "gravgirl", modelName = "uraraka", displayName = "Grav Girl", stars = 3, archetype = "assassin", rangeMode = "ranged", stats = { health = 452, dmg = 101, as = 2, range = 20, cost = 514, move_speed = 12.3 } },
	{ id = "johnsparta", modelName = "masterchief", displayName = "John Sparta", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 588, dmg = 71, as = 1.72, range = 16, cost = 492, move_speed = 11 } },
	{ id = "struggler", modelName = "guts", displayName = "Struggler", stars = 3, archetype = "bruiser", rangeMode = "melee", stats = { health = 664, dmg = 83, as = 1.72, range = 5, cost = 502, move_speed = 11 } },
	{ id = "koku3", modelName = "goku3", displayName = "Koku (God)", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 592, dmg = 70, as = 1.76, range = 17, cost = 482, move_speed = 11 } },
	{ id = "halfghoul", modelName = "kenkaneki", displayName = "Half Ghoul", stars = 3, archetype = "assassin", rangeMode = "melee", stats = { health = 478, dmg = 109, as = 2.02, range = 5, cost = 516, move_speed = 12.2 } },
	{ id = "hollow", modelName = "gabimaru", displayName = "Hollow", stars = 3, archetype = "assassin", rangeMode = "melee", stats = { health = 468, dmg = 106, as = 2, range = 5, cost = 506, move_speed = 12.1 } },
	{ id = "chessking", modelName = "lelouch", displayName = "Chess King", stars = 3, archetype = "buff", rangeMode = "ranged", stats = { health = 600, dmg = 53, as = 1.82, range = 22, cost = 468, move_speed = 10.6 } },
	{ id = "namedking", modelName = "namelessking", displayName = "Named King", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 584, dmg = 69, as = 1.77, range = 17, cost = 478, move_speed = 11 } },
	{ id = "moonlit_vulpine", modelName = "tamamo", displayName = "Moonlit Vulpine", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 576, dmg = 68, as = 1.7, range = 15, cost = 475, move_speed = 10.9 } },
	{ id = "scout", modelName = "camper", displayName = "Scout", stars = 3, archetype = "tank", rangeMode = "melee", stats = { health = 736, dmg = 44, as = 1.35, range = 5, cost = 488, move_speed = 9.5 } },
	{ id = "clockwork", modelName = "kurumitokisaki", displayName = "Clockwork", stars = 3, archetype = "assassin", rangeMode = "ranged", stats = { health = 452, dmg = 101, as = 2, range = 20, cost = 514, move_speed = 12.3 } },
	{ id = "pillar_of_peace", modelName = "allmight", displayName = "Pillar of Peace", stars = 3, archetype = "bruiser", rangeMode = "melee", stats = { health = 717, dmg = 84, as = 1.8, range = 5, cost = 500, move_speed = 11.2 } },
	{ id = "patriot", modelName = "homelander", displayName = "Patriot", stars = 3, archetype = "assassin", rangeMode = "ranged", stats = { health = 446, dmg = 100, as = 2.1, range = 22, cost = 525, move_speed = 12.4 } },
	{ id = "lily", modelName = "lilith", displayName = "Lily", stars = 3, archetype = "buff", rangeMode = "ranged", stats = { health = 600, dmg = 53, as = 1.82, range = 22, cost = 468, move_speed = 10.6 } },
	{ id = "whisper_magus", modelName = "qifrey", displayName = "Whisper Magus", stars = 3, archetype = "assassin", rangeMode = "ranged", stats = { health = 438, dmg = 99, as = 2.05, range = 21, cost = 508, move_speed = 12.2 } },
	{ id = "golden_king", modelName = "gilgamesh", displayName = "Golden King", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 620, dmg = 73, as = 1.8, range = 16, cost = 493, move_speed = 11.2 } },
	{ id = "mirror", modelName = "aizen", displayName = "Mirror", stars = 3, archetype = "assassin", rangeMode = "ranged", stats = { health = 452, dmg = 101, as = 2, range = 20, cost = 514, move_speed = 12.3 } },
	{ id = "godender", modelName = "kratos", displayName = "Godender", stars = 3, archetype = "bruiser", rangeMode = "melee", stats = { health = 690, dmg = 81, as = 1.8, range = 5, cost = 491, move_speed = 11.1 } },
	{ id = "skychef2", modelName = "sanji2", displayName = "Sky Chef (Royal)", stars = 3, archetype = "bruiser", rangeMode = "ranged", stats = { health = 604, dmg = 71, as = 1.8, range = 16, cost = 487, move_speed = 11.1 } },
	{ id = "titlecard", modelName = "invincible", displayName = "Titlecard", stars = 3, archetype = "bruiser", rangeMode = "melee", stats = { health = 664, dmg = 83, as = 1.72, range = 5, cost = 502, move_speed = 11 } },
	{ id = "drill_vanguard", modelName = "simon2", displayName = "Drill Rookie", stars = 3, archetype = "bruiser", rangeMode = "melee", stats = { health = 717, dmg = 84, as = 1.8, range = 5, cost = 500, move_speed = 11.2 } },
	{ id = "engine", modelName = "enjin", displayName = "Engine", stars = 3, archetype = "bruiser", rangeMode = "melee", stats = { health = 688, dmg = 80, as = 1.68, range = 5, cost = 488, move_speed = 10.8 } },

	-- 2 star
	{ id = "akiyo", modelName = "aki", displayName = "Akiyo", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 238, dmg = 54, as = 1.9, range = 5, cost = 268, move_speed = 12 } },
	{ id = "baruto", modelName = "naruto", displayName = "Baruto", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 241, dmg = 55, as = 1.9, range = 5, cost = 270, move_speed = 12.1 } },
	{ id = "spiderman", modelName = "spiderman", displayName = "Webslinger", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 255, dmg = 58, as = 2, range = 5, cost = 281, move_speed = 12.2 } },
	{ id = "tanjiro", modelName = "tanjiro", displayName = "Tanjiru", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 252, dmg = 57, as = 2, range = 5, cost = 279, move_speed = 12.2 } },
	{ id = "thorfyn", modelName = "thorfinn", displayName = "Thorfyn", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 258, dmg = 58, as = 2, range = 5, cost = 284, move_speed = 12.3 } },
	{ id = "greyfang", modelName = "wolf", displayName = "Greyfang", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 247, dmg = 56, as = 1.9, range = 5, cost = 275, move_speed = 12.1 } },
	{ id = "zolo", modelName = "zoro", displayName = "Zolo", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 260, dmg = 59, as = 2, range = 5, cost = 285, move_speed = 12.3 } },
	{ id = "bridgit", modelName = "bridget", displayName = "Bridgit", stars = 2, archetype = "assassin", rangeMode = "ranged", stats = { health = 231, dmg = 52, as = 2, range = 22, cost = 286, move_speed = 12.3 } },
	{ id = "getoux", modelName = "getoux", displayName = "Getoux", stars = 2, archetype = "assassin", rangeMode = "ranged", stats = { health = 207, dmg = 47, as = 1.9, range = 19, cost = 264, move_speed = 12 } },
	{ id = "lamplight", modelName = "light", displayName = "Lamplight", stars = 2, archetype = "assassin", rangeMode = "ranged", stats = { health = 216, dmg = 49, as = 1.9, range = 20, cost = 272, move_speed = 12.1 } },
	{ id = "skeleton", modelName = "sans", displayName = "Skeleton", stars = 2, archetype = "assassin", rangeMode = "ranged", stats = { health = 220, dmg = 50, as = 1.9, range = 20, cost = 276, move_speed = 12.1 } },
	{ id = "trooper", modelName = "soldier", displayName = "Trooper", stars = 2, archetype = "assassin", rangeMode = "ranged", stats = { health = 229, dmg = 52, as = 2, range = 22, cost = 284, move_speed = 12.3 } },
	{ id = "supersonic", modelName = "sonic", displayName = "Supersonic", stars = 2, archetype = "assassin", rangeMode = "ranged", stats = { health = 220, dmg = 50, as = 1.9, range = 20, cost = 276, move_speed = 12.1 } },
	{ id = "denjiro", modelName = "denji", displayName = "Denjiro", stars = 2, archetype = "bruiser", rangeMode = "melee", stats = { health = 342, dmg = 40, as = 1.7, range = 5, cost = 256, move_speed = 10.9 } },
	{ id = "fin", modelName = "finn", displayName = "Fin", stars = 2, archetype = "bruiser", rangeMode = "melee", stats = { health = 364, dmg = 43, as = 1.7, range = 5, cost = 268, move_speed = 11.1 } },
	{ id = "gone", modelName = "gon", displayName = "Gone", stars = 2, archetype = "bruiser", rangeMode = "melee", stats = { health = 370, dmg = 43, as = 1.7, range = 5, cost = 271, move_speed = 11.2 } },
	{ id = "ichiro2", modelName = "ichigo2", displayName = "Ichiro (Form 2)", stars = 2, archetype = "bruiser", rangeMode = "melee", stats = { health = 336, dmg = 40, as = 1.7, range = 5, cost = 253, move_speed = 10.9 } },
	{ id = "boxer", modelName = "ksi", displayName = "Boxer", stars = 2, archetype = "bruiser", rangeMode = "melee", stats = { health = 355, dmg = 42, as = 1.7, range = 5, cost = 264, move_speed = 11.1 } },
	{ id = "luffi2", modelName = "luffy2", displayName = "Luffi (Form 2)", stars = 2, archetype = "bruiser", rangeMode = "melee", stats = { health = 371, dmg = 43, as = 1.7, range = 5, cost = 272, move_speed = 11.2 } },
	{ id = "power", modelName = "power", displayName = "Power", stars = 2, archetype = "bruiser", rangeMode = "melee", stats = { health = 327, dmg = 39, as = 1.6, range = 5, cost = 248, move_speed = 10.8 } },
	{ id = "purpleguy", modelName = "williamafton", displayName = "Purple Guy", stars = 2, archetype = "bruiser", rangeMode = "melee", stats = { health = 330, dmg = 39, as = 1.6, range = 5, cost = 250, move_speed = 10.9 } },
	{ id = "miku2", modelName = "miku2", displayName = "Miku (Rotten)", stars = 2, archetype = "buff", rangeMode = "ranged", stats = { health = 302, dmg = 28, as = 1.7, range = 21, cost = 251, move_speed = 10.5 } },
	{ id = "nicorobyn", modelName = "nicorobin", displayName = "Nico Robyn", stars = 2, archetype = "buff", rangeMode = "ranged", stats = { health = 281, dmg = 26, as = 1.7, range = 19, cost = 239, move_speed = 10.3 } },
	{ id = "teto", modelName = "teto", displayName = "Teto", stars = 2, archetype = "buff", rangeMode = "ranged", stats = { health = 291, dmg = 27, as = 1.7, range = 20, cost = 245, move_speed = 10.4 } },
	{ id = "mrbeast", modelName = "mrbeast", displayName = "MrBeast", stars = 2, archetype = "money_farm", rangeMode = "ranged", stats = { health = 294, dmg = 23, as = 1.5, range = 21, cost = 243, move_speed = 10.6 } },
	{ id = "gigachad", modelName = "gigachad", displayName = "Gigachad", stars = 2, archetype = "tank", rangeMode = "melee", stats = { health = 581, dmg = 29, as = 1.4, range = 5, cost = 264, move_speed = 9.8 } },
	{ id = "blockman", modelName = "steve", displayName = "Blockman", stars = 2, archetype = "tank", rangeMode = "melee", stats = { health = 577, dmg = 29, as = 1.4, range = 5, cost = 262, move_speed = 9.8 } },
	{ id = "umbraplate", modelName = "darkknight", displayName = "Umbra Plate", stars = 2, archetype = "bruiser", rangeMode = "melee", stats = { health = 348, dmg = 41, as = 1.68, range = 5, cost = 260, move_speed = 10.9 } },
	{ id = "blackmore", modelName = "apollo", displayName = "Blackmore", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 242, dmg = 55, as = 1.92, range = 5, cost = 271, move_speed = 12.1 } },
	{ id = "rabble", modelName = "susie", displayName = "Rabble", stars = 2, archetype = "tank", rangeMode = "melee", stats = { health = 590, dmg = 30, as = 1.38, range = 5, cost = 266, move_speed = 9.7 } },
	{ id = "bloodlace", modelName = "toga", displayName = "Bloodlace", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 250, dmg = 57, as = 1.95, range = 5, cost = 278, move_speed = 12.2 } },
	{ id = "digitalgirl", modelName = "mita", displayName = "Digital Girl", stars = 2, archetype = "buff", rangeMode = "ranged", stats = { health = 298, dmg = 28, as = 1.68, range = 21, cost = 248, move_speed = 10.5 } },
	{ id = "manageddemocracy", modelName = "helldiver", displayName = "Managed Democracy", stars = 2, archetype = "bruiser", rangeMode = "ranged", stats = { health = 352, dmg = 40, as = 1.65, range = 15, cost = 256, move_speed = 10.9 } },
	{ id = "koku2", modelName = "goku2", displayName = "Koku (Super)", stars = 2, archetype = "bruiser", rangeMode = "ranged", stats = { health = 348, dmg = 40, as = 1.64, range = 16, cost = 258, move_speed = 10.9 } },
	{ id = "lionknight", modelName = "artorius", displayName = "Lionknight", stars = 2, archetype = "tank", rangeMode = "melee", stats = { health = 594, dmg = 30, as = 1.39, range = 5, cost = 267, move_speed = 9.7 } },
	{ id = "scythemeister", modelName = "maka", displayName = "Scythemeister", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 246, dmg = 56, as = 1.93, range = 5, cost = 274, move_speed = 12.1 } },
	{ id = "scannerunit", modelName = "9s", displayName = "Scanner Unit", stars = 2, archetype = "bruiser", rangeMode = "ranged", stats = { health = 338, dmg = 39, as = 1.63, range = 16, cost = 252, move_speed = 10.8 } },
	{ id = "emperorstag", modelName = "symbolirudolf", displayName = "Emperor Stag", stars = 2, archetype = "assassin", rangeMode = "ranged", stats = { health = 220, dmg = 50, as = 1.9, range = 20, cost = 276, move_speed = 12.1 } },
	{ id = "granite", modelName = "ryu", displayName = "Granite", stars = 2, archetype = "bruiser", rangeMode = "ranged", stats = { health = 348, dmg = 40, as = 1.64, range = 16, cost = 258, move_speed = 10.9 } },
	{ id = "ice_duelist", modelName = "kamisato", displayName = "Ice Duelist", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 258, dmg = 58, as = 2, range = 5, cost = 284, move_speed = 12.3 } },
	{ id = "lutao_exclusive", modelName = "hutao_exclusive", displayName = "Lutao (Exclusive)", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 252, dmg = 57, as = 2, range = 5, cost = 279, move_speed = 12.2 } },
	{ id = "scp-049", modelName = "plaguedoctor", displayName = "SCP-049", stars = 2, archetype = "buff", rangeMode = "melee", stats = { health = 300, dmg = 28, as = 1.7, range = 5, cost = 248, move_speed = 10.5 } },
	{ id = "the_adversary", modelName = "slaytheprincess", displayName = "The Adversary", stars = 2, archetype = "bruiser", rangeMode = "melee", stats = { health = 355, dmg = 42, as = 1.7, range = 5, cost = 264, move_speed = 11.1 } },
	{ id = "tetoris", modelName = "teto", displayName = "Tetoris", stars = 2, archetype = "healer", rangeMode = "ranged", stats = { health = 260, dmg = 18, as = 1.55, range = 24, cost = 250, move_speed = 10.5 } },
	{ id = "love_diary", modelName = "yuno", displayName = "Love Diary", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 247, dmg = 56, as = 1.95, range = 5, cost = 275, move_speed = 12.1 } },
	{ id = "medallion", modelName = "meliodas", displayName = "Medallion", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 255, dmg = 58, as = 2, range = 5, cost = 281, move_speed = 12.2 } },
	{ id = "spear_guardian", modelName = "undyne", displayName = "Spear Guardian", stars = 2, archetype = "bruiser", rangeMode = "ranged", stats = { health = 352, dmg = 40, as = 1.65, range = 15, cost = 256, move_speed = 10.9 } },
	{ id = "void_sovereign", modelName = "anos", displayName = "Void Sovereign", stars = 2, archetype = "bruiser", rangeMode = "ranged", stats = { health = 338, dmg = 39, as = 1.63, range = 16, cost = 252, move_speed = 10.8 } },
	{ id = "scrap_ripper", modelName = "rudo", displayName = "Scrap Ripper", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 242, dmg = 55, as = 1.92, range = 5, cost = 271, move_speed = 12.1 } },
	{ id = "iron_halberd", modelName = "maki", displayName = "Iron Halberd", stars = 2, archetype = "bruiser", rangeMode = "melee", stats = { health = 364, dmg = 43, as = 1.7, range = 5, cost = 268, move_speed = 11.1 } },
	{ id = "bone_rider", modelName = "skullknight", displayName = "Bone Rider", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 246, dmg = 56, as = 1.93, range = 5, cost = 274, move_speed = 12.1 } },
	{ id = "ember_flinger", modelName = "ace", displayName = "Ember Flinger", stars = 2, archetype = "bruiser", rangeMode = "ranged", stats = { health = 348, dmg = 40, as = 1.65, range = 15, cost = 256, move_speed = 10.9 } },
	{ id = "hawk_eyes", modelName = "roy", displayName = "Hawk Eyes", stars = 2, archetype = "assassin", rangeMode = "ranged", stats = { health = 216, dmg = 49, as = 1.9, range = 20, cost = 272, move_speed = 12.1 } },
	{ id = "pink_atom", modelName = "atomeve", displayName = "Pink Atom", stars = 2, archetype = "bruiser", rangeMode = "ranged", stats = { health = 352, dmg = 40, as = 1.65, range = 15, cost = 256, move_speed = 10.9 } },
	{ id = "sunglasses_chief", modelName = "kamina", displayName = "Sunglasses Chief", stars = 2, archetype = "assassin", rangeMode = "melee", stats = { health = 260, dmg = 59, as = 2, range = 5, cost = 285, move_speed = 12.3 } },
	{ id = "ember_archer", modelName = "zanka", displayName = "Ember Archer", stars = 2, archetype = "assassin", rangeMode = "ranged", stats = { health = 231, dmg = 52, as = 2, range = 22, cost = 286, move_speed = 12.3 } },

	-- 1 star
	{ id = "infiltrator", modelName = "spy", displayName = "Infiltrator", stars = 1, archetype = "assassin", rangeMode = "melee", stats = { health = 127, dmg = 29, as = 1.8, range = 5, cost = 124, move_speed = 12.1 } },
	{ id = "foxgirl", modelName = "ahri", displayName = "Foxgirl", stars = 1, archetype = "assassin", rangeMode = "ranged", stats = { health = 111, dmg = 25, as = 1.8, range = 19, cost = 122, move_speed = 12 } },
	{ id = "asagi", modelName = "isagi", displayName = "Asagi", stars = 1, archetype = "assassin", rangeMode = "ranged", stats = { health = 116, dmg = 26, as = 1.9, range = 21, cost = 129, move_speed = 12.2 } },
	{ id = "killerstar", modelName = "keemstar", displayName = "Killer Star", stars = 1, archetype = "assassin", rangeMode = "ranged", stats = { health = 111, dmg = 25, as = 1.8, range = 19, cost = 121, move_speed = 12 } },
	{ id = "hagi", modelName = "nagi", displayName = "Hagi", stars = 1, archetype = "assassin", rangeMode = "ranged", stats = { health = 118, dmg = 27, as = 1.9, range = 22, cost = 131, move_speed = 12.2 } },
	{ id = "raze", modelName = "raze", displayName = "Raze", stars = 1, archetype = "assassin", rangeMode = "ranged", stats = { health = 113, dmg = 26, as = 1.8, range = 19, cost = 124, move_speed = 12.1 } },
	{ id = "rimuru", modelName = "rimuru", displayName = "Slime Boy", stars = 1, archetype = "assassin", rangeMode = "ranged", stats = { health = 113, dmg = 26, as = 1.8, range = 19, cost = 124, move_speed = 12.1 } },
	{ id = "couriersix", modelName = "courier_6", displayName = "Courier Six", stars = 1, archetype = "bruiser", rangeMode = "ranged", stats = { health = 162, dmg = 19, as = 1.6, range = 15, cost = 119, move_speed = 11 } },
	{ id = "hazmat", modelName = "hunk", displayName = "Hazmat", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 190, dmg = 22, as = 1.6, range = 5, cost = 125, move_speed = 11.1 } },
	{ id = "letterman", modelName = "jacket", displayName = "Letterman", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 185, dmg = 22, as = 1.6, range = 5, cost = 121, move_speed = 11 } },
	{ id = "elevens", modelName = "evans", displayName = "Elevens", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 182, dmg = 21, as = 1.6, range = 5, cost = 118, move_speed = 11 } },
	{ id = "ichirokurasaki", modelName = "ichigokurasaki", displayName = "Ichiro Kurasaki", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 188, dmg = 22, as = 1.6, range = 5, cost = 124, move_speed = 11.1 } },
	{ id = "sideburns", modelName = "katanaman", displayName = "Sideburns", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 188, dmg = 22, as = 1.6, range = 5, cost = 124, move_speed = 11.1 } },
	{ id = "luffi", modelName = "luffy", displayName = "Luffi", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 183, dmg = 22, as = 1.6, range = 5, cost = 120, move_speed = 11 } },
	{ id = "manjisano", modelName = "manjirosano", displayName = "Manji Sano", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 179, dmg = 21, as = 1.6, range = 5, cost = 116, move_speed = 10.9 } },
	{ id = "sandwich", modelName = "mordecai", displayName = "Sandwich", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 184, dmg = 22, as = 1.6, range = 5, cost = 120, move_speed = 11 } },
	{ id = "cook", modelName = "walterwhite", displayName = "Cook", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 184, dmg = 22, as = 1.6, range = 5, cost = 120, move_speed = 11 } },
	{ id = "koku", modelName = "goku", displayName = "Koku", stars = 1, archetype = "bruiser", rangeMode = "ranged", stats = { health = 169, dmg = 20, as = 1.6, range = 17, cost = 125, move_speed = 11.1 } },
	{ id = "miku", modelName = "miku", displayName = "Miku", stars = 1, archetype = "buff", rangeMode = "ranged", stats = { health = 149, dmg = 14, as = 1.6, range = 18, cost = 109, move_speed = 10.4 } },
	{ id = "dime", modelName = "penny", displayName = "Dime", stars = 1, archetype = "buff", rangeMode = "ranged", stats = { health = 159, dmg = 15, as = 1.6, range = 21, cost = 118, move_speed = 10.5 } },
	{ id = "remedy", modelName = "sage", displayName = "Remedy", stars = 1, archetype = "healer", rangeMode = "ranged", stats = { health = 160, dmg = 12, as = 1.5, range = 24, cost = 117, move_speed = 10.4 } },
	{ id = "flamingo", modelName = "flamingo", displayName = "Flamingo", stars = 1, archetype = "money_farm", rangeMode = "ranged", stats = { health = 150, dmg = 12, as = 1.4, range = 21, cost = 110, move_speed = 10.5 } },
	{ id = "hazardcrew", modelName = "lethalcompany", displayName = "Hazard Crew", stars = 1, archetype = "money_farm", rangeMode = "ranged", stats = { health = 148, dmg = 12, as = 1.4, range = 21, cost = 109, move_speed = 10.5 } },
	{ id = "minimumwageworker", modelName = "minimumwageworker", displayName = "Minimum Wage Worker", stars = 1, archetype = "money_farm", rangeMode = "ranged", stats = { health = 142, dmg = 11, as = 1.4, range = 18, cost = 103, move_speed = 10.4 } },
	{ id = "kiyoayan", modelName = "ayanokoji", displayName = "Kiyo Ayan", stars = 1, archetype = "tank", rangeMode = "melee", stats = { health = 314, dmg = 16, as = 1.3, range = 5, cost = 123, move_speed = 9.8 } },
	{ id = "borisjohnson", modelName = "borisjohnson", displayName = "Boris Johnson", stars = 1, archetype = "tank", rangeMode = "melee", stats = { health = 312, dmg = 16, as = 1.3, range = 5, cost = 122, move_speed = 9.8 } },
	{ id = "sprint", modelName = "speed", displayName = "Sprint", stars = 1, archetype = "tank", rangeMode = "melee", stats = { health = 318, dmg = 16, as = 1.4, range = 5, cost = 124, move_speed = 9.9 } },
	{ id = "heavyman", modelName = "heavy", displayName = "Heavyman", stars = 1, archetype = "tank", rangeMode = "ranged", stats = { health = 291, dmg = 15, as = 1.4, range = 16, cost = 129, move_speed = 9.9 } },
	{ id = "jogou", modelName = "jogo", displayName = "Jogou", stars = 1, archetype = "tank", rangeMode = "ranged", stats = { health = 286, dmg = 14, as = 1.4, range = 15, cost = 126, move_speed = 9.9 } },
	{ id = "pillager", modelName = "barbarian", displayName = "Pillager", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 188, dmg = 22, as = 1.6, range = 5, cost = 124, move_speed = 11.1 } },
	{ id = "reapershandmaiden", modelName = "graves", displayName = "Reaper's Handmaiden", stars = 1, archetype = "bruiser", rangeMode = "ranged", stats = { health = 168, dmg = 21, as = 1.55, range = 14, cost = 118, move_speed = 11 } },
	{ id = "flufshealer", modelName = "ralsei", displayName = "Fluff Healer", stars = 1, archetype = "healer", rangeMode = "ranged", stats = { health = 162, dmg = 12, as = 1.5, range = 24, cost = 118, move_speed = 10.4 } },
	{ id = "droptrooper", modelName = "odst", displayName = "Droptrooper", stars = 1, archetype = "assassin", rangeMode = "ranged", stats = { health = 114, dmg = 27, as = 1.85, range = 20, cost = 126, move_speed = 12.1 } },
	{ id = "facelesssinger", modelName = "ado", displayName = "Faceless Singer", stars = 1, archetype = "buff", rangeMode = "ranged", stats = { health = 150, dmg = 14, as = 1.6, range = 19, cost = 111, move_speed = 10.4 } },
	{ id = "azure_kicker", modelName = "chunli", displayName = "Azure Kicker", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 182, dmg = 21, as = 1.6, range = 5, cost = 118, move_speed = 11 } },
	{ id = "caskbrawler", modelName = "taninogimlet", displayName = "Cask Brawler", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 185, dmg = 22, as = 1.6, range = 5, cost = 121, move_speed = 11 } },
	{ id = "windblade", modelName = "jett", displayName = "Windblade", stars = 1, archetype = "assassin", rangeMode = "ranged", stats = { health = 114, dmg = 26, as = 1.85, range = 20, cost = 126, move_speed = 12.1 } },
	{ id = "shadow_scythe", modelName = "kayn", displayName = "Shadow Scythe", stars = 1, archetype = "assassin", rangeMode = "melee", stats = { health = 128, dmg = 29, as = 1.8, range = 5, cost = 124, move_speed = 12.1 } },
	{ id = "mech_bunny", modelName = "dva", displayName = "Mech Bunny", stars = 1, archetype = "bruiser", rangeMode = "ranged", stats = { health = 170, dmg = 20, as = 1.6, range = 16, cost = 125, move_speed = 11.1 } },
	{ id = "juniper_nurse", modelName = "juno", displayName = "Juniper Nurse", stars = 1, archetype = "healer", rangeMode = "ranged", stats = { health = 162, dmg = 12, as = 1.5, range = 24, cost = 118, move_speed = 10.4 } },
	{ id = "shop_critter", modelName = "temmie", displayName = "Shop Critter", stars = 1, archetype = "money_farm", rangeMode = "ranged", stats = { health = 148, dmg = 12, as = 1.4, range = 21, cost = 109, move_speed = 10.5 } },
	{ id = "signal_sage", modelName = "ren", displayName = "Signal Sage", stars = 1, archetype = "buff", rangeMode = "ranged", stats = { health = 150, dmg = 14, as = 1.6, range = 19, cost = 111, move_speed = 10.4 } },
	{ id = "gravekeeper", modelName = "flins", displayName = "Gravekeeper", stars = 1, archetype = "assassin", rangeMode = "melee", stats = { health = 126, dmg = 28, as = 1.8, range = 5, cost = 123, move_speed = 12 } },
	{ id = "paper_marksman", modelName = "nikolai", displayName = "Paper Marksman", stars = 1, archetype = "assassin", rangeMode = "ranged", stats = { health = 116, dmg = 26, as = 1.9, range = 21, cost = 129, move_speed = 12.2 } },
	{ id = "sky_chef", modelName = "sanji1", displayName = "Sky Chef", stars = 1, archetype = "bruiser", rangeMode = "ranged", stats = { health = 168, dmg = 21, as = 1.55, range = 14, cost = 118, move_speed = 11 } },
	{ id = "nose", modelName = "ussop", displayName = "Nose", stars = 1, archetype = "assassin", rangeMode = "ranged", stats = { health = 113, dmg = 26, as = 1.8, range = 19, cost = 124, move_speed = 12.1 } },
	{ id = "drill_rookie", modelName = "simon", displayName = "Drill Rookie", stars = 1, archetype = "bruiser", rangeMode = "melee", stats = { health = 184, dmg = 22, as = 1.6, range = 5, cost = 120, move_speed = 11 } },
	{ id = "ritual_guardian", modelName = "maharaga", displayName = "Ritual Guardian", stars = 1, archetype = "tank", rangeMode = "melee", stats = { health = 314, dmg = 16, as = 1.35, range = 5, cost = 123, move_speed = 9.8 } },
}

local function buildUnitsAndCategories()
	local units = {}
	local categories = {
		one_star = {},
		two_star = {},
		three_star = {},
		four_star = {},
	}

	for _, row in ipairs(ROSTER) do
		local id = normalizeUnitId(row.id)
		local stars = tonumber(row.stars) or 1
		local category = STAR_TO_CATEGORY[stars] or "one_star"
		local archetype = tostring(row.archetype or "bruiser")
		local rangeMode = tostring(row.rangeMode or "melee")

		-- Each unit must specify explicit stats.
		local stats = row.stats or {}
		local displayName = (type(row.displayName) == "string" and row.displayName ~= "") and row.displayName or displayNameFromUnitId(id)
		local placeCost = tonumber(stats.cost) or 0
		if stars == 2 or stars == 3 then
			placeCost = remapAndClampCost(placeCost, stars)
		end
		local baseRange = tonumber(stats.range) or 0
		local baseHealth = tonumber(stats.health) or 0
		if baseRange == MELEE_RANGE_HP_BUFF_THRESHOLD and baseHealth > 0 then
			baseHealth = math.floor(baseHealth * MELEE_RANGE_HP_BUFF_MULT + 0.5)
		end
		-- Preserve the explicit roster modelName so consumers (server cache, client UI lookups,
		-- etc.) can resolve the rig name without poking at Roblox instances. Falls back to id
		-- when the row omits a custom rig name (id == modelName cases).
		local rosterModelName = (type(row.modelName) == "string" and row.modelName ~= "") and row.modelName or id
		units[id] = {
			name = (type(row.name) == "string" and row.name ~= "") and row.name or displayName,
			displayName = displayName,
			health = baseHealth,
			dmg = tonumber(stats.dmg) or 0,
			as = tonumber(stats.as) or 1,
			range = baseRange,
			cost = placeCost,
			move_speed = tonumber(stats.move_speed) or 10,
			model = resolveModelForUnitDef(id, row),
			modelName = rosterModelName,
			category = category,
			archetype = archetype,
			rangeMode = rangeMode,
			defaultAbilityId = ARCHETYPE_TO_ABILITY[archetype] or "default_burst",
		}
		table.insert(categories[category], id)
	end

	-- Enemy/NPC default model (not part of summon pool); resolve Noob explicitly so roster entries never fall back to it.
	local noobTemplate = characters
		and (characters:FindFirstChild("Noob") or characters:FindFirstChild("noob"))
		or nil
	units.noob = {
		name = "Noob",
		health = 120,
		dmg = 10,
		as = 1.0,
		range = 10,
		cost = 140,
		move_speed = 10,
		model = noobTemplate,
		modelName = "Noob",
		category = "one_star",
		archetype = "bruiser",
		rangeMode = "ranged",
		defaultAbilityId = "default_burst",
	}

	-- Wave enemies: same baseline stats as Noob, different rigs from CompletedCharacterModels.
	local npcBaselineStats = {
		health = 120,
		dmg = 10,
		as = 1.0,
		range = 10,
		cost = 140,
		move_speed = 10,
		category = "one_star",
		archetype = "bruiser",
		rangeMode = "ranged",
		defaultAbilityId = "default_burst",
	}

	local function registerWaveNpcUnitId(rawId)
		local id = normalizeUnitId(rawId)
		if id == "" then
			return
		end
		local template = resolveModelForUnitId(id) or resolveWaveNpcTemplateForUnitId(id)
		local displayName = displayNameFromUnitId(id)
		units[id] = {
			name = displayName,
			displayName = displayName,
			health = npcBaselineStats.health,
			dmg = npcBaselineStats.dmg,
			as = npcBaselineStats.as,
			range = npcBaselineStats.range,
			cost = npcBaselineStats.cost,
			move_speed = npcBaselineStats.move_speed,
			model = template,
			-- Wave NPCs use their unitId as the rig name (with WAVE_NPC_MODEL_CANDIDATES handling
			-- the rare alias). Storing it lets the server resolve the right ServerStorage rig.
			modelName = (template and template.Name) or id,
			category = npcBaselineStats.category,
			archetype = npcBaselineStats.archetype,
			rangeMode = npcBaselineStats.rangeMode,
			defaultAbilityId = npcBaselineStats.defaultAbilityId,
		}
	end
	for _, npcId in ipairs({
		"bandit",
		"bandit2",
		"bandit3",
		"pirate",
		"pirate2",
		"pirate3",
		"mercenary",
		"mercenary2",
		"mercenary3",
		"gladiator",
		"gladiator2",
		"gladiator3",
	}) do
		registerWaveNpcUnitId(npcId)
	end

	-- Inventory-only fodder: same rigs as wave NPCs, very weak, no archetype (for hero level-up sacrifices).
	local EXP_FODDER_STATS = {
		health = 22,
		dmg = 3,
		as = 1.3,
		range = 6,
		cost = 22,
		move_speed = 8,
	}
	for _, npcId in ipairs({
		"bandit",
		"bandit2",
		"bandit3",
		"pirate",
		"pirate2",
		"pirate3",
		"mercenary",
		"mercenary2",
		"mercenary3",
		"gladiator",
		"gladiator2",
		"gladiator3",
	}) do
		local nid = normalizeUnitId(npcId)
		local base = units[nid]
		if base and base.model then
			local expId = "exp_" .. nid
			local disp = tostring(base.displayName or base.name or nid) .. " (Exp)"
			units[expId] = {
				name = disp,
				displayName = disp,
				health = EXP_FODDER_STATS.health,
				dmg = EXP_FODDER_STATS.dmg,
				as = EXP_FODDER_STATS.as,
				range = EXP_FODDER_STATS.range,
				cost = EXP_FODDER_STATS.cost,
				move_speed = EXP_FODDER_STATS.move_speed,
				model = base.model,
				-- EXP fodder shares the wave-NPC rig; copy that rig name for cache lookups.
				modelName = base.modelName or (base.model and base.model.Name) or nid,
				category = "exp_unit",
				archetype = nil,
				rangeMode = "ranged",
				defaultAbilityId = "default_burst",
			}
		end
	end

	return units, categories
end

local GeneratedUnits, GeneratedCategories = buildUnitsAndCategories()

local module = {
	-- Combat session money, run/quest profile money, and account EXP (via AddPlayerExp). Not refunds / dev tools.
	REWARD_PAYOUT_MULT = 0.5,
	mapModelID = mapModelID, -- asset id for "CompletedMaps" model (contains multiple maps by name)
	Maps = {
		colosseummap = {
			displayName = "Colosseum Map",
			modelName = "ColosseumMap"
		},
		castlemap = {
			displayName = "Castle Map",
			modelName = "CastleMap"
		},
		forestmap = {
			displayName = "Grasslands",
			modelName = "ForestMap"
		},
		beachmap = {
			displayName = "Setting Sail",
			modelName = "BeachMap"
		},
		bridgemap = {
			displayName = "Bridge Crossing",
			modelName = "BridgeMap"
		},
		oceanmap = {
			displayName = "Pirate Invasion!",
			modelName = "OceanMap"
		}
	},
	Categories = GeneratedCategories,
	StarLevels = {
		exp_unit = 0,
		one_star = 1,
		two_star = 2,
		three_star = 3,
		four_star = 4,
	},
	StarColors = {
		one_star = Color3.fromRGB(220, 220, 220),
		two_star = Color3.fromRGB(90, 220, 110),
		three_star = Color3.fromRGB(80, 160, 255),
		four_star = Color3.fromRGB(190, 90, 255),
	},
	Units = GeneratedUnits,
	--[[ (legacy Units table removed; kept commented for history)
		beatrixlebeau = {
			name = "Beatrix Lebeau",
			health = 380,
			dmg = 45,
			as = 1.8,
			range = 30,
			cost = 580,
			move_speed = 10,
			model = characters:WaitForChild("beatrixlebeau"),
			category = "four_star"
		},
		walterwhite = {
			name = "Walter White",
			health = 400,
			dmg = 50,
			as = 1.4,
			range = 15,
			cost = 540,
			move_speed = 11,
			model = characters:WaitForChild("walterwhite"),
			category = "four_star"
		},
		ronaldo = {
			name = "Ronaldo",
			health = 360,
			dmg = 48,
			as = 1.9,
			range = 15,
			cost = 560,
			move_speed = 16,
			model = characters:WaitForChild("ronaldo"),
			category = "four_star"
		},
		joker = {
			name = "Joker",
			health = 380,
			dmg = 52,
			as = 1.7,
			range = 15,
			cost = 560,
			move_speed = 10,
			model = characters:WaitForChild("joker"),
			category = "four_star"
		},
		omniman = {
			name = "Omniman",
			health = 520,
			dmg = 70,
			as = 1.2,
			range = 5,
			cost = 680,
			move_speed = 12,
			model = characters:WaitForChild("omniman"),
			category = "four_star"
		},
		hollowknight = {
			name = "Hollow Knight",
			health = 460,
			dmg = 60,
			as = 1.8,
			range = 5,
			cost = 620,
			move_speed = 11,
			model = characters:WaitForChild("hollowknight"),
			category = "four_star"
		},
		hatsunemiku = {
			name = "Hatsune Miku",
			health = 350,
			dmg = 45,
			as = 2.2,
			range = 15,
			cost = 560,
			move_speed = 11,
			model = characters:WaitForChild("hatsunemiku"),
			category = "four_star"
		},
		luffy = {
			name = "Luffy",
			health = 500,
			dmg = 65,
			as = 1.6,
			range = 5,
			cost = 660,
			move_speed = 11,
			model = characters:WaitForChild("luffy"),
			category = "four_star"
		},
		gojo = {
			name = "Gojo",
			health = 420,
			dmg = 70,
			as = 1.2,
			range = 20,
			cost = 680,
			move_speed = 10,
			model = characters:WaitForChild("gojo"),
			category = "four_star"
		},
		sans = {
			name = "Sans",
			health = 320,
			dmg = 55,
			as = 2.0,
			range = 20,
			cost = 660,
			move_speed = 9,
			model = characters:WaitForChild("sans"),
			category = "four_star"
		},
		ichigokurasaki = {
			name = "Ichigo Kurasaki",
			health = 480,
			dmg = 68,
			as = 1.5,
			range = 5,
			cost = 670,
			move_speed = 11,
			model = characters:WaitForChild("ichigokurasaki"),
			category = "four_star"
		},
		phoenix = {
			name = "Phoenix",
			health = 360,
			dmg = 58,
			as = 1.8,
			range = 15,
			cost = 580,
			move_speed = 11,
			model = characters:WaitForChild("phoenix"),
			category = "four_star"
		},
		power = {
			name = "Power",
			health = 470,
			dmg = 62,
			as = 1.7,
			range = 5,
			cost = 640,
			move_speed = 11,
			model = characters:WaitForChild("power"),
			category = "four_star"
		},
		cid = {
			name = "Cid",
			health = 290,
			dmg = 40,
			as = 1.6,
			range = 5,
			cost = 210,
			move_speed = 11,
			model = characters:WaitForChild("cid"),
			category = "three_star"
		},
		rimuru = {
			name = "Rimuru",
			health = 310,
			dmg = 38,
			as = 1.5,
			range = 30,
			cost = 430,
			move_speed = 10,
			model = characters:WaitForChild("rimuru"),
			category = "three_star"
		},
		jogo = {
			name = "Jogo",
			health = 260,
			dmg = 36,
			as = 1.4,
			range = 30,
			cost = 410,
			move_speed = 9,
			model = characters:WaitForChild("jogo"),
			category = "three_star"
		},
		zoro = {
			name = "Zoro",
			health = 360,
			dmg = 44,
			as = 1.5,
			range = 5,
			cost = 440,
			move_speed = 10,
			model = characters:WaitForChild("zoro"),
			category = "three_star"
		},
		nami = {
			name = "Nami",
			health = 240,
			dmg = 32,
			as = 1.7,
			range = 15,
			cost = 170,
			move_speed = 10,
			model = characters:WaitForChild("nami"),
			category = "three_star"
		},
		toji = {
			name = "Toj",
			health = 340,
			dmg = 46,
			as = 1.8,
			range = 5,
			cost = 220,
			move_speed = 12,
			model = characters:WaitForChild("toji"),
			category = "three_star"
		},
		bondrewd = {
			name = "Bondrewd",
			health = 270,
			dmg = 34,
			as = 1.4,
			range = 15,
			cost = 180,
			move_speed = 10,
			model = characters:WaitForChild("bondrewd"),
			category = "three_star"
		},
		philza = {
			name = "Philza",
			health = 260,
			dmg = 33,
			as = 1.6,
			range = 15,
			cost = 170,
			move_speed = 10,
			model = characters:WaitForChild("philza"),
			category = "three_star"
		},
		williamafton = {
			name = "William Afton",
			health = 290,
			dmg = 35,
			as = 1.3,
			range = 15,
			cost = 160,
			move_speed = 10,
			model = characters:WaitForChild("williamafton"),
			category = "three_star"
		},
		steve = {
			name = "Steve",
			health = 300,
			dmg = 38,
			as = 1.4,
			range = 5,
			cost = 180,
			move_speed = 10,
			model = characters:WaitForChild("steve"),
			category = "three_star"
		},
		tracer = {
			name = "Tracer",
			health = 200,
			dmg = 35,
			as = 4.5,
			range = 15,
			cost = 700,
			move_speed = 20,
			model = characters:WaitForChild("tracer"),
			category = "four_star"
		},
		clementine = {
			name = "Clementine",
			health = 250,
			dmg = 30,
			as = 1.6,
			range = 10,
			cost = 150,
			move_speed = 10,
			model = characters:WaitForChild("clementine"),
			category = "three_star"
		},
		leviackerman = {
			name = "Levi Ackerman",
			health = 320,
			dmg = 42,
			as = 2.1,
			range = 5,
			cost = 480,
			move_speed = 17,
			model = characters:WaitForChild("leviackerman"),
			category = "three_star"
		},
		lethalcompany = {
			name = "Lethal Company",
			health = 290,
			dmg = 32,
			as = 1.6,
			range = 5,
			cost = 400,
			move_speed = 11,
			model = characters:WaitForChild("lethalcompany"),
			category = "three_star"
		},
		thorfinn = {
			name = "Thorfinn",
			health = 310,
			dmg = 40,
			as = 2.0,
			range = 5,
			cost = 460,
			move_speed = 16,
			model = characters:WaitForChild("thorfinn"),
			category = "three_star"
		},
		jinx = {
			name = "Jinx",
			health = 250,
			dmg = 36,
			as = 1.9,
			range = 30,
			cost = 470,
			move_speed = 10,
			model = characters:WaitForChild("jinx"),
			category = "three_star"
		},
		link = {
			name = "Link",
			health = 300,
			dmg = 38,
			as = 1.6,
			range = 15,
			cost = 200,
			move_speed = 10,
			model = characters:WaitForChild("link"),
			category = "three_star"
		},
		raze = {
			name = "Raze",
			health = 280,
			dmg = 40,
			as = 1.5,
			range = 15,
			cost = 210,
			move_speed = 10,
			model = characters:WaitForChild("raze"),
			category = "three_star"
		},
		chalk = {
			name = "Chalk",
			health = 270,
			dmg = 34,
			as = 1.6,
			range = 10,
			cost = 170,
			move_speed = 10,
			model = characters:WaitForChild("chalk"),
			category = "three_star"
		},
		neon = {
			name = "Neon",
			health = 230,
			dmg = 30,
			as = 2.2,
			range = 10,
			cost = 200,
			move_speed = 18,
			model = characters:WaitForChild("neon"),
			category = "three_star"
		},
		manjirosano = {
			name = "Manjiro Sano",
			health = 200,
			dmg = 26,
			as = 1.7,
			range = 5,
			cost = 300,
			move_speed = 11,
			model = characters:WaitForChild("manjirosano"),
			category = "two_star"
		},
		goblinslayer = {
			name = "Goblin Slayer",
			health = 220,
			dmg = 30,
			as = 1.4,
			range = 5,
			cost = 140,
			move_speed = 10,
			model = characters:WaitForChild("goblinslayer"),
			category = "two_star"
		},
		natsudragneel = {
			name = "Natsu Dragneel",
			health = 210,
			dmg = 32,
			as = 1.5,
			range = 5,
			cost = 150,
			move_speed = 10,
			model = characters:WaitForChild("natsudragneel"),
			category = "two_star"
		},
		ayanokoji = {
			name = "Ayano Koji",
			health = 190,
			dmg = 22,
			as = 1.6,
			range = 10,
			cost = 110,
			move_speed = 10,
			model = characters:WaitForChild("ayanokoji"),
			category = "two_star"
		},
		aki = {
			name = "Aki",
			health = 200,
			dmg = 26,
			as = 1.5,
			range = 10,
			cost = 120,
			move_speed = 10,
			model = characters:WaitForChild("aki"),
			category = "two_star"
		},
		spy = {
			name = "Spy",
			health = 180,
			dmg = 30,
			as = 2.0,
			range = 5,
			cost = 320,
			move_speed = 11,
			model = characters:WaitForChild("spy"),
			category = "two_star"
		},
		bridget = {
			name = "Bridget",
			health = 190,
			dmg = 24,
			as = 1.7,
			range = 10,
			cost = 120,
			move_speed = 10,
			model = characters:WaitForChild("bridget"),
			category = "two_star"
		},
		gon = {
			name = "Gon",
			health = 210,
			dmg = 28,
			as = 1.6,
			range = 5,
			cost = 130,
			move_speed = 10,
			model = characters:WaitForChild("gon"),
			category = "two_star"
		},
		sage = {
			name = "Sage",
			health = 200,
			dmg = 22,
			as = 1.4,
			range = 15,
			cost = 120,
			move_speed = 17,
			model = characters:WaitForChild("sage"),
			category = "two_star"
		},
		mario = {
			name = "Mario",
			health = 200,
			dmg = 26,
			as = 1.6,
			range = 5,
			cost = 120,
			move_speed = 10,
			model = characters:WaitForChild("mario"),
			category = "two_star"
		},
		nautilus = {
			name = "Nautilus",
			health = 260,
			dmg = 28,
			as = 1.2,
			range = 5,
			cost = 130,
			move_speed = 8,
			model = characters:WaitForChild("nautilus"),
			category = "two_star"
		},
		mash = {
			name = "Mash",
			health = 240,
			dmg = 34,
			as = 1.3,
			range = 5,
			cost = 150,
			move_speed = 10,
			model = characters:WaitForChild("mash"),
			category = "two_star"
		},
		penny = {
			name = "Penny",
			health = 190,
			dmg = 20,
			as = 1.4,
			range = 10,
			cost = 260,
			move_speed = 10,
			model = characters:WaitForChild("penny"),
			category = "two_star"
		},
		flamingo = {
			name = "Flamingo",
			health = 190,
			dmg = 23,
			as = 1.5,
			range = 15,
			cost = 110,
			move_speed = 10,
			model = characters:WaitForChild("flamingo"),
			category = "two_star"
		},
		ksi = {
			name = "Ksi",
			health = 190,
			dmg = 24,
			as = 1.6,
			range = 15,
			cost = 110,
			move_speed = 10,
			model = characters:WaitForChild("ksi"),
			category = "two_star"
		},
		mayorlewis = {
			name = "Mayor Lewis",
			health = 170,
			dmg = 18,
			as = 1.3,
			range = 10,
			cost = 80,
			move_speed = 8,
			model = characters:WaitForChild("mayorlewis"),
			category = "two_star"
		},
		keemstar = {
			name = "Keemstar",
			health = 175,
			dmg = 20,
			as = 1.4,
			range = 10,
			cost = 90,
			move_speed = 10,
			model = characters:WaitForChild("keemstar"),
			category = "two_star"
		},
		edwardrichtofen = {
			name = "Edward Richtofen",
			health = 200,
			dmg = 28,
			as = 1.4,
			range = 15,
			cost = 140,
			move_speed = 10,
			model = characters:WaitForChild("edwardrichtofen"),
			category = "two_star"
		},
		wolf = {
			name = "Wolf",
			health = 210,
			dmg = 26,
			as = 1.7,
			range = 5,
			cost = 310,
			move_speed = 11,
			model = characters:WaitForChild("wolf"),
			category = "two_star"
		},
		nicorobin = {
			name = "Nico Robin",
			health = 215,
			dmg = 30,
			as = 1.5,
			range = 15,
			cost = 150,
			move_speed = 17,
			model = characters:WaitForChild("nicorobin"),
			category = "two_star"
		},
		gigachad = {
			name = "Giga Chad",
			health = 260,
			dmg = 32,
			as = 1.2,
			range = 5,
			cost = 300,
			move_speed = 9,
			model = characters:WaitForChild("gigachad"),
			category = "two_star"
		},
		edwardelric = {
			name = "Edward Elric",
			health = 210,
			dmg = 30,
			as = 1.6,
			range = 5,
			cost = 150,
			move_speed = 10,
			model = characters:WaitForChild("edwardelric"),
			category = "two_star"
		},
		getou = {
			name = "Getou",
			health = 205,
			dmg = 28,
			as = 1.4,
			range = 15,
			cost = 150,
			move_speed = 10,
			model = characters:WaitForChild("getou"),
			category = "two_star"
		},
		yuji = {
			name = "Yuji",
			health = 230,
			dmg = 30,
			as = 1.8,
			range = 5,
			cost = 330,
			move_speed = 11,
			model = characters:WaitForChild("yuji"),
			category = "two_star"
		},
		tanjiro = {
			name = "Tanjiro",
			health = 220,
			dmg = 30,
			as = 1.7,
			range = 5,
			cost = 330,
			move_speed = 10,
			model = characters:WaitForChild("tanjiro"),
			category = "two_star"
		},
		minimumwageworker = {
			name = "Minimum Wage Worker",
			health = 140,
			dmg = 14,
			as = 1.4,
			range = 5,
			cost = 60,
			move_speed = 9,
			model = characters:WaitForChild("minimumwageworker"),
			category = "one_star"
		},
		borisjohnson = {
			name = "Boris Johnson",
			health = 140,
			dmg = 15,
			as = 1.2,
			range = 10,
			cost = 60,
			move_speed = 9,
			model = characters:WaitForChild("borisjohnson"),
			category = "one_star"
		},
		sungjinwoo = {
			name = "SungJin Woo",
			health = 160,
			dmg = 20,
			as = 1.7,
			range = 5,
			cost = 90,
			move_speed = 10,
			model = characters:WaitForChild("sungjinwoo"),
			category = "one_star"
		},
		madarauchiha = {
			name = "Madara Uchiha",
			health = 165,
			dmg = 22,
			as = 1.5,
			range = 15,
			cost = 95,
			move_speed = 10,
			model = characters:WaitForChild("madarauchiha"),
			category = "one_star"
		},
		kirito = {
			name = "Kirito",
			health = 155,
			dmg = 18,
			as = 1.6,
			range = 5,
			cost = 200,
			move_speed = 10,
			model = characters:WaitForChild("kirito"),
			category = "one_star"
		},
		katanaman = {
			name = "Katana Man",
			health = 160,
			dmg = 19,
			as = 1.4,
			range = 5,
			cost = 190,
			move_speed = 10,
			model = characters:WaitForChild("katanaman"),
			category = "one_star"
		},
		doomslayer = {
			name = "Doom Slayer",
			health = 180,
			dmg = 22,
			as = 1.2,
			range = 5,
			cost = 220,
			move_speed = 10,
			model = characters:WaitForChild("doomslayer"),
			category = "one_star"
		},
		finn = {
			name = "Finn",
			health = 150,
			dmg = 16,
			as = 1.5,
			range = 5,
			cost = 70,
			move_speed = 10,
			model = characters:WaitForChild("finn"),
			category = "one_star"
		},
		evans = {
			name = "Evans",
			health = 145,
			dmg = 15,
			as = 1.5,
			range = 10,
			cost = 65,
			move_speed = 10,
			model = characters:WaitForChild("evans"),
			category = "one_star"
		},
		izaya = {
			name = "Izaya",
			health = 150,
			dmg = 17,
			as = 1.6,
			range = 10,
			cost = 75,
			move_speed = 10,
			model = characters:WaitForChild("izaya"),
			category = "one_star"
		},
		denji = {
			name = "Denji",
			health = 170,
			dmg = 20,
			as = 1.8,
			range = 5,
			cost = 230,
			move_speed = 11,
			model = characters:WaitForChild("denji"),
			category = "one_star"
		},
		goku = {
			name = "Goku",
			health = 165,
			dmg = 19,
			as = 1.6,
			range = 12,
			cost = 120,
			move_speed = 10,
			model = characters:WaitForChild("goku"),
			category = "one_star"
		},

]]--
	-- NOTE: Units/Categories are generated from the roster above.

	Abilities = {
		default_burst = {
			behavior = "burst_scaled_damage",
			multMin = 2,
			multMax = 3,
			displayName = "Mana burst",
			description = "At 100 mana, unleashes a heavy hit that scales with attack damage.",
		},
		base_money_farm = {
			behavior = "money_farm",
			amount = 140,
			displayName = "Cashout",
			description = "Generates extra in-run money when cast.",
		},
		base_assassin_burst = {
			behavior = "burst_scaled_damage",
			multMin = 3,
			multMax = 5,
			displayName = "Assassinate",
			description = "A massive burst that scales with attack damage.",
		},
		base_bruiser_sustain = {
			behavior = "bruiser_sustain",
			damageMult = 2.2,
			selfHealFrac = 0.18, -- % of max HP
			displayName = "Overwhelm",
			description = "Hits hard and heals the caster.",
		},
		base_tank_heal = {
			behavior = "tank_heal",
			selfHealFrac = 0.45, -- % of max HP
			displayName = "Fortify",
			description = "Heals the caster for a large amount.",
		},
		base_buff_round = {
			behavior = "buff_round",
			buffFrac = 0.20,
			targetCount = 2,
			displayName = "Rally",
			description = "Buffs the nearest allies' damage for the round.",
		},
		base_healer_aoe = {
			behavior = "healer_aoe",
			healFrac = 0.25, -- % of each target's max HP (uses PlacedStatsMaxHealth when upgraded)
			targetCount = 3, -- nearest other allies (healer also heals self when healSelf is true)
			healSelf = true,
			displayName = "Mend",
			description = "Heals you and the three nearest allies for 25% of each unit's max health.",
		},
	},

	-- Limits for player-placed allies (Workspace.AlliedHeroes); see PlaceUnitServer.
	PlacementRules = {
		maxUnitsPerPlayer = 20,
		maxCopiesPerUnitId = 4,
	},

	--[[
		Battle tutorial: separate published place with GameInfo.mode = "tutorial".
		Map lives in Workspace (e.g. TutorialMap with AllyArea / EnemyArea); RuntimeBootstrap skips catalog map mount when placeRole = "tutorial".
		Lobby redirect: BattleTutorialLobbyRedirect when tutorialPlaceId > 0.
	]]
	BattleTutorial = {
		tutorialPlaceId = 101795303171103,
		returnLobbyPlaceId = 114631315585399,
		-- Player humanoid after cosmetics / cutscene unlock (not StarterPlayer-derived).
		playerWalkSpeed = 60,
		playerJumpHeight = 14.4,
	},

	--[[
		StoryMode — worlds, acts, boss waves, hardcore tuning, first-clear bonuses.

		Saved progress shape (recommended for PlayerProfile / DataStores):
		  profile.story = {
		    worlds = {
		      [worldId] = {
		        acts = {
		          [actNumber] = { normal = boolean, hardcore = boolean },
		          ...
		        },
		      },
		    },
		  }
		Helpers below accept `progress` = profile.story or nil.

		WaveServer difficulty: use StoryGetWaveDifficultyMultiplier(worldId, actNumber, waveNumber, hardcore)
		as the numeric `difficulty` argument (baseline multiplier × act × optional boss buff).
	]]
	StoryMode = {
		-- Published story gameplay place (separate simulation).
		storyPlaceId = 89708614669753,

		actsPerWorld = 5,

		hardcore = {
			difficultyMultiplier = 2,
			rewardMultiplier = 2,
		},

		-- First-clear bonus EXP only (run-completion XP from damage/waves is unchanged).
		firstClearExpMultiplier = 10,

		-- Ordered list; `order` must be 1..N with no gaps for unlock helpers.
		Worlds = {
			{
				id = "grasslands",
				order = 1,
				displayName = "Grasslands",
				subtitle = "Verdant frontier",
				themeColor = Color3.fromRGB(90, 220, 110),
				worldImage = "rbxassetid://118961618593530", -- optional rbxassetid://... (UI can fallback to existing image)
				mapKey = "forestmap",
				acts = {
					{
						act = 1,
						waves = 6,
						baseDifficulty = 1,
						rewardsSummary = "Coins, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.25,
						},
						firstClearBonus = { money = 450, gems = 5, exp = 300 },
						firstClearBonusHardcore = { money = 900, gems = 10, exp = 600 },
					},
					{
						act = 2,
						waves = 8,
						baseDifficulty = 1,
						rewardsSummary = "Coins, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.3,
						},
						firstClearBonus = { money = 600, gems = 10, exp = 413 },
						firstClearBonusHardcore = { money = 1200, gems = 20, exp = 825 },
					},
					{
						act = 3,
						waves = 10,
						baseDifficulty = 2,
						rewardsSummary = "Coins, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.35,
						},
						firstClearBonus = { money = 780, gems = 10, exp = 525 },
						firstClearBonusHardcore = { money = 1560, gems = 20, exp = 1050 },
					},
					{
						act = 4,
						waves = 12,
						baseDifficulty = 3,
						rewardsSummary = "Coins, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.4,
						},
						firstClearBonus = { money = 1020, gems = 15, exp = 675 },
						firstClearBonusHardcore = { money = 2040, gems = 30, exp = 1350 },
					},
					{
						act = 5,
						waves = 14,
						baseDifficulty = 3,
						rewardsSummary = "Coins, Exp",
						-- Example: dedicated boss unit (larger model); story place should spawn `unitId` with scaled stats.
						boss = {
							style = "boss_unit",
							unitId = "noob",
							modelScale = 1.65,
							statMultiplier = 1.45,
						},
						firstClearBonus = { money = 1500, gems = 25, exp = 975 },
						firstClearBonusHardcore = { money = 3000, gems = 50, exp = 1950 },
					},
				},
			},
			{
				id = "setting_sail",
				order = 2,
				displayName = "Setting Sail",
				subtitle = "Coastal currents",
				themeColor = Color3.fromRGB(80, 160, 255),
				worldImage = "rbxassetid://124723922725774",
				mapKey = "beachmap",
				acts = {
					{
						act = 1,
						waves = 8,
						baseDifficulty = 2,
						rewardsSummary = "Coins, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.28,
						},
						firstClearBonus = { money = 660, gems = 10, exp = 450 },
						firstClearBonusHardcore = { money = 1320, gems = 20, exp = 900 },
					},
					{
						act = 2,
						waves = 10,
						baseDifficulty = 2,
						rewardsSummary = "Coins, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.33,
						},
						firstClearBonus = { money = 900, gems = 15, exp = 600 },
						firstClearBonusHardcore = { money = 1800, gems = 30, exp = 1200 },
					},
					{
						act = 3,
						waves = 12,
						baseDifficulty = 3,
						rewardsSummary = "Coins, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.38,
						},
						firstClearBonus = { money = 1140, gems = 15, exp = 750 },
						firstClearBonusHardcore = { money = 2280, gems = 30, exp = 1500 },
					},
					{
						act = 4,
						waves = 16,
						baseDifficulty = 4,
						rewardsSummary = "Coins, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.42,
						},
						firstClearBonus = { money = 1440, gems = 20, exp = 938 },
						firstClearBonusHardcore = { money = 2880, gems = 40, exp = 1875 },
					},
					{
						act = 5,
						waves = 20,
						baseDifficulty = 5,
						rewardsSummary = "Coins, Exp",
						boss = {
							style = "boss_unit",
							unitId = "noob",
							modelScale = 1.65,
							statMultiplier = 1.48,
						},
						firstClearBonus = { money = 1860, gems = 30, exp = 1200 },
						firstClearBonusHardcore = { money = 3720, gems = 60, exp = 2400 },
					},
				},
			},
			{
				id = "pirate_invasion",
				order = 3,
				displayName = "Pirate Invasion!",
				subtitle = "Defend the ship",
				themeColor = Color3.fromRGB(114, 213, 255),
				worldImage = "rbxassetid://112792531040468",
				mapKey = "oceanmap",
				acts = {
					{
						act = 1,
						waves = 8,
						baseDifficulty = 3,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.34,
						},
						firstClearBonus = { money = 960, gems = 15, exp = 638 },
						firstClearBonusHardcore = { money = 1920, gems = 30, exp = 1275 },
					},
					{
						act = 2,
						waves = 10,
						baseDifficulty = 3,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.38,
						},
						firstClearBonus = { money = 1260, gems = 20, exp = 825 },
						firstClearBonusHardcore = { money = 2520, gems = 40, exp = 1650 },
					},
					{
						act = 3,
						waves = 12,
						baseDifficulty = 4,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.42,
						},
						firstClearBonus = { money = 1560, gems = 25, exp = 1013 },
						firstClearBonusHardcore = { money = 3120, gems = 50, exp = 2025 },
					},
					{
						act = 4,
						waves = 16,
						baseDifficulty = 5,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.46,
						},
						firstClearBonus = { money = 1980, gems = 30, exp = 1275 },
						firstClearBonusHardcore = { money = 3960, gems = 60, exp = 2550 },
					},
					{
						act = 5,
						waves = 20,
						baseDifficulty = 6,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "boss_unit",
							unitId = "noob",
							modelScale = 1.7,
							statMultiplier = 1.52,
						},
						firstClearBonus = { money = 2460, gems = 40, exp = 1575 },
						firstClearBonusHardcore = { money = 4920, gems = 80, exp = 3150 },
					},
				},
			},
			{
				id = "ocean_walkway",
				order = 4,
				displayName = "Ocean Walkway",
				subtitle = "Prove you're worthy",
				themeColor = Color3.fromRGB(210, 210, 126),
				worldImage = "rbxassetid://122578934855402",
				mapKey = "bridgemap",
				acts = {
					{
						act = 1,
						waves = 10,
						baseDifficulty = 4,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.4,
						},
						firstClearBonus = { money = 1260, gems = 20, exp = 825 },
						firstClearBonusHardcore = { money = 2520, gems = 40, exp = 1650 },
					},
					{
						act = 2,
						waves = 12,
						baseDifficulty = 4,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.44,
						},
						firstClearBonus = { money = 1560, gems = 25, exp = 1050 },
						firstClearBonusHardcore = { money = 3120, gems = 50, exp = 2100 },
					},
					{
						act = 3,
						waves = 14,
						baseDifficulty = 5,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.48,
						},
						firstClearBonus = { money = 1920, gems = 30, exp = 1275 },
						firstClearBonusHardcore = { money = 3840, gems = 60, exp = 2550 },
					},
					{
						act = 4,
						waves = 18,
						baseDifficulty = 6,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.52,
						},
						firstClearBonus = { money = 2340, gems = 35, exp = 1538 },
						firstClearBonusHardcore = { money = 4680, gems = 70, exp = 3075 },
					},
					{
						act = 5,
						waves = 22,
						baseDifficulty = 7,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "boss_unit",
							unitId = "noob",
							modelScale = 1.72,
							statMultiplier = 1.55,
						},
						firstClearBonus = { money = 2880, gems = 45, exp = 1875 },
						firstClearBonusHardcore = { money = 5760, gems = 90, exp = 3750 },
					},
				},
			},
			{
				id = "colosseum",
				order = 5,
				displayName = "Colosseum",
				subtitle = "Prove your strength.",
				themeColor = Color3.fromRGB(255, 150, 70),
				worldImage = "rbxassetid://72009997051659",
				mapKey = "colosseummap",
				acts = {
					{
						act = 1,
						waves = 12,
						baseDifficulty = 9,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.52,
						},
						firstClearBonus = { money = 1560, gems = 25, exp = 1050 },
						firstClearBonusHardcore = { money = 3120, gems = 50, exp = 2100 },
					},
					{
						act = 2,
						waves = 14,
						baseDifficulty = 11,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.56,
						},
						firstClearBonus = { money = 1920, gems = 30, exp = 1275 },
						firstClearBonusHardcore = { money = 3840, gems = 60, exp = 2550 },
					},
					{
						act = 3,
						waves = 16,
						baseDifficulty = 13,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.6,
						},
						firstClearBonus = { money = 2340, gems = 35, exp = 1538 },
						firstClearBonusHardcore = { money = 4680, gems = 70, exp = 3075 },
					},
					{
						act = 4,
						waves = 20,
						baseDifficulty = 16,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "stat_buff",
							statMultiplier = 1.64,
						},
						firstClearBonus = { money = 2760, gems = 40, exp = 1800 },
						firstClearBonusHardcore = { money = 5520, gems = 80, exp = 3600 },
					},
					{
						act = 5,
						waves = 24,
						baseDifficulty = 20,
						rewardsSummary = "Coins, Gems, Exp",
						boss = {
							style = "boss_unit",
							unitId = "noob",
							modelScale = 1.75,
							statMultiplier = 1.68,
						},
						firstClearBonus = { money = 3300, gems = 50, exp = 2175 },
						firstClearBonusHardcore = { money = 6600, gems = 100, exp = 4350 },
					},
				},
			},
		},
	},

	Mutations = {
		holographic = {
			displayName = "Holographic",
			statMultipliers = {
				health = 1.25,
				dmg = 1.25,
				as = 1.06,
				range = 1.03,
				move_speed = 1.25,
			},
			ui = {
				gradient = { "F8FAFC", "DDEBFF", "E9D5FF", "FFE4E6", "E0F2FE", "F8FAFC" },
				animation = {
					type = "slow_shimmer_drift",
					gradientRotation = 25,
					rotateSpeed = 6,
					offsetSweep = true,
					sweepDuration = 2.4,
					sweepDirection = "horizontal",
					sweepBrightness = 0.18,
					sweepWidth = 0.12,
				},
			},
			chanceDenominator = 100, -- 1/100
		},
		ethereal = {
			displayName = "Ethereal",
			statMultipliers = {
				health = 1.5,
				dmg = 1.5,
				as = 1.08,
				range = 1.04,
				move_speed = 1.5,
			},
			ui = {
				gradient = { "EDE9FE", "C4B5FD", "A78BFA", "DDD6FE" },
				animation = {
					type = "soft_float",
					gradientRotation = 90,
					rotateSpeed = 2,
					offsetSweep = true,
					sweepDuration = 3.2,
					sweepDirection = "vertical",
					sweepBrightness = 0.10,
					sweepWidth = 0.18,
				},
			},
			chanceDenominator = 150, -- 1/150
		},
		radiant = {
			displayName = "Radiant",
			statMultipliers = {
				health = 1.75,
				dmg = 1.75,
				as = 1.10,
				range = 1.05,
				move_speed = 1.75,
			},
			ui = {
				gradient = { "FFFFFF", "FFF3A0", "FFD54F", "FFFFFF" },
				animation = {
					type = "holy_shine_pulse",
					gradientRotation = 35,
					rotateSpeed = 4,
					offsetSweep = true,
					sweepDuration = 1.8,
					sweepDirection = "diagonal",
					sweepBrightness = 0.26,
					sweepWidth = 0.10,
				},
			},
			chanceDenominator = 200, -- 1/200
		},
		void = {
			displayName = "Void",
			statMultipliers = {
				health = 2.0,
				dmg = 2.0,
				as = 1.12,
				range = 1.06,
				move_speed = 2.0,
			},
			ui = {
				gradient = { "0F0F1A", "3B0A45", "7B2CBF", "C77DFF" },
				animation = {
					type = "slow_ominous_rotation",
					gradientRotation = 0,
					rotateSpeed = 10,
					offsetSweep = true,
					sweepDuration = 4.5,
					sweepDirection = "horizontal",
					sweepBrightness = 0.08,
					sweepWidth = 0.14,
				},
			},
			chanceDenominator = 250, -- 1/250
		},
		prismatic = {
			displayName = "Prismatic",
			statMultipliers = {
				health = 3.0,
				dmg = 3.0,
				as = 1.15,
				range = 1.08,
				move_speed = 3.0,
			},
			ui = {
				gradient = { "FF4D4D", "FF9F1C", "FFE66D", "2EC4B6", "3A86FF", "8338EC" },
				animation = {
					type = "premium_rainbow_cycle",
					gradientRotation = 30,
					rotateSpeed = 12,
					offsetSweep = true,
					sweepDuration = 1.4,
					sweepDirection = "diagonal",
					sweepBrightness = 0.22,
					sweepWidth = 0.09,
				},
			},
			chanceDenominator = 500, -- 1/500
		},
	},
}

-- ---------------------------------------------------------------------------
-- Story mode helpers (config + progression rules; UI / Story place consume)
-- ---------------------------------------------------------------------------

function module.NormalizeUnitId(id)
	return normalizeUnitId(id)
end

function module.IsExpUnitId(unitId)
	local u = unitId and module.Units[unitId]
	return u ~= nil and u.category == "exp_unit"
end

function module.StoryGetConfig()
	return module.StoryMode
end

function module.StoryGetWorlds()
	local sm = module.StoryMode
	if not sm or type(sm.Worlds) ~= "table" then
		return {}
	end
	return sm.Worlds
end

function module.StoryFindWorld(worldId)
	if type(worldId) ~= "string" or worldId == "" then
		return nil
	end
	for _, w in ipairs(module.StoryGetWorlds()) do
		if w.id == worldId then
			return w
		end
	end
	return nil
end

function module.StoryGetAct(worldId, actNumber)
	local w = module.StoryFindWorld(worldId)
	if not w or type(w.acts) ~= "table" then
		return nil
	end
	local n = math.floor(tonumber(actNumber) or 0)
	if n < 1 or n > #w.acts then
		return nil
	end
	return w.acts[n], w
end

local function storyGetActFlags(progress, worldId, actNumber)
	local root = progress and progress.worlds and progress.worlds[worldId]
	local row = root and root.acts and root.acts[actNumber]
	local n = row and row.normal == true
	local h = row and row.hardcore == true
	return n, h
end

function module.StoryActIsComplete(progress, worldId, actNumber)
	local n, h = storyGetActFlags(progress, worldId, actNumber)
	return n or h
end

function module.StoryActModeComplete(progress, worldId, actNumber, hardcore)
	local n, h = storyGetActFlags(progress, worldId, actNumber)
	return hardcore and h or (not hardcore and n)
end

function module.StoryWorldFullyComplete(progress, worldId)
	local w = module.StoryFindWorld(worldId)
	if not w or type(w.acts) ~= "table" then
		return false
	end
	for i = 1, #w.acts do
		if not module.StoryActIsComplete(progress, worldId, i) then
			return false
		end
	end
	return true
end

function module.StoryWorldUnlocked(progress, worldId)
	local worlds = module.StoryGetWorlds()
	local target = module.StoryFindWorld(worldId)
	if not target then
		return false
	end
	local ord = tonumber(target.order) or 999
	if ord <= 1 then
		return true
	end
	for _, w in ipairs(worlds) do
		local o = tonumber(w.order) or 999
		if o == ord - 1 then
			return module.StoryWorldFullyComplete(progress, w.id)
		end
	end
	return false
end

function module.StoryActUnlocked(progress, worldId, actNumber)
	if not module.StoryWorldUnlocked(progress, worldId) then
		return false
	end
	local n = math.floor(tonumber(actNumber) or 0)
	if n == 1 then
		return true
	end
	return module.StoryActIsComplete(progress, worldId, n - 1)
end

-- Milestones for UI (e.g. 2/10): per-act normal clear + per-act hardcore clear.
function module.StoryWorldMilestoneCount(progress, worldId)
	local w = module.StoryFindWorld(worldId)
	if not w or type(w.acts) ~= "table" then
		return 0, 0
	end
	local done = 0
	local max = #w.acts * 2
	for i = 1, #w.acts do
		local n, h = storyGetActFlags(progress, worldId, i)
		if n then
			done += 1
		end
		if h then
			done += 1
		end
	end
	return done, max
end

function module.StoryGetHardcoreMultipliers()
	local sm = module.StoryMode
	local hc = sm and sm.hardcore
	local dm = (hc and tonumber(hc.difficultyMultiplier)) or 2
	local rm = (hc and tonumber(hc.rewardMultiplier)) or 2
	return math.max(0.01, dm), math.max(0.01, rm)
end

function module.StoryGetWaveCount(worldId, actNumber)
	local act = module.StoryGetAct(worldId, actNumber)
	return act and tonumber(act.waves) or nil
end

function module.StoryIsBossWave(worldId, actNumber, waveNumber)
	local wc = module.StoryGetWaveCount(worldId, actNumber)
	if not wc then
		return false
	end
	return math.floor(tonumber(waveNumber) or 0) == wc
end

function module.StoryGetBossConfig(worldId, actNumber)
	local act = module.StoryGetAct(worldId, actNumber)
	return act and act.boss
end

-- Numeric difficulty for WaveServer / scaling (includes hardcore; optional boss wave buff).
function module.StoryGetWaveDifficultyMultiplier(worldId, actNumber, waveNumber, hardcore)
	local act = module.StoryGetAct(worldId, actNumber)
	if not act then
		return 1
	end
	local base = math.max(0.01, tonumber(act.baseDifficulty) or 1)
	if hardcore then
		local dm = select(1, module.StoryGetHardcoreMultipliers())
		base *= dm
	end
	if module.StoryIsBossWave(worldId, actNumber, waveNumber) then
		local boss = act.boss
		if type(boss) == "table" and boss.style == "stat_buff" then
			local m = tonumber(boss.statMultiplier) or 1
			base *= math.max(0.01, m)
		elseif type(boss) == "table" and boss.style == "boss_unit" then
			local m = tonumber(boss.statMultiplier) or 1
			base *= math.max(0.01, m)
		end
	end
	return base
end

function module.StoryGetRewardMultiplier(hardcore)
	if hardcore then
		return select(2, module.StoryGetHardcoreMultipliers())
	end
	return 1
end

function module.StoryGetFirstClearExpMultiplier()
	local sm = module.StoryMode
	local m = tonumber(sm and sm.firstClearExpMultiplier)
	if (not m or m <= 0) and sm then
		m = tonumber(sm.accountExpMultiplier)
	end
	if not m or m <= 0 then
		return 1
	end
	return m
end

function module.StoryGetFirstClearBonus(worldId, actNumber, hardcore)
	local act = module.StoryGetAct(worldId, actNumber)
	if not act then
		return nil
	end
	if hardcore then
		local b = act.firstClearBonusHardcore
		if type(b) == "table" then
			return b
		end
		local base = act.firstClearBonus
		if type(base) ~= "table" then
			return nil
		end
		local rm = select(2, module.StoryGetHardcoreMultipliers())
		return {
			money = math.floor((tonumber(base.money) or 0) * rm + 0.5),
			gems = math.floor((tonumber(base.gems) or 0) * rm + 0.5),
			exp = math.floor((tonumber(base.exp) or 0) * rm + 0.5),
		}
	end
	return act.firstClearBonus
end

-- Single payload for teleport / GameInfo / story simulation bootstrap.
function module.StoryGetRunContext(worldId, actNumber, hardcore)
	local act, world = module.StoryGetAct(worldId, actNumber)
	if not act or not world then
		return nil
	end
	local sm = module.StoryMode
	return {
		storyPlaceId = sm and sm.storyPlaceId,
		worldId = world.id,
		worldOrder = world.order,
		displayName = world.displayName,
		subtitle = world.subtitle,
		mapKey = world.mapKey,
		actNumber = act.act,
		waves = act.waves,
		baseDifficulty = act.baseDifficulty,
		hardcore = hardcore == true,
		rewardMultiplier = module.StoryGetRewardMultiplier(hardcore == true),
		rewardsSummary = act.rewardsSummary,
		boss = act.boss,
		firstClearBonus = module.StoryGetFirstClearBonus(worldId, actNumber, false),
		firstClearBonusHardcore = module.StoryGetFirstClearBonus(worldId, actNumber, true),
	}
end

-- Backwards compatibility: older code/data calls these "Varieties".
module.Varieties = module.Mutations

-- Legacy per-wave round-win cash (used before telescoping marginal payouts).
function module.ComputeLegacyWaveClearBonus(wave, difficulty)
	local w = math.max(1, math.floor((tonumber(wave) or 1) + 0.5))
	local d = math.max(0.01, (typeof(difficulty) == "number") and difficulty or 1)
	return math.floor(200 + w * 60 + math.sqrt(d) * 30 + 0.5)
end

-- Legacy run-end profile reward scaling used by Story/Infinite summaries.
function module.ComputeLegacyRunReward(waveReached, difficulty)
	local w = math.max(1, math.floor((tonumber(waveReached) or 1) + 0.5))
	local d = (typeof(difficulty) == "number" and difficulty > 0) and difficulty or 1
	local base = 40 * (w ^ 1.35) + 15 * w * d
	return math.floor(base + 0.5)
end

function module.ApplyRewardPayoutMult(amount)
	local n = tonumber(amount) or 0
	if n < 0 then
		return math.floor(n + 0.5)
	end
	local m = tonumber(module.REWARD_PAYOUT_MULT) or 1
	if m <= 0 then
		return 0
	end
	return math.floor(n * m + 0.5)
end

-- Gem rewards from quests, dailies (on grant), story first-clear bonuses, etc. (not shop/refunds.)
module.GEM_REWARD_PAYOUT_MULT = 1.0

function module.ApplyGemRewardPayoutMult(amount)
	local n = math.floor((tonumber(amount) or 0) + 0.5)
	if n <= 0 then
		return n
	end
	local m = tonumber(module.GEM_REWARD_PAYOUT_MULT) or 1
	if m <= 0 then
		return 0
	end
	return math.max(0, math.floor(n * m + 0.5))
end

return module
