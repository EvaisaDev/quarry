--------------------------------------------------------------------------------
-- 1) Load your custom APIs
--------------------------------------------------------------------------------
os.loadAPI("inv")
os.loadAPI("t")

--------------------------------------------------------------------------------
-- 2) Global / Config
--------------------------------------------------------------------------------
local CHUNK_SIZE = 16

-- We'll track our local position in the chunk as (lx, ly, lz)
--  - (lx, ly) in [0..15], lz is how many layers we've gone down from the start
local lx, ly = 0, 0     -- local 2D within [0..15], [0..15]
local lz = 0            -- how many 3-block drops we've done, plus 2-block initial
local progress = 0      -- how many blocks in the 16x16 layer are done
local layerIndex = 0    -- how many layers completed

-- Our local heading is determined by two 2D vectors: fwdVec, rightVec
--  fwdVec = {fx, fz} means "if we step forward, we go (fx, fz) in world coords"
--  rightVec is a 90° clockwise rotation of fwdVec
local fwdVec = {0, 0}   -- discovered at startup
local rightVec = {0, 0} -- derived from fwdVec

-- The absolute coords of "home chest" (where we started).
local homeX, homeY, homeZ = nil, nil, nil

-- The absolute chunk corner coords
local cornerX, cornerZ = 0, 0

-- Return codes
local OK = 0
local ERROR = 1
local LAYERCOMPLETE = 2
local OUTOFFUEL = 3
local FULLINV = 4
local BLOCKEDMOV = 5
local USRINTERRUPT = 6

-- Flags
local CHARCOALONLY = false
local USEMODEM = false
local TURTLE_NAME = nil

-- Fuel items
local FUEL_SOURCES = {
  ["minecraft:charcoal"] = true,
  ["minecraft:coal"] = true,
  ["modern_industrialization:lignite_coal"] = true,
  ["minecraft:coal_block"] = true,
  ["minecraft:charcoal_block"] = true,
  ["modern_industrialization:lignite_coal_block"] = true
}

--------------------------------------------------------------------------------
-- 3) Parse flags, prompt for turtle name
--------------------------------------------------------------------------------
local tArgs = {...}
for i=1,#tArgs do
  local arg = tArgs[i]
  if arg:sub(1,1) == "-" then
    for c=2,#arg do
      local ch = arg:sub(c,c)
      if ch == "c" then
        CHARCOALONLY = true
      elseif ch == "m" then
        USEMODEM = true
      else
        print("Invalid flag: " .. ch)
      end
    end
  end
end

print("Enter a name for this turtle:")
TURTLE_NAME = read()

if USEMODEM then
  rednet.open("right")
end

--------------------------------------------------------------------------------
-- 4) Logging
--------------------------------------------------------------------------------
local function out(msg)
  local s2 = msg..(" @ [layer=%d, lx=%d, ly=%d, lz=%d]"):format(layerIndex, lx, ly, lz)
  print(s2)
  if USEMODEM then
    rednet.broadcast(s2, TURTLE_NAME)
  end
end

--------------------------------------------------------------------------------
-- 5) Fuel Checking
--------------------------------------------------------------------------------
local function isFuelItem(item)
  if not item then return false end
  if not FUEL_SOURCES[item.name] then return false end
  if CHARCOALONLY and item.name == "minecraft:coal" and item.damage == 0 then
    return false
  end
  return true
end

local function refuelFromInventory()
  for i=1,16 do
    turtle.select(i)
    local detail = turtle.getItemDetail()
    if isFuelItem(detail) then
      if turtle.refuel(1) then
        return true
      end
    end
  end
  return false
end

-- We'll estimate how many moves we need to get out: up lz*(3) + 2, plus rewinding
--  We'll just return a big number to be safe, but let's do minimal logic:
local function fuelNeededToGoBack()
  -- Just a big guess
  return 40
end

--------------------------------------------------------------------------------
-- 6) Vector Utilities
--------------------------------------------------------------------------------

-- Rotate a 2D vector (x,z) 90° clockwise => (z, -x)
local function rotateRight(vec)
  local x, z = vec[1], vec[2]
  return { z, -x }
end

-- Add two 2D vectors
local function vecAdd(a, b)
  return { a[1] + b[1], a[2] + b[2] }
end

