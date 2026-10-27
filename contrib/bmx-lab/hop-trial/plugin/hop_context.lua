-- Private copied-package observer. All capabilities stay in memory; only named
-- diagnostic values reach the recorder. No reads or native cleanup start here.
local Context={}
local Object={};Object.__index=Object
local states=setmetatable({},{__mode="k"})
local bound
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function get(t,k) if plain(t) then return rawget(t,k) end;return nil end
local function fields(t,names)
    local out={}
    for name in names:gmatch("%S+") do
        local v=get(t,name)
        if type(v)=="boolean" or type(v)=="string" or finite(v) then out[name]=v end
    end
    return out
end
local function vec(v,n)
    if typeof(v)=="vector" and n==3 then return {v.x,v.y,v.z} end
    if not plain(v) then return nil end
    local out={}
    for i=1,n do
        local value=rawget(v,i)
        if value==nil and n==3 then value=rawget(v,({"x","y","z"})[i]) end
        if not finite(value) then return nil end
        out[i]=value
    end
    return out
end
local function vectors(out,row,names)
    for name in names:gmatch("%S+") do out[name]=vec(get(row,name),3) end
    return out
end
local function body(row)
    local out=vectors(fields(row,"serial time seconds mass"),row,"position velocity angular_velocity inertia")
    out.rotation=vec(get(row,"rotation"),4)
    return out
end
local source_names="generation user sequence source_epoch context_generation observation_serial observed_ms packet neutral input_ok phase"
local function source(row)
    local out=fields(row,source_names)
    local pad=get(row,"pad")
    if plain(pad) then
        out.pad=fields(pad,"playstation left_x left_y right_x right_y left_trigger right_trigger")
        out.pad.buttons=fields(get(pad,"buttons"),"up down left right start back left_stick right_stick lb rb a b x y")
    end
    return out
end
local function controls(row)
    return fields(row,"hop_event_id hop_strength pedal steer brake rotation_reserved")
end
local function model(row)
    local out=vectors(fields(row,"valid issue grounded hop_applied hop_event_id contact_scale diagnostic_only force_applied"),
        row,"force torque linear_impulse angular_impulse hop_impulse")
    local wheels=get(row,"wheels")
    if plain(wheels) then out.wheels={};for i=1,2 do out.wheels[i]=fields(get(wheels,i),"radius inertia angular_speed") end end
    return out
end
local function rays(rows)
    if not plain(rows) then return nil end
    local out={}
    for i=1,32 do
        local row=rawget(rows,i);if row==nil then break end
        out[i]=vectors(fields(row,"status motion fraction normal_available surface_velocity_available visual_hit"),row,
            "position normal surface_velocity")
    end
    return out
end
local query_names="status reason epoch_matches accounting_known measurements_complete native_casts budget_exhausted local_actor_excluded owned_bodies_excluded named_actor_categories_absent requested_query_preset actor_lane"
local function contact(row)
    local decoded=get(row,"decoded") or row
    local out=fields(decoded,"valid status reason force_ready force_reason")
    out.query=fields(get(decoded,"query"),query_names)
    out.rays=rays(get(decoded,"rays"))
    local support=get(row,"support") or get(decoded,"support")
    out.support=vectors(fields(support,"known grounded_known grounded provenance reason"),support,"point normal surface_velocity")
    local samples=get(row,"samples")
    if plain(samples) then
        out.samples={}
        for i=1,2 do
            local sample=get(samples,i);local hit=get(sample,"contact")
            out.samples[i]=vectors(fields(sample,"separation verified_plane balance_normal_available"),sample,"balance_normal")
            out.samples[i].contact=vectors(fields(hit,"status"),hit,"point normal forward surface_velocity")
        end
    end
    return out
end
local function receipt(row)
    local out=fields(row,"sequence outcome requested_serial produced_serial force_attempted torque_attempted retained quarantined cleanup_disposition")
    if plain(get(row,"successor")) then out.successor=body(row.successor) end
    return out
