-- Source-only draft. Injected callbacks are adapters, never native authority.
local Probe={}
local Object={}; Object.__index=Object
local PRIVATE=setmetatable({}, {__mode="k"})
local C={prepare_limit=8,wait_ms=10000,approval_ms=15000,survey_ms=500,
    ray_budget=8,fresh_ms=100,watchdog_ms=4000,read_ms=250,radius=.1,half_margin=.75}
local STAGES={"initial_park","initial_park_observed","transform","categories","collisions",
    "motion","wake","dynamic_observed","repark","repark_observed"}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function plain(t) return type(t)=="table" and getmetatable(t)==nil end
local function vec(v)
    if not plain(v) or #v~=3 then return false end
    for k,n in pairs(v) do if (k~=1 and k~=2 and k~=3) or not finite(n) or math.abs(n)>100000 then return false end end
    return true
end
local function serial(v)
    return type(v)=="string" and #v<=20 and string.match(v,"^[1-9]%d*$")~=nil
        and (#v<20 or v<="18446744073709551615")
end
local function serial_after(a,b) return #a>#b or (#a==#b and a>b) end
local function copy(value,depth,budget)
    depth=depth or 0; budget=budget or {n=0}; budget.n+=1
    if depth>12 or budget.n>4096 then error("receipt exceeds copy bound",0) end
    if type(value)=="number" then if not finite(value) then error("nonfinite receipt",0) end;return value end
    if type(value)=="string" then if #value>512 then error("receipt string too long",0) end;return value end
    if type(value)=="boolean" or value==nil then return value end
    if not plain(value) then error("receipt must contain plain data only",0) end
    local out,count={},0
    for k,v in pairs(value) do
        count+=1
        if count>64 or (type(k)~="string" and type(k)~="number")
            or (type(k)=="string" and #k>64) or (type(k)=="number" and (k<1 or k>64 or k%1~=0)) then
            error("receipt key bound",0)
        end
        out[k]=copy(v,depth+1,budget)
    end
    return out
end
local function call(s,name,...)
    local fn=s.api[name]
    if type(fn)~="function" then return false,"missing adapter: "..name end
    return pcall(fn,...)
end
local function event(s,name,detail)
    if #s.events<24 then table.insert(s.events,{name=name,detail=string.sub(tostring(detail or ""),1,160),at_ms=s.last_now or 0}) end
end
local function finish(s,phase,why)
    if s.terminal then return end
    s.phase,s.reason,s.terminal=phase,why,true
    event(s,"terminal",why)
end
local function now(s)
    local ok,n=call(s,"now")
    if not ok or not finite(n) or n<0 or (s.last_now and n<s.last_now) then
        if s.body then s.cleanup="unconfirmed";s.operator_end_required=true end
        finish(s,"unconfirmed","clock_unavailable_or_regressed");return nil
    end
    s.last_now=n;return n
end
local function context(s,closed)
    local ok,c=call(s,"context")
    if not ok or not plain(c) or type(c.level)~="string" or #c.level==0 or #c.level>200
        or not vec(c.position) or not finite(c.heading) or not finite(c.speed) or math.abs(c.speed)>.05
        or c.on_foot~=true or c.airborne~=false or c.focused~=true or c.gameplay~=true
        or c.menu_known~=true or c.menu_open~=false or type(c.interface_open)~="boolean" then
        return nil,"context_unavailable_or_not_stationary_on_foot"
    end
    if s.anchor then
        if c.level~=s.anchor.level then return nil,"level_changed" end
        local d=0;for j=1,3 do d+=(c.position[j]-s.anchor.position[j])^2 end
        local h=math.atan2(math.sin(c.heading-s.anchor.heading),math.cos(c.heading-s.anchor.heading))
        if d>.05^2 or math.abs(h)>.03 then return nil,"actor_moved_since_survey" end
    end
    if closed and c.interface_open then return nil,"close_interface" end
    return copy(c)
end
local function release_before_begin(s,why)
    if s.body and s.counts.begin==0 and not s.release_attempted then
        s.release_attempted=true;s.counts.release+=1
        local ok,a,b=call(s,"release",s.body)
        s.release_report={returned=ok,accepted=ok and a==true,reason=string.sub(tostring(b or (not ok and a) or ""),1,160)}
    end
    if s.body then s.cleanup="unconfirmed";s.operator_end_required=true end
    finish(s,"refused",why)
end
local function definition(position)
    return {mass=12,inertia={2,3,4},position=copy(position),rotation={0,0,0,1},
        capsules={{a={0,0,0},b={0,.2,0},radius=C.radius}}}
end
local function start_survey(s,refresh,t)
    s.phase=refresh and "refreshing" or "surveying"
    s.survey={refresh=refresh,started_ms=t,index=1,rays={},floor_hits={},observations={}}
    local q=s.survey;local x,z=s.candidate.x,s.candidate.z
    for _,offset in ipairs({{0,0},{-.5,0},{.5,0},{0,-.5},{0,.5}}) do
        table.insert(q.rays,{kind="floor",from={x+offset[1],s.anchor.position[2]+1,z+offset[2]},
            to={x+offset[1],s.anchor.position[2]-3,z+offset[2]}})
    end
end
local function append_obstacles(s)
    local q=s.survey;local y=q.floor_hits[1][2]
    for _,p in ipairs(q.floor_hits) do if math.abs(p[2]-y)>.03 then return false,"floor_samples_not_flat" end end
    if y>s.anchor.position[2]+.25 or s.anchor.position[2]-y>3 then return false,"floor_height_out_of_bound" end
    if q.refresh and math.abs(y-s.candidate.floor_y)>.01 then return false,"approved_floor_changed" end
    if not q.refresh then s.candidate.floor_y=y;s.candidate.position={s.candidate.x,y+1,s.candidate.z} end
    local x,z=s.candidate.x,s.candidate.z
    -- 24 horizontal diameters and nine vertical segments sample a generous box.
    -- Neither these rays nor an operator observation prove swept-volume clearance.
    for _,height in ipairs({.35,1,1.65}) do
        for k=0,7 do
            local a=k*math.pi/8;local dx,dz=math.cos(a)*C.half_margin,math.sin(a)*C.half_margin
            table.insert(q.rays,{kind="obstacle",from={x-dx,y+height,z-dz},to={x+dx,y+height,z+dz}})
        end
    end
    for _,dx in ipairs({-.5,0,.5}) do for _,dz in ipairs({-.5,0,.5}) do
        table.insert(q.rays,{kind="obstacle",from={x+dx,y+.35,z+dz},to={x+dx,y+1.65,z+dz}})
    end end
    return true
end
local function survey_tick(s,t)
    local q=s.survey
    if t-q.started_ms>C.survey_ms then finish(s,"refused","survey_expired");return end
    local ctx,why=context(s,q.refresh)
    if not ctx then finish(s,"refused",why);return end
    for _=1,C.ray_budget do
        local ray=q.rays[q.index]
        if not ray then break end
        s.counts.rays+=1
        local ok,r=call(s,"ray",copy(ray.from),copy(ray.to))
        if not ok or not plain(r) or (r.status~="hit" and r.status~="clear") then
            finish(s,"refused","ray_unavailable_or_malformed");return
        end
        if ray.kind=="floor" then
            if r.status~="hit" or not vec(r.position) or not finite(r.fraction) or r.fraction<0 or r.fraction>1 then
                finish(s,"refused","floor_not_measured");return
            end
            for j=1,3 do
                if math.abs(r.position[j]-(ray.from[j]+(ray.to[j]-ray.from[j])*r.fraction))>.025 then
                    finish(s,"refused","floor_hit_off_segment");return
                end
            end
            table.insert(q.floor_hits,copy(r.position))
        elseif r.status~="clear" then finish(s,"refused","obstacle_ray_hit");return end
        table.insert(q.observations,{kind=ray.kind,from=ray.from,to=ray.to,status=r.status,
            position=r.position and copy(r.position) or nil,fraction=r.fraction,tick_started_ms=t})
        q.index+=1
        if q.index==6 then
            local passed,issue=append_obstacles(s)
            if not passed then finish(s,"refused",issue);return end
        end
    end
    local after=now(s);if not after or s.terminal then return end
    local same,issue=context(s,q.refresh)
    if not same then finish(s,"refused",issue);return end
    if after-q.started_ms>C.survey_ms then finish(s,"refused","survey_expired");return end
    if q.index>#q.rays then
        local evidence={started_ms=q.started_ms,at_ms=after,ray_count=#q.observations,observations=q.observations,
            scope="bounded_segments_plus_operator_observation_not_volume_clearance"}
        if q.refresh then
            s.refresh=evidence;s.fresh_at=after;s.phase="create_ready"
        else
            s.initial_survey=evidence;s.candidate.at_ms=after;s.phase="await_visual_approval"
        end
        s.survey=nil;event(s,"survey_complete",q.refresh and "refresh" or "initial")
    end
end
local function good_sample(a)
    if not plain(a) or not serial(a.serial) or not finite(a.time) or a.time<0 or not finite(a.seconds)
        or a.seconds<.01 or a.seconds>.03 or not vec(a.position) or not vec(a.velocity)
        or not vec(a.angular_velocity) or not vec(a.inertia) or a.mass~=12
        or not plain(a.rotation) or #a.rotation~=4 then return false end
    local n=0;for _,v in ipairs(a.rotation) do if not finite(v) then return false end;n+=v*v end
    if math.abs(n-1)>.001 then return false end
    for j=1,3 do if math.abs(a.inertia[j]-({2,3,4})[j])>.001 then return false end end
    return true
end
local function quaternion(q)
    if not plain(q) or #q~=4 then return false end
    local n=0;for _,v in ipairs(q) do if not finite(v) then return false end;n+=v*v end
    return math.abs(n-1)<.001
end
local function zero(v,n)
    if not plain(v) or #v~=n then return false end
    for i=1,n do if v[i]~=0 then return false end end
    return true
end
local function epoch(e)
    return plain(e) and serial(e.serial) and finite(e.time) and e.time>=0
        and finite(e.seconds) and e.seconds>=.01 and e.seconds<=.03
end
local function observed(o,dynamic,collisions,parked)
    if not plain(o) or o.available~=true or o.dynamic~=dynamic or o.shape_count~=1
        or not plain(o.categories) or #o.categories~=1 or o.categories[1]~=0
        or not plain(o.collisions) or #o.collisions~=1 or o.collisions[1]~=collisions
        or not plain(o.sample) or not epoch(o.sample.epoch) or not vec(o.sample.position)
        or not vec(o.sample.velocity) or not vec(o.sample.angular_velocity) or not vec(o.sample.inertia)
        or not quaternion(o.sample.rotation) or not finite(o.sample.mass) or o.sample.mass<=0
        or not finite(o.angular_fourth) then return false end
    if not plain(o.force) or #o.force~=4 or not plain(o.torque) or #o.torque~=4 then return false end
    for i=1,4 do if not finite(o.force[i]) or not finite(o.torque[i]) then return false end end
    if parked and (not zero(o.sample.velocity,3) or not zero(o.sample.angular_velocity,3)
        or not zero(o.force,4) or not zero(o.torque,4)) then return false end
    return true
end
local function later(a,b)
    return epoch(a) and epoch(b) and serial_after(a.serial,b.serial) and a.time>b.time
end
local function cleanup_confirmed(r)
    if r.terminal~=true or r.phase~="terminal" or r.cleanup~="confirmed" or r.cleanup_owed~=false
        or not plain(r.records) or #r.records>16 then return false end
    local park,last
    for _,v in ipairs(r.records) do
        if not plain(v) then return false end
        if v.stage=="repark" and v.passed==true then park=v end
        last=v
    end
    return park~=nil and plain(last) and last.stage=="repark_observed" and last.passed==true
        and later(last.epoch,park.epoch) and observed(last.observation,false,0,true)
        and last.observation.sample.epoch.serial==last.epoch.serial
        and last.observation.sample.epoch.time==last.epoch.time
        and last.observation.sample.epoch.seconds==last.epoch.seconds
end
local function success(r,d)
    if not plain(r) or r.status~="observed" or not cleanup_confirmed(r)
        or r.first_failure~="none" or r.cycle_count~=1 or r.native_retirement_known~=false
        or not finite(r.elapsed_ms) or r.elapsed_ms<0 or r.elapsed_ms>=3000
        or r.record_count~=10 or #r.records~=10 or not vec(r.target_position) or not quaternion(r.target_rotation) then return false end
    for j=1,3 do if math.abs(r.target_position[j]-d.position[j])>.01 then return false end end
    for j=1,4 do if r.target_rotation[j]~=d.rotation[j] then return false end end
    for i,name in ipairs(STAGES) do
        local row=r.records[i]
        if not plain(row) or row.stage~=name or row.passed~=true or not epoch(row.epoch) then return false end
        if i~=1 and i~=9 then
            if not observed(row.observation,i>=6 and i<=8,(i>=5 and i<=8) and 257 or 0,i==2 or i==10)
                or row.observation.sample.epoch.serial~=row.epoch.serial
                or row.observation.sample.epoch.time~=row.epoch.time
                or row.observation.sample.epoch.seconds~=row.epoch.seconds then return false end
        end
        if i>1 then
            local prev=r.records[i-1].epoch
            if row.epoch.time<prev.time or serial_after(prev.serial,row.epoch.serial) then return false end
        end
    end
    local transform=r.records[3].observation.sample
    for j=1,3 do if transform.position[j]~=r.target_position[j] then return false end end
    for j=1,4 do if transform.rotation[j]~=r.target_rotation[j] then return false end end
    return later(r.records[2].epoch,r.records[1].epoch) and later(r.records[8].epoch,r.records[7].epoch)
end
function Probe.new(api)
    assert(plain(api),"injected API table required")
    local self=setmetatable({},Object)
    PRIVATE[self]={api=api,phase="idle",reason="explicit_prepare_required",terminal=false,events={},
        counts={prepare=0,rays=0,create=0,read=0,begin=0,poll=0,release=0},cleanup="not_started",
        operator_end_required=false,used=false}
    return self
end
function Object:prepare()
    local s=PRIVATE[self]
    if s.terminal or s.used or s.prepare_queued or s.counts.prepare>=C.prepare_limit then return false end
    local t=now(s);if not t then return false end
    s.prepare_queued=t;s.phase="prepare_requested";return true
end
function Object:survey()
    local s=PRIVATE[self]
    if s.terminal or s.used or s.phase~="prepared" then return false end
    s.used=true;s.phase="survey_requested";return true
end
function Object:approve(id)
    local s=PRIVATE[self]
    if s.terminal or s.phase~="await_visual_approval" or id~=1 then return false end
    local t=now(s);if not t then return false end
    if t-s.candidate.at_ms>C.approval_ms then finish(s,"refused","candidate_expired");return false end
    local ctx,why=context(s,false)
    if not ctx then finish(s,"refused",why);return false end
    s.approval={candidate_id=1,position=copy(s.candidate.position),at_ms=t,action="explicit_menu_visual_approval"}
    s.phase="approval_wait";return true
end
function Object:stop()
    local s=PRIVATE[self]
    if s.terminal then return end
    s.stop_requested=true
    if not s.probe then release_before_begin(s,"operator_stop")
    else s.reason="operator_stop_cleanup_still_owed";event(s,"operator_stop","no_cancel_api; continue_polling") end
end
function Object:unload()
    local s=PRIVATE[self]
    if s.terminal then return end
    if s.probe or s.counts.begin>0 then
        s.cleanup="unconfirmed";s.operator_end_required=true;finish(s,"unconfirmed","unloaded_before_terminal_receipt")
    else release_before_begin(s,"unloaded_before_begin") end
end
function Object:tick()
    local s=PRIVATE[self]
    if s.terminal then return end
    local t=now(s);if not t then return end
    if s.probe then
        if t-s.begin_at>=C.watchdog_ms then
            s.cleanup="unconfirmed";s.operator_end_required=true;finish(s,"unconfirmed","tick_observed_watchdog_expired");return
        end
        s.counts.poll+=1
        local ok,r,why=call(s,"poll",s.probe)
        if not ok or r==nil then event(s,"poll_unavailable",why or r);return end
        local copied,result=pcall(copy,r)
        if not copied or not plain(result) or type(result.terminal)~="boolean" or type(result.first_failure)~="string" then
            event(s,"poll_malformed","cleanup remains owed");return
        end
        if result.terminal then
            local malformed=not plain(result.records) or #result.records>16
            if not malformed then
                for _,row in ipairs(result.records) do if not plain(row) then malformed=true;break end end
            end
            if malformed then event(s,"poll_malformed","terminal records malformed; cleanup remains owed");return end
        end
        s.last_result=result
        if result.first_failure and result.first_failure~="none" and not s.first_failure then s.first_failure=result.first_failure end
        if not result.terminal then return end
        if success(result,s.definition) and not s.first_failure and not s.stop_requested then
            s.cleanup="confirmed";finish(s,"observed","one_mechanism_cycle_only")
        else
            s.cleanup=cleanup_confirmed(result) and "confirmed" or "unconfirmed"
            s.operator_end_required=s.cleanup~="confirmed"
            finish(s,"failed",s.first_failure or "terminal_result_not_success")
        end
        return
    end
    if s.prepare_queued then
        if t-s.prepare_queued>C.wait_ms then finish(s,"refused","prepare_action_expired");return end
        local ctx,why=context(s,true)
        if not ctx then if why=="close_interface" then return end;finish(s,"refused",why);return end
        local capable,yes=call(s,"capabilities")
        if not capable or yes~=true then finish(s,"refused","qualification_capability_unavailable");return end
        s.prepare_queued=nil;s.counts.prepare+=1
        local ok,ready,issue=call(s,"prepare")
        if not ok or type(ready)~="boolean" then finish(s,"refused","prepare_malformed");return end
        s.phase=ready and "prepared" or "prepare_pending"
        s.reason=ready and "warmup_only_survey_required" or string.sub(tostring(issue or "unknown"),1,160)
        event(s,"prepare",s.reason);return
    end
    if s.phase=="survey_requested" then
        local ctx,why=context(s,false)
        if not ctx then finish(s,"refused",why);return end
        s.anchor=ctx;s.candidate={id=1,x=ctx.position[1]+3*math.sin(ctx.heading),z=ctx.position[3]+3*math.cos(ctx.heading)}
        start_survey(s,false,t)
    end
    if s.phase=="surveying" or s.phase=="refreshing" then survey_tick(s,t);return end
    if s.phase=="await_visual_approval" then
        local ctx,why=context(s,false)
        if not ctx then finish(s,"refused",why);return end
        if t-s.candidate.at_ms>C.approval_ms then finish(s,"refused","candidate_expired") end;return
    end
    if s.phase=="approval_wait" then
        if t-s.approval.at_ms>C.wait_ms or t-s.candidate.at_ms>C.approval_ms then finish(s,"refused","approval_expired");return end
        local ctx,why=context(s,true)
        if not ctx then if why=="close_interface" then return end;finish(s,"refused",why);return end
        start_survey(s,true,t);return
    end
    if s.phase=="create_ready" then
        local ctx,why=context(s,true)
        if not ctx then release_before_begin(s,why);return end
        if t-s.fresh_at>C.fresh_ms then finish(s,"refused","refreshed_survey_stale");return end
        local capable,yes=call(s,"capabilities")
        if not capable or yes~=true then finish(s,"refused","qualification_capability_unavailable");return end
        local fresh=now(s);if not fresh then return end
        if fresh-s.fresh_at>C.fresh_ms or fresh-s.refresh.started_ms>C.survey_ms then finish(s,"refused","refreshed_survey_stale");return end
        s.definition=definition(s.approval.position);s.counts.create+=1
        local ok,body,issue=call(s,"create",copy(s.definition))
        if not ok or body==nil then
            s.cleanup="unconfirmed";s.operator_end_required=true;finish(s,"refused","create_refused_or_unknown: "..string.sub(tostring(issue or body),1,100));return
        end
        s.body=body;s.created_at=fresh;s.phase="read_ready";return
    end
    if s.phase=="read_ready" then
        local ctx,why=context(s,true)
        if not ctx then release_before_begin(s,why);return end
        if t-s.created_at>C.read_ms or t-s.fresh_at>C.read_ms then release_before_begin(s,"read_admission_stale");return end
        s.counts.read+=1;local ok,a=call(s,"read",s.body)
        if not ok or not good_sample(a) then release_before_begin(s,"coherent_body_read_unavailable");return end
        local valid_copy,initial=pcall(copy,a)
        if not valid_copy then release_before_begin(s,"body_read_not_plain_data");return end
        for j=1,3 do if math.abs(a.position[j]-s.definition.position[j])>.25 then release_before_begin(s,"body_read_pose_outside_candidate");return end end
        s.initial_read=initial
        local returned=now(s);if not returned then return end
        local same,issue=context(s,true)
        if not same or returned-t>C.fresh_ms then release_before_begin(s,issue or "body_read_stale");return end
        local admission=now(s);if not admission then return end
        if admission-t>C.fresh_ms or admission-s.fresh_at>C.read_ms or admission-s.refresh.started_ms>C.survey_ms then release_before_begin(s,"body_read_stale");return end
        s.counts.begin+=1;s.begin_at=admission
        local began,probe,why_begin=call(s,"begin",s.body)
        if not began or probe==nil then
            s.cleanup="unconfirmed";s.operator_end_required=true
            finish(s,"unconfirmed","begin_refused_or_unknown: "..string.sub(tostring(why_begin or probe),1,100));return
        end
        s.probe=probe;s.cleanup="pending";s.phase="polling";event(s,"begin","one_attempt_consumed")
    end
end
function Object:snapshot()
    local s=PRIVATE[self]
    return copy({schema="body-reactivation-draft-v1",phase=s.phase,reason=s.reason,terminal=s.terminal,
        cleanup=s.cleanup,operator_end_required=s.operator_end_required,counts=s.counts,events=s.events,
        candidate=s.candidate,approval=s.approval,initial_survey=s.initial_survey,refresh=s.refresh,
        definition=s.definition,initial_read=s.initial_read,last_result=s.last_result,first_failure=s.first_failure,
        release=s.release_report,stop_requested=s.stop_requested==true,
        evidence_scope="one_body_one_cycle_rays_and_operator_observation; not_reuse_or_mount_qualification",
        actor_generation_available=false,process_identity_external=true,storage_durability_unverified=true})
end
Probe.limits=table.freeze(C)
return table.freeze(Probe)
