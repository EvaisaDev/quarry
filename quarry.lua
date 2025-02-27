--------------------------------------------------------------------------------
-- 1) Load your custom APIs:
--    - "inv" for inventory (inv.isInventoryFull(), inv.dropThrash(), etc.)
--    - "t"   for turtle movement (t.dig(), t.fw(), t.down(), etc.)
--------------------------------------------------------------------------------
os.loadAPI("inv")
os.loadAPI("t")

--------------------------------------------------------------------------------
-- 2) Global / Config Variables
--------------------------------------------------------------------------------
local CHUNK_SIZE = 16  -- we always mine a 16x16 chunk
local x, y, z = 0, 0, 0  -- local coordinates for the "snake": x=0..15, y=0..15, z negative as we go down
local progress = 0      -- how many blocks of the 16×16 layer are done (0..255)
local layerIndex = 0    -- how many layers we've finished (0=top layer, 1=next, etc.)
local facingfw = true   -- whether we are moving "forward" in y or backward
local orientation = 0   -- real-world orientation (0=north,1=east,2=south,3=west)

-- "home" chest absolute coordinates (where the turtle started).
local homeX, homeY, homeZ = nil, nil, nil

-- Return/status codes
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

-- Recognized Fuel
local FUEL_SOURCES = {
  ["minecraft:charcoal"] = true,
  ["minecraft:coal"] = true,
  ["modern_industrialization:lignite_coal"] = true,
  ["minecraft:coal_block"] = true,
  ["minecraft:charcoal_block"] = true,
  ["modern_industrialization:lignite_coal_block"] = true
}

--------------------------------------------------------------------------------
-- 3) Parse command-line flags, prompt for turtle name
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
-- 4) Utility Logging / Broadcasting
--------------------------------------------------------------------------------
local function out(msg)
  local s2 = msg .. (" @ [layer=%d, x=%d, y=%d, z=%d]"):format(layerIndex, x, y, z)
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
  -- Charcoal only?
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

-- Approx moves needed to get back "home" if we want. 
-- We'll go up -z steps, then x steps, then y steps, plus a small buffer.
local function fuelNeededToGoBack()
  local needed = -z + x + y + 2
  if needed < 0 then needed = 0 end
  return needed
end

--------------------------------------------------------------------------------
-- 6) Orientation & Movement
--------------------------------------------------------------------------------
local function turnLeft()
  turtle.turnLeft()
  orientation = (orientation - 1) % 4
end

local function turnRight()
  turtle.turnRight()
  orientation = (orientation + 1) % 4
end

-- Face a given direction (0=north,1=east,2=south,3=west)
local function face(dir)
  while orientation ~= dir do
    turnLeft()
  end
end

--------------------------------------------------------------------------------
-- 7) Detect the chest & orientation, record chest's absolute coords as "home"
--------------------------------------------------------------------------------
local function detectOrientationAndHome()
  -- 1) spin up to 4 times to find chest in front
  local found = false
  for _=1,4 do
    local ok, data = turtle.inspect()
    if ok and data.name == "minecraft:chest" then
      found = true
      break
    end
    turnLeft()
  end
  if not found then
    error("No chest found around the turtle. Cannot detect orientation!")
  end

  -- The chest is in front => rotate 180° so it's behind us
  turnLeft()
  turnLeft()

  -- record the turtle's absolute position
  local xOld, yOld, zOld = gps.locate()
  if not xOld then
    error("GPS not available for orientation detection!")
  end

  -- move forward 1 block
  if not turtle.forward() then
    error("Blocked or out of fuel while stepping away from chest.")
  end

  local xNew, yNew, zNew = gps.locate()
  if not xNew then
    error("GPS not available after stepping away.")
  end

  local dx = xNew - xOld
  local dz = zNew - zOld

  if dx == 1 and dz == 0 then
    orientation = 1 -- east
  elseif dx == -1 and dz == 0 then
    orientation = 3 -- west
  elseif dx == 0 and dz == 1 then
    orientation = 2 -- south
  elseif dx == 0 and dz == -1 then
    orientation = 0 -- north
  else
    error(("Unexpected movement for orientation detection, dx=%d dz=%d"):format(dx,dz))
  end

  -- rotate 180° to face the chest again
  turnLeft()
  turnLeft()

  -- Now the turtle is next to the chest again, facing it.
  out(("Orientation: %d (0=north,1=east,2=south,3=west)"):format(orientation))

  -- The chest is "in front" => we can guess the chest's absolute coords
  local cx, cy, cz = gps.locate()
  if not cx then
    error("GPS not available to record chest location!")
  end
  -- The chest is 1 block in front of the turtle
  if orientation == 0 then
    cz = cz - 1
  elseif orientation == 1 then
    cx = cx + 1
  elseif orientation == 2 then
    cz = cz + 1
  elseif orientation == 3 then
    cx = cx - 1
  end

  homeX, homeY, homeZ = cx, cy, cz
  out(("Recorded chest (home) coords: (%.1f, %.1f, %.1f)"):format(homeX, homeY, homeZ))
