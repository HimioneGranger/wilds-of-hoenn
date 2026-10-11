-- Per-map eligible-cell listing and wild table presence, read entirely from
-- the engine (EnginePatch): no reimplemented terrain/encounter rules.
local V = ...
local Config = V.require("config")
local EnginePatch = V.require("engine_patch")
local Reachability = V.require("reachability")

local EncounterSource = {}
EncounterSource.__index = EncounterSource

function EncounterSource.new(mod)
  return setmetatable({
    mod = mod,
    mapId = nil,
    skip = true,
    hasLand = false,
    hasWater = false,
    cells = { land = {}, water = {} },
  }, EncounterSource)
end

--- Rescans the current map: cell terrain classification (land/water, from
--- the ROM's metatile encounter type) and whether its wild table has a
--- land/water area at all. Called on map.entered.
function EncounterSource:loadMap(mapId)
  self.mapId = mapId
  self.reachable, self.shore = nil, nil
  self.cells = { land = {}, water = {} }
  self.hasLand, self.hasWater = false, false

  -- Battle Pike / Battle Pyramid: wild generation there is special-cased
  -- (facilityEncounter in encounter_rules/rse.lua) and this mod adds no
  -- visible spawns on those maps -- see docs/ARCHITECTURE.md "What v1
  -- deliberately leaves out".
  if EnginePatch.isSweetScentFacility(mapId) then
    self.skip = true
    return
  end
  -- Safari Zone (Ruby / Sapphire / Emerald and FireRed / LeafGreen): the
  -- engine runs those battles itself, with balls and bait.
  if EnginePatch.safariActive() then
    self.skip = true
    return
  end
  self.skip = false

  EnginePatch.ensureEncountersLoaded()
  local t = EnginePatch.tableFor(mapId)
  self.hasLand = type(t) == "table" and (t.land ~= nil or t.grass ~= nil)
  self.hasWater = type(t) == "table" and t.water ~= nil
  if not (self.hasLand or self.hasWater) then return end

  local w, h = EnginePatch.mapBounds()
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local terrain = EnginePatch.terrainAt(x, y)
      if terrain == "land" and self.hasLand then
        self.cells.land[#self.cells.land + 1] = { x = x, y = y }
      elseif terrain == "water" and self.hasWater then
        self.cells.water[#self.cells.water + 1] = { x = x, y = y }
      end
    end
  end
end

--- The current map's eligible cells for `terrain` ("land" | "water"), a
--- fresh array of {x, y} tables (copy-on-read, same contract as
--- Gen1Recomp's own ow.entities facade -- callers must not mutate it
--- across calls and expect the mutation to persist).
function EncounterSource:eligibleCells(terrain)
  local list = self.cells[terrain]
  if not list then return {} end
  local reachable, shore = self.reachable, self.shore
  local range = Config.SHORE_WATER_RANGE or 0
  local out = {}
  for i = 1, #list do
    local c = list[i]
    local d = shore and shore[Reachability.key(c.x, c.y)]
    if not reachable or Reachability.has(reachable, c.x, c.y) or (d and d <= range) then
      out[#out + 1] = { x = c.x, y = c.y }
    end
  end
  return out
end

--- Whether a wild Pokemon of `terrain` may stay on (x, y): reachable, or (water)
--- anywhere in water connected to the reachable shore.
function EncounterSource:canStay(x, y, terrain)
  if not self.reachable or Reachability.has(self.reachable, x, y) then return true end
  return terrain == "water" and self.shore ~= nil and self.shore[Reachability.key(x, y)] ~= nil
end

local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

--- Water cells outside `set`, keyed like Reachability, valued by how many water
--- cells out from the reachable shore they lie (1 = beside a reachable cell).
function EncounterSource:_shoreWater(set)
  local key, has = Reachability.key, Reachability.has
  local water = {}
  for _, c in ipairs(self.cells.water) do water[key(c.x, c.y)] = c end
  local depth, queue = {}, {}
  for _, c in ipairs(self.cells.water) do
    if not has(set, c.x, c.y) then
      for _, n in ipairs(NEIGHBOURS) do
        if has(set, c.x + n[1], c.y + n[2]) then
          depth[key(c.x, c.y)] = 1
          queue[#queue + 1] = c
          break
        end
      end
    end
  end
  local head = 1
  while head <= #queue do
    local c = queue[head]
    head = head + 1
    local d = depth[key(c.x, c.y)]
    for _, n in ipairs(NEIGHBOURS) do
      local k = key(c.x + n[1], c.y + n[2])
      local w = water[k]
      if w and not depth[k] and not has(set, w.x, w.y) then
        depth[k] = d + 1
        queue[#queue + 1] = w
      end
    end
  end
  return depth
end

--- Restricts eligibleCells to a reachable set (lib/reachability.lua build()),
--- plus the water seen from its shore (Config.SHORE_WATER_RANGE), or lifts the
--- restriction with nil. Reachability is a view over the cells loadMap found,
--- so it can be swapped without rescanning the map.
function EncounterSource:setReachable(set)
  self.reachable = set
  self.shore = set and self:_shoreWater(set) or nil
end

function EncounterSource:isEligible()
  return not self.skip and (self.hasLand or self.hasWater)
end

return EncounterSource
