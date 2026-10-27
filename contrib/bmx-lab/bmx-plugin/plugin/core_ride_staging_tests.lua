-- Constructed cases for Core's ride staging (INTEGRATION_PLAN B3, B7, B13, B14).
-- Injected SDK-shaped services only. newproxy values are test identities, never
-- native handles, input ownership, contact provenance or Follow receipts. Both
-- activation literals stay false, so no case creates a Ride; a call into a force,
-- contact or receipt function fails the case. Core and the facade each allow one
-- mount per VM, so one real mount covers B3, B7 and B14, and B13 calls the
-- facade's own API check directly. Requiring this module performs no call.
local Runtime=require("./bike_runtime")
local Core=require("./bike_runtime_core")
local Admission=require("./bike_admission")
local G=require("./bike_geometry")
local Tests={}

local pad_buttons={"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"}
local force_methods={"probe_batch","submit","receipt","acknowledge"}
-- The facade's mount list after this change, in its reviewed order.
local expected_order={"./lease_identity","./lease_source","./force_math","./bike_geometry","./bike_visual","./bike_spawn",
    "./tire","./brake","./pump","./force_solver","./forces","./force_stage","./catalog","./input","./ride_input_mapping",
    "./frame_identity","./motions","./tricks","./trick_runtime","./pose_targets",
    "./contact_runtime","./ride_inflight","./ride_runtime","./bones","./mounted_pose","./board_drop",
    "./equipment_transition","./equipment_runtime","./bike_runtime_core"}
-- Each staged module's top-level requires, read from its source. bike_admission
-- is loaded by admission itself, before the list starts.
local requires={
    ["./lease_identity"]={},["./force_math"]={},["./bike_geometry"]={},["./catalog"]={},["./equipment_transition"]={},
    ["./lease_source"]={"./lease_identity"},
    ["./bike_visual"]={"./force_math","./bike_geometry"},
    ["./bike_spawn"]={"./force_math","./bike_geometry","./bike_visual"},
    ["./tire"]={"./force_math"},
    ["./brake"]={"./force_math","./tire"},
    ["./pump"]={"./force_math"},
    ["./force_solver"]={"./force_math","./brake"},
    ["./forces"]={"./force_math","./tire","./pump","./force_solver"},
    ["./force_stage"]={"./force_math","./forces"},
    ["./input"]={"./catalog"},
    ["./ride_input_mapping"]={"./input","./lease_identity"},
    ["./frame_identity"]={"./lease_identity"},
    ["./motions"]={},
    ["./tricks"]={"./catalog","./motions"},
    ["./trick_runtime"]={"./tricks","./motions","./catalog","./frame_identity","./force_math","./lease_identity"},
    ["./pose_targets"]={"./catalog","./motions"},
    ["./contact_runtime"]={"./frame_identity"},
    ["./ride_inflight"]={"./force_math"},
    ["./ride_runtime"]={"./ride_input_mapping","./forces","./force_math","./lease_identity","./bike_geometry","./ride_inflight","./catalog"},
    ["./bones"]={},["./board_drop"]={},
    ["./mounted_pose"]={"./bike_geometry","./bones"},
    ["./equipment_runtime"]={"./equipment_transition"},
    ["./bike_runtime_core"]={"./equipment_runtime","./bike_admission"},
}
-- What prepare_backend binds, and through it what create_ride needs.
local backend={"./lease_source","./bike_spawn","./lease_identity","./bike_geometry","./ride_runtime","./contact_runtime","./force_stage","./trick_runtime","./pose_targets","./mounted_pose","./board_drop"}
-- The standalone mesh presenter stays out: Ride and Spawn already own presentation.
local never_staged={"./trick_presentation"}