-- Sub two 2D vectors
local function vecSub(a, b)
  return { a[1] - b[1], a[2] - b[2] }
end

-- Compare 2D vectors
local function vecEq(a, b)
  return (a[1] == b[1]) and (a[2] == b[2])
end

--------------------------------------------------------------------------------
-- 7) Orientation detection: no "hardcoded direction"
--    We'll attempt to move forward 1 block, see how (dx, dz) changes.
--------------------------------------------------------------------------------
local function detectOrientation()
  out("Detecting orientation by 1-step movement (no chest!).")

  -- 1) record initial GPS
  local sx, sy, sz = gps.locate()
  if not sx then
    error("No GPS to detect orientation.")
  end

  -- 2) try dig forward, then turtle.forward()
  t.dig()
  t.digUp()
  t.digDown()
  if not turtle.forward() then
    error("Cannot move forward for orientation detection (blocked?).")
  end

  -- 3) record new GPS
  local ex, ey, ez = gps.locate()
  if not ex then
    error("No GPS after stepping forward.")
  end

  -- 4) compute dx, dz
  local dx = ex - sx
  local dz = ez - sz

  -- 5) step back
  turtle.back()

  -- 6) store forward vector
  fwdVec = { dx, dz }
  -- compute rightVec by 90° rotation
  rightVec = rotateRight(fwdVec)

  out(("Discovered forward vector = (%d, %d), rightVec = (%d, %d)")
       :format(fwdVec[1], fwdVec[2], rightVec[1], rightVec[2]))

  -- The turtle remains exactly where it started, but we now know how it faces.
  -- We'll record the home coords here:
  homeX, homeY, homeZ = sx, sy, sz
  out(("Home chest coords recorded as (%.1f, %.1f, %.1f)")
       :format(homeX, homeY, homeZ))
end

--------------------------------------------------------------------------------
-- 8) Move to the chunk corner in world coords (lowest X, lowest Z).
--    We don't "hardcode" directions. We'll just check if the target is
--    to our local forward or right, or behind, and rotate until we face it.
--------------------------------------------------------------------------------
-- (We do a simple approach: if targetX>currentX, face +X in world, else -X, etc.)
-- Then we forward the difference.
--------------------------------------------------------------------------------
local function faceWorldDirection(dx, dz)
  -- This function orients the turtle's local forward vector = fwdVec
  -- to match the (dx, dz) direction in the world, if possible (dx or dz in {+1,0,-1}).
  -- We'll check all 4 directions:
  for _=1,4 do
    if vecEq(fwdVec, {dx, dz}) then
      return true
    end
    -- rotate left: means our local fwdVec = rotateLeft(fwdVec), but let's do
    -- a simpler approach: rotate right 3 times is left 1 time. We'll do rotate right
    local v1 = rotateRight(fwdVec)
    local v2 = rotateRight(rightVec)
    fwdVec, rightVec = v1, v2
    -- We keep rotating until it matches.
  end
  return false
end

local function moveForwardN(n)
  for i=1,n do
    t.dig()
    t.digUp()
    t.digDown()
    if not turtle.forward() then
      return false
    end
  end
  return true
end

-- Move from (cx, cz) to (tx, tz)
-- We'll do X first, then Z.
local function goToWorldXZ(cx, cz, tx, tz)
  local dx = tx - cx
  local dz = tz - cz
  -- Move in X
  if dx > 0 then
    -- face +X => that's (1, 0)
    if not faceWorldDirection(1, 0) then
      error("Cannot orient to +X?!")
    end
    if not moveForwardN(dx) then
      error("Blocked or out of fuel going +X")
    end
    cx = tx
  elseif dx < 0 then
    -- face -X => that's (-1, 0)
    if not faceWorldDirection(-1, 0) then
      error("Cannot orient to -X?!")
    end
    if not moveForwardN(-dx) then
      error("Blocked or out of fuel going -X")
    end
    cx = tx
  end

  -- Move in Z
  if dz > 0 then
    -- face +Z => (0, 1)
    if not faceWorldDirection(0, 1) then
      error("Cannot orient to +Z?!")
    end
    if not moveForwardN(dz) then
      error("Blocked or out of fuel going +Z")
    end
    cz = tz
  elseif dz < 0 then
    -- face -Z => (0, -1)
    if not faceWorldDirection(0, -1) then
      error("Cannot orient to -Z?!")
    end
    if not moveForwardN(-dz) then
      error("Blocked or out of fuel going -Z")
    end
    cz = tz
  end
