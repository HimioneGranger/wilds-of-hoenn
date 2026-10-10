-- Classic Encounters (options.lua `classic_enc`, main.lua's encounter.roll wrap) against
-- the REAL engine: loads wilds_of_hoenn through gen1recomp's real mod Loader
-- (tests/modkit) and runs the engine's own Encounters.onStep -- the call
-- player.lua makes after every finished step -- with the option on and off.
--
-- Run from inside a gen1recomp checkout with this mod linked at mods/wilds_of_hoenn:
--   cd ../gen1recomp
--   luajit mods/wilds_of_hoenn/tests/classic_encounters_test.lua
--
-- ROM-free: the step roll itself (encounter_rules/*.step) is replaced with one that
-- always finds a Treecko, and the species-name lookups are stubbed, so what is under
-- test is only the hook path between the step and the encounter. The Loader reads the
-- options saved on this machine, so the test sets the option itself every time.
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

love = love or require("tests.love_stub")
local GameVersion = require("src.core.GameVersion")
local T = require("tests.modkit")

local steps = 0
for _, key in ipairs({ "rse", "rs", "frlg" }) do
  package.loaded["src.core.game3.encounter_rules." .. key] = { bind = function()
    return {
      resetRateModifiers = function() end,
      step = function() steps = steps + 1 return { species = 277, level = 5 } end,
    }
  end }
end
local Pokemon = require("src.core.game3.pokemon")
local realKeyName, realFromName = Pokemon.keyName, Pokemon.speciesFromName
Pokemon.keyName = function(id) return id == 277 and "TREECKO" or nil end
Pokemon.speciesFromName = function(n) return n == "TREECKO" and 277 or nil end
local Encounters = require("src.core.game3.encounters")
local realEnsure = Encounters.ensureLoaded
Encounters.ensureLoaded = function() end

local function step()
  local ok, enc = pcall(Encounters.onStep, "MAP_ROUTE101", "land", {})
  return ok, enc
end

for _, game in ipairs({ "emerald", "firered" }) do
  GameVersion.set(game)
  local r = T.sdk.loadMod("mods/wilds_of_hoenn", { data = T.fixtures.fresh(), generation = 3 })
  check(#r.errors == 0, game .. ": Wilds loads")
  r.loader.modOptions = r.loader.modOptions or {}
  r.loader.modOptions.wilds_of_hoenn = r.loader.modOptions.wilds_of_hoenn or {}
  local opts = r.loader.modOptions.wilds_of_hoenn

  opts.classic_enc = true
  steps = 0
  local ok, enc = step()
  check(ok and enc and enc.species == 277, game .. ": Classic Encounters ON -- the step's encounter goes through")
  check(steps == 1, game .. ": ...rolled by the game's own step rule, once")

  opts.classic_enc = false
  steps = 0
  ok, enc = step()
  check(ok and enc == nil, game .. ": Classic Encounters OFF -- no step encounter")
  check(steps == 0, game .. ": ...the step rule is not even rolled")

  opts.classic_enc = nil
  ok, enc = step()
  check(ok and enc and enc.species == 277, game .. ": never set -- the default (ON) applies")
  if r.release then r.release() end
end

Pokemon.keyName, Pokemon.speciesFromName = realKeyName, realFromName
Encounters.ensureLoaded = realEnsure

print("")
if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("classic_encounters_test: all passed")
