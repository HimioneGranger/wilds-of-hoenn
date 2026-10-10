-- Run: lua tests/shiny_unit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. tostring(msg) .. "\n")
  else
    print("ok  " .. tostring(msg))
  end
end
local function eq(a, b, msg)
  check(a == b, string.format("%s (got %s expected %s)", msg, tostring(a), tostring(b)))
end

local engineIsShiny -- real bxor-based reference check, mirrors pokemon.lua:1397
local function realIsShiny(personality, otId, otSecretId)
  local function xor16(a, b)
    a, b = a % 65536, b % 65536
    local result, bitval = 0, 1
    for _ = 1, 16 do
      local abit, bbit = a % 2, b % 2
      if abit ~= bbit then result = result + bitval end
      a, b = (a - abit) / 2, (b - bbit) / 2
      bitval = bitval * 2
    end
    return result
  end
  local hi = math.floor(personality / 65536) % 65536
  local lo = personality % 65536
  local value = xor16(xor16(otId, otSecretId), xor16(hi, lo))
  return value < 8
end
engineIsShiny = realIsShiny

local fakeEngine = {}
local modules = {}
local V = { path = "." }
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  if name == "engine_patch" then
    modules[name] = fakeEngine
    return fakeEngine
  end
  local chunk = assert(loadfile("lib/" .. name .. ".lua"))
  local value = chunk(V)
  modules[name] = value
  return value
end

fakeEngine.trainerIds = function() return { otId = 1000, otSecretId = 2000 } end
fakeEngine.isShiny = function(p, otId, otSecretId) return realIsShiny(p, otId, otSecretId) end
fakeEngine.genderOf = function(_species, _p) return 0 end

local Shiny = V.require("shiny")

-- ------- xor16 correctness against known values
eq(Shiny._xor16(0, 0), 0, "xor16(0,0)")
eq(Shiny._xor16(0xFFFF, 0xFFFF), 0, "xor16(ffff,ffff)")
eq(Shiny._xor16(0xFF00, 0x00FF), 0xFFFF, "xor16(ff00,00ff)")
eq(Shiny._xor16(0x1234, 0x5678), 0x444C, "xor16(1234,5678) matches a known value")

-- ------- boostedPersonality always returns a personality that is
-- genuinely shiny for the given trainer, and keeps nature + gender
math.randomseed(1)
for trial = 1, 20 do
  local otId, otSecretId = 1000 * trial, 2000 + trial
  local base = math.floor(math.random() * 4294967296)
  local wantGender = trial % 3 -- fake gender tag, just needs to round-trip
  local genderFn = function(p)
    -- deterministic pure function of p for this test -- real callers pass
    -- EnginePatch.genderOf(species, p)
    return (p + trial) % 3
  end
  -- Make `base` actually have gender wantGender for a fair nature/gender test.
  while genderFn(base) ~= wantGender do base = base + 1 end
  local p = Shiny.boostedPersonality(base, otId, otSecretId, genderFn, 256)
  check(p ~= nil, "boostedPersonality finds a match (trial " .. trial .. ")")
  if p then
    check(realIsShiny(p, otId, otSecretId), "result is genuinely shiny (trial " .. trial .. ")")
    eq(p % 25, base % 25, "nature preserved (trial " .. trial .. ")")
    eq(genderFn(p), wantGender, "gender preserved (trial " .. trial .. ")")
  end
end

-- ------- boostedPersonality with no genderFn only has to keep nature
math.randomseed(2)
local baseNoGender = math.floor(math.random() * 4294967296)
local p2 = Shiny.boostedPersonality(baseNoGender, 42, 99, nil, 256)
check(p2 ~= nil, "boostedPersonality works without a genderFn")
if p2 then
  check(realIsShiny(p2, 42, 99), "no-gender result is genuinely shiny")
  eq(p2 % 25, baseNoGender % 25, "no-gender result preserves nature")
end