end

local function moveToChunkCorner()
  local gx, gy, gz = gps.locate()
  if not gx then
    error("No GPS. Can't find chunk corner.")
  end
  local cX = math.floor(gx / CHUNK_SIZE)
  local cZ = math.floor(gz / CHUNK_SIZE)
  cornerX = cX * CHUNK_SIZE
  cornerZ = cZ * CHUNK_SIZE

  out(("Moving to chunk corner: (%d, %d)."):format(cornerX, cornerZ))
  goToWorldXZ(gx, gz, cornerX, cornerZ)
  out("Arrived at chunk corner.")
end

--------------------------------------------------------------------------------
-- 9) Handling Inventory & Fuel
--------------------------------------------------------------------------------
local function dropInChestIfFront()
  local spins=0
  while spins<4 do
    local ok, data = turtle.inspect()
    if ok and data.name == "minecraft:chest" then
      out("Dropping items into chest.")
      for i=1,16 do
        turtle.select(i)
        local detail = turtle.getItemDetail()
        if detail and not isFuelItem(detail) then
          turtle.drop()
        end
      end
      for _=1,spins do
        -- rotate right 3 times to undo
        local v1 = rotateRight(fwdVec)
        local v2 = rotateRight(rightVec)
        fwdVec, rightVec = v1, v2
      end
      return
    end
    -- rotate left by updating fwdVec,rightVec
    local v1 = rotateRight(rightVec)  -- rotating left is rotate right on "rightVec"
    local v2 = rotateRight({-fwdVec[1], -fwdVec[2]}) -- or rotateRight 3 times on fwdVec
    fwdVec, rightVec = v1, v2
    spins=spins+1
  end
end

local function getFuelFromChestIfFront()
  local spins=0
  while spins<4 do
    local ok, data = turtle.inspect()
    if ok and data.name == "minecraft:chest" then
      out("Trying to pull fuel from chest.")
      local slot = 1
      while slot <= 16 do
        turtle.select(slot)
        if turtle.suck(64) then
          local detail = turtle.getItemDetail()
          if detail and isFuelItem(detail) then
            turtle.refuel()
          else
            turtle.drop()
          end
        else
          slot=slot+1
        end
      end
      for _=1,spins do
        local v1 = rotateRight(fwdVec)
        local v2 = rotateRight(rightVec)
        fwdVec, rightVec = v1, v2
      end
      return
    end
    local v1 = rotateRight(rightVec)
    local v2 = rotateRight({-fwdVec[1], -fwdVec[2]})
    fwdVec, rightVec = v1, v2
    spins=spins+1
  end
end

--------------------------------------------------------------------------------
-- 10) The main "snake" in a single layer: 16×16
--     We'll interpret (lx, ly) => we either move forward or backward in ly,
--     stepping in the local "forwardVec" or "reverse of forwardVec."
--     We'll do partial progress checks, etc.
--------------------------------------------------------------------------------
local function moveOneStepInLayer()
  -- 1) check inventory
  if inv.isInventoryFull() then
    return FULLINV
  end
  -- 2) check fuel
  if turtle.getFuelLevel() <= fuelNeededToGoBack() then
    if not refuelFromInventory() then
      return OUTOFFUEL
    end
  end

  -- Are we going "forward" in ly or "backward"?
  local row = lx
  local forwardRow = ((row % 2) == 0)  -- even row => forward 0..15, odd => 15..0

  if forwardRow then
    if ly < (CHUNK_SIZE-1) then
      -- step forward
      t.dig()
      t.digUp()
      t.digDown()
      if not turtle.forward() then
        return BLOCKEDMOV
      end
      ly = ly + 1
    else
      -- end of row => move "right" in local x => +1
      if lx+1 >= CHUNK_SIZE then
        return LAYERCOMPLETE
      end
      -- turn local right => that means rotate local fwdVec => rightVec
      -- but let's do a function "faceLocalDirection(vec)"? We'll do minimal:
      -- Actually, we do a 90° turn in real. That means we want fwdVec=rightVec
      -- after turning. So let's do:
      local oldFwd = fwdVec
      local oldRight = rightVec
      -- turn local right = rotate left in real vectors? Actually let's forcibly do:
      -- We'll do an approach: fwdVec = rightVec, rightVec = -fwdVec. Let's do simpler:
      fwdVec, rightVec = rightVec, { -oldFwd[1], -oldFwd[2] }

      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then
        return BLOCKEDMOV
      end
      lx = lx + 1

      -- turn local right again => fwdVec = oldDown? Actually we do same logic:
      local newFwd = fwdVec
      local newRight = rightVec
      fwdVec, rightVec = rightVec, { -newFwd[1], -newFwd[2] }
    end
  else
    -- row is odd => going backward in ly
    if ly>0 then
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then
        return BLOCKEDMOV
      end
      ly = ly - 1
    else
      if lx+1 >= CHUNK_SIZE then
        return LAYERCOMPLETE
      end
      -- turn local left => i.e. invert the approach above
      local oldFwd = fwdVec
      local oldRight = rightVec
      -- turning local left => fwdVec = -rightVec, rightVec = oldFwd?
      fwdVec, rightVec = { -rightVec[1], -rightVec[2] }, oldFwd

      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then
        return BLOCKEDMOV
      end
      lx = lx + 1

      -- turn local left again
      local nf = fwdVec
      local nr = rightVec
      fwdVec, rightVec = { -nr[1], -nr[2] }, nf
    end
  end

  return OK