end
-- These are observed SDK result shapes, never permission to create or reuse.
local prepare_pending="native body producer setup pending; call prepare again explicitly"
local prepare_clock_wait="waiting for a fresh qualified 60 Hz physics step"
local function preparation(args,result)
    local out={phase="malformed",arguments=args.n}
    if result[1]==false then out.phase="raised"
    elseif result[1]==true and args.n==0 then
        if result.n==2 and result[2]==true then out.phase="ready"
        elseif result.n==3 and result[2]==false and type(result[3])=="string" then
            out.phase=(result[3]==prepare_pending or result[3]==prepare_clock_wait) and "pending" or "refused"
        end
    end
    return out
end
local follow_names="phase reason park_reason sequence final_revision final_native_epoch returned_revision in_flight claim_known orphaned park_observed native_retirement_known terminal"
local lease_names="phase status reason revocation user sequence source_epoch context_generation requested_ms expires_ms observed_ms last_observation renewals source_released capture_reserved orphaned capturing report_debt generation revision publications neutral_releases terminal quarantined last_serial remaining_ms lifetime_remaining_ms base_ms renewal_ms lifetime_ms renewable active"
local function force_pending(row)
    local out=fields(row,"phase issue hop_disposition force_pending unknown pending_count pending_sequence pending_limit submitted acknowledged stop_requested ack_attempted last_serial observed_steps model_steps")
    local disposition=get(row,"hop_disposition")
    if plain(disposition) then out.hop_disposition=fields(disposition,"id disposition confirmed") end
    local pending=get(row,"pending_commands")
    if plain(pending) then
        out.pending_commands={}
        for i=1,3 do
            if get(pending,i)==nil then break end
            out.pending_commands[i]=fields(pending[i],"sequence serial ack_attempted acknowledged unknown outcome")
        end
    end
    return out
end
local function pose(row)
    local out=fields(row,"state blend weight reason capability sends ends last_sent qualified issue trick_scope mount_ms mounted_ms ticks sent_ticks nil_calls nil_accepted stopped")
    local plan=get(row,"plan")
    if plain(plan) then
        out.plan={at_ms=get(plan,"at_ms"),hips=vec(get(plan,"hips"),3),wrists={},ankles={}}
        for i=1,2 do
            out.plan.wrists[i]=vec(get(get(plan,"wrists"),i),3)
            out.plan.ankles[i]=vec(get(get(plan,"ankles"),i),3)
        end
    end
    return out
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function place_probe(args,result)
    if args.n~=2 or args[2]~=2 or not plain(args[1]) or result[1]~=false or result.n~=2
        or type(result[2])~="string" or not result[2]:find("place has a position, a rotation or both",1,true) then return false end
    local joint=rawget(args[1],49)
    if not plain(joint) or next(args[1])~=49 or next(args[1],49)~=nil then return false end
    local place=rawget(joint,"place")
    return plain(place) and next(joint)=="place" and next(joint,"place")==nil and next(place)==nil
end
function Context.new(guard,recorder)
    assert(type(guard)=="table" and type(recorder)=="table","trial guard and recorder required")
    local self=setmetatable({},Object)
    states[self]={guard=guard,recorder=recorder,configured=false,stopped=false,cached={}}
    return table.freeze(self)
end
function Object:request_stop(reason)
    local s=states[self]
    if not s.stopped then
        s.stopped=true;s.reason=type(reason)=="string" and reason or "trial observer failed"
        -- Revocation is pure. Main owns ordinary request_stop after the call unwinds.
        pcall(s.guard.stop,s.guard,s.reason)
    end
end
function Object:configure(config)
    local s=states[self]
    if s.configured then self:request_stop("trial configured twice");return false,s.reason end
    s.configured=true
    local ok,accepted,why=pcall(s.guard.configure,s.guard,{phase=config.phase,admitted=config.admission_enabled==true})
    if not ok or accepted~=true then self:request_stop(type(why)=="string" and why or "trial admission closed");return false,s.reason end
    return true
