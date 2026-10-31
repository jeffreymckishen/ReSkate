-- Mod-local points, never native score/progression. A queued authored catch can
-- appear as pending HUD text; it earns nothing until its force receipt has a
-- coherent applied successor and a separate measured landing is qualified.
local Frame=require("./frame_identity")
local Identity=require("./lease_identity")
local Score={}
local MAX_SCORE,MAX_EVENTS=999999999,16
local channels=table.freeze({
    barspin=table.freeze({name="Barspin",base=200}),
    tailwhip=table.freeze({name="Tailwhip",base=350}),
    -- Legacy mod difficulty1; an authored local value, C0 still uncalibrated.
    one_hander=table.freeze({name="One Hander",base=100}),
})
-- These are the legacy mod's authored difficulty2/3 bases and local repeat,
-- combination and category defaults. C0 has not calibrated them to Skate.
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function bounded(v,lo,hi) return finite(v) and v>=lo and v<=hi end
local function count(v,hi) return bounded(v,0,hi) and v%1==0 end
local function sat(v) return math.floor(math.clamp(v,0,MAX_SCORE)) end
local function dense(v,limit)
    if not plain(v) then return nil end
    local n,high=0,0
    for k in next,v do
        n+=1
        if n>limit or not count(k,limit) or k==0 then return nil end
        high=math.max(high,k)
    end
    return n==high and n or nil
end
local function same_owner(a,b)
    if not rawequal(a.body_handle,b.body_handle) then return false end
    for _,key in ipairs({"lease_handle","generation","user","sequence","source_epoch","context_generation"}) do
        if a.source[key]~=b.source[key] then return false end
    end
    return true
end
local function read_frame(raw)
    local f,why=Frame.copy(raw)
    if not f then return nil,why end
    if not f.fresh or not f.gates.focused or f.gates.menu_open then return nil,"owner_or_focus_gate" end
    return f
end
local function totals(rows,confirmed_only)
    local points,n,unique,repeats=0,0,0,{}
    for _,r in ipairs(rows) do
        if not confirmed_only or r.confirmed then
            local repeated=repeats[r.channel] or 0
            if repeated==0 then unique+=1 end
            points+=math.floor(channels[r.channel].base*math.max(.1,1-.25*repeated))
            repeats[r.channel]=repeated+1;n+=1
        end
    end
    local combo=math.min(2,1+.2*math.max(0,unique-1))
    local multiplier=math.min(4,1+.5*unique)
    return points,sat(points*combo*multiplier),n,multiplier,combo