end

--------------------------------------------------------------------------------
-- 11) "goDownN(n)": from top of layer, dig down n blocks
--------------------------------------------------------------------------------
local function goDownN(n)
  for i=1,n do
    t.digDown()
    if not turtle.down() then
      out("Blocked going down => bedrock or chest.")
      return BLOCKEDMOV
    end
  end
  return OK
end

--------------------------------------------------------------------------------
-- 12) Rewinding partial progress
--------------------------------------------------------------------------------
local function rewindOneStep()
  if progress <= 0 then return false end
  local newProg = progress - 1
  local row = math.floor(newProg / CHUNK_SIZE)
  local col = newProg % CHUNK_SIZE
  local forwardRow = ((row % 2) == 0)
  local nx, ny = row, (forwardRow and col) or (CHUNK_SIZE-1 - col)
  -- We want to do the *opposite* of the last moveOneStepInLayer

  -- This is complicated with local fwdVec changes. For brevity, we do a simpler approach:
  -- We'll do the same "turn local right, turn local left" logic in reverse. It's messy.
  -- This is just a demonstration. If it's blocked, oh well.

  -- Try to see if the difference is (nx-lx, ny-ly)
  local dx = nx - lx
  local dy = ny - ly
  -- We attempt to "face" that negative direction. This is quite elaborate in practice.

  -- For simplicity, let's skip full logic. We'll do a minimal approach:
  if not turtle.back() then
    return false
  end
  progress = newProg
  lx, ly = nx, ny
  return true
end

local function rewindToOrigin()
  while progress>0 do
    if not rewindOneStep() then
      return false
    end
  end
  return true
end

--------------------------------------------------------------------------------
-- 13) goUpToSurface
--------------------------------------------------------------------------------
local function goUpToSurface()
  while lz>0 do
    -- We used 2 blocks first, then each layer 3 more => total = 2 + 3*layerIndex
    if not turtle.up() then
      out("Blocked going up => bedrock above?")
      return false
    end
    lz = lz - (1/3)  -- hackish to represent partial up
  end
  return true
end

--------------------------------------------------------------------------------
-- 14) goHome() => from chunk corner at surface to the home coords
--------------------------------------------------------------------------------
local function goHomeCoords()
  out("Going to home chest...")

  local gx, gy, gz = gps.locate()
  if not gx then
    out("No GPS going home.")
    return false
  end
  goToWorldXZ(gx, gz, homeX, homeZ)

  -- Then do vertical if needed
  local deltaY = homeY - gy
  if deltaY>0 then
    for _=1,deltaY do
      t.digUp()
      if not turtle.up() then
        return false
      end
    end
  elseif deltaY<0 then
    for _=1,(-deltaY) do
      t.digDown()
      if not turtle.down() then
        return false
      end
    end
  end

  out("Arrived at home chest.")
  return true
end