end
function Object:status()
    local s=states[self]
    return {stop_requested=s.stopped,reason=s.reason,at_ms=s.now}
end
function Object:append(kind,row)
    local s=states[self]
    row.at_ms=s.now
    local ok,accepted,why=pcall(s.recorder.append,s.recorder,kind,row)
    if not ok or accepted~=true then self:request_stop(type(why)=="string" and why or "trial evidence unavailable");return false end
    return true
end
function Object:before_force(handle,raw,mapped,measured,frame,wheel_contact)
    local s=states[self]
    if s.stopped then return false,s.reason end
    local ok,accepted,why=pcall(s.guard.begin,s.guard,handle,raw,mapped,measured,frame,wheel_contact)
    if not ok or accepted~=true then self:request_stop(type(why)=="string" and why or "trial frame refused");return false,s.reason end
    -- Exact opaque binding is private; scalar diagnostics never replace it.
    s.body,s.epoch,s.serial=handle,get(raw,"epoch"),get(raw,"serial")
    self:append("source",source(get(mapped,"source")))
    self:append("body",body(raw))
    local projected=controls(get(mapped,"force_controls"))
    projected.hop=get(mapped,"hop")~=nil
    self:append("mapped_hop",projected)
    self:append("contact",contact(wheel_contact))
    return not s.stopped,s.reason
end
function Object:observe_preview(h,folded,selected,result,candidate)
    local s=states[self]
    local observed=fields(folded,"mass")
    vectors(observed,folded,"center_of_mass linear_velocity angular_velocity inertia_body")
    observed.orientation=vec(get(folded,"orientation"),4)
    local projected=model(result)
    if plain(get(result,"diagnostic")) then projected.diagnostic=model(result.diagnostic) end
    self:append("preview",{seconds=h,body=observed,controls=controls(selected),model=projected,serial=s.serial})
    if s.stopped then return false,s.reason end
    local ok,accepted,why=pcall(s.guard.observe,s.guard,h,folded,selected,result,candidate)
    if not ok or accepted~=true then self:request_stop(type(why)=="string" and why or "trial force refused");return false,s.reason end
    return true
end
function Object:submit(handle,epoch,packet,delegate)
    local s=states[self]
    if s.stopped then return false,"hop guard: "..(s.reason or "trial stopped") end
    return s.guard:submit(handle,epoch,packet,delegate)