end

--------------------------------------------------------------------------------
-- 8) Move from current GPS location to chunk corner
--------------------------------------------------------------------------------
local function moveToChunkCorner()
  local gx, gy, gz = gps.locate()
  if not gx then
    error("GPS locate failed! Cannot move to chunk corner.")
  end

  local cX = math.floor(gx / CHUNK_SIZE)
  local cZ = math.floor(gz / CHUNK_SIZE)
  local cornerX = cX * CHUNK_SIZE
  local cornerZ = cZ * CHUNK_SIZE

  out(("Moving to chunk corner (%d, _, %d)."):format(cornerX, cornerZ))

  local dx = cornerX - gx
  local dz = cornerZ - gz

  -- Move in X
  if dx > 0 then
    face(1) -- east
    for _=1,dx do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then
        error("Blocked or out of fuel going east.")
      end
    end
  elseif dx < 0 then
    face(3) -- west
    for _=1,(-dx) do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then
        error("Blocked or out of fuel going west.")
      end
    end
  end

  -- Move in Z
  if dz > 0 then
    face(2) -- south
    for _=1,dz do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then
        error("Blocked or out of fuel going south.")
      end
    end
  elseif dz < 0 then
    face(0) -- north
    for _=1,(-dz) do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then
        error("Blocked or out of fuel going north.")
      end
    end
  end

  out("Reached chunk corner.")
end

--------------------------------------------------------------------------------
-- 9) Drop all non-fuel items if there's a chest in front
--------------------------------------------------------------------------------
local function dropInChest()
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
      -- revert orientation
      for _=1,spins do
        turnRight()
      end
      return
    end
    turnLeft()
    spins=spins+1
  end
end

--------------------------------------------------------------------------------
-- 10) Attempt to pull additional fuel from the chest in front
--------------------------------------------------------------------------------
local function getFuelFromChest()
  local spins=0
  while spins<4 do
    local ok, data = turtle.inspect()
    if ok and data.name == "minecraft:chest" then
      out("Trying to pull fuel from chest.")
      local slot = 1
      while slot <= 16 do
        turtle.select(slot)
        -- attempt to suck a stack
        if turtle.suck(64) then
          local detail = turtle.getItemDetail()
          if detail and isFuelItem(detail) then
            turtle.refuel()
          else
            -- not fuel => put it back
            turtle.drop()
          end
        else
          slot=slot+1
        end
      end
      for _=1,spins do
        turnRight()
      end
      return
    end
    turnLeft()
    spins=spins+1
  end
end

--------------------------------------------------------------------------------
-- 11) Go down 2 blocks from corner (digging if blocked)
--------------------------------------------------------------------------------
local function goDown2()
  for _=1,2 do
    if turtle.getFuelLevel() <= fuelNeededToGoBack() then
      if not refuelFromInventory() then
        out("No fuel in inventory. Out of fuel!")
        return OUTOFFUEL
      end
    end
    t.digDown()
    if not turtle.down() then
      out("Blocked from going down => bedrock or chest.")
      return BLOCKEDMOV
    end
    z = z - 1
  end
  return OK
end

--------------------------------------------------------------------------------
-- 12) Converting progress <-> (x,y,facingfw) so we can "rewind" or "resume"
--------------------------------------------------------------------------------
local function progressToXY(p)
  local row = math.floor(p / CHUNK_SIZE)
  local col = p % CHUNK_SIZE
  local forward = ((row % 2) == 0)
  local xx = row
  local yy = (forward and col) or (CHUNK_SIZE-1 - col)
  return xx, yy, forward
