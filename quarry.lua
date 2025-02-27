-------------------------------------------
-- Make sure "inv" and "t" APIs exist    --
-------------------------------------------
os.loadAPI("inv")
os.loadAPI("t")

----------------------------------------------------
-- GLOBALS & CONSTANTS --
----------------------------------------------------
local x = 0       -- Local coordinate X in the "snake" pattern
local y = 0       -- Local coordinate Y in the "snake" pattern
local z = 0       -- Local vertical coordinate (down = negative)
local max = 16    -- Will be adjusted based on chunk boundary
local facingfw = true

local OK = 0
local ERROR = 1
local LAYERCOMPLETE = 2
local OUTOFFUEL = 3
local FULLINV = 4
local BLOCKEDMOV = 5
local USRINTERRUPT = 6

local CHARCOALONLY = false
local USEMODEM = true

-----------------------------------
-- Fuel items recognized:        --
-----------------------------------
local FUEL_SOURCES = {
  ["minecraft:charcoal"] = true,
  ["minecraft:coal"] = true,
  ["modern_industrialization:lignite_coal"] = true,
  ["minecraft:coal_block"] = true,
  ["minecraft:charcoal_block"] = true,
  ["modern_industrialization:lignite_coal_block"] = true
}

----------------------------------------------------
-- Check if an item is acceptable fuel
----------------------------------------------------
function isFuelItem(item)
  if item == nil then
    return false
  end
  if not FUEL_SOURCES[item.name] then
    return false
  end
  -- If forced charcoal-only, skip normal coal
  if CHARCOALONLY and item.name == "minecraft:coal" and item.damage == 0 then
    return false
  end
  return true
end

----------------------------------------------------
-- Parse command-line args (flags)
----------------------------------------------------
local tArgs = {...}
for i=1,#tArgs do
  local arg = tArgs[i]
  if string.find(arg, "-") == 1 then
    for c=2,string.len(arg) do
      local ch = string.sub(arg,c,c)
      if ch == 'c' then
        CHARCOALONLY = true
      else
        write("Invalid flag '")
        write(ch)
        print("'")
      end
    end
  end
end

----------------------------------------------------
-- Print/log function with optional modem usage
----------------------------------------------------
function out(s)
  local s2 = s .. " @ [" .. x .. ", " .. y .. ", " .. z .. "]"
  print(s2)
  if USEMODEM then
    rednet.broadcast(s2, "miningTurtle")
  end
end

----------------------------------------------------
-- Drop all non-fuel items into a chest in front
----------------------------------------------------
function dropInChest()
  local turns = 0
  while turns < 4 do
    local success, data = turtle.inspect()
    if success and data.name == "minecraft:chest" then
      out("Dropping items in chest")
      for i=1,16 do
        turtle.select(i)
        local d = turtle.getItemDetail()
        if d ~= nil and not isFuelItem(d) then
          turtle.drop()
          print("Dropped " .. d.name)
        end
      end
      -- Return to original orientation
      for i=1,turns do
        turtle.turnRight()
      end
      return
    end
    turtle.turnLeft()
    turns = turns + 1
  end
end

----------------------------------------------------
-- Attempt to refuel from any recognized fuel in inventory
----------------------------------------------------
function refuel()
  for i=1,16 do
    turtle.select(i)
    local item = turtle.getItemDetail()
    if isFuelItem(item) and turtle.refuel(1) then
      return true
    end
  end
  return false
end

----------------------------------------------------
-- Fuel needed to get back to y=0,x=0 and z=0
-- The function is conservative, adding +2 extra
----------------------------------------------------
function fuelNeededToGoBack()
  -- We must move upward -z steps, then x steps, then y steps
  return -z + x + y + 2
end

----------------------------------------------------
-- Modified goDown():
-- Goes down EXACTLY 2 blocks, then stops.
----------------------------------------------------
function goDown()
  for i = 1,2 do
    if turtle.getFuelLevel() <= fuelNeededToGoBack() then
      if not refuel() then
        out("Out of fuel!")
        return OUTOFFUEL
      end
    end
    local success = turtle.down()
    if not success then
      out("Blocked from going down. (Chest or block in the way?)")
      return BLOCKEDMOV
    end
    z = z - 1
  end
  return OK
end

----------------------------------------------------
-- Move forward one block in the horizontal "snake"
-- pattern (calls t.dig(), t.fw()).  We also
-- handle inventory checks and out-of-fuel checks.
----------------------------------------------------
function moveH()
  -- 1) Check if we are full
  if inv.isInventoryFull() then
    out("Dropping trash")
    inv.dropThrash()
    if inv.isInventoryFull() then
      out("Stacking items")
      inv.stackItems()
    end
    if inv.isInventoryFull() then
      out("Full inventory!")
      return FULLINV
    end
  end

  -- 2) Check if we have enough fuel
  if turtle.getFuelLevel() <= fuelNeededToGoBack() then
    if not refuel() then
      out("Out of fuel!")
      return OUTOFFUEL
    end
  end

  -- 3) Decide how to move in the local x-y plane
  if facingfw and y < max - 1 then
    -- Move forward in the "y" direction
    local dugFw = t.dig()
    if dugFw == false then
      out("Hit bedrock or unbreakable block forward.")
      return BLOCKEDMOV
    end
    t.digUp()
    t.digDown()

    -- Actually move forward
    if t.fw() == false then
      return BLOCKEDMOV
    end
    y = y+1

  elseif (not facingfw) and y > 0 then
    -- Move backward in the "y" direction
    t.dig()
    t.digUp()
    t.digDown()
    if t.fw() == false then
      return BLOCKEDMOV
    end
    y = y - 1

  else
    -- We reached the end of the row; time to snake over in x
    if x+1 >= max then
      -- That means we finished this entire layer
      t.digUp()
      t.digDown()
      return LAYERCOMPLETE
    end
    -- Turn and move 1 block in x
    if facingfw then
      turtle.turnRight()
    else
      turtle.turnLeft()
    end
    t.dig()
    t.digUp()
    t.digDown()
    if t.fw() == false then
      return BLOCKEDMOV
    end
    x = x+1
    -- Turn again
    if facingfw then
      turtle.turnRight()
    else
      turtle.turnLeft()
    end
    facingfw = not facingfw
  end

  return OK