local function services()
    local f={now=1000,calls={},forbidden={},reserves={},releases={},records={},renewals=0,capture_acked=false}
    local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
    local function note(name) f.calls[name]=(f.calls[name] or 0)+1 end
    local function forbidden(name)
        return function() f.forbidden[name]=(f.forbidden[name] or 0)+1;error(name.." must not be reached",0) end
    end
    function s.time.now() return f.now end
    -- Closed menus, focused gameplay, an upright, grounded on-foot (504) rider.
    function s.input.focus() return {focused=true,interface_open=false,gameplay=true} end
    function s.input.allowed() return true end
    function s.menu.game() return {open=false} end
    function s.skater.get() return {airborne=false,position=vector.create(0,0,0),heading=0} end
    function s.skater.telemetry() return {skater=true,airborne=false,teleport_pending=false,
        watch={valid=true,state=504,ragdoll_known=true,ragdoll=false,wipeouts=0}} end
    function s.level.current() return {name="sanvan"} end
    function s.json.encode() return "bounded constructed encoding" end
    function s.storage.get(key) return f.records[key] end
    function s.storage.set(key,record) f.records[key]=record end -- The SDK returns no values.
    -- On foot, so no stock pulse; no publication follows a refused reserve; no Ride.
    for _,name in {"pulse","pulse_state","pulse_cancel","pulse_acknowledge"} do s.input[name]=forbidden("input."..name) end
    for _,name in {"publish_follow","read_follow","stop_follow","acknowledge_follow"} do
        s.world.physics[name]=forbidden("world.physics."..name)
    end
    for _,name in force_methods do s.world.physics[name]=forbidden("world.physics."..name) end

    -- One selected stream with a single, constant neutral observation.
    local function stream(row)
        row.transport,row.source_identity,row.physical_device_identity="xinput","observed_stream","unobserved"
        row.user,row.sequence,row.source_epoch,row.context_generation=f.user,"11","12","13"
        return row
    end
    local function neutral()
        local pad={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,playstation=false,buttons={}}
        for _,name in pad_buttons do pad.buttons[name]=false end
        return pad
    end
    function s.input.lease(user)
        note("input.lease")
        if f.lease then return nil,"busy" end
        f.user,f.lease,f.lease_status=user,newproxy(),"active"
        return f.lease
    end
    function s.input.lease_read(handle)
        note("input.lease_read")
        if handle~=f.lease or f.lease_status~="active" then return nil,"unavailable" end
        local row=stream({mode="observe",capturing=false,report_debt=false,observation_serial="5",
            observed_ms="2000",packet=1,pad=neutral()})
        row.epoch=newproxy()
        return row
    end
    function s.input.lease_renew(handle)
        note("input.lease_renew")
        if handle~=f.lease then return false,"stale_epoch" end
        f.renewals+=1
        return true
    end
    function s.input.lease_state(handle)
        note("input.lease_state")
        if handle~=f.lease then return nil,"unavailable" end
        local terminal=f.lease_status~="active"
        local reserved=f.capture~=nil and not f.capture_acked
        return stream({mode="observe",capturing=false,report_debt=false,status=f.lease_status,
            reason=terminal and "cancelled" or "none",terminal=terminal,requested_ms="1000",expires_ms="900000",
            observed_ms="2000",last_observation="5",renewals=tostring(f.renewals),
            source_released=terminal and not reserved,capture_reserved=reserved,orphaned=false})
    end
    function s.input.lease_release(handle)
        note("input.lease_release")
        if handle~=f.lease or f.lease_status~="active" then return false,"unavailable" end
        f.lease_status="released"
        return true
    end
    function s.input.lease_acknowledge(handle)
        note("input.lease_acknowledge")
        if handle~=f.lease or f.lease_status=="active" or (f.capture and not f.capture_acked) then return false,"busy" end
        return true
    end
    local function capture_row()
        local c=f.capture
        return stream({mode="capture",capture_scope="selected_observed_xinput_stream",
            publication_scope="process_outer_xinput_buffer",consumption="unobserved",semantic_completion="unobserved",
            capturing=c.phase=="capturing",report_debt=c.phase=="capturing",phase=c.phase,reason=c.reason,
            terminal=c.phase=="complete",quarantined=false,generation=c.generation,revision=c.revision,
            expires_ms="900000",publications=c.publications,neutral_releases=c.neutral_releases})
    end
    function s.input.lease_capture(handle)
        note("input.lease_capture")
        if handle~=f.lease or f.capture then return false,"busy" end
        f.capture={phase="waiting_neutral",reason="none",generation="21",revision="22",
            publications="0",neutral_releases="0",reads=0}
        return true
    end
    function s.input.lease_capture_state(handle)
        note("input.lease_capture_state")
        if handle~=f.lease or not f.capture then return nil,"unavailable" end
        local c=f.capture
        c.reads+=1
        -- Constructed: the second read reports the selected stream as captured.
        if c.phase=="waiting_neutral" and c.reads>1 then c.phase,c.publications="capturing","1" end
        return capture_row()
    end
    function s.input.lease_release_capture(handle)
        note("input.lease_release_capture")
        local c=f.capture
        if handle~=f.lease or not c or c.phase=="complete" then return false,"unavailable" end
        c.phase,c.reason,c.generation,c.revision,c.neutral_releases="complete","cancelled","23","24",c.publications
        return true
    end
    function s.input.lease_acknowledge_capture(handle)
        note("input.lease_acknowledge_capture")
        if handle~=f.lease or not f.capture or f.capture.phase~="complete" then return false,"busy" end
        f.capture_acked=true
        return true
    end

    -- Eight loaded parts whose wheel bounds match the authored radius.
    local r=G.wheel_radius
    function s.entities.bounds() note("entities.bounds");return vector.create(-.02,-r,-r),vector.create(.02,r,r) end
    function s.entities.set() note("entities.set");return true end
    function s.entities.status() note("entities.status");return "ready" end
    function s.entities.remove() note("entities.remove") end -- The SDK returns no values.
    function s.world.physics.prepare() note("world.physics.prepare");return true end
    function s.world.physics.create(definition)
        note("world.physics.create")
        if f.body then return nil,"busy" end
        f.body,f.definition=newproxy(),definition
        return f.body
    end
    function s.world.physics.read(body)
        note("world.physics.read")
        if body~=f.body or not f.definition then return nil,"invalid_owner" end
        -- One constructed sample at rest where the body was placed; not a native measurement.
        f.sample=f.sample or {epoch=newproxy(),serial="7",time=1,seconds=1/60,mass=G.mass,
            position=f.definition.position,rotation=f.definition.rotation,velocity=vector.create(0,0,0),
            angular_velocity=vector.create(0,0,0),inertia=vector.create(G.inertia[1],G.inertia[2],G.inertia[3])}
        return f.sample
    end
    function s.world.physics.release(body)
        note("world.physics.release")
        table.insert(f.releases,body)
        return body==f.body
    end
    function s.world.physics.reserve_follow(body,attachment)
        note("world.physics.reserve_follow")
        table.insert(f.reserves,{body=body,attachment=attachment})
        -- A known refusal ends the attempt before publication; Core then releases the body.
        return nil,"native_refused"
    end
    return f,s