end

local function XYtoProgress(xx, yy, fw)
  local row = xx
  local col
  if (row % 2)==0 then
    col = yy
  else
    col = CHUNK_SIZE-1 - yy
  end
  return row * CHUNK_SIZE + col
end

--------------------------------------------------------------------------------
-- 13) Move a single step in the snake
--------------------------------------------------------------------------------
local function moveHOneStep()
  -- Check inventory
  if inv.isInventoryFull() then
    return FULLINV
  end

  -- Check fuel
  if turtle.getFuelLevel() <= fuelNeededToGoBack() then
    if not refuelFromInventory() then
      return OUTOFFUEL
    end
  end

  -- Actually do the movement
  if facingfw then
    -- going +y
    if y < (CHUNK_SIZE-1) then
      if not t.dig() then
        out("Blocked forward => bedrock?")
        return BLOCKEDMOV
      end
      t.digUp()
      t.digDown()
      if not t.fw() then
        return BLOCKEDMOV
      end
      y = y + 1
    else
      -- end of row => move x + 1
      if x+1 >= CHUNK_SIZE then
        return LAYERCOMPLETE
      end
      turnRight()
      t.dig(); t.digUp(); t.digDown()
      if not t.fw() then
        return BLOCKEDMOV
      end
      x = x + 1
      turnRight()
      facingfw = false
    end
  else
    -- going -y
    if y>0 then
      t.dig(); t.digUp(); t.digDown()
      if not t.fw() then
        return BLOCKEDMOV
      end
      y = y - 1
    else
      -- end of row => move x + 1
      if x+1 >= CHUNK_SIZE then
        return LAYERCOMPLETE
      end
      turnLeft()
      t.dig(); t.digUp(); t.digDown()
      if not t.fw() then
        return BLOCKEDMOV
      end
      x = x + 1
      turnLeft()
      facingfw = true
    end
  end

  return OK
end

--------------------------------------------------------------------------------
-- 14) "Rewind" from partial position back to (x=0,y=0,z same)
--     by stepping in reverse
--------------------------------------------------------------------------------
local function moveBackOneStep()
  local newP = progress - 1
  if newP < 0 then return false end -- can't go below 0
  local nx, ny, nfwd = progressToXY(newP)
  -- We'll do the OPPOSITE movement that got us from newP to progress.

  if nx < x then
    -- we must have come from x-1 => we turned right or left
    if facingfw then
      turnLeft()  -- opposite of turnRight
      if not turtle.forward() then return false end
      x = nx
      turnLeft()
    else
      turnRight()
      if not turtle.forward() then return false end
      x = nx
      turnRight()
    end
    facingfw = nfwd
  elseif ny < y then
    -- we must face backward in y
    if facingfw then
      turnRight(); turnRight()
      if not turtle.forward() then return false end
      y = ny
      turnRight(); turnRight()
    else
      if not turtle.forward() then return false end
      y = ny
    end
    facingfw = nfwd
  elseif ny > y then
    -- we must face forward in y
    if not facingfw then
      turnRight(); turnRight()
      if not turtle.forward() then return false end
      y = ny
      turnRight(); turnRight()
    else
      if not turtle.forward() then return false end
      y = ny
    end
    facingfw = nfwd
  end

  progress = newP
  return true
end

local function rewindToOrigin()
  while progress>0 do
    local ok = moveBackOneStep()
    if not ok then
      out("Rewind failed. Possibly blocked or out of fuel.")
      return false
    end
  end
  return true
end

--------------------------------------------------------------------------------
-- 15) Move up to z=0
--------------------------------------------------------------------------------
local function goUpToSurface()
  while z<0 do
    if not turtle.up() then
      out("Blocked going up => bedrock above?")
      return false
    end
    z=z+1
  end
  return true
end

