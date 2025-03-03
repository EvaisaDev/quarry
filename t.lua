local MAXTRIES = 100

function turnAround()
	local success = false
	
	success = turtle.turnRight()
	success = success and turtle.turnRight()
	
	return success
end

function dig()
	local tries = 0
	
	while turtle.detect() do

		local s, data = turtle.inspect()
		if data.name == "minecraft:bedrock" then
			printError("Hit bedrock forwards!")
			return false
		end
		
		turtle.dig()
		sleep(0.4)
		
		tries = tries+1
		if tries > MAXTRIES then

			printError("Can't dig forward")
			return false
			
		end
	end
	
	return true
end

function digDown()
	local tries = 0
	
	while turtle.detectDown() do

		local s, data = turtle.inspectDown()
		if data.name == "minecraft:bedrock" then
			printError("Hit bedrock below!")
			return false
		end
	
		turtle.digDown()
		sleep(0.4)
		
		tries = tries+1
		if tries > MAXTRIES then
			printError("Can't dig down")
			return false
		end
	end
	
	return true
end

function digUp()
	local tries = 0
	
	while turtle.detectUp() do

		local s, data = turtle.inspectUp()
		if data.name == "minecraft:bedrock" then
			printError("Hit bedrock above!")
			return false
		end
	
		turtle.digUp()
		sleep(0.4)
		
		tries = tries+1
		if tries > MAXTRIES then
			printError("Can't dig up")
			return false
		end
	end
	
	return true
end


function fw(l)
	l=l or 1
	
	for i=1, l do
	
		local tries = 0
		
		while turtle.forward() ~= true do
			
			turtle.dig()
			turtle.attack()
			sleep(0.2)
			
			tries = tries+1
			if tries > MAXTRIES then
				printError("Can't move forward")
				return false
			end
		end
	end
	
	return true
end

function up(l)
	l=l or 1
	
	for i=1, l do
	
		local tries = 0
		
		while turtle.up() ~= true do
			
			turtle.digUp()
			turtle.attackUp()
			sleep(0.2)
			
			tries = tries+1
			if tries > MAXTRIES then
				printError("Can't move up")
				return false
			end
		end
	end
	
	return true
end

function down(l)
	l=l or 1
	
	for i=1, l do
	
		local tries = 0
	
		while turtle.down() ~= true do
	
			turtle.digDown()
			turtle.attackDown()
			sleep(0.2)
		
			tries = tries+1
			if tries > MAXTRIES then
				printError("Can't move down")
				return false
			end
		end
	end
	
	return true
end

function back(l)
	l=l or 1
	
	for i=1, l do
	
		if turtle.back() ~= true then
			turnAround()
			fw()
			turnAround()
		end
	end
end

local FUEL_SOURCES={
	["minecraft:charcoal"]=true,
	["minecraft:coal"]=true,
	["modern_industrialization:lignite_coal"]=true,
	["minecraft:coal_block"]=true,
	["minecraft:charcoal_block"]=true,
	["modern_industrialization:lignite_coal_block"]=true
  }
  
function isFuelItem(item)
	if not item then
	  return false
	end
	if not FUEL_SOURCES[item.name] then
	  return false
	end
	if CHARCOALONLY and item.name=="minecraft:coal" and item.damage==0 then
	  return false
	end
	return true
end
  
function refuel()
	for i=1,16 do
	  turtle.select(i)
	  local item=turtle.getItemDetail()
	  if isFuelItem(item) and turtle.refuel(1) then
		return true
	  end
	end
	return false
end