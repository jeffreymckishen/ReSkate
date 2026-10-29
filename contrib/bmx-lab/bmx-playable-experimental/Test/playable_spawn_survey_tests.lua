-- Pure local spawn survey fixtures; no game, native query or input is used.
local Rec=require("./ride_r1_record")
local G=require("./bike_geometry")
local T={}
function T.run()
 local cases,assertions=0,0
 local function check(ok,why)assertions+=1;assert(ok,why)end
 local function case(name,fn)cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why))end
 local function radius(p)return math.sqrt(p[1]^2+p[3]^2)end
 local function survey(options)
  options=options or {};local p={0,.5,0};local probes,floor_index=0,0
  local function cast(ray,floor)
   probes+=1
   if floor then
    floor_index+=1
    if floor_index==1 and options.floor_fault then
     if options.floor_fault=="malformed" then return "hit",{0/0,0,0}end
     return options.floor_fault
    end
    local top=0
    if options.planter and (ray.from[1]^2+(ray.from[3]-options.planter)^2)<=.25^2 then top=2.03 end
    if top>ray.from[2] then return "unavailable"end
    return "hit",{ray.from[1],top,ray.from[3]}
   end
   if options.obstacle_fault then return options.obstacle_fault end
   if options.planter then
    local dx,dz=ray.to[1]-ray.from[1],ray.to[3]-ray.from[3]
    local t=math.clamp((-ray.from[1]*dx+(options.planter-ray.from[3])*dz)/(dx*dx+dz*dz),0,1)
    local x,z=ray.from[1]+t*dx,ray.from[3]+t*dz
    if x*x+(z-options.planter)^2<=.25^2 and ray.from[2]<=2.03 then return "hit"end
   end
   return "clear"
  end
  local floor,misses={},0
  for _,ray in ipairs(Rec.survey_floor_rays(p,0))do
   local status,hit=cast(ray,true);local v=status=="hit" and Rec.survey_floor_hit(ray,hit)
   if v then floor[#floor+1]={dx=ray.dx,dz=ray.dz,y=v[2]}else misses+=1 end
  end
  local plane=Rec.survey_plane(floor)
  local verdict=Rec.survey_judge(0,floor,misses,plane,0)
  if not verdict.pass then return verdict,probes end
  local blocked=0;local rays=Rec.survey_obstacle_rays(p,0,plane)
  for i,ray in ipairs(rays)do
   if cast(ray,false)~="clear" then blocked+=1 end
   if i%(Rec.SURVEY_RAYS_PER_TICK-1)==0 or i==#rays then
    local check_ray=Rec.survey_check_ray(p,0);local status,hit=cast(check_ray,true)
    if status~="hit" or not Rec.survey_on_plane(plane,check_ray,Rec.survey_floor_hit(check_ray,hit)) then
     return {pass=false,why="closing floor query changed"},probes
    end
   end
  end
  return Rec.survey_judge(0,floor,misses,plane,blocked),probes
 end
 case("geometry plus margin fits the derived local radius",function()
  check(Rec.SURVEY_R==1.25 and Rec.SURVEY_CLEARANCE_MARGIN_M==.5,"local clearance radius")
  for _,capsule in ipairs(G.capsules)do
   for _,endpoint in ipairs({capsule.a,capsule.b})do
    check(radius(endpoint)+capsule.radius+.5<=Rec.SURVEY_R,"every capsule endpoint plus radius and margin is covered")
   end
  end
  for _,axle in ipairs({G.front_axle,G.rear_axle})do
   check(radius(axle)+G.wheel_radius+.5<=Rec.SURVEY_R,"full wheel extent and margin covered")
  end
  check(Rec.SURVEY_FOOTPRINT_M<=.75,"current footprint fits authored sizing")
  local counts=Rec.survey_counts()
  check(counts.floor==180 and counts.obstacle==1080 and Rec.SURVEY_RAYS_PER_TICK==32,"original query counts and tick budget")
  local expected={.75,.875,1,1.125,1.25}
  for i,r in ipairs(expected)do check(Rec.SURVEY_FLOOR_RINGS[i]==r,"local floor ring"..i)end
  for _,ray in ipairs(Rec.survey_obstacle_rays({0,.5,0},0,{a=0,b=0,c=0}))do
   check(math.abs(radius(ray.from)-.75)<1e-9 and math.abs(radius(ray.to)-1.25)<1e-9,"unchanged inner ring and local outer ring")
  end
 end)
 case("nearby planter outside spawn footprint does not veto Mount",function()
  local verdict,probes=survey({planter=2})
  check(verdict.pass,"2m planter outside local clearance must not reject spawn")
  check(probes==Rec.survey_counts().probes,"all floor/obstacle/closing floor queries still required")
 end)
 case("planter intruding at1m still refuses spawn",function()
  local verdict=survey({planter=1})
  check(not verdict.pass,"intruding planter cannot become clear terrain")
 end)
 case("missing malformed unavailable floor still refuses",function()
  for _,fault in ipairs({"clear","malformed","unavailable"})do
   local verdict=survey({floor_fault=fault})
   check(not verdict.pass and verdict.floor_misses>0,"unsafe floor result remains a refusal: "..fault)
  end
 end)
 case("obstruction and unknown obstacle results still refuse",function()
  for _,fault in ipairs({"hit","unavailable","malformed"})do
   local verdict=survey({obstacle_fault=fault})
   check(not verdict.pass and verdict.blocked>0,"every obstacle ray must be clear: "..fault)
  end
 end)
 case("freshness movement heading and residual limits stay original",function()
  check(Rec.SURVEY_RESIDUAL_M==.04 and Rec.SURVEY_SLOPE_DEG==.5
   and Rec.SURVEY_DOWNHILL_DEG==.5 and Rec.SURVEY_UPHILL_DEG==.75,"terrain limits unchanged")
  check(Rec.SURVEY_MAX_AGE_MS==45000 and Rec.SURVEY_MOVE_M==.25 and Rec.SURVEY_TURN_RAD==math.rad(5),"freshness limits unchanged")
  local sv={pass=true,at=0,p={0,.5,0},heading=0}
  check(Rec.survey_fresh(sv,{position={0,.5,0},heading=0},45000),"original age boundary")
  check(not Rec.survey_fresh(sv,{position={0,.5,0},heading=0},45001),"old survey still rejected")
  check(not Rec.survey_fresh(sv,{position={.251,.5,0},heading=0},1),"moved rider still rejected")
  check(not Rec.survey_fresh(sv,{position={0,.5,0},heading=math.rad(6)},1),"turned rider still rejected")
 end)
 return {cases=cases,assertions=assertions,native_qualified=false}
end
return T