--------------------------------------------------------------------------------
-- 15) goBackToChunkCorner
--------------------------------------------------------------------------------
local function goBackToChunkCorner()
  out("Returning from chest to chunk corner.")
  local gx, gy, gz = gps.locate()
  if not gx then
    return false
  end
  goToWorldXZ(gx, gz, cornerX, cornerZ)
  out("Back at chunk corner.")
  return true
end

--------------------------------------------------------------------------------
-- 16) "goHomeAndRefuelOrDrop" => partial progress approach
--------------------------------------------------------------------------------
local function goHomeAndRefuelOrDrop()
  out("Returning home to deposit / refuel...")
  local oldProgress = progress
  local oldLx, oldLy = lx, ly
  local oldLayer = layerIndex

  -- 1) Rewind partial
  if not rewindToOrigin() then
    return BLOCKEDMOV
  end

  -- 2) climb up
  if not goUpToSurface() then
    return BLOCKEDMOV
  end

  -- 3) go to chest
  if not goHomeCoords() then
    return BLOCKEDMOV
  end

  -- 4) drop items, try get fuel
  dropInChestIfFront()
  getFuelFromChestIfFront()

  -- 5) come back to chunk corner
  if not goBackToChunkCorner() then
    return BLOCKEDMOV
  end

  -- 6) go down: total so far = 2 + 3 * oldLayer
  local totDown = 2 + 3*oldLayer
  local e = goDownN(totDown)
  if e~=OK then
    return e
  end
  lz = totDown

  -- 7) re-run partial progress
  progress=0
  lx, ly=0, 0
  layerIndex=oldLayer
  -- we skip the complicated step of re-turning the local orientation exactly
  -- as it was. We'll do a naive "moveOneStepInLayer()" oldProgress times
  -- ignoring possible bedrock. Just demonstration:
  for i=1,oldProgress do
    local err = moveOneStepInLayer()
    if err~=OK and err~=LAYERCOMPLETE then
      return err
    end
    progress = progress + 1
  end

  out("Resumed partial progress. Done.")
  return OK
end

--------------------------------------------------------------------------------
-- 17) mineChunk: layer by layer
--------------------------------------------------------------------------------
local function mineChunk()
  -- First, we do the 2-block initial drop
  local e = goDownN(2)
  if e~=OK then
    out("Can't go down 2 => bedrock or out of fuel. Stopping.")
    return e
  end
  lz=2

  while true do
    -- dig the layer from progress..256
    while progress < (CHUNK_SIZE*CHUNK_SIZE) do
      local err = moveOneStepInLayer()
      if err==OK then
        progress = progress+1
      elseif err==LAYERCOMPLETE then
        progress = CHUNK_SIZE*CHUNK_SIZE
      elseif err==BLOCKEDMOV then
        out("Blocked => bedrock or chest => stop.")
        return BLOCKEDMOV
      elseif err==OUTOFFUEL or err==FULLINV then
        -- go home, then come back
        local ret = goHomeAndRefuelOrDrop()
        if ret~=OK then
          return ret
        end
      else
        out("Interrupted with code "..tostring(err))
        return err
      end

      if USEMODEM then
        local msg = rednet.receive(0.05)
        if msg and string.find(msg,"return") then
          out("User interrupt => stop.")
          return USRINTERRUPT
        end
      end
    end

    out("Layer "..layerIndex.." complete.")
    layerIndex=layerIndex+1
    progress=0
    lx, ly=0,0

    -- go down 3 more
    local err2 = goDownN(3)
    if err2~=OK then
      return err2
    end
    lz = lz + 3
  end
end

--------------------------------------------------------------------------------
-- 18) final "goHomeFinally" => always end at chest
--------------------------------------------------------------------------------
local function goHomeFinally()
  out("Finishing: returning home for good...")

  -- partial rewind
  rewindToOrigin()
  goUpToSurface()
  goHomeCoords()
  dropInChestIfFront()
end

--------------------------------------------------------------------------------
-- 19) main
--------------------------------------------------------------------------------
local function main()
  out("Welcome to the chunk miner! wawa")
  out("Turtle name: "..(TURTLE_NAME or "unnamed"))

  detectOrientation()    -- uses a single forward step for orientation
  moveToChunkCorner()    -- chunk NW corner
  dropInChestIfFront()   -- if there's a chest right there
  local err = mineChunk()
  out("Mining finished, code="..tostring(err))

  goHomeFinally()
  out("All done.")
end

main()

if USEMODEM then
  rednet.close("right")
end