end
function Object:observe_service(path,args,result)
    local s=states[self]
    if path=="time.now" then
        if result[1] and result.n==2 and finite(result[2]) then s.now=result[2] end
        return true
    end
    local row,kind
    local value;if result[1] then value=result[2] end
    if path=="world.physics.prepare" then kind="prepare";row=preparation(args,result)
    elseif path=="world.physics.read" then kind="body";row=body(value)
    elseif path=="world.probe" then
        kind="contact";row=fields(value,"status reason")
        row.rays={vectors(fields(value,"status motion fraction normal_available surface_velocity_available"),value,"position normal surface_velocity")}
    elseif path=="world.physics.probe_batch" then
        kind="contact";row=fields(value,"status reason")
        row.query=fields(value,query_names);row.rays=rays(get(value,"rays"))
        if plain(value) then row.query.epoch_matches=get(value,"epoch")~=nil and get(value,"epoch")==args[2] end
    elseif path=="world.physics.submit" then
        kind="submit";row=vectors(fields(args[3],"impulse_id"),args[3],"force torque impulse")
        row.serial=args[1]==s.body and args[2]==s.epoch and s.serial or nil
        if result[1] and result.n==4 and result[2]==true and result[3]==nil then row.sequence=result[4] end
    elseif path=="world.physics.receipt" then kind="receipt";row=receipt(value)
    elseif path=="world.physics.acknowledge" then
        kind="ack";row={sequence=args[2]}
        if result[1] and result.n==2 and result[2]==true then row.acknowledged=true
        elseif result[1] and result.n==3 and result[2]==false and type(result[3])=="string" then row.acknowledged=false end
    elseif path=="skater.pose" then
        kind="pose";row={}
        -- MountedPose's exact malformed place probe is a pre-native validator
        -- check. Its expected exception must still reach classify_probe.
        if place_probe(args,result) then row.state="capability_probe";row.reason="expected place validator refusal"
        elseif not result[1] or result.n~=2 or result[2]~=true then self:request_stop("SDK pose refusal, exception or malformed result") end
    elseif path=="input.lease_read" then kind="source";row=source(value)
    elseif path:sub(1,12)=="input.lease_" or path=="input.lease" or path=="world.physics.read_follow_lease" then
        kind="lease";row=fields(value,lease_names)
    elseif path:sub(1,14)=="world.physics." then
        kind="follow";row=fields(value,follow_names)
        local pending=get(value,"pending")
        if plain(pending) and type(get(pending,1))=="string" then row.pending={pending[1]} end
    else return true end
    row.call=path;row.call_ok=result[1]==true;row.arity=result[1] and result.n-1 or 0
    if type(value)=="boolean" then row.result=value end
    if type(result[3])=="string" then row.reason=result[3] end
    -- Do not stringify thrown objects: they may be capabilities or invoke code.
    if not result[1] and row.reason==nil then row.reason="SDK call raised" end
    return self:append(kind,row)
end
function Object:append_cached(kind,row)
    local s=states[self]
    -- These are cached Core DTOs, not additional SDK observations. Suppress
    -- unchanged projections even after a stored chunk has been flushed.
    if s.cached[kind] and same(s.cached[kind],row) then return true end
    s.cached[kind]=row
    -- append adds a timestamp; retain an unmodified comparison copy instead.
    local copy={};for k,v in pairs(row) do copy[k]=v end
    return self:append(kind,copy)
end
function Object:after_step(snapshot)
    local s=states[self]
    if not plain(snapshot) then self:request_stop("Core status unavailable");return end
    local ok,accepted=pcall(s.recorder.terminal,s.recorder,snapshot)
    if not ok or accepted~=true then self:request_stop("terminal evidence unavailable") end
    local checked,evidence=pcall(s.recorder.status,s.recorder)
    if not checked or type(evidence)~="table" or evidence.stop_requested==true then
        self:request_stop("recorder requested stop")
    end
    local ride=get(snapshot,"ride")
    if plain(ride) then self:append_cached("force_pending",force_pending(ride)) end
    local posture=get(snapshot,"mounted_pose")
    if plain(posture) then self:append_cached("pose",pose(posture)) end
    local last=get(snapshot,"last_source_step")
    if plain(last) and plain(get(last,"sample")) then
        local row=source(last.sample)
        for _,key in ipairs({"generation","input_ok","phase"}) do row[key]=get(last,key) end
        self:append_cached("source",row)
    end
    if get(snapshot,"stop_latched")==true then self:request_stop(get(snapshot,"stop_reason") or "Core stopped") end
end
function Object:flush(witness)
    local s=states[self]
    return s.recorder:flush(witness)
end
function Object:interrupt(snapshot)
    local s=states[self]
    return s.recorder:interrupt(snapshot)
end
function Context.bind(instance)
    assert(bound==nil and states[instance],"trial context binds once")
    bound=instance
end
function Context.before_force(...)
    if not bound then return false,"trial context unavailable" end
    return bound:before_force(...)
end
function Context.observe_preview(...)
    if not bound then return false,"trial context unavailable" end
    return bound:observe_preview(...)
end
function Context.observer_failed()
    if bound then bound:request_stop("force observer raised") end
end
return table.freeze(Context)