end
function Score.new()
    local rows,owner,last_sequence,last_serial,last_landing={},nil,nil,nil,nil
    local stopped,issue=false,"none"
    local banked,best,landed,last_closed=0,0,0,nil
    local object={}
    local function lose(reason,terminal)
        local points,_,n=totals(rows,false)
        if n>0 then
            last_closed=table.freeze({outcome="lost",reason=reason,score=0,points=points,tricks=n,
                authored=true,native_score=false,native_landing=false})
        end
        rows={};issue=reason;stopped=stopped or terminal==true
        return false,reason
    end
    local function bound_frame(raw)
        local f,why=read_frame(raw)
        if not f then return nil,why end
        if owner and not same_owner(owner,f) then return nil,"owner_changed" end
        return f
    end
    function object:queue(raw,presentation)
        if stopped then return false,"stopped" end
        local f,why=bound_frame(raw)
        if not f then return lose(why,true) end
        if not plain(presentation) or presentation.valid~=true
            or presentation.scope~="predictive_accepted_ray_barspin_only"
            or presentation.realized~=false or presentation.completion_qualified~=false
            or presentation.serial~=f.serial or not Identity.is_nonzero_u64(presentation.accepted_sequence) then
            return lose("invalid_adopt_receipt",true)
        end
        if presentation.authored_events==nil then return true,"no_events" end
        local n=dense(presentation.authored_events,2)
        if not n then return lose("invalid_event_array",true) end
        if n==0 then return true,"no_events" end
        if last_sequence and Identity.compare(presentation.accepted_sequence,last_sequence)~=1 then
            return false,"stale_sequence"
        end
        if last_serial and Identity.compare(f.serial,last_serial)~=1
            or last_landing and Identity.compare(f.serial,last_landing)~=1 then return false,"stale_body_serial" end
        if #rows+n>MAX_EVENTS then return lose("event_capacity",true) end
        local additions,seen={},{}
        for i=1,n do
            local e=presentation.authored_events[i]
            local c=plain(e) and channels[e.channel] or nil
            local pose=c and e.channel=="one_hander"
            local shape=c and (pose and e.kind=="authored_pose_recovery"
                and e.movement_id==36 and e.side=="left" and e.direction==nil
                or not pose and e.kind=="authored_channel_catch" and (e.direction==-1 or e.direction==1))
            if not c or not shape or seen[e.channel]
                or e.scope~="mod_authored_accepted_step" or e.catch_phase~="regrip_complete" or e.authored_completion~=true
                or e.body_serial~=f.serial or e.accepted_sequence~=presentation.accepted_sequence
                or e.source_observation_serial~=f.source.observation_serial
                or e.prediction_only~=true or e.native_application~="unobserved"
                or e.native_application_observed~=false or e.native_catch~=false or e.native_landing~=false
                or e.landing_quality_available~=false or e.completion_qualified~=false then
                return lose("invalid_catch_event",true)
            end
            seen[e.channel]=true
            additions[i]={channel=e.channel,name=c.name,direction=e.direction,serial=f.serial,time=f.time,
                seconds=f.seconds,sequence=presentation.accepted_sequence,confirmed=false}
        end
        -- Consume the entire bounded batch only after every edge is checked.
        owner=owner or f
        for _,row in ipairs(additions) do rows[#rows+1]=row end
        last_sequence,last_serial=presentation.accepted_sequence,f.serial
        issue="pending_application"
        return true,issue
    end
    function object:observe(raw,receipt)
        if stopped then return false,"stopped" end
        if not plain(receipt) or not Identity.is_nonzero_u64(receipt.sequence) then
            return lose("invalid_application_receipt",true)
        end
        local first
        for _,r in ipairs(rows) do if r.sequence==receipt.sequence then first=r;break end end
        if not first then return false,"not_score_sequence" end
        local f,why=bound_frame(raw)
        if not f then return lose(why,true) end
        if receipt.requested_serial~=first.serial then return lose("application_binding_mismatch",true) end
        if receipt.outcome=="queued" then
            if receipt.produced_serial~="0" or receipt.force_attempted~=false or receipt.torque_attempted~=false
                or receipt.retained~=false or receipt.quarantined~=false or receipt.cleanup_disposition~="none"
                or receipt.successor~=nil then
                return lose("invalid_queued_receipt",true)
            end
            return true,"pending_application"
        end
        if receipt.outcome=="partial" or receipt.outcome=="rejected" or receipt.outcome=="expired" then
            return lose("command_"..receipt.outcome,true)
        end
        local successor=receipt.successor
        if receipt.outcome~="applied" or receipt.force_attempted~=true or receipt.torque_attempted~=true
            or receipt.retained~=false or receipt.quarantined~=false or receipt.cleanup_disposition~="none"
            or Identity.bounded_delta(receipt.produced_serial,first.serial,1)~=1 then
            return lose("application_unqualified",true)
        end
        -- An applied row without its later measured successor stays pending.
        if successor==nil then return true,"pending_successor" end
        local steps=plain(successor) and Identity.bounded_delta(successor.serial,first.serial,64)
        if not steps or steps<2 or type(successor.epoch)~="userdata"
            or successor.seconds~=first.seconds or not finite(successor.time)
            or math.abs(successor.time-first.time-steps*first.seconds)>1e-6
            or Identity.compare(f.serial,successor.serial)<0 or f.time<successor.time then
            return lose("application_successor_mismatch",true)
        end
        local current_steps=Identity.bounded_delta(f.serial,successor.serial,64)
        if not current_steps or math.abs(f.time-successor.time-current_steps*first.seconds)>1e-6 then
            return lose("application_observation_mismatch",true)
        end
        for _,r in ipairs(rows) do
            if r.sequence==receipt.sequence then
                if r.confirmed and r.confirmed_serial~=successor.serial then return lose("application_successor_changed",true) end
                r.confirmed,r.confirmed_serial=true,successor.serial
            end
        end
        issue="pending_landing"
        return true,issue
    end
    function object:land(raw,quality)
        if stopped then return false,"stopped" end
        if #rows==0 then return false,"no_pending_tricks" end
        local f,why=bound_frame(raw)
        if not f then return lose(why,true) end
        if last_landing and Identity.compare(f.serial,last_landing)~=1 then return false,"stale_landing" end
        if not plain(quality) or quality.available~=true or quality.qualified~=true then
            last_landing=f.serial
            return lose("landing_quality_unavailable",false)
        end
        -- This record must come from an actual current measured landing producer.
        -- The current ray adapter declares quality unavailable and cannot supply it.
        if quality.scope~="measured_mod_landing_v1" or quality.serial~=f.serial
            or not rawequal(quality.physics_epoch,f.physics_epoch)
            or quality.source_observation_serial~=f.source.observation_serial
            or quality.grounded~=true or quality.support_known~=true
            or quality.observations_complete~=true or quality.owned_bodies_excluded~=true
            or quality.native_landing~=false
            or not bounded(quality.body_up_alignment,.5,1)
            or not bounded(quality.support_up_alignment,.15,1)
            or not bounded(quality.heading_cos,-1,1) or math.abs(quality.heading_cos)<math.cos(math.rad(35))
            or not bounded(quality.closing_normal_speed,0,7)
            or not bounded(quality.settled_seconds,.06,.5)
            or not count(quality.settled_samples,31) or quality.settled_samples<4 then
            last_landing=f.serial
            return lose("landing_quality_invalid",false)
        end
        for _,r in ipairs(rows) do
            if not r.confirmed or Identity.compare(f.serial,r.serial)~=1
                or Identity.compare(f.serial,r.confirmed_serial)<0 then
                last_landing=f.serial
                return lose("application_unobserved_at_landing",false)
            end
        end
        local points,score,n,multiplier,combo=totals(rows,false)
        banked=sat(banked+score);best=math.max(best,score);landed=sat(landed+1)
        last_closed=table.freeze({outcome="landed",reason="qualified_measured_mod_landing",score=score,
            points=points,tricks=n,multiplier=multiplier,combo_factor=combo,
            authored=true,native_score=false,native_landing=false})
        rows={};last_landing=f.serial;issue="none"
        return true,last_closed
    end
    function object:cancel(reason)
        if stopped then return false,"stopped" end
        local why=type(reason)=="string" and #reason>0 and #reason<=100 and reason or "cancelled"
        lose(why,true);return true,why
    end
    object.stop=object.cancel
    function object:view()
        local points,score,n,multiplier,combo=totals(rows,false)
        local _,eligible,confirmed=totals(rows,true)
        local display={}
        for i=math.max(1,#rows-3),#rows do
            local r=rows[i]
            display[#display+1]=table.freeze({name=r.name,channel=r.channel,body_serial=r.serial,
                accepted_sequence=r.sequence,state=r.confirmed and "force_applied_observed" or "prediction_only"})
        end
        return table.freeze({scope="authored_mod_score_only",calibration="C0_UNRUN",native_score=false,
            active=n>0,pending_points=points,pending_score=score,eligible_pending_score=eligible,
            tricks=n,observed_command_tricks=confirmed,multiplier=multiplier,combo_factor=combo,
            rows=table.freeze(display),banked_total=banked,best_combo=best,landed_combos=landed,
            last_closed=last_closed,stopped=stopped,issue=issue})
    end
    object.status=object.view
    return table.freeze(object)
end
Score.rules=table.freeze({barspin=200,tailwhip=350,one_hander=100,repeat_step=.25,repeat_floor=.1,
    combination_step=.2,combination_cap=2,category_step=.5,multiplier_cap=4,
    maximum_events=MAX_EVENTS,maximum_score=MAX_SCORE,calibration="C0_UNRUN"})
return table.freeze(Score)
