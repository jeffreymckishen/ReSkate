-- One explicit spawn/read/visual/release trial. No input claim, rider mutation,
-- contact query, force packet or legacy C++ BMX call is made by this module.
local M=require("./force_math")
local G=require("./bike_geometry")
local Visual=require("./bike_visual")
local S={} local Runtime={} Runtime.__index=Runtime
local function xyz(v) return {v.x,v.y,v.z} end
local function vec(v) return typeof(v)=="vector" and M.vec(xyz(v),100000) end
local function canonical(x)
    return type(x)=="string" and x:match("^[1-9][0-9]*$")~=nil and #x<=20
        and (#x<20 or x<="18446744073709551615")
end
local function compare(a,b) if #a~=#b then return #a<#b and -1 or 1 end return a==b and 0 or (a<b and -1 or 1) end
local function equal_number(a,b) return a==b and (a~=0 or 1/a==1/b) end
local function same(a,b)
    if not a or not b or a.serial~=b.serial or a.time~=b.time or a.seconds~=b.seconds or a.mass~=b.mass then return false end
    for _,name in {"position","velocity","angular_velocity","inertia"} do
        for _,axis in {"x","y","z"} do if not equal_number(a[name][axis],b[name][axis]) then return false end end
    end
    for i=1,4 do if not equal_number(a.rotation[i],b.rotation[i]) then return false end end
    return true
end
local function valid(sample)
    if type(sample)~="table" or typeof(sample.epoch)~="userdata" or not canonical(sample.serial)
        or not M.finite(sample.time) or sample.time<0 or not M.finite(sample.seconds)
        or math.abs(sample.seconds-1/60)>1e-7 or not M.finite(sample.mass) or math.abs(sample.mass-G.mass)>.001
        or not vec(sample.position) or not vec(sample.velocity) or not vec(sample.angular_velocity) or not vec(sample.inertia) then return false end
    for i,axis in {"x","y","z"} do if math.abs(sample.inertia[axis]-G.inertia[i])>.001 then return false end end
    return Visual.from_sample(sample)~=nil
end
function S.new(api)
    return setmetatable({api=api or reskate,phase="idle",detail="No Lua bike spawned.",used=false,
        wall=0,phase_wall=0,read_wall=0,updates=0,body_release_attempted=false,
        visual_remove_requested=false,body_release_accepted=false,cleanup_unknown=false,
        creation_attempts=0,creation_unknown=false,clock_retried=false,asset_part=1},Runtime)
end
function Runtime:status()
    local measurement=nil
    if self.sample then
        measurement={serial=self.sample.serial,time=self.sample.time,seconds=self.sample.seconds,
            position=xyz(self.sample.position),rotation=self.sample.rotation,
            velocity=xyz(self.sample.velocity),angular_velocity=xyz(self.sample.angular_velocity)}
    end
    return {phase=self.phase,detail=self.detail,used=self.used,body=self.body~=nil,
        visual_updates=self.updates,serial=self.sample and self.sample.serial or nil,
        body_release_attempted=self.body_release_attempted,body_release_accepted=self.body_release_accepted,
        visual_remove_requested=self.visual_remove_requested,cleanup_unknown=self.cleanup_unknown,
        creation_attempts=self.creation_attempts,creation_unknown=self.creation_unknown,
        clock_retry_available=self.phase=="clock_prepared" and not self.clock_retried,
        last_measurement=measurement,
        scope="Lua bike visual and owned chassis only; no mounted rider, riding or tricks"}
end
function Runtime:request()
    if self.used or self.phase~="idle" then return false,"This VM already consumed its one spawn request." end
    self.used=true self.phase="armed" self.phase_wall=self.wall
    self.detail="Close the menu; one bike spawn is armed for 30 seconds."
    return true
end
function Runtime:retry_after_clock_warmup()
    if self.phase~="clock_prepared" or self.clock_retried then return false,"No preallocation readiness retry is available." end
    self.clock_retried=true self.visual_requested=false self.visual_remove_requested=false self.asset_part=1
    self.phase="armed" self.phase_wall=self.wall
    self.detail="One explicit readiness retry is armed. Close the menu."
    return true
end
function Runtime:stop(reason)
    if self.phase=="closed" or self.phase=="cleanup_unknown" then return end
    self.detail=tostring(reason or "explicit stop") self.phase="stopping"
    if self.creation_unknown then self.cleanup_unknown=true end
    if self.visual_requested and not self.visual_remove_requested then
        self.visual_remove_requested=true
        for id=1,8 do
            local ok=pcall(self.api.entities.remove,id)
            if not ok then self.cleanup_unknown=true end
        end
    end
    if self.body and not self.body_release_attempted then
        self.body_release_attempted=true
        local called,released,why=pcall(self.api.world.physics.release,self.body)
        self.body_release_accepted=called and released==true
        if self.body_release_accepted then self.body=nil else self.cleanup_unknown=true self.detail..="; release="..tostring(why or released) end
    end
    self.phase=self.cleanup_unknown and "cleanup_unknown" or "closed"
end
function Runtime:owned_measurement() return self.body,self.sample end
function Runtime:_assets()
    -- Exact names avoid a cold walk of the complete native asset registry.
    -- One lookup per tick keeps the eight-part preflight inside one deadline.
    local part=self.asset_part
    if part>#G.blueprints then return true end
    local name=G.blueprints[part]
    local low,high=self.api.entities.bounds(name)
    if low==nil and high==nil then return false,"waiting for loaded mesh bounds: "..name end
    if not vec(low) or not vec(high) or low.x>high.x or low.y>high.y or low.z>high.z
        or (low.x==high.x and low.y==high.y and low.z==high.z) then
        return nil,"invalid loaded mesh bounds: "..name
    end
    if part==3 or part==4 then
        local radius=math.max(high.y-low.y,high.z-low.z)*.5
        if math.abs(radius-G.wheel_radius)>.002 then
            return nil,string.format("wheel geometry mismatch %s: measured %.6f m, Lua %.6f m",name,radius,G.wheel_radius)
        end
    end
    self.asset_part+=1
    if self.asset_part<=#G.blueprints then return false,"checked loaded mesh bounds: "..name end
    return true
end
function Runtime:_place(matrices)
    -- A setter can accept only a prefix. Cleanup owns all eight IDs from the
    -- first attempted call, rather than waiting for the complete batch.
    self.visual_requested=true
    for id,matrix in matrices do
        local ok,why=self.api.entities.set(id,G.blueprints[id],{matrix=matrix},false,nil,{solid=false})
        if not ok then return false,"bike visual request refused: "..tostring(why) end
    end
    return true
end
function Runtime:_update(dt)
    if self.phase=="idle" or self.phase=="closed" or self.phase=="cleanup_unknown" or self.phase=="clock_prepared" then return end
    if not M.finite(dt) or dt<0 or dt>250 then self:stop("invalid/stalled wall tick") return end
    self.wall+=dt
    local focus=self.api.input.focus()
    local ready=focus and focus.focused and focus.gameplay and not focus.interface_open
    if self.phase=="armed" then
        if self.wall-self.phase_wall>30000 then self:stop("spawn Arm expired") return end
        if not ready then return end
        local actor=self.api.skater.get()
        if not actor or not vec(actor.position) or not M.finite(actor.heading) then self:stop("local actor placement unavailable") return end
        -- Keep the unmounted body away from the local rider. No floor is inferred.
        self.root={actor.position.x+3*math.cos(actor.heading),actor.position.y+.5,actor.position.z-3*math.sin(actor.heading)}
        self.rotation={0,math.sin(actor.heading*.5),0,math.cos(actor.heading*.5)}
        self.phase="loading_assets" self.phase_wall=self.wall
    end
    if not ready then self:stop("focus/menu/gameplay changed") return end
    if self.phase=="loading_assets" then
        if self.wall-self.phase_wall>5000 then self:stop("bike asset preflight timed out") return end
        local assets,why=self:_assets()
        if assets==nil then self:stop(why) return end
        if not assets then
            self.detail=why
            return
        end
        local placed,why=self:_place(assert(Visual.matrices(self.root,self.rotation)))
        if not placed then self:stop(why) return end
        self.phase="waiting_visuals" self.phase_wall=self.wall
        return
    end
    if self.phase=="waiting_visuals" then
        for id=1,8 do
            local state=self.api.entities.status(id)
            if state=="missing" or state=="hidden" then self:stop("bike part is unavailable: "..id) return end
            if state~="ready" then
                if self.wall-self.phase_wall>5000 then self:stop("bike entity readiness timed out") end
                return
            end
        end
        local definition=assert(Visual.definition(self.root,self.rotation))
        self.creation_attempts+=1 self.creation_unknown=true
        self.body,self.detail=self.api.world.physics.create(definition)
        if not self.body then
            -- This exact native refusal covers unavailable anchor capture OR clock
            -- qualification, before slot reservation/allocation (owned_bodies.cpp).
            -- It does not identify the cause or prove clock initialization.
            -- No retry occurs without the separate explicit action.
            local warmup=self.detail=="waiting for a fresh qualified 60 Hz physics step"
            if warmup then self.creation_unknown=false end
            self:stop("body creation refused or unknown: "..tostring(self.detail))
            if warmup and not self.clock_retried and not self.cleanup_unknown then
                self.phase="clock_prepared"
                self.detail="Preallocation readiness unavailable; no slot was reserved. Use the separate readiness retry once."
            end
            return
        end
        self.creation_unknown=false
        self.phase="waiting_sample" self.phase_wall=self.wall self.read_wall=self.wall
    end
    if self.phase=="waiting_sample" or self.phase=="spawned" then
        if self.wall-self.phase_wall>5000 then self:stop("five-second unmounted spawn trial completed") return end
        local sample,why=self.api.world.physics.read(self.body)
        if not sample then self:stop("body observation unavailable: "..tostring(why)) return end
        if not valid(sample) then self:stop("invalid measured bike body") return end
        if self.sample then
            local order=compare(sample.serial,self.sample.serial)
            if order<0 or sample.time<self.sample.time or (order>0 and sample.time<=self.sample.time)
                or (order==0 and not same(sample,self.sample)) then self:stop("body observation regressed or changed within its epoch") return end
            if order==0 then
                if self.wall-self.read_wall>100 then self:stop("body native clock stopped advancing") end
                return
            end
        end
        -- A bounded unmounted test; no controller is allowed to chase a lost body.
        local delta=M.sub(xyz(sample.position),M.add(self.root,M.turn(self.rotation,G.com)))
        if M.length(delta)>2 then self:stop("body left the two-metre spawn envelope") return end
        local placed,why=self:_place(assert(Visual.from_sample(sample)))
        if not placed then self:stop(why) return end
        self.sample=sample self.read_wall=self.wall self.updates+=1
        self.phase="spawned" self.detail="Lua bike parts follow the measured chassis. Rider and controls remain untouched."
    end
end
function Runtime:update(dt)
    local ok,why=pcall(self._update,self,dt)
    if not ok then self:stop("spawn adapter exception: "..tostring(why)) end
end
return S
