-- One constructed gentle-grade regression. No native/game support is inferred.
local Survey=require("./ride_r1_record")
local Entry=require("./bmx_playable_entry")
local Spawn=require("./bike_spawn")
local M=require("./force_math")
local G=require("./bike_geometry")
local Tests={}
local function copy(v)
    if type(v)~="table" then return v end
    local out={} for k,x in pairs(v) do out[k]=copy(x) end return out
end
local function cleaned()
    return {phase="done",bike_cleanup_complete=true,bike_authority=false,cleanup_pending=false,
        cleanup_unknown=false,stock_toggle_blocked=false,unloaded=false,stop_latched=true}
end
local function entry_fixture(check,options)
        options=options or {}
        local f={now=0,slot=0,focused=true,gameplay=true,overlay=true,game_menu=false,stock=504,
            position=vector.create(0,.5,0),heading=0,slope=0,new_calls=0,steps=0,mounts=0,stops=0,toggles=0,
            unloads=0,prepares=0,probes=0,probe_tick=0,probe_peak=0,events={},keys=options.keys or {},latest=cleaned()}
        f.latest.phase="idle";f.latest.stop_latched=false
        local R={time={},input={},menu={},skater={},storage={},world={physics={}}}
        function R.time.now() return f.now end
        function R.input.focus()
            if f.on_focus then f.on_focus() end
            return {focused=f.focused,gameplay=f.gameplay,interface_open=f.overlay}
        end
        function R.menu.game() if f.on_menu then f.on_menu() end;return {open=f.game_menu} end
        function R.skater.get()
            if f.on_actor then f.on_actor() end
            return {position=f.position,heading=f.heading}
        end
        function R.skater.telemetry()
            if f.on_telemetry then f.on_telemetry() end
            return {watch={state=f.stock}}
        end
        function R.storage.keys() if f.keys_raise then error("keys unavailable") end;return f.keys end
        function R.world.physics.prepare()
            f.prepares+=1;f.events[#f.events+1]="prepare"
            if f.on_prepare then return f.on_prepare(f.prepares) end
            return true
        end
        function R.world.probe(from,to)
            f.probes+=1;f.probe_tick+=1;f.probe_peak=math.max(f.probe_peak,f.probe_tick)
            if f.on_probe then f.on_probe(from,to) end
            if from.y-to.y>1 then
                local radius=math.sqrt(from.x*from.x+from.z*from.z)
                local y=math.tan(math.rad(f.slope))*from.x
                if f.outer_variation and radius>.750001 then y+=f.outer_variation end
                return {status="hit",position=vector.create(from.x,y,from.z)}
            end
            if f.obstacle then return {status=f.obstacle,position=vector.create(to.x,to.y,to.z)} end
            return {status="clear"}
        end
        local owner={}
        function owner:step(dt)
            f.steps+=1;f.events[#f.events+1]="step"
            if f.step_raise then error("constructed step failure") end
            if f.on_step then f.on_step(dt) end
            return copy(f.latest)
        end
        function owner:request_mount(slot,grade)
            f.grade=grade;f.mounts+=1;f.events[#f.events+1]="mount";check(slot==0,"selected slot is preserved")
            if f.on_mount then return f.on_mount() end
            f.latest={phase="following",bike_cleanup_complete=false,bike_authority=true,cleanup_pending=false,
                cleanup_unknown=false,stock_toggle_blocked=true,unloaded=false,stop_latched=false}
            return true
        end
        function owner:request_stop(why)
            f.stops+=1;f.events[#f.events+1]="stop";check(type(why)=="string","stop reason remains explicit")
            f.latest={phase="cleanup",bike_cleanup_complete=false,bike_authority=true,cleanup_pending=true,
                cleanup_unknown=false,stock_toggle_blocked=true,unloaded=false,stop_latched=true}
            if f.on_stop then f.on_stop() end
            return true
        end
        function owner:request_stock_toggle(slot)
            f.toggles+=1;f.events[#f.events+1]="stock";check(slot==0,"stock transaction uses selected slot")
            if f.on_stock then return f.on_stock() end
            f.latest=cleaned();f.latest.stock_toggle_blocked=true;f.latest.cleanup_pending=true
            return true
        end
        function owner:unload()
            f.unloads+=1;f.events[#f.events+1]="unload"
            if f.on_unload then f.on_unload() end
            f.latest=cleaned();f.latest.unloaded=true;return copy(f.latest)
        end
        local Runtime={}
        function Runtime.new(services,config)
            f.new_calls+=1;check(services==R and config.qualification_only==true,"existing private lifecycle contract is preserved")
            return owner
        end
        if options.gentle then function owner:playable_grade_policy() return Survey.PLAYABLE_GRADE_POLICY end end
        f.R=R;f.owner=owner
        f.entry=Entry.new(R,Runtime,Survey,{admitted=options.admitted~=false,slot=0,session_renewable=options.gentle==true})
        function f.tick(count)
            for _=1,count or 1 do f.now+=16;f.probe_tick=0;f.entry:step(16) end
        end
        function f.await_mount()
            for _=1,200 do f.tick();if f.entry:status().mount_requested or f.entry:status().phase=="blocked" then return end end
            error("bounded fixture did not reach mount or refusal")
        end
        function f.riding()
            f.overlay=false;check(f.entry:mount(),"explicit mount intent accepted")
            f.await_mount();check(f.mounts==1,"exactly one lifecycle mount requested");f.tick()
            check(f.entry:status().phase=="riding","actual supplied following status drives visible riding phase")
        end
        return f
    end
local function spawn_fixture(grade,options)
    options=options or {}
    local f={now=grade and grade.at_ms or 1000,rays=0,creates=0,removes=0,releases=0,sets=0,
        actor={position=vector.create(0,.5,0),heading=grade and grade.heading or 0}}
    local api={time={},input={},skater={},entities={},world={physics={}}}
    function api.time.now() return f.now end
    function api.input.focus() return {focused=true,gameplay=true,interface_open=false} end
    function api.skater.get() return f.actor end
    function api.world.raycast(from,to)
        f.rays+=1
        if options.cancel_at==f.rays then f.owner:stop("constructed ray cancellation") end
        if options.missing_at==f.rays then return nil end
        local g=grade
        local y=g and g.origin[2]+g.b*(from.x-g.origin[1])+g.c*(from.z-g.origin[3]) or 0
        if options.cross_at==f.rays then y+=.0031 end
        return vector.create(from.x,y,from.z)
    end
    function api.entities.bounds() return vector.create(-.02,-G.wheel_radius,-G.wheel_radius),vector.create(.02,G.wheel_radius,G.wheel_radius) end
    function api.entities.set() f.sets+=1;return true end
    function api.entities.status()
        if options.expire_during_status then f.now=(grade and grade.expires_ms or f.now)+1 end
        return "ready"
    end
    function api.entities.remove() f.removes+=1 end
    function api.world.physics.create(definition) f.creates+=1;f.definition=definition;f.body=newproxy();return f.body end
    function api.world.physics.read(body)
        assert(body==f.body)
        return {epoch=newproxy(),serial="1",time=1/60,seconds=1/60,mass=G.mass,position=f.definition.position,
            rotation=f.definition.rotation,velocity=vector.create(0,0,0),angular_velocity=vector.create(0,0,0),inertia=vector.create(unpack(G.inertia))}
    end
    function api.world.physics.release(body) assert(body==f.body);f.releases+=1;return true end
    f.owner=Spawn.new(api,{session_renewable=true})
    function f.drive()
        assert(f.owner:request())
        for _=1,30 do
            f.now+=16;f.owner:update(16)
            local phase=f.owner:status().phase
            if phase=="spawned" or phase=="closed" or phase=="cleanup_unknown" then break end
        end
        return f.owner:status()
    end
    return f
end
function Tests.run()
    local assertions=0
    local function check(v,why) assertions+=1;assert(v,why) end
    check(Survey.SURVEY_SLOPE_DEG==.5 and Survey.SURVEY_DOWNHILL_DEG==.5 and Survey.SURVEY_UPHILL_DEG==.75,
        "R1 lab defaults stay unchanged")
    local entry=entry_fixture(check,{gentle=true})
    entry.slope=1.59;entry.overlay=false
    check(entry.entry:mount(),"one explicit playable Mount intent")
    entry.await_mount()
    check(entry.mounts==1 and type(entry.grade)=="table" and table.isfrozen(entry.grade),
        "measured1.59degree survey reaches one immutable plane handoff")
    local grade=entry.grade
    check(math.abs(math.deg(math.atan(math.sqrt(grade.b^2+grade.c^2)))-1.59)<.001,
        "handoff retains actual fitted grade, not a level substitute")
    check(grade.expires_ms-grade.at_ms==Survey.SURVEY_MAX_AGE_MS,"survey deadline is not extended")
    local floor={}
    for _,ray in ipairs(Survey.survey_floor_rays({0,.5,0},0)) do floor[#floor+1]={dx=ray.dx,dz=ray.dz,y=grade.b*ray.dx+grade.c*ray.dz} end
    local plane=Survey.survey_plane(floor)
    check(not Survey.survey_judge(0,floor,0,plane,0).pass,"same measured grade stays refused by legacy lab judge")
    check(Survey.playable_survey_judge(0,floor,0,plane,0).pass,"closed playable judge accepts measured gentle plane")
    check(not Survey.playable_survey_judge(0,floor,1,plane,0).pass,"missing floor sample still refuses")
    check(not Survey.playable_survey_judge(0,floor,0,plane,1).pass,"obstacle hit/unavailable still refuses")
    local steep=copy(plane);steep.b=math.tan(math.rad(5.01));steep.c=0
    check(not Survey.playable_survey_judge(0,floor,0,steep,0).pass,"over5degree grade stays closed")
    local rough=copy(plane);rough.residual=.0031
    check(not Survey.playable_survey_judge(0,floor,0,rough,0).pass,"new grade cannot bypass3mm agreement")
    local varied=entry_fixture(check,{gentle=true})
    varied.slope=1.59;varied.outer_variation=.02;varied.overlay=false
    check(varied.entry:mount(),"one Mount surveys the entire outer clearance area")
    varied.await_mount()
    check(varied.mounts==1 and varied.grade~=nil,"outer2cm terrain variation does not tilt or reject the local support plane")
    check(varied.probes==Survey.survey_counts().probes and varied.probe_peak<=Survey.SURVEY_RAYS_PER_TICK,
        "all180floor and1080obstacle rays plus each check ray remain mandatory at unchanged cadence")
    check(math.abs(varied.grade.origin[2])<1e-6 and math.abs(varied.grade.b-grade.b)<1e-6,
        "measured local footprint retains actual1.59degree normal and center height")
    local varied_floor=copy(floor)
    for _,q in ipairs(varied_floor) do if q.dx*q.dx+q.dz*q.dz>.750001^2 then q.y+=.02 end end
    local all_plane=Survey.survey_plane(varied_floor)
    local local_plane=Survey.playable_survey_plane(varied_floor)
    check(all_plane.residual>.003 and local_plane.residual<1e-6,"constructed outer variation reproduces the obsolete global3mm refusal")
    local local_verdict=Survey.playable_survey_judge(0,varied_floor,0,local_plane,0)
    check(local_verdict.pass and local_verdict.grade_required and math.abs(local_verdict.outer_residual_mm-20)<1e-6,
        "accepted verdict truthfully separates local3mm support and original40mm outer clearance")
    check(not Survey.playable_survey_judge(0,varied_floor,1,local_plane,0).pass,
        "even an outer missing ray still refuses the whole survey")
    check(not Survey.playable_survey_judge(0,varied_floor,0,local_plane,1).pass,
        "outer obstacle hit or unavailable remains fatal")
    local curb=copy(varied_floor);curb[1].y+=.012
    local curb_plane=Survey.playable_survey_plane(curb)
    local curb_verdict=Survey.playable_survey_judge(0,curb,0,curb_plane,0)
    check(not curb_verdict.pass and curb_verdict.why:find("footprint plane residual",1,true)
        and curb_verdict.why:find("slope",1,true),"true local curb refuses with actual residual and slope values")
    local far=copy(varied_floor)
    for _,q in ipairs(far) do if q.dx*q.dx+q.dz*q.dz>.750001^2 then q.y+=.0201 end end
    local far_verdict=Survey.playable_survey_judge(0,far,0,Survey.playable_survey_plane(far),0)
    check(not far_verdict.pass and far_verdict.why:find("outer clearance residual",1,true),
        "outer variation beyond original40mm stays closed")
    local check_ray=Survey.survey_check_ray({0,.5,0},0)
    check(not Survey.playable_survey_on_plane(local_plane,check_ray,{0,.0031,.75}),
        "during obstacle work a changed local check hit over3mm still refuses")
    local near_flat=entry_fixture(check,{gentle=true})
    near_flat.outer_variation=.02;near_flat.overlay=false
    check(near_flat.entry:mount(),"near-level local area retains explicit mount intent")
    near_flat.await_mount()
    check(near_flat.mounts==1 and near_flat.grade~=nil,"outer variation on near-level support still requires measured three-ray placement")
    local f=spawn_fixture(varied.grade)
    check(f.owner:set_playable_grade(varied.grade),"fresh local plane admitted before one spawn despite outer variation")
    local status=f.drive()
    check(status.phase=="spawned" and f.rays==3 and f.creates==1,"center and two wheel measurements precede one body creation")
    local n=M.unit({-grade.b,1,-grade.c})
    local up=M.turn(f.definition.rotation,{0,1,0})
    check(M.length(M.sub(up,n))<1e-6,"spawn body up aligns to measured plane normal")
    check(math.abs(f.owner:floor_height()-grade.origin[2])<1e-6,"floor_height remains the actual center hit")
    check(status.grade.native_collision_contact==false and status.grade.queries==3,"placement does not claim native collision contact")
    for _,gap in ipairs(status.grade.clearances) do check(gap>=0 and gap<=.02,"both measured wheel gaps stay within original2cm bounds") end
    f.owner:stop("constructed cleanup")
    check(f.releases==1 and f.removes==8 and not f.owner:status().cleanup_unknown,"known body and visuals retain normal cleanup")
    for _,options in ipairs({{missing_at=2},{cross_at=3},{cancel_at=2},{expire_during_status=true}}) do
        local bad=spawn_fixture(grade,options);check(bad.owner:set_playable_grade(grade),"counterexample binds same source plane")
        local denied=bad.drive()
        check(denied.phase=="closed" and bad.creates==0 and not denied.cleanup_unknown,
            "missing/cross-plane/cancel/expiry never allocates or invents ownership")
        check(bad.rays<=3,"grade refusal never repeats or exceeds its bounded query transaction")
        local before=bad.rays;bad.owner:update(16)
        check(bad.rays==before and not bad.owner:retry_after_clock_warmup(),"consumed floor observations never replay")
    end
    local drift=spawn_fixture(grade);check(drift.owner:set_playable_grade(grade),"drift counterexample binds")
    drift.actor.position=vector.create(.251,.5,0)
    check(drift.drive().phase=="closed" and drift.rays==0 and drift.creates==0,"actor drift beyond original25cm stops before floor query")
    local turn=spawn_fixture(grade);check(turn.owner:set_playable_grade(grade),"heading counterexample binds")
    turn.actor.heading=grade.heading+math.rad(5.01)
    check(turn.drive().phase=="closed" and turn.rays==0,"heading drift beyond original5degrees stops before floor query")
    local flat_entry=entry_fixture(check,{gentle=true});flat_entry.overlay=false
    check(flat_entry.entry:mount(),"ordinary flat mount intent accepted")
    flat_entry.await_mount()
    check(flat_entry.mounts==1 and flat_entry.grade==nil,"normal truly flat survey keeps the existing one-ray placement branch")
    local flat=spawn_fixture(nil)
    check(flat.drive().phase=="spawned" and flat.rays==1 and flat.owner:status().grade==nil,"ordinary flat spawn retains its one-ray branch")
    check(math.abs(flat.definition.rotation[1])+math.abs(flat.definition.rotation[2])+math.abs(flat.definition.rotation[3])==0,
        "ordinary heading-zero flat orientation stays byte-equivalent yaw-only")
    flat.owner:stop("constructed flat cleanup")
    return {cases=1,assertions=assertions,constructed=true,native_qualified=false}
end
return table.freeze(Tests)