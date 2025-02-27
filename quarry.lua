os.loadAPI("inv")
os.loadAPI("t")

function getGPSPos()
	local x, y, z = gps.locate()
	if x == nil then
		return nil
	end
	return {x = x, y = y, z = z}
end


local start = getGPSPos()
local max = 16
local facingfw = true
local facing = nil
local corner = getChunkOrigin()

local OK = 0
local ERROR = 1
local LAYERCOMPLETE = 2
local OUTOFFUEL = 3
local FULLINV = 4
local BLOCKEDMOV = 5
local USRINTERRUPT = 6
local OUTOFCHUNK = 7

local CHARCOALONLY = false
local USEMODEM = false

local FUEL_SOURCES = {
    ["minecraft:charcoal"] = true,
    ["minecraft:coal"] = true,
    ["modern_industrialization:lignite_coal"] = true,
    ["minecraft:coal_block"] = true,
    ["minecraft:charcoal_block"] = true,
    ["modern_industrialization:lignite_coal_block"] = true
}

function isFuelItem(item)
    if item == nil then
        return false
    end
    if not FUEL_SOURCES[item.name] then
        return false
    end
    if CHARCOALONLY and item.name == "minecraft:coal" and item.damage == 0 then
        return false
    end
    return true
end

local tArgs = {...}
for i = 1, #tArgs do
    local arg = tArgs[i]
    if string.find(arg, "-") == 1 then
        for c = 2, string.len(arg) do
            local ch = string.sub(arg, c, c)
            if ch == "c" then
                CHARCOALONLY = true
            elseif ch == "m" then
                USEMODEM = true
            else
                write("Invalid flag '")
                write(ch)
                print("'")
            end
        end
    end
end

function out(s)
	local pos = getGPSPos()
    s2 = s .. " @ [" .. pos.x .. ", " .. pos.y .. ", " .. pos.z .. "]"
    print(s2)
    if USEMODEM then
        rednet.broadcast(s2, "miningTurtle")
    end
end

function dropInChest()
    local turns = 0
    while turns < 4 do
        local success, data = turtle.inspect()
        if success and data.name == "minecraft:chest" then
            out("Dropping items in chest")
            for i = 1, 16 do
                turtle.select(i)
                local d = turtle.getItemDetail()
                if d ~= nil and not isFuelItem(d) then
                    turtle.drop()
                    print("Dropped " .. d.name)
                end
            end
            for i = 1, turns do
                turtle.turnRight()
            end
            return
        end
        turtle.turnLeft()
        turns = turns + 1
    end
end

function goDown()
    while true do
        if turtle.getFuelLevel() <= fuelNeededToGoBack() then
            if not refuel() then
                return OUTOFFUEL
            end
        end
        if not turtle.down() then
            turtle.up()
            return
        end
    end
end

function fuelNeededToGoBack()
	local pos = getGPSPos()

	local y = math.abs(pos.y - start.y)
	local x = math.abs(pos.x - start.x)
	local z = math.abs(pos.z - start.z)

    return y + x + z + 2
end

function refuel()
    for i = 1, 16 do
        turtle.select(i)
        item = turtle.getItemDetail()
        if isFuelItem(item) and turtle.refuel(1) then
            return true
        end
    end
    return false
end


function getChunkOrigin()
	local pos = getGPSPos()
	if pos == nil then
		return nil
	end
	local x = math.floor(pos.x / 16) * 16
	local z = math.floor(pos.z / 16) * 16
	return {x = x, z = z}
end

function moveH()
    if inv.isInventoryFull() then
        out("Dropping thrash")
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

	-- if outside of chunk boundaries, error
	local gpsPos = getGPSPos()
	if gpsPos == nil then
		return ERROR
	end
	local chunkOrigin = getChunkOrigin()
	if chunkOrigin == nil then
		return ERROR
	end
	if gpsPos.x < chunkOrigin.x or gpsPos.x >= chunkOrigin.x + 16 or
		gpsPos.z < chunkOrigin.z or gpsPos.z >= chunkOrigin.z + 16 then
		return OUTOFCHUNK
	end
	

    if turtle.getFuelLevel() <= fuelNeededToGoBack() then
        if not refuel() then
            out("Out of fuel!")
            return OUTOFFUEL
        end
    end

	-- calculate x, z, as local coordinates by offsetting from chunk origin
	local x = gpsPos.x - chunkOrigin.x
	local z = gpsPos.z - chunkOrigin.z

    if facingfw and z < max - 1 then
        local dugFw = t.dig()
        if dugFw == false then
            out("Hit bedrock, can't keep going")
            return BLOCKEDMOV
        end
        t.digUp()
        t.digDown()
        if t.fw() == false then
            return BLOCKEDMOV
        end
        z = z + 1
    elseif not facingfw and z > 0 then
        t.dig()
        t.digUp()
        t.digDown()
        if t.fw() == false then
            return BLOCKEDMOV
        end
        z = z - 1
    else
        if x + 1 >= max then
            t.digUp()
            t.digDown()
            return LAYERCOMPLETE
        end
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
        x = x + 1
        if facingfw then
            turtle.turnRight()
        else
            turtle.turnLeft()
        end
        facingfw = not facingfw
    end
    return OK
end

function digLayer()
    local errorcode = OK
    while errorcode == OK do
        if USEMODEM then
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

function goToOrigin()
	local gpsPos = getGPSPos()
	if gpsPos == nil then
		return
	end
	local chunkOrigin = getChunkOrigin()
	if chunkOrigin == nil then
		return
	end
	local x = gpsPos.x - chunkOrigin.x
	local z = gpsPos.z - chunkOrigin.z
    if facingfw then
        turtle.turnLeft()
        t.fw(x)
        turtle.turnLeft()
        t.fw(z)
        turtle.turnRight()
        turtle.turnRight()
    else
        turtle.turnRight()
        t.fw(x)
        turtle.turnLeft()
        t.fw(z)
        turtle.turnRight()
        turtle.turnRight()
    end
    x = 0
    z = 0
    facingfw = true
end


function getFacingDirection()
	-- get position, move forward, get position again
	local pos1 = getGPSPos()
	if pos1 == nil then
		return nil
	end
	t.fw()
	local pos2 = getGPSPos()
	if pos2 == nil then
		return nil
	end
	-- move back to original position
	t.back()
	
	-- return direction vector
	return {x = pos2.x - pos1.x, z = pos2.z - pos1.z}
end

facing = getFacingDirection()

function goUp()
	local pos = getGPSPos()
    while pos.y < start.y do
        t.up()
        pos = getGPSPos()
    end
    goToOrigin()
end

function mainloop()
    while true do
        local errorcode = digLayer()
        if errorcode ~= OK then
            goUp()
            return errorcode
        end
        goToOrigin()
        for i = 1, 3 do
            t.digDown()
            success = t.down()
            if not success then
                goUp()
                return BLOCKEDMOV
            end
        end

		
    end
end

if USEMODEM then
    rednet.open("right")
end

out("\n\n\n-- WELCOME TO THE MINING TURTLE --\n\n")
dropInChest()

out("Chunk corner: [" .. corner.x .. ", "  .. corner.z .. "]")


while true do
    goDown()


    local errorcode = mainloop()
    dropInChest()
    if errorcode ~= FULLINV then
        break
    end
end

if USEMODEM then
    rednet.close("right")
end
