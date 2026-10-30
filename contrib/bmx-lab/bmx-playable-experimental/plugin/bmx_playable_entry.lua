-- Experimental one-session entry coordinator. The pinned lifecycle owns every
-- input lease, body, Follow, force, pose, equipment transition and cleanup call.
local Entry={}
local PREP_COLD="native body producer setup pending; call prepare again explicitly"
local PREP_CLOCK="waiting for a fresh qualified 60 Hz physics step"
local PREP_PHASE="owned bodies require the current local client phase outside multiplayer"
local function plain(v) return type(v)=="table" and getmetatable(v)==nil end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function text(v,fallback) return type(v)=="string" and string.sub(v,1,180) or fallback end
local function call(fn,...)
    if type(fn)~="function" then return table.pack(false,"required method unavailable") end
    return table.pack(pcall(fn,...))
end
local function clean(s)
    return plain(s) and s.phase=="done" and s.bike_cleanup_complete==true
        and s.bike_authority==false and s.cleanup_pending==false and s.cleanup_unknown==false
        and s.stock_toggle_blocked==false and s.unloaded~=true
end
-- A display/intent classification only. The lifecycle still proves all cleanup.
local function fall_cause(s)
    local ride=plain(s) and s.stop_latched==true and s.ride or nil
    local issue=plain(ride) and ride.stop_requested==true and ride.issue or nil
    if type(issue)=="string" and (issue:match("^measured tilt [%d%.]+ deg over the %d+ deg Ride stop$")
        or issue:match("^measured roll rate [%d%.]+ rad/s over the %d+ rad/s Ride stop$")) then return text(issue) end
    return nil
