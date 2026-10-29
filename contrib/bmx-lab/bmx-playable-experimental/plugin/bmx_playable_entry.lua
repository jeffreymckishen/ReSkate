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
    local phase,detail="idle",admitted and "On foot, choose Mount in a flat clear area." or "This experimental source build is closed."
    local used,mount_issued,return_pending,stock_attempted=false,false,false,false
    local attempts_used=0
    local second_prepare_pending=false
    local attempt_limit=two_cycle and 2 or 1
    local stopped,cancel_sent,cancelled,unloaded,ticking=false,false,false,false,false
    local generation,latest,known=0,nil,false
    local prep_at,prep_last,prep_calls,last_clock,survey=nil,nil,0,nil,nil
    local object={}
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
        return_pending=false;second_prepare_pending=false;generation+=1
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
        if verdict.pass then return displayed~=nil and displayed>.05 end
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
        -- S2d's operator rule required the displayed two-decimal slope <=0.05.
        local slope=plain(verdict) and verdict.slope_deg
        local displayed=finite(slope) and tonumber(string.format("%.2f",slope)) or nil
        survey.state="done";survey.verdict=verdict;survey.at=now
        survey.pass=plain(verdict) and verdict.pass==true and displayed~=nil and displayed<=.05
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
            survey.plane=Survey.survey_plane(survey.floor)
            local floor=Survey.survey_judge(survey.heading,survey.floor,survey.misses,survey.plane,0)
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
        if not Survey.survey_on_plane(survey.plane,ray,checked) then
            fail("Survey floor changed; attempt ended.");return
        end
        if survey.next>#survey.rays then
            survey_finish(Survey.survey_judge(survey.heading,survey.floor,survey.misses,survey.plane,survey.hits+survey.unavailable),now)
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
        local out=call(owner.request_mount,owner,slot)
        if generation~=version or cancelled or unloaded then return end
        if not out[1] or out[2]~=true then fail(text(out[3],"Mount refused; no retry in this session."));return end
        phase,detail="mounting","Mount armed. Keep controls released while the lifecycle takes ownership."
    end
    local function return_step()
        local version=generation
        if not known or not clean(latest) then detail="Returning: waiting for confirmed cleanup; no stock input sent.";return end
        local observed=state();if observed==nil or generation~=version or cancelled or unloaded then return end
        if observed==100 then
            return_pending=false
            if two_cycle and attempts_used<attempt_limit then
                local ready=call(owner.can_prepare_next_mount,owner)
                if generation~=version or cancelled or unloaded then return end
                if not ready[1] or ready[2]~=true then
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
        return_pending=true;generation+=1;phase,detail="returning","Stopping the bike before returning to the skateboard."
        stop_once("explicit return to skateboard",false)
        return true
    end
    function object:cancel()
        if unloaded then return false,"Entry is unloaded." end
        cancelled=true;return_pending=false;second_prepare_pending=false;generation+=1
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
            elseif mount_issued and known and phase~="skateboard" then
                if latest.phase=="following" and latest.stop_latched~=true then phase,detail="riding","One-session bike active. Return or Cancel remains available."
                elseif latest.stop_latched==true or latest.phase=="done" then
                    phase,detail="stopped",text(latest.stop_reason,"Ride stopped; cleanup continues. Return remains available.") end
            end
            end
        end
        local advanced=pcall(advance)
        ticking=false
        if not advanced then known=false;fail("Entry step failed; cleanup remains required.") end
    end
    function object:status()
        local history=table.clone(terrain_refusals);table.freeze(history)
        return table.freeze({phase=phase,detail=detail,admitted=admitted,slot=slot,mount_intent_used=used,
            terrain_refusal_count=#history,terrain_refusal_limit=MAX_TERRAIN_REFUSALS,terrain_refusals=history,
            preflight_retry_available=phase=="preflight_refused" and not cancelled and not unloaded,
            mount_requested=mount_issued,return_requested=return_pending,stock_attempted=stock_attempted,cancelled=cancelled,
            prepare_calls=prep_calls,survey_state=survey and survey.state or "not_started",
            core_phase=known and latest.phase or "unknown",
            lifecycle_detail=known and (plain(latest.spawn) and text(latest.spawn.detail,nil) or text(latest.detail,nil)
                or text(latest.stop_reason,"Lifecycle status observed.")) or "Lifecycle status is unknown; no stock switch is allowed.",
            bike_authority=not known or latest.bike_authority~=false,
            attempts_used=attempts_used,attempt_limit=attempt_limit,new_allocation_each_cycle=two_cycle,
            cleanup_pending=not known or latest.cleanup_pending~=false,cleanup_unknown=not known or latest.cleanup_unknown~=false,
            stock_toggle_blocked=not known or latest.stock_toggle_blocked~=false,session_reusable=false})
    end
    function object:unload()
        if unloaded then return end
        unloaded=true;cancelled=true;return_pending=false;second_prepare_pending=false;generation+=1
        local out=call(owner.unload,owner)
        if out[1] and out.n==2 and plain(out[2]) then latest=out[2];known=true else known=false end
        phase,detail="unloaded","Unloaded; native cleanup remains with the lifecycle and SDK."
    end
    return table.freeze(object)
end
return table.freeze(Entry)