end

----------------------------------------------------
-- Dig a single layer in the 2D "snake" pattern
----------------------------------------------------
function digLayer()
  local errorcode = OK
  while errorcode == OK do
    if USEMODEM then
      -- Check if user typed "return" or some signal over modem
      local msg = rednet.receive(1)
      if msg ~= nil and string.find(msg, "return") ~= nil then
        return USRINTERRUPT
      end
    end
    errorcode = moveH()
  end

  if errorcode == LAYERCOMPLETE then
    return OK
  end
  return errorcode
end

----------------------------------------------------
-- Go back to local origin (x=0,y=0) on the same
-- layer (z doesn't change)
----------------------------------------------------
function goToOrigin()
  -- If we are "facing forward," we expect to turn left, etc
  if facingfw then
    turtle.turnLeft()
    t.fw(x)
    turtle.turnLeft()
    t.fw(y)
    turtle.turnRight()
    turtle.turnRight()
  else
    turtle.turnRight()
    t.fw(x)
    turtle.turnLeft()
    t.fw(y)
    turtle.turnRight()
    turtle.turnRight()
  end
  x = 0
  y = 0
  facingfw = true
end

----------------------------------------------------
-- Go back up until z=0, then go to origin x=0,y=0
----------------------------------------------------
function goUp()
  while z < 0 do
    t.up()
    z = z+1
  end
  goToOrigin()
end

----------------------------------------------------
-- Main loop: 
--   1) dig the current layer with snake pattern
--   2) return to origin
--   3) go down 3 blocks to next layer
----------------------------------------------------
function mainloop()
  while true do
    local errorcode = digLayer()
    if errorcode ~= OK then
      -- Something happened: out of fuel, full inv, blocked, user interrupt ...
      goUp()
      return errorcode
    end
    goToOrigin()

    -- Drop down 3 more blocks for the next layer
    for i = 1,3 do
      t.digDown()
      local success = t.down()
      if not success then
        goUp()
        return BLOCKEDMOV
      end
      z = z - 1
      out("Z: " .. z)
    end
  end
end

----------------------------------------------------
-- Initialization (Open modem if asked, etc.)
----------------------------------------------------
if USEMODEM then
  rednet.open("right")
end

----------------------------------------------------
-- CHUNK BOUNDING via GPS:
--   1) Locate the turtle
--   2) Figure out chunk boundaries (16×16)
--   3) Adjust 'max' so we don't cross that chunk
----------------------------------------------------
do
  local gpsx, gpsy, gpsz = gps.locate()
  if not gpsx then
    error("ERROR: GPS not found or cannot locate. Chunk alignment unavailable.")
  end

  -- Which chunk are we in?
  local chunkX = math.floor(gpsx / 16)
  local chunkZ = math.floor(gpsz / 16)

  local chunkXMin = chunkX * 16
  local chunkXMax = chunkXMin + 15
  local chunkZMin = chunkZ * 16
  local chunkZMax = chunkZMin + 15

  -- How far until the chunk boundary in X or Z direction from our current location?
  -- We'll do a naive approach: we won't exceed the minimum leftover in either dimension.
  --
  -- Note: The script uses 'x' to track left-right movement and 'y' to track forward-back
  -- in a "snake." We don't truly know how that correlates to world X or Z. For a simple
  -- solution, we just pick the smallest leftover across X or Z, so we never cross the chunk.
  --
  local leftoverX = (gpsx >= 0)
                      and (chunkXMax - gpsx + 1)
                      or  (gpsx - chunkXMin + 1)
  local leftoverZ = (gpsz >= 0)
                      and (chunkZMax - gpsz + 1)
                      or  (gpsz - chunkZMin + 1)

  -- Force them to be at least 1..16
  if leftoverX < 1 then leftoverX = 1 end
  if leftoverZ < 1 then leftoverZ = 1 end
  if leftoverX > 16 then leftoverX = 16 end
  if leftoverZ > 16 then leftoverZ = 16 end

  -- We'll reduce the snake dimension to the min leftover so we won't exceed chunk boundaries
  max = math.min(leftoverX, leftoverZ, 16)

  print(("GPS location: (%.2f, %.2f, %.2f) => chunk=(%d,%d)."):format(gpsx,gpsy,gpsz,chunkX,chunkZ))
  print(("Chunk boundaries: X=[%d..%d], Z=[%d..%d]."):format(chunkXMin,chunkXMax,chunkZMin,chunkZMax))
  print("Adjusted 'max' for local snake to: "..max)
end

----------------------------------------------------
-- Let the user know we’re starting
----------------------------------------------------
out("\n\n\n-- WELCOME TO THE MINING TURTLE --\n\n")
dropInChest()

----------------------------------------------------
-- Start the 2-block descent, then main loop
----------------------------------------------------
while true do
  local downResult = goDown()
  if downResult ~= OK then
    -- Could not go down even 2 blocks => likely blocked by chest or out of fuel
    break
  end

  local errorcode = mainloop()
  dropInChest()

  -- If we ended for some reason other than FULLINV, break out
  if errorcode ~= FULLINV then
    break
  end
end

----------------------------------------------------
-- Cleanup
----------------------------------------------------
if USEMODEM then
  rednet.close("right")
end
