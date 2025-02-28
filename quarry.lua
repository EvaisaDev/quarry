os.loadAPI("t")
os.loadAPI("inv")

local heading=0
local sx,sy,sz

function initHeading()
 local x1,y1,z1=gps.locate()
 if not x1 then return false end
 if not t.fw(1) then return false end
 local x2,y2,z2=gps.locate()
 if not x2 then return false end
 t.back(1)
 if x2>x1 then heading=1 end
 if x2<x1 then heading=3 end
 if z2>z1 then heading=2 end
 if z2<z1 then heading=0 end
 return true
end

function turnLeft()
 turtle.turnLeft()
 heading=(heading+3)%4
end

function turnRight()
 turtle.turnRight()
 heading=(heading+1)%4
end

function turnAround()
 turtle.turnRight()
 turtle.turnRight()
 heading=(heading+2)%4
end

function face(d)
 local diff=(d-heading)%4
 if diff==1 then turnRight() end
 if diff==2 then turnAround() end
 if diff==3 then turnLeft() end
end

function moveTo(x2,y2,z2)
 local x,y,z=gps.locate()
 if not x then return end
 if x2>x then
  face(1)
  while x<x2 do
   if not t.fw(1) then return end
   if not t.dig() then return end
   local nx,ny,nz=gps.locate()
   if not nx then return end
   x,y,z=nx,ny,nz
  end
 elseif x2<x then
  face(3)
  while x>x2 do
   if not t.fw(1) then return end
   if not t.dig() then return end
   local nx,ny,nz=gps.locate()
   if not nx then return end
   x,y,z=nx,ny,nz
  end
 end
 if z2>z then
  face(2)
  while z<z2 do
   if not t.fw(1) then return end
   if not t.dig() then return end
   local nx,ny,nz=gps.locate()
   if not nx then return end
   x,y,z=nx,ny,nz
  end
 elseif z2<z then
  face(0)
  while z>z2 do
   if not t.fw(1) then return end
   if not t.dig() then return end
   local nx,ny,nz=gps.locate()
   if not nx then return end
   x,y,z=nx,ny,nz
  end
 end
 if y2>y then
  while y<y2 do
   if not t.up(1) then return end
   local nx,ny,nz=gps.locate()
   if not nx then return end
   x,y,z=nx,ny,nz
  end
 elseif y2<y then
  while y>y2 do
   if not t.down(1) then return end
   local nx,ny,nz=gps.locate()
   if not nx then return end
   x,y,z=nx,ny,nz
  end
 end
end

function depositAll()
 local h=heading
 local f=false
 for i=1,4 do
  local ok,b=turtle.inspect()
  if ok and b and string.find(b.name,"chest") then
   for slot=1,16 do
    turtle.select(slot)
    local item=turtle.getItemDetail(slot)
    if item then
     if t.isFuelItem(item) then
      if item.count>16 then
       turtle.drop(item.count-16)
      end
     else
      turtle.drop()
     end
    end
   end
   f=true
   break
  end
  turnRight()
 end

 -- rotate twice
 turnRight()
 turnRight()



 if not f then
  error("No chest found")
 end
end

function goHome()
 moveTo(sx,sy,sz)
end

function init()
 t.refuel()
 local x,y,z=gps.locate()
 if not x then return end
 sx,sy,sz=x,y,z

 t.digDown()
 t.down(1)
 t.digDown()
 t.down(1)
 

 while not turtle.detectDown() do
  if not t.down(1) then return end
 end
 local x1,y1,z1=gps.locate()
 if not x1 then return end
 local cX=x1-(x1%16)
 local cZ=z1-(z1%16)
 moveTo(cX,y1,cZ)
 face(2)
end

function checkInventoryAndFuel()
 inv.stackItems()
 if inv.isInventoryFull() then
  inv.dropThrash()
 end
 inv.stackItems()
 t.refuel()
 if turtle.getFuelLevel()<100 or inv.isInventoryFull() then
  goHome()
  depositAll()
  initHeading()
  init()
  return true
 end
 return false
end

function mineLayer()
 local restart = false
 for row=0,15 do
  if(restart)then
	break
  end
  for col=0,15 do
   if col>0 then
    if not t.fw(1) then return false end
    if not t.dig() then return false end
    if(checkInventoryAndFuel()) then 
		restart = true
		break
	end
   end
  end
  if(restart)then
	break
  end
  if row<15 then
   if row%2==0 then
    turnLeft()
    if not t.fw(1) then return false end
    if not t.dig() then return false end
    if(checkInventoryAndFuel()) then 
		restart = true
		break
	end
    turnLeft()
   else
    turnRight()
    if not t.fw(1) then return false end
    if not t.dig() then return false end
    if(checkInventoryAndFuel()) then 
		restart = true
		break
	end
    turnRight()
   end
  end
 end

 if(restart)then
	return mineLayer()
 end

 return true
end

function excavateChunk()
 while true do
  local ok=mineLayer()
  if not ok then return end
  if not t.digDown() then
   goHome()
   return
  end
  if not t.down(1) then
   goHome()
   return
  end
 end
end

function main()
	if not initHeading() then return end

	while true do
		init()
		excavateChunk()
		goHome()
		depositAll()
		turnAround()
	end
end

main()