end

function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end

    cases+=1 do
        check(Core.probe_batches_per_serial==4 and table.isfrozen(Core),"Core exports its fixed four-batch allowance read-only")
        check(not pcall(function() Core.probe_batches_per_serial=5 end),"a caller cannot raise Core's allowance")
    end

    cases+=1 do
        -- B13. The facade runs this exact check (bike_runtime.lua admission) before
        -- it stages any module, so no Core, Source, body or Ride exists yet.
        local listed={}
        for _,path in Admission.required do listed[path]=true end
        for _,name in force_methods do
            check(listed["world.physics."..name]==true,"admission requires world.physics."..name)
        end
        for _,name in force_methods do
            local f,s=services()
            s.world.physics[name]=nil
            local T={counts={},calls={},omitted_calls=0}
            local ok,missing=Admission.bind(T,s,true).available()
            check(ok==false and missing=="world.physics."..name,"a missing "..name.." refuses admission by name")
            check(#T.calls==0 and next(f.calls)==nil and next(f.forbidden)==nil,
                "the refusal only looks names up; no service, body or Follow call is made")
        end
        local f,s=services()
        local ok,last=Admission.bind({counts={},calls={},omitted_calls=0},s,true).available()
        check(ok==true and last=="vector.create" and next(f.calls)==nil,"the complete constructed services pass the same check")
    end

    cases+=1 do
        -- B14 and B3: imports, Core construction and backend preparation use separate steps.
        local f,s=services()
        local owner=Runtime.new(s,{qualification_only=true})
        local accepted,why=owner:request_mount(0)
        -- The facade's acceptance carries its status text (bike_runtime.lua: T.detail).
        check(accepted==true and why=="Request accepted; preparing. Stop cancels it before acquisition.",
            "one constructed private mount intent is admitted")
        local out=owner:status()
        check(out.startup.pending==true and out.startup.loaded==1 and out.startup.last_module=="./bike_admission",
            "admission loads only itself before the staged list")
        local staged,position={},{["./bike_admission"]=0}
        for index=1,#expected_order do
            f.now+=16;out=owner:step(16)
            check(out.startup.loaded==index+1,"each startup step loads exactly one staged module")
            table.insert(staged,out.startup.last_module);position[out.startup.last_module]=index
        end
        for index,name in expected_order do check(staged[index]==name,"staged module "..index.." is "..name) end
        for name,needs in requires do
            check(position[name]~=nil,name.." is staged")
            for _,need in needs do
                check(position[need]~=nil and position[need]<position[name],name.." is staged after "..need)
            end
        end
        for _,name in never_staged do check(position[name]==nil,name.." is not staged") end
        check(out.startup.core_ready==false and out.startup.backend_ready==false and out.startup.ride_modules_bound~=true,
            "the final Core import does not construct its owner or bind backend modules")
        check(next(f.calls)==nil and next(f.forbidden)==nil,"staging imports acquire no native services")
        f.now+=16;out=owner:step(16)
        check(out.startup.core_ready==true and out.startup.core_instances==1 and out.startup.equipment_instances==1
            and out.startup.backend_ready==false and out.startup.ride_modules_bound==false
            and out.startup.source_instances==0 and out.startup.spawn_instances==0 and out.startup.pose_instances==0 and out.startup.trick_instances==0,
            "the next guarded step constructs one Core and equipment owner without preparing a backend")
        check(out.startup.loaded==#expected_order+1 and out.startup.last_module=="./bike_runtime_core"
            and next(f.calls)==nil and next(f.forbidden)==nil,"Core construction adds no import or native acquisition")
        f.now+=16;out=owner:step(16)
        check(out.startup.backend_ready==true and out.startup.ride_modules_bound==true
            and out.startup.core_instances==1 and out.startup.source_instances==1
            and out.startup.spawn_instances==1 and out.startup.pose_instances==1 and out.startup.trick_instances==1,
            "backend preparation binds Ride, Contact, one inert trick adapter and Poser after all imports and Core construction")
        check(next(f.calls)==nil and next(f.forbidden)==nil,"backend preparation still acquires no native services")
        check(out.startup.ride_trick_adapter==true,"the bound Ride models carry one inert trick adapter")
        check(out.startup.loaded==#expected_order+1 and out.startup.last_module=="./bike_runtime_core",
            "backend preparation adds nothing to the staged list")
        for _,name in backend do check(position[name]~=nil,"backend module "..name.." was staged first") end
        -- create_ride itself is unreachable while RIDE_COMPOSITION_QUALIFIED is false.
        -- Its source holds no require; it uses only what was bound above.

        -- B7: Core's own mount check, then the zero-force qualification up to Follow.
        f.now+=16;out=owner:step(16)
        check(out.phase=="armed" and out.startup.pending==false,"the deferred handoff reaches Core's own mount check")
        for _=1,400 do
            if #f.reserves>0 then break end
            f.now+=16;out=owner:step(16)
        end
        check(#f.reserves==1,"one Follow reservation is attempted")
        local reserve=f.reserves[1]
        check(f.body~=nil and reserve.body==f.body,"Follow reserves the body Spawn handed off")
        local a=reserve.attachment
        local keys=0
        for _ in pairs(a) do keys+=1 end
        check(keys==4 and a.cleanup=="owned_body" and a.motion_policy=="callback_entry",
            "the reservation names cleanup=owned_body and motion_policy=callback_entry, and nothing else new")
        check(typeof(a.offset_from_com)=="vector" and a.offset_from_com==vector.create(-G.com[1],-G.com[2],-G.com[3]),
            "the COM offset is unchanged")
        check(type(a.root_in_body)=="table" and #a.root_in_body==4 and a.root_in_body[1]==0 and a.root_in_body[2]==0
            and a.root_in_body[3]==0 and a.root_in_body[4]==1,"the root orientation is unchanged")
        check(out.reserve_attempted and out.reserve_refused and not out.reserve_unknown and not out.publish_attempted,
            "a known refusal is recorded and nothing is published")
        check(#f.releases==1 and f.releases[1]==f.body and out.ordinary_release_accepted==true,
            "Core releases the exact refused body once")
        check(out.ride_composition_qualified==false and out.ride==nil and out.call_counts["ride.new"]==nil,
            "no Ride is constructed while the Core literal is false")
        for _=1,20 do
            if out.phase=="done" then break end
            f.now+=16;out=owner:step(16)
        end
        check(out.phase=="done" and out.bike_cleanup_complete==true and out.cleanup_unknown==false,
            "cleanup completes with no retained duty")
        check(f.calls["entities.remove"]==8 and f.calls["input.lease_acknowledge_capture"]==1
            and f.calls["input.lease_acknowledge"]==1,"visuals are removed and the input lease drains")
        check(f.calls["world.physics.create"]==1 and f.calls["world.physics.reserve_follow"]==1,
            "one body and one reservation, no retry")
        check(next(f.forbidden)==nil,"no stock pulse, publication, Follow read or force, contact or receipt call")
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
-- Shared constructed service factory for the separate provisional-offset suite.
-- This exports no real SDK handle or production activation option.
Tests.spawn_services=services
return Tests
