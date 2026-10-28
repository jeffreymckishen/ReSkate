-- Ordinary bmx_ground_pump.h policy; world-down COM actuation, no integration.
local M=require("./force_math")
local Pump={}
local Controller={} Controller.__index=Controller
function Pump.new() return setmetatable({},Controller) end
function Controller:reset()
    self.direct_armed=false self.supported_seen=false self.previous_supported=false self.flight=false
    self.direct_elapsed=0 self.automatic_remaining=0 self.air_seconds=0
end
function Controller:step(h,s)
    if self.direct_elapsed==nil then self:reset() end
    local out={valid=false,applied=false,automatic_armed=false,status="disabled",down_acceleration=0,direct_input=0,automatic_input=0,direct_seconds=0,automatic_remaining=0,air_seconds=0}
    if not M.finite(h) or h<=0 or h>.1 then self:reset() out.status="invalid_sample" return out end
    for _,name in {"input","manual","nose_manual","world_upward_speed","pedal"} do
        if not M.finite(s[name]) then self:reset() out.status="invalid_sample" return out end
    end
    out.valid=true if not s.enabled or not s.operator_available then self:reset() return out end
    local input=math.clamp(s.input,-1,1) local released=input>=-.3
    if released then self.direct_armed=true self.direct_elapsed=0 end
    if not s.supported then
        self.direct_armed=false self.direct_elapsed=0 self.automatic_remaining=0
        if self.previous_supported and self.supported_seen then self.flight=true self.air_seconds=0
        elseif self.flight then self.air_seconds=math.min(60,self.air_seconds+h) end
        self.previous_supported=false out.air_seconds=self.air_seconds out.status="unsupported" return out
    end
    local landing=self.flight and self.air_seconds>.15 out.air_seconds=self.air_seconds
    self.supported_seen=true self.previous_supported=true self.flight=false self.air_seconds=0
    if s.inhibited or s.manual>.05 or s.nose_manual>.05 then
        self.direct_armed=false self.direct_elapsed=0 self.automatic_remaining=0
        out.status=s.inhibited and "inhibited" or "manual" return out
    end
    if landing then self.automatic_remaining=.3 out.automatic_armed=true end
    local direct,automatic=0,0
    if not released and self.direct_armed then
        local remaining=math.max(0,.45-self.direct_elapsed) direct=-input*math.min(h,remaining)/h
        self.direct_elapsed=math.min(.45,self.direct_elapsed+h) if self.direct_elapsed>=.45 then self.direct_armed=false end
    end
    if self.automatic_remaining>0 then automatic=.4*math.min(h,self.automatic_remaining)/h self.automatic_remaining=math.max(0,self.automatic_remaining-h) end
    out.direct_input=direct out.automatic_input=automatic out.direct_seconds=self.direct_elapsed out.automatic_remaining=self.automatic_remaining
    if s.world_upward_speed>.5 then out.status="upward" return out end
    out.down_acceleration=11*math.max(direct,automatic)*(math.abs(s.pedal)>.0001 and .75 or 1) out.applied=out.down_acceleration>0
    if out.applied then out.status=direct>0 and (automatic>0 and "combined" or "direct") or "automatic"
    elseif not released then out.status=self.direct_elapsed>=.45 and "exhausted" or "waiting_release" else out.status="neutral" end
    return out
end
return Pump