--------------------------------------------------------------------------------
-- 16) Travel between chunk corner <-> home chest using GPS
--------------------------------------------------------------------------------
local function goToChest()
  out("Traveling to home chest...")

  local gx, gy, gz = gps.locate()
  if not gx then
    out("GPS fail going to chest.")
    return false
  end

  local dx = homeX - gx
  local dy = homeY - gy
  local dz = homeZ - gz

  -- Move in X
  if dx>0 then
    face(1) -- east
    for _=1,dx do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then
        out("Blocked going east to chest.")
        return false
      end
    end
  elseif dx<0 then
    face(3) -- west
    for _=1,(-dx) do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then
        out("Blocked going west to chest.")
        return false
      end
    end
  end

  -- Move in Y (vertical)
  if dy>0 then
    for _=1,dy do
      t.digUp()
      if not turtle.up() then
        out("Blocked going up to chest.")
        return false
      end
    end
  elseif dy<0 then
    for _=1,(-dy) do
      t.digDown()
      if not turtle.down() then
        out("Blocked going down to chest.")
        return false
      end
    end
  end

  -- Move in Z
  if dz>0 then
    face(2) -- south
    for _=1,dz do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then
        out("Blocked going south to chest.")
        return false
      end
    end
  elseif dz<0 then
    face(0) -- north
    for _=1,(-dz) do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then
        out("Blocked going north to chest.")
        return false
      end
    end
  end

  out("Arrived at chest.")
  return true
end

local function goBackToChunkCorner()
  out("Returning from chest to chunk corner...")

  local gx, gy, gz = gps.locate()
  if not gx then
    out("GPS fail going back corner.")
    return false
  end

  local cX = math.floor(gx / CHUNK_SIZE)
  local cZ = math.floor(gz / CHUNK_SIZE)
  local cornerX = cX * CHUNK_SIZE
  local cornerZ = cZ * CHUNK_SIZE

  local dx = cornerX - gx
  local dy = 0  -- Typically, we assume corner is the same Y as we are now
  local dz = cornerZ - gz

  if dx>0 then
    face(1)
    for _=1,dx do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then return false end
    end
  elseif dx<0 then
    face(3)
    for _=1,(-dx) do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then return false end
    end
  end

  if dy>0 then
    for _=1,dy do
      t.digUp(); if not turtle.up() then return false end
    end
  elseif dy<0 then
    for _=1,(-dy) do
      t.digDown(); if not turtle.down() then return false end
    end
  end

  if dz>0 then
    face(2)
    for _=1,dz do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then return false end
    end
  elseif dz<0 then
    face(0)
    for _=1,(-dz) do
      t.dig(); t.digUp(); t.digDown()
      if not turtle.forward() then return false end
    end
  end

  out("Arrived back at chunk corner.")
  return true
end

--------------------------------------------------------------------------------
-- 17) "Go Home" if we run out of fuel or inventory => deposit & refuel
--     Then come back and resume EXACTLY where we left off.
--------------------------------------------------------------------------------
local function goHomeAndRefuelOrDrop()
  out("Returning home to deposit items / get fuel...")

  -- Save old progress, layer, z
  local oldProgress = progress
  local oldLayer = layerIndex
  local oldZ = z

  -- 1) Rewind to (0,0) on this layer
  if not rewindToOrigin() then
    return BLOCKEDMOV
  end

  -- 2) Climb up to z=0
  if not goUpToSurface() then
    return BLOCKEDMOV
  end

  -- 3) Move from chunk corner => chest
  if not goToChest() then
    return BLOCKEDMOV
  end

  -- 4) Drop items, attempt to get more fuel
  dropInChest()
  getFuelFromChest()

  -- 5) Go back to chunk corner
  if not goBackToChunkCorner() then
    return BLOCKEDMOV
  end

  -- 6) Go back down to old layer: 2 + 3*(oldLayer)
  local totalDown = 2 + 3*(oldLayer)
  for _=1,totalDown do
    t.digDown()
    if not turtle.down() then
      out("Blocked going back down => bedrock?")
      return BLOCKEDMOV
    end
    z = z - 1
  end

  -- 7) Re-play partial progress from 0..(oldProgress-1)
  local function moveHNoChecks()
    if facingfw then
      if y<(CHUNK_SIZE-1) then
        t.dig(); t.digUp(); t.digDown()
        if not t.fw() then return BLOCKEDMOV end
        y=y+1
      else
        if x+1>=CHUNK_SIZE then
          return LAYERCOMPLETE
        end
        turnRight()
        t.dig(); t.digUp(); t.digDown()
        if not t.fw() then return BLOCKEDMOV end
        x=x+1
        turnRight()
        facingfw=false
      end
    else
      if y>0 then
        t.dig(); t.digUp(); t.digDown()
        if not t.fw() then return BLOCKEDMOV end
        y=y-1
      else
        if x+1>=CHUNK_SIZE then
          return LAYERCOMPLETE
        end
        turnLeft()
        t.dig(); t.digUp(); t.digDown()
        if not t.fw() then return BLOCKEDMOV end
        x=x+1
        turnLeft()
        facingfw=true
      end
    end
    return OK
  end

  progress=0
  x=0
  y=0
  facingfw=true
  layerIndex=oldLayer

  for _=1,oldProgress do
    local e = moveHNoChecks()
    if e==BLOCKEDMOV then
      out("Blocked while resuming partial progress!")
      return BLOCKEDMOV
    elseif e==LAYERCOMPLETE then
      break
    end
    progress = progress+1
  end

  out("Back to mining position. Resuming!")
  return OK
