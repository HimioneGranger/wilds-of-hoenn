-- Shiny chains end to end on the REAL engine and mod Loader: National Dex Gen 3,
-- Modern Spawns and Wilds of Hoenn loaded together (tests/modkit), a chain built
-- through Modern Spawns' exports, then a classic step encounter run through the
-- real `encounter.species` hook chain -- Modern Spawns (priority -100) swaps in the
-- chained species, Wilds (above it) gives it the chain's perfect stats.
--
-- Run from inside a gen1recomp checkout with Pokemon FireRed imported and
-- mods/national_dex_gen3, mods/modern_spawns and mods/wilds_of_hoenn linked:
--   cd ../gen1recomp
--   luajit mods/wilds_of_hoenn/tests/shiny_chain_test.lua
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

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end
if not (exists("mods/modern_spawns/manifest.json") and exists("mods/national_dex_gen3/manifest.json")) then
  print("skip: mods/modern_spawns and mods/national_dex_gen3 must be linked into this checkout")
  print("shiny_chain_test: skipped")
  return
end

love = love or require("tests.love_stub")
local GameVersion = require("src.core.GameVersion")
local Runtime = require("src.mods.Runtime")
local T = require("tests.modkit")
local MsHelpers = dofile("mods/modern_spawns/tests/_helpers.lua")
local okData, data = pcall(MsHelpers.gen3Data)
if not okData then
  print("skip: FireRed is not imported (" .. tostring(data) .. ")")
  print("shiny_chain_test: skipped")
  return
end

GameVersion.set("firered")
local run = T.sdk.loadMods({ "mods/national_dex_gen3", "mods/modern_spawns", "mods/wilds_of_hoenn" },
  { data = data, generation = 3 })
check(#run.errors == 0, "the three mods load (" .. tostring(run.errors[1]) .. ")")
local loader = run.loader
loader.modSave.modern_spawns = { seed = "HOENN" }
loader.modOptions.modern_spawns = { enabled = "on", max_generation = "9" }
local ms = loader.exports.modern_spawns
check(ms and ms.isActive(), "Modern Spawns is active")

local P = data.gen3Pokemon
local mapId = "FR_ROUTE_1"
local slot = data.gen3Encounters[mapId].land.slots[1]
local function step()
  return Runtime.call("encounter.species", function(e) return e end,
    { species = P.keyName(slot.species), speciesId = slot.species, level = slot.minLevel, personality = 12345 },
    { mapId = mapId, terrain = "land", rng = function() return 4321 end })
end

local first = step()
-- the engine's number (speciesId; species may be the key name, as Wilds' own hook reads it)
local function idOf(e) return e and (tonumber(e.speciesId) or tonumber(e.species)) end
local species = idOf(first)
check(species ~= nil, "a Route 1 step encounter (species " .. tostring(species) .. ")")
check(first and first.ivs == nil, "no chain yet: Wilds leaves its IVs to the engine")

for _ = 1, 40 do ms.chainRecord(species, "win") end
check(ms.chain() and ms.chain().count == 40, "forty in a row (through Modern Spawns' export)")

local chained = step()
check(idOf(chained) == species, "the step encounter is the chained species")
local perfect = 0
for _, v in pairs(chained and chained.ivs or {}) do if v == 31 then perfect = perfect + 1 end end
check(perfect >= 3, "...with the chain's three perfect stats (" .. perfect .. ")")
check(chained and chained.personality ~= nil, "...and a personality (made shiny when the chance hits)")

loader.events:emit("world.blacked_out", {})
check(ms.chain() == nil, "blacking out ends the chain")
local after = step()
check(after and after.ivs == nil, "...and the bonus with it")

run.release()
print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("shiny_chain_test: all passed")