end
function Entry.new(R,Runtime,Survey,options)
    assert(type(R)=="table" and type(Runtime)=="table" and type(Survey)=="table","entry dependencies required")
    local slot=type(options)=="table" and options.slot or 0
    assert(finite(slot) and slot%1==0 and slot>=0 and slot<=3,"controller slot required")
    local two_cycle=type(options)=="table" and options.experimental_two_cycle==true
    local session_renewable=type(options)=="table" and options.session_renewable==true
    local made=call(two_cycle and Runtime.new_experimental_two_cycle or Runtime.new,R,{qualification_only=true,session_renewable=session_renewable})
    assert(made[1] and made.n==2 and type(made[2])=="table","one inert lifecycle owner required")
    local owner=made[2] -- Constructed exactly once; never replaced or rearmed here.
    local admitted=type(options)=="table" and options.admitted==true
    local capability=call(owner.playable_grade_policy,owner)
    local gentle_grade=admitted and session_renewable and capability[1] and capability.n==2
        and capability[2]==Survey.PLAYABLE_GRADE_POLICY and type(Survey.playable_survey_judge)=="function"
        and type(Survey.playable_survey_plane)=="function" and type(Survey.playable_survey_on_plane)=="function"
    local function judge(...)
        if gentle_grade then return Survey.playable_survey_judge(...) end
        return Survey.survey_judge(...)
    end
    local phase,detail="idle",admitted and "On foot, choose Mount in a flat clear area." or "This experimental source build is closed."
    local used,mount_issued,return_pending,stock_attempted=false,false,false,false
    local attempts_used=0
    local second_prepare_pending=false
    local attempt_limit=two_cycle and 2 or 1
    local fallen,recover_pending=nil,false
    local stopped,cancel_sent,cancelled,unloaded,ticking=false,false,false,false,false
    local generation,latest,known=0,nil,false
    local prep_at,prep_last,prep_calls,last_clock,survey=nil,nil,0,nil,nil
    local object={}
    local return_plan,return_position
    local MAX_TERRAIN_REFUSALS=8
    local terrain_refusals={}
    -- These exact fields exist in the pinned facade's pre-admission status.
    -- No Core, Source, body, Follow or equipment owner exists in this state.
    local function inert(s)
        return plain(s) and s.schema==1 and s.kind=="bike-lifecycle-v1" and s.phase=="idle"
            and s.qualification_only==true and s.mount_enabled==false and s.used==false
            and s.bike_authority==false and s.cleanup_pending==false and s.cleanup_unknown==false
            and s.stock_toggle_blocked==false and s.unloaded==false
            and plain(s.equipment) and s.equipment.phase=="idle"
            and s.equipment.retained==false and s.equipment.unloaded==false
            and plain(s.startup) and s.startup.pending==false and s.startup.loaded==0
            and s.startup.core_ready==false and s.startup.backend_ready==false
    end
    local function preflight_clear()
        if attempts_used~=1 or not used or mount_issued or return_pending or stock_attempted
            or stopped or cancel_sent or cancelled or unloaded or not known or not inert(latest) then return false end
        local out=call(owner.status,owner)
        if not out[1] or out.n~=2 or not inert(out[2]) then return false end
        local keys=call(R.storage and R.storage.keys)
        return keys[1] and keys.n==2 and plain(keys[2]) and next(keys[2])==nil
    end
    local function stop_once(why,cancel)
        if cancel then if cancel_sent then return end;cancel_sent=true
        else if stopped then return end;stopped=true end
        local out=call(owner.request_stop,owner,why)
        if not out[1] or out[2]~=true then detail="Stop requested; cleanup status must remain visible." end
    end
    local function fail(why)
        phase,detail="blocked",text(why,"Operation failed; no retry in this session.")
        return_pending=false;second_prepare_pending=false;recover_pending=false;generation+=1
        -- A later equipment transaction has independent authority from the ride stop.
        stop_once("experimental entry: "..detail,stock_attempted)
    end
    local function clock()
        local out=call(R.time and R.time.now)
        local now=out[2]
        if not out[1] or out.n~=2 or not finite(now) or now<0 or last_clock and now<last_clock then
            fail("Clock unavailable or reversed; attempt ended.");return nil
        end
        last_clock=now;return now
    end
    local function environment(overlay_allowed)
        local f=call(R.input and R.input.focus)
        local m=call(R.menu and R.menu.game)
        if not f[1] or f.n~=2 or not plain(f[2]) or type(f[2].focused)~="boolean"
            or type(f[2].gameplay)~="boolean" or type(f[2].interface_open)~="boolean"
            or not m[1] or m.n~=2 or not plain(m[2]) or type(m[2].open)~="boolean" then
            fail("Focus or menu readiness unavailable.");return false
        end
        return f[2].focused and f[2].gameplay and not m[2].open
            and (overlay_allowed or not f[2].interface_open)
    end
    local function actor()
        local out=call(R.skater and R.skater.get)
        local a=out[2]
        if not out[1] or out.n~=2 or not plain(a) or typeof(a.position)~="vector"
            or not finite(a.position.x) or not finite(a.position.y) or not finite(a.position.z) or not finite(a.heading) then
            fail("Rider position or heading unavailable.");return nil
        end
        return a
    end
    local function state()
        local out=call(R.skater and R.skater.telemetry)
        if not out[1] or out.n~=2 or not plain(out[2]) or not plain(out[2].watch)
            or (out[2].watch.state~=100 and out[2].watch.state~=504) then
            fail("Stock rider state unavailable; no switch was sent.");return nil
        end
        return out[2].watch.state
    end
    local function fresh_namespace()
        local out=call(R.storage and R.storage.keys)
        if not out[1] or out.n~=2 or not plain(out[2]) or next(out[2])~=nil then
            phase,detail="blocked","Prior or unreadable lifecycle storage; use a fresh experimental session."
            return false
        end
        return true
    end
    local namespace_clear=fresh_namespace()
    local function start_survey()
        local version=generation
        local a=actor();if not a or generation~=version or cancelled or unloaded then return end
        local p={a.position.x,a.position.y,a.position.z}
        survey={state="running",phase="floor",p=p,heading=a.heading,next=1,ticks=0,floor={},misses=0,hits=0,unavailable=0,
            rays=Survey.survey_floor_rays(p,a.heading)}
        phase,detail="surveying","Checking the full clear area; stay still."
    end
    local function terrain_only(verdict,displayed)
        if not plain(verdict) or type(verdict.pass)~="boolean" or not survey
            or survey.misses~=0 or survey.hits~=0 or survey.unavailable~=0
            or verdict.floor_misses~=0 or verdict.floor_rays~=#survey.floor or verdict.blocked~=0
            or not plain(survey.plane) or not finite(survey.plane.residual) or survey.plane.residual<0
            or not finite(verdict.slope_deg) or verdict.slope_deg<0
            or not finite(verdict.downhill_deg) or not finite(verdict.downhill_dir_deg)
            or not finite(verdict.residual_mm) or verdict.residual_mm<0 then return false end
        if verdict.pass then return not gentle_grade and displayed~=nil and displayed>.05 end
        if gentle_grade then
            return survey.plane.residual>Survey.PLAYABLE_GRADE_RESIDUAL_M
                or verdict.slope_deg>Survey.PLAYABLE_GRADE_SLOPE_DEG
                or finite(verdict.outer_residual_mm) and verdict.outer_residual_mm>Survey.SURVEY_RESIDUAL_M*1000
        end
        return survey.plane.residual>Survey.SURVEY_RESIDUAL_M
            or verdict.slope_deg>Survey.SURVEY_SLOPE_DEG
            or verdict.downhill_deg>Survey.SURVEY_DOWNHILL_DEG
            or -verdict.downhill_deg>Survey.SURVEY_UPHILL_DEG
    end
    local function terrain_refused(verdict,now,displayed,why)
        if not terrain_only(verdict,displayed) then return false end
        local version=generation
        local clear=preflight_clear()
        if generation~=version or cancelled or unloaded then return true end
        if not clear then return false end
        local count=#terrain_refusals+1
        terrain_refusals[count]=table.freeze({index=count,at=now,reason=why,
            residual_mm=verdict.residual_mm,slope_deg=verdict.slope_deg,downhill_deg=verdict.downhill_deg})
        if count>=MAX_TERRAIN_REFUSALS then return false end
        generation+=1
        phase,detail="preflight_refused","Terrain preflight "..tostring(count)..": "..why
            ..". No mount requested. Move to a flat clear area, then choose Mount again."
        return true
    end
    local function survey_finish(verdict,now)
        -- Keep S2d's display rule for lab owners. The closed playable owner
        -- instead requires a measured gentle plane and aligned Spawn placement.
        local slope=plain(verdict) and verdict.slope_deg
        local displayed=finite(slope) and tonumber(string.format("%.2f",slope)) or nil
        survey.state="done";survey.verdict=verdict;survey.at=now
        survey.pass=plain(verdict) and verdict.pass==true and displayed~=nil and (gentle_grade or displayed<=.05)
        if not survey.pass then
            local why=text(plain(verdict) and verdict.pass==true and "Survey slope must display 0.05 degrees or less for this profile."
                or plain(verdict) and verdict.why,"Clear-area survey refused.")
            if not terrain_refused(verdict,now,displayed,why) then fail(why) end
            return
        end
        phase,detail="awaiting_mount","Survey passed. Close menus and release all controls."
    end
    local function cast(ray)
        local out=call(R.world and R.world.probe,vector.create(ray.from[1],ray.from[2],ray.from[3]),vector.create(ray.to[1],ray.to[2],ray.to[3]))
        if not out[1] or out.n~=2 or not plain(out[2]) then return "unavailable" end
        return out[2].status,out[2].status=="hit" and out[2].position or nil
    end
    local function survey_step(now)
        local version=generation
        local cap=Survey.SURVEY_RAYS_PER_TICK
        survey.ticks+=1
        if survey.phase=="floor" then
            local last=math.min(#survey.rays,survey.next+cap-1)
            for i=survey.next,last do
                local ray=survey.rays[i];local status,at=cast(ray)
                if generation~=version or cancelled or unloaded then return end
                local v=status=="hit" and Survey.survey_floor_hit(ray,at) or nil
                if v then survey.floor[#survey.floor+1]={dx=ray.dx,dz=ray.dz,y=v[2]} else survey.misses+=1 end
            end
            survey.next=last+1;if survey.next<=#survey.rays then return end
            if gentle_grade then survey.plane=Survey.playable_survey_plane(survey.floor)
            else survey.plane=Survey.survey_plane(survey.floor) end
            local floor=judge(survey.heading,survey.floor,survey.misses,survey.plane,0)
            if floor.pass~=true then survey_finish(floor,now);return end
            survey.phase="obstacles";survey.rays=Survey.survey_obstacle_rays(survey.p,survey.heading,survey.plane);survey.next=1
            return
        end
        local last=math.min(#survey.rays,survey.next+cap-2)
        for i=survey.next,last do
            local status=cast(survey.rays[i])
            if generation~=version or cancelled or unloaded then return end
            if status=="hit" then survey.hits+=1 elseif status~="clear" then survey.unavailable+=1 end
        end
        survey.next=last+1
        local ray=Survey.survey_check_ray(survey.p,survey.heading);local status,at=cast(ray)
        if generation~=version or cancelled or unloaded then return end
        local checked=status=="hit" and Survey.survey_floor_hit(ray,at) or nil
        local on_plane=gentle_grade and Survey.playable_survey_on_plane or Survey.survey_on_plane
        if not on_plane(survey.plane,ray,checked) then
            fail("Survey floor changed; attempt ended.");return
        end
        if survey.next>#survey.rays then
            survey_finish(judge(survey.heading,survey.floor,survey.misses,survey.plane,survey.hits+survey.unavailable),now)
        end
    end
    local function prep_step(now)
        if now-prep_at>=30000 or prep_calls>=20 then fail("Preparation timed out; no mount was requested.");return end
        if prep_last and now-prep_last<100 then return end
        local version=generation
        if not environment(true) or generation~=version or cancelled or unloaded or phase~="preparing" then return end
        prep_calls+=1;prep_last=now
        local out=call(R.world and R.world.physics and R.world.physics.prepare)
        if generation~=version or cancelled or unloaded then return end
        if not out[1] or type(out[2])~="boolean" or out[2] and out.n~=2 or not out[2] and out.n~=3 then
            fail("Preparation failed or returned an unknown result.");return
        end
        local returned=clock()
        if not returned or generation~=version or cancelled or unloaded then return end
        if returned-prep_at>=30000 then fail("Preparation timed out; no mount was requested.");return end
        if out[2] then start_survey();return end
        if out[3]~=PREP_COLD and out[3]~=PREP_CLOCK and out[3]~=PREP_PHASE then
            fail(text(out[3],"Native preparation refused."));return
        end
        detail="Preparing the native body service; no body has been requested."
    end
    local function mount_step(now)
        local version=generation
        if not environment(false) then return end
        if state()~=504 then if phase~="blocked" then fail("Start on foot for this experimental ride.") end;return end
        local a=actor();if not a then return end
        local fresh,why=Survey.survey_fresh(survey,a,now)
        if not fresh then fail(text(why,"Survey is no longer fresh."));return end
        if generation~=version or cancelled or unloaded then return end
        mount_issued=true -- Burn before callback, even if the owner refuses or raises.
        local grade
        if gentle_grade and survey.verdict.grade_required==true then
            grade=table.freeze({policy=Survey.PLAYABLE_GRADE_POLICY,
                origin=table.freeze({survey.p[1],survey.plane.a,survey.p[3]}),
                actor_position=table.freeze({survey.p[1],survey.p[2],survey.p[3]}),
                b=survey.plane.b,c=survey.plane.c,residual=survey.plane.residual,heading=survey.heading,
                at_ms=survey.at,expires_ms=survey.at+Survey.SURVEY_MAX_AGE_MS})
        end
        local out
        if grade then out=call(owner.request_mount,owner,slot,grade)
        else out=call(owner.request_mount,owner,slot) end
        if generation~=version or cancelled or unloaded then return end
        if not out[1] or out[2]~=true then fail(text(out[3],"Mount refused; no retry in this session."));return end
        phase,detail="mounting","Mount armed. Keep controls released while the lifecycle takes ownership."
    end
    local function handback_step(version)
        if not return_plan then return true end
        local function live() return generation==version and not cancelled and not unloaded and return_pending end
        local now=clock();if not live() then return false,"cancelled" end
        if not now or now<return_plan.stop_ms or now>=return_plan.expires_ms then return false,"Return position deadline expired; final Return blocked" end
        if not environment(false) or not live() then return false,"Return position context lost" end
        if return_position.last_poll and now-return_position.last_poll<50 then return false,"pending" end
        return_position.last_poll=now
        local allowed=call(R.input and R.input.allowed);if not live() then return false,"cancelled" end
        local level=call(R.level and R.level.current);if not live() then return false,"cancelled" end
        if not allowed[1] or allowed.n~=2 or allowed[2]~=true or not level[1] or level.n~=2
            or not plain(level[2]) or level[2].name~=return_plan.level then return false,"Return permission or level changed" end

        if not return_position.attempted then
            -- Reserve the existing native5s queue lifetime plus100ms observed
            -- convergence INSIDE the original stop+20s window, never after it.
            if now+5100>=return_plan.expires_ms then return false,"Too little original cleanup time for one queued Return" end
            local p=return_plan.ground
            -- This location came from the live epoch-bound qualified batch,
            -- not a post-park or unclassified ray and not a static-world pin.
            local watch=call(R.skater and R.skater.telemetry);if not live() then return false,"cancelled" end
            local w=watch[2]
            if not watch[1] or watch.n~=2 or not plain(w) or w.skater~=true or w.teleport_pending~=false or w.airborne~=false
                or not plain(w.watch) or w.watch.valid~=true or w.watch.state~=100 or w.watch.ragdoll_known~=true
                or w.watch.ragdoll~=false or w.watch.wipeouts~=return_plan.wipeouts then return false,"Fresh grounded-stock Return context unavailable" end
            now=clock();if not live() then return false,"cancelled" end
            if not now or now+5100>=return_plan.expires_ms then return false,"Return queue no longer fits original deadline" end
            return_position.attempted=true;return_position.unknown=true -- burn before callback; never retry
            return_position.target=table.freeze({p[1],p[2]+return_plan.actor_floor_clearance_m,p[3]})
            return_position.sent_ms=now
            local q=return_position.target
            local sent=call(R.skater and R.skater.teleport,vector.create(q[1],q[2],q[3]),return_plan.heading)
            if not live() then return false,"cancelled" end
            if not sent[1] or sent.n~=2 or sent[2]~=true then
                local refused=sent[1] and sent.n==3 and sent[2]==false and type(sent[3])=="string"
                return_position.unknown=not refused;return_position.phase=refused and "refused" or "unknown"
                return false,refused and "Return placement refused: "..text(sent[3],"refused") or "Return placement result unknown; no retry or final Return"
            end
            return_position.unknown=false;return_position.queued=true;return_position.phase="queued"
            now=clock();if not live() then return false,"cancelled" end
            if not now or now>=return_plan.expires_ms then return_position.unknown=true;return false,"Return request crossed original deadline" end
            detail="Return placement queued after stock ACK; waiting for actual grounded100 position."
            return false,"pending"
        end
        local watch=call(R.skater and R.skater.telemetry);if not live() then return false,"cancelled" end
        local actor=call(R.skater and R.skater.get);if not live() then return false,"cancelled" end
        now=clock();if not live() then return false,"cancelled" end
        if not now or now>=return_plan.expires_ms then return false,"Return position observation crossed original deadline" end
        local w,a=watch[2],actor[2]
        if watch[1] and watch.n==2 and plain(w) and w.skater==true and type(w.teleport_pending)=="boolean"
            and plain(w.watch) and w.watch.valid==true and w.watch.ragdoll_known==true and w.watch.ragdoll==false
            and w.watch.wipeouts==return_plan.wipeouts and w.watch.state==100
            and actor[1] and actor.n==2 and plain(a) and typeof(a.position)=="vector"
            and finite(a.position.x) and finite(a.position.y) and finite(a.position.z) and finite(a.heading) then
            local p=return_position.target
            local dx,dy,dz=a.position.x-p[1],a.position.y-p[2],a.position.z-p[3]
            local turn=(a.heading-return_plan.heading+math.pi)%(2*math.pi)-math.pi
            local matched=w.teleport_pending==false and a.airborne==false and w.airborne==false
                and dx*dx+dz*dz<=.25*.25 and math.abs(dy)<=.25 and math.abs(turn)<=math.rad(5)
            if matched then
                return_position.first_match=return_position.first_match or now
                return_position.samples=(return_position.samples or 0)+1
                if now-return_position.first_match>=100 and return_position.samples>=3 then
                    return_position.observed=true;return_position.phase="observed"
                    return_position.observed_ms=now;return_position.position=table.freeze({a.position.x,a.position.y,a.position.z})
                    detail="Grounded100 Return position observed after the stock target and ACK."
                    return true
                end
            else return_position.first_match=nil;return_position.samples=0 end
        else return_position.first_match=nil;return_position.samples=0 end
        return false,"pending"
    end
    local function return_step()
        local version=generation
        if not known or not clean(latest) then detail="Returning: waiting for confirmed cleanup; no stock input sent.";return end
        if return_plan and stock_attempted then
                -- Stock's physical transition can replace its root. Place only
                -- AFTER that exact transaction has observed100 and cleared ACK.
                local e=latest.equipment
                local receipt=plain(e) and e.terminal_receipt or nil
                if not stock_attempted or not plain(e) or e.phase~="done" or e.outcome~="target_observed"
                    or e.initial_state~=504 or e.expected_state~=100 or e.retained~=false or e.acknowledged~=true
                    or e.qualified_transition~=true or e.current_transition~=true or e.unloaded~=false or e.storage_fault~=false
                    or not plain(receipt) or receipt.terminal~=true or receipt.claim_released~=true
                    or receipt.report_debt~=false or receipt.quarantined~=false then
                    fail("Matched clean stock100 target and ACK required before Return placement.");return
                end
                local ready,why=handback_step(version)
                if generation~=version or cancelled or unloaded then return end
                if not ready then
                    if why~="pending" then
                        return_position.phase="blocked";return_position.reason=why
                        return_position.unknown=return_position.unknown or return_position.queued and not return_position.observed
                        fail(why)
                    end
                    return
                end
        end
        -- During a queued placement handback_step tolerates missing/transient
        -- samples without admitting an effect. Only its actual100 convergence
        -- reaches this fresh state check and final Return path.
        local observed=state();if observed==nil or generation~=version or cancelled or unloaded then return end
        if observed==100 then
            if return_plan and (not stock_attempted or return_position.observed~=true) then
                fail("Matched stock100 ACK and position convergence required for final Return.");return
            end
            return_pending=false
            if two_cycle and attempts_used<attempt_limit then
                local ready=call(owner.can_prepare_next_mount,owner)
                if generation~=version or cancelled or unloaded then return end
                if not ready[1] or ready[2]~=true then
                    recover_pending=false
                    phase,detail="spent","Skateboard observed; prior cycle did not qualify a clean successor. No further attempt."
                    return
                end
            end
            phase,detail="skateboard",two_cycle and attempts_used<attempt_limit and "Skateboard observed. One fresh-allocation attempt remains; Mount first obtains on-foot504 again." or "Skateboard observed; the bounded attempts are spent."
            return
        end
        if stock_attempted then fail("Stock transition ended without an observed skateboard; no retry.");return end
        if not environment(false) then return end
        if generation~=version or cancelled or unloaded then return end
        if return_plan then
            local now=clock()
            if generation~=version or cancelled or unloaded then return end
            if not now or now<return_plan.stop_ms or now+5100>=return_plan.expires_ms then
                fail("Too little original Return time before stock transition.");return
            end
        end
        stock_attempted=true -- One existing equipment transaction, never a per-tick pulse.
        local out=call(owner.request_stock_toggle,owner,slot)
        if generation~=version or cancelled or unloaded then return end
        if not out[1] or out[2]~=true then fail(text(out[3],"Stock switch refused; cleanup remains owned by the lifecycle."));return end
        phase,detail="returning","Stock transition armed. Release all controls and wait for the skateboard."
    end
    local function step_off(now)
        local version=generation
        if second_prepare_pending then
            if not environment(false) then return end
            if generation~=version or cancelled or unloaded then return end
            if not known or not clean(latest) then fail("Previous Return is no longer fully clean.");return end
            local current=state()
            if generation~=version or cancelled or unloaded then return end
            if current~=100 then fail("Attempt two still requires current stock100 before step-off.");return end
            -- Consume the deferred request before any owner callback can reenter.
            -- The menu click spends the intent; only a closed-menu tick sends it.
            second_prepare_pending=false
            local prepared=call(owner.prepare_next_mount,owner,slot)
            if generation~=version or cancelled or unloaded then return end
            if not prepared[1] or prepared[2]~=true then fail(text(prepared[3],"Second preparation refused."));return end
            detail="Step-off armed once. Keep menus closed and controls released for the504 ACK."
            return
        end
        local out=call(owner.next_mount_ready,owner)
        if generation~=version or cancelled or unloaded then return end
        if not out[1] or out.n~=3 or type(out[2])~="boolean" then fail("On-foot preparation status unavailable.");return end
        if not out[2] then
            if out[3]~="pending" then fail(text(out[3],"On-foot preparation failed.")) end
            return
        end
        if state()~=504 or generation~=version or cancelled or unloaded then
            if generation==version and not cancelled and not unloaded then fail("Fresh acknowledged on-foot target required.") end
            return
        end
        prep_at=now;prep_last=nil;prep_calls=0;survey=nil
        phase,detail="preparing","On-foot504 + ACK observed. Preparing a fresh survey for attempt two."
    end
    function object:mount()
        if not admitted then return false,"Experimental source admission is closed." end
        if phase=="preflight_refused" then
            if unloaded or ticking or cancelled or not namespace_clear then return false,"Preflight retry unavailable." end
            local version=generation
            local clear=preflight_clear()
            if generation~=version or cancelled or unloaded then return false,detail end
            if not clear then fail("Preflight owner or storage proof lost; no retry.");return false,detail end
            local current=state()
            if generation~=version or cancelled or unloaded then return false,detail end
            if current~=504 then fail("Preflight retry requires on-foot504; no retry.");return false,detail end
            local now=clock()
            if not now or generation~=version or cancelled or unloaded then return false,detail end
            -- A new explicit terrain survey gets the original prepare bounds.
            -- Neither the reserved attempt nor any lifecycle/native state is reset.
            generation+=1;prep_at=now;prep_last=nil;prep_calls=0;survey=nil
            phase,detail="preparing","Retrying terrain preflight; stay on foot and still. Prior refusals remain recorded."
            return true
        end
        if unloaded or ticking or cancelled or not namespace_clear or attempts_used>=attempt_limit
            or used and (not two_cycle or phase~="skateboard") then return false,"Consumed, busy or retained attempt; not available." end
        attempts_used+=1;used=true;generation+=1
        local version=generation
        if attempts_used==2 then
            -- Burn the second intent before ALL fallible callbacks. Return's
            -- old stock100 history is archived by the private owner first.
            phase,detail="stepping_off","Attempt two is spent. Close menus and release controls before the guarded stock100 to on-foot504 transition."
            mount_issued=false;return_pending=false;stock_attempted=false;stopped=false;cancel_sent=false
            if not known or not clean(latest) then fail("Previous Return is not fully clean.");return false,detail end
            local current=state()
            if generation~=version or cancelled or unloaded then return false,detail end
            if current~=100 then
                fail("Attempt two requires current stock100 after Return. Already on foot or unreadable state spends this intent.")
                return false,detail
            end
            second_prepare_pending=true
            return true
        end
        phase,detail="preparing","Preparing, then surveying the clear area. Stay on foot and still."
        prep_at=clock()
        if not prep_at or cancelled or unloaded or phase~="preparing" then return false,detail end
        return true
    end
    function object:return_to_skateboard()
        if unloaded or ticking or cancelled or not mount_issued or return_pending or stock_attempted then
            return false,"Return is unavailable; Cancel may stop an unfinished preparation."
        end
        return_pending=true;return_plan=nil;return_position=nil;generation+=1;phase,detail="returning","Stopping the bike before returning to the skateboard."
        if type(owner.request_return)=="function" then
            stopped=true -- one capture/stop callback, even if it refuses or raises
            local version=generation
            local out=call(owner.request_return,owner)
            if generation~=version or cancelled or unloaded then return false,"Return cancelled" end
            if not out[1] or out[2]~=true or out.n~=2 and out.n~=3 then
                -- The cold/busy facade may refuse before it reaches Core stop.
                -- Reissue the ordinary idempotent stop rather than suppress cleanup.
                stopped=false;fail(text(out[3],"Live Return capture failed; cleanup continues."));return false,detail
            end
            local p=out[3]
            if p~=nil then
                if not plain(p) or not table.isfrozen(p) or p.schema~="measured_return_position_v1"
                    or not plain(p.ground) or not table.isfrozen(p.ground) or not finite(p.ground[1]) or not finite(p.ground[2]) or not finite(p.ground[3])
                    or not finite(p.actor_floor_clearance_m) or p.actor_floor_clearance_m<0 or p.actor_floor_clearance_m>2
                    or not finite(p.heading) or not finite(p.stop_ms) or not finite(p.expires_ms)
                    or p.expires_ms-p.stop_ms~=20000 or type(p.level)~="string" or not finite(p.wipeouts) then
                    fail("Malformed measured Return handoff; no stock input.");return false,detail
                end
                return_plan=p;return_position={phase="prepared",attempted=false,queued=false,observed=false,unknown=false}
            end
        else stop_once("explicit return to skateboard",false) end
        return true
    end
    local function recoverable()
        return admitted and two_cycle and attempts_used==1 and mount_issued and fallen~=nil
            and not recover_pending and not return_pending and not unloaded and not ticking and not cancelled
            and namespace_clear and known and latest.cleanup_unknown==false
            and (phase=="fallen" or phase=="skateboard")
    end
    function object:recover()
        if not recoverable() then return false,"Recovery needs a known fall, cleanable first attempt and one remaining attempt." end
        recover_pending=true -- One explicit intent before any Return callback can reenter.
        if phase=="skateboard" then return true end
        local out=call(self.return_to_skateboard,self)
        if not out[1] or out[2]~=true or cancelled or unloaded then
            recover_pending=false;return false,text(out[3],"Recovery Return was refused or cancelled.")
        end
        return true
    end
    function object:cancel()
        if unloaded then return false,"Entry is unloaded." end
        if return_position and return_position.queued and not return_position.observed then
            return_position.unknown=true;return_position.phase="interrupted"
        end
        cancelled=true;return_pending=false;second_prepare_pending=false;recover_pending=false;generation+=1
        phase,detail="cancelled","Cancelled. The lifecycle continues cleanup; this session cannot remount."
        stop_once("explicit playable cancel",true)
        return true
    end
    function object:step(dt_ms)
        if unloaded then return end
        if ticking then self:cancel();return end
        ticking=true
        local function advance()
            local out=call(owner.step,owner,dt_ms)
            if out[1] and out.n==2 and plain(out[2]) then latest=out[2];known=true
            else known=false;fail("Lifecycle step unavailable; cleanup remains required.") end
            if recover_pending and known and latest.cleanup_unknown~=false then
                fail("Recovery stopped by unknown lifecycle cleanup; no fresh Mount.");return
            end
            if not cancelled and phase~="blocked" then
            if return_pending then return_step()
            elseif phase=="stepping_off" or phase=="preparing" or phase=="surveying" or phase=="awaiting_mount" then
                local now=clock()
                if now then
                    if phase=="stepping_off" then step_off(now)
                    elseif phase=="preparing" then prep_step(now)
                    elseif phase=="surveying" then
                        local version=generation
                        if environment(true) and generation==version and not cancelled and not unloaded and phase=="surveying" then survey_step(now) end
                    elseif phase=="awaiting_mount" then mount_step(now) end
                end
            elseif mount_issued and known and phase~="skateboard" and phase~="spent" then
                if latest.phase=="following" and latest.stop_latched~=true then
                    fallen=nil;phase,detail="riding","One-session bike active. Return or Cancel remains available."
                elseif latest.stop_latched==true or latest.phase=="done" then
                    fallen=fall_cause(latest) or fallen
                    if fallen then phase,detail="fallen","Bike stopped after a fall: "..fallen
                        ..(attempts_used<attempt_limit and ". Recover can return and prepare the remaining attempt."
                            or ". Both attempts are spent; Return remains available.")
                    else phase,detail="stopped",text(latest.stop_reason,"Ride stopped; cleanup continues. Return remains available.") end
                end
            end
            end
        end
        local advanced=pcall(advance)
        ticking=false
        if not advanced then known=false;fail("Entry step failed; cleanup remains required.")
        elseif recover_pending and not cancelled and not unloaded and phase=="skateboard" then
            recover_pending=false -- Consume before fresh Mount callbacks; no automatic retry.
            local out=call(self.mount,self)
            if not out[1] or out[2]~=true then fail(text(out[3],"Recovery Mount refused; the intent is spent.")) end
        end
    end
    function object:status()
        local history=table.clone(terrain_refusals);table.freeze(history)
        return table.freeze({phase=phase,detail=detail,admitted=admitted,slot=slot,mount_intent_used=used,
            terrain_refusal_count=#history,terrain_refusal_limit=MAX_TERRAIN_REFUSALS,terrain_refusals=history,
            preflight_retry_available=phase=="preflight_refused" and not cancelled and not unloaded,
            mount_requested=mount_issued,return_requested=return_pending,stock_attempted=stock_attempted,cancelled=cancelled,
            fall_reason=fallen,recovery_pending=recover_pending,recovery_available=recoverable(),
            prepare_calls=prep_calls,survey_state=survey and survey.state or "not_started",
            core_phase=known and latest.phase or "unknown",return_position=return_position and table.freeze(table.clone(return_position)) or nil,
            lifecycle_detail=known and (plain(latest.spawn) and text(latest.spawn.detail,nil) or text(latest.detail,nil)
                or text(latest.stop_reason,"Lifecycle status observed.")) or "Lifecycle status is unknown; no stock switch is allowed.",
            bike_authority=not known or latest.bike_authority~=false,
            attempts_used=attempts_used,attempt_limit=attempt_limit,new_allocation_each_cycle=two_cycle,
            cleanup_pending=not known or latest.cleanup_pending~=false,cleanup_unknown=not known or latest.cleanup_unknown~=false,
            stock_toggle_blocked=not known or latest.stock_toggle_blocked~=false,session_reusable=false})
    end
    function object:unload()
        if unloaded then return end
        if return_position and return_position.queued and not return_position.observed then
            return_position.unknown=true;return_position.phase="interrupted"
        end
        unloaded=true;cancelled=true;return_pending=false;second_prepare_pending=false;recover_pending=false;generation+=1
        local out=call(owner.unload,owner)
        if out[1] and out.n==2 and plain(out[2]) then latest=out[2];known=true else known=false end
        phase,detail="unloaded","Unloaded; native cleanup remains with the lifecycle and SDK."
    end
    return table.freeze(object)
end
return table.freeze(Entry)