-- ------- rollForEncounter: without a chain, only the engine's own shiny
fakeEngine.isShiny = function(_p, _otId, _otSecretId) return true end
local enc = { species = 25, level = 10, personality = 1 }
Shiny.rollForEncounter(enc, nil)
eq(enc.shiny, true, "an engine-shiny roll stays shiny")
eq(enc.personality, 1, "...untouched")
fakeEngine.isShiny = function(_p, _otId, _otSecretId) return false end
enc = { species = 25, level = 10, personality = 1 }
Shiny.rollForEncounter(enc, nil)
eq(enc.shiny, false, "no chain: a non-shiny roll stays non-shiny (native odds only)")
eq(enc.personality, 1, "...untouched")
eq(enc.ivs, nil, "...and no IVs are added")

-- ------- rollForEncounter: a chain's shiny chance
fakeEngine.isShiny = function(p, otId, otSecretId) return realIsShiny(p, otId, otSecretId) end
fakeEngine.trainerIds = function() return { otId = 7, otSecretId = 11 } end
math.randomseed(3)
enc = { species = 25, level = 10, personality = 12345 }
local nature = enc.personality % 25
Shiny.rollForEncounter(enc, { shiny = 1, perfectIvs = 0 }, function(a, b)
  if a == nil then return 0 end -- the chance draw: always hits
  return math.random(a, b)
end)
eq(enc.shiny, true, "a chain's chance that hits makes it shiny")
eq(enc.personality % 25, nature, "...keeping its nature")
check(realIsShiny(enc.personality, 7, 11), "...genuinely shiny for this trainer")
eq(enc.ivs, nil, "no perfect stats asked: IVs left to the engine")

fakeEngine.isShiny = function(_p, _otId, _otSecretId) return false end
enc = { species = 25, level = 10, personality = 999 }
Shiny.rollForEncounter(enc, { shiny = 0.5, perfectIvs = 0 }, function(a, b)
  if a == nil then return 0.9 end -- misses
  return math.random(a, b)
end)
eq(enc.shiny, false, "a chance that misses leaves it alone")
eq(enc.personality, 999, "...personality untouched")

-- ------- the stat floor
local function count31(ivs)
  local n = 0
  for _, k in ipairs(Shiny.STATS) do if ivs[k] == 31 then n = n + 1 end end
  return n
end
local zero = function(a, b) if a == nil then return 0.9 end return a end -- lowest IVs, no shuffle
enc = { species = 25, level = 10, personality = 5 }
Shiny.ivFloor(enc, 2, zero)
check(type(enc.ivs) == "table", "an encounter without IVs gets them rolled the engine's way")
eq(count31(enc.ivs), 2, "...with 2 perfect stats")
for _, k in ipairs(Shiny.STATS) do
  check(enc.ivs[k] >= 0 and enc.ivs[k] <= 31, "IV " .. k .. " in 0..31")
end
enc = { ivs = { hp = 4, atk = 5, def = 6, spe = 7, spa = 8, spd = 9 } }
Shiny.ivFloor(enc, 3, math.random)
eq(count31(enc.ivs), 3, "3 perfect stats on given IVs")
local kept = 0
for k, v in pairs({ hp = 4, atk = 5, def = 6, spe = 7, spa = 8, spd = 9 }) do
  if enc.ivs[k] == v then kept = kept + 1 end
end
eq(kept, 3, "...the other 3 kept as they were")
enc = { ivs = { hp = 1 } }
Shiny.ivFloor(enc, 0, math.random)
eq(enc.ivs.hp, 1, "0 perfect stats changes nothing")
enc = {}
Shiny.ivFloor(enc, 9, math.random)
eq(count31(enc.ivs), 6, "never more than all six")
local seen = {}
for _ = 1, 200 do
  local e = { ivs = { hp = 0, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 } }
  Shiny.ivFloor(e, 1, math.random)
  for k, v in pairs(e.ivs) do if v == 31 then seen[k] = true end end
end
local all = true
for _, k in ipairs(Shiny.STATS) do if not seen[k] then all = false end end
check(all, "the perfect stat can land on any of the six")

-- rollForEncounter applies the floor with the chain's bonus
fakeEngine.isShiny = function() return false end
enc = { species = 25, level = 10, personality = 77 }
Shiny.rollForEncounter(enc, { shiny = 0, perfectIvs = 1 })
eq(count31(enc.ivs) >= 1, true, "rollForEncounter gives the chain's perfect stats")

print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("shiny_unit_test: all passed")