end

--------------------------------------------------------------------------------
-- 18) Main chunk-mining loop
--------------------------------------------------------------------------------
local function mineChunk()
  while true do
    -- Mine the current layer until progress=256 or done
    while progress < (CHUNK_SIZE*CHUNK_SIZE) do
      local err = moveHOneStep()
      if err == OK then
        progress = progress+1
      elseif err == LAYERCOMPLETE then
        -- finished this layer
        progress = CHUNK_SIZE*CHUNK_SIZE
      elseif err == OUTOFFUEL or err == FULLINV then
        -- go home, deposit or get fuel, then come back
        local ret = goHomeAndRefuelOrDrop()
        if ret ~= OK then
          return ret
        end
      elseif err == BLOCKEDMOV then
        out("Movement blocked => bedrock or unbreakable.")
        return BLOCKEDMOV
      else
        -- Possibly USRINTERRUPT or something
        out("Mining interrupted with code "..tostring(err))
        return err
      end

      -- Also check for user "return" via RedNet
      if USEMODEM then
        local msg = rednet.receive(0.05) -- quick poll
        if msg and string.find(msg,"return") then
          out("User interrupt via RedNet => stopping.")
          return USRINTERRUPT
        end
      end
    end

    -- done with layer => increment layerIndex
    out("Completed layer "..layerIndex)
    layerIndex=layerIndex+1
    progress=0
    x,y=0,0
    facingfw=true

    -- go down 3 blocks for next layer
    for _=1,3 do
      t.digDown()
      if not turtle.down() then
        out("Blocked going down => bedrock => done.")
        return BLOCKEDMOV
      end
      z=z-1
    end
  end
end

--------------------------------------------------------------------------------
-- 19) Final "goHome()" at the end if we are done or got an error
--------------------------------------------------------------------------------
local function goHomeFinally()
  out("Returning home at end or on error...")

  -- If we're in middle of a layer, let's try rewinding to (0,0).
  rewindToOrigin()  -- If blocked, oh well

  -- Then go up
  goUpToSurface()   -- If blocked, oh well

  -- Then attempt to go to chest
  goToChest()

  -- Drop items
  dropInChest()
end

--------------------------------------------------------------------------------
-- 20) Main Program
--------------------------------------------------------------------------------
local function main()
  out("Welcome to the chunk miner!")
  out("Turtle name: "..(TURTLE_NAME or "unnamed"))

  -- 1) Detect orientation from chest, record chest coords
  detectOrientationAndHome()

  -- 2) Move to local chunk corner
  moveToChunkCorner()

  -- 3) Possibly there's a chest in front now, deposit items
  dropInChest()

  -- 4) Dig down 2
  local ret=goDown2()
  if ret~=OK then
    out("Can't go down 2 => blocked or no fuel. We'll go home.")
    goHomeFinally()
    return
  end

  -- 5) Now mine chunk
  local result = mineChunk()

  out("Mine Chunk finished => code "..tostring(result))
  -- If we get BLOCKEDMOV (bedrock) or an error => we go home
  -- Also if we truly finished, we want to go home as requested.
  goHomeFinally()

  out("All done. Code="..tostring(result))
end

--------------------------------------------------------------------------------
-- Run it
--------------------------------------------------------------------------------
main()

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------
if USEMODEM then
  rednet.close("right")
end
