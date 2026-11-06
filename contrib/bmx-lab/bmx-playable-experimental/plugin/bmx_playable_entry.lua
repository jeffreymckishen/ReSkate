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
-- What main.lua keeps under the settings key (y_button.lua): schema 1 and whether bike mode is on, and nothing else.
local function settings_valid(v)
    if not plain(v) or v.schema~=1 or type(v.bike_mode)~="boolean" then return false end
    for k in pairs(v) do if k~="schema" and k~="bike_mode" then return false end end
    return true
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
        or issue:match("^measured roll rate [%d%.]+ rad/s over the %d+ rad/s Ride stop$")
        or issue:match("^hit something at [%d%.]+ m/s$")
        or issue=="rider came off the bike"
        -- Core's own stop when the game bails the hidden on-foot rider mid-ride (bike_runtime_core.lua knocked_down).
        or issue=="rider was knocked down") then return text(issue) end
    return nil
end
-- One line of what the lifecycle says, for the log. The ledger is cleared at the next load, so this is what outlives a launch.
local function lifecycle_line(s)
    local e=plain(s.equipment) and s.equipment or {}
    local r=plain(e.receipt) and e.receipt or {}
    local f=plain(e.first_fall) and e.first_fall or {}
    local ride=plain(s.ride) and s.ride or {}
    local source=plain(s.source) and s.source or {}
    local spawn=plain(s.spawn) and s.spawn or {}
    -- The facts Core read last, frozen at a stop, so a readiness stop says which one failed. The switch's settle
    -- suffix says why a switch that did not reach its target gave up (settle_deadline says only that it did).
    local ready=plain(s.readiness) and s.readiness or {}
    local initial=plain(s.initial_readiness) and s.initial_readiness or {}
    local suffix=plain(e.suffix) and e.suffix or {}
    return string.format("core=%s detail=%q stop=%q ride_issue=%q bike_clean=%s pending=%s unknown=%s blocked=%s gear_unknown=%s late=%s closed=%s"
        .." source=%s gear=%s/%s/%s attempt=%s retained=%s pulse=%s press=%s neutral=%s debt=%s mask=%s fall_state=%s fall_ragdoll=%s fall_wipeouts=%s/%s"
        .." origin=%s miss=%s refusal=%s ready_state=%s ready_ragdoll=%s ready_wipeouts=%s/%s settle_failure=%s",
        tostring(s.phase),text(s.detail,""),text(s.stop_reason,""),text(ride.issue,""),tostring(s.bike_cleanup_complete),tostring(s.cleanup_pending),
        tostring(s.cleanup_unknown),tostring(s.stock_toggle_blocked),tostring(s.gear_unknown),tostring(s.cleanup_expired),tostring(s.startup_closed),
        tostring(source.phase),tostring(e.phase),tostring(e.outcome),tostring(e.reason),tostring(e.attempt),tostring(e.retained),
        tostring(r.status),tostring(r.press_publications),tostring(r.neutral_publications),tostring(r.report_debt),tostring(r.first_rejection_mask),
        tostring(f.state),tostring(f.ragdoll),tostring(f.wipeouts),tostring(f.baseline_wipeouts),
        tostring(spawn.origin),tostring(spawn.reuse_miss),tostring(spawn.creation_refusal),
        tostring(ready.state),tostring(ready.ragdoll),tostring(ready.wipeouts),tostring(initial.wipeouts),tostring(suffix.last_failure))
end
function Entry.new(R,Runtime,Survey,options)
    assert(type(R)=="table" and type(Runtime)=="table" and type(Survey)=="table","entry dependencies required")
    local slot=type(options)=="table" and options.slot or 0
    assert(finite(slot) and slot%1==0 and slot>=0 and slot<=3,"controller slot required")
    local two_cycle=type(options)=="table" and options.experimental_two_cycle==true
    local auto_return=type(options)=="table" and options.auto_return==true
    local session_renewable=type(options)=="table" and options.session_renewable==true
    -- The one storage key a load keeps, main.lua's bike mode switch: fresh_namespace clears every other key, and the
    -- first ride's proof (preflight_clear) accepts it as the only one. Core and the equipment owner never write it.
    local settings_key=type(options)=="table" and type(options.settings_key)=="string" and #options.settings_key<=64
        and string.match(options.settings_key,"^[%w_]+$") and options.settings_key or nil
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
    local STOCK_RETRIES,STOCK_RETRY_MS,NOTICE_MS,RETURN_LIMIT_MS=4,500,4000,45000
    -- A rider the game has not stood up yet spends none of RETURN_LIMIT_MS: after a crash the game kept riders down
    -- for 17 s, 24 s and over 45 s in the trials. This much longer cap still ends a Return that never finishes.
    local RETURN_HARD_MS=180000
    -- Time a Return has spent where the game could take the switch, and the previous tick's clock and answer.
    local return_used,return_seen,return_open=0,nil,false
    -- All of that time, the rider down or not, for the hard cap. Whether the rider was down as of the last tick, from
    -- that tick's own read of the rider: a state the switch cannot act on, ragdolled or in the air. Core's refusal of
    -- the switch is not used for it. Core gives the same refusal for a level change, and no switch is asked for while a
    -- control is held, so its last answer can be stale for a rider who has stood up since.
    local return_total,return_down=0,false
    -- Whether the game has the rider ragdolled while Entry waits on the player outside a Return (DOWN_WAITS), read at
    -- most every 250 ms in step(). help_line runs every frame and reads nothing itself.
    local DOWN_WAITS={blocked=true,spent=true,fallen=true,stopped=true,preflight_refused=true}
    local rider_down,down_read_at=false,nil
    local notice,notice_until,last_clock=nil,0,nil
    local mount_charged,last_stop,logged_phase,logged_line=false,nil,nil,nil
    -- What this Mount's stop has told the rider, so a stop is told once and not every tick it stays latched. Each
    -- accepted Mount clears it: the same refusal twice in a row is two refusals, and each is told.
    local stop_told=nil
    local function trace(line) call(R.log,"[BMX] "..line) end
    -- Shown without reading the clock. A reason given with it is what the log keeps: the lifecycle's own words,
    -- which say why to someone reading the log but nothing a rider can act on, so the rider is told the message.
    local function announce(message,reason)
        if reason then trace(reason);trace("told: "..message) else trace(message) end
        notice,notice_until=text(message,""),(last_clock or 0)+NOTICE_MS
    end
    -- What the rider is told to press, for the controls main.lua's bike mode picks (set_controls). In bike mode Y gets
    -- on the bike from the board or on foot (y_button.lua), so these lines name only Y, though LB + A still works.
    -- ride_stopped is what a ride that ended by itself tells the rider: any end other than a fall is the same to them,
    -- the bike stopped and they can ride again once back on the board. With auto_return the ride's end starts a Return
    -- on the same tick, and a Mount is refused until that reaches the board, so the notice says where the rider is
    -- going instead (RIDE_RETURNING), as a fall with no mount left does. moved is a first ride's survey that the rider
    -- moved away from before the bike was asked for.
    local WORDS={
        lb_a={ride_stopped="The ride stopped. Hold LB and press A to ride again.",
            step_off="Step off your skateboard with Y, then hold LB and press A.",
            moved="Stand still while the bike gets ready. Hold LB and press A again.",
            off_board="Press Y for your skateboard, then hold LB and press A.",
            board="Get on your skateboard, then hold LB and press A.",
            ride_again="Hold LB and press A to ride again.",
            let_go="Let go of every control for a moment, then hold LB and press A.",
            close_menus="Close menus and let go of the controls, then hold LB and press A.",
            help={fallen="The ride ended. Hold LB and press A to ride again.",
                preflight_refused="No room here or too steep: move, then hold LB and press A.",
                blocked="That didn't finish. Get on your skateboard, then hold LB and press A.",
                spent="That didn't finish. Get on your skateboard, then hold LB and press A."}},
        y={ride_stopped="The ride stopped. Press Y to ride again.",
            step_off="Press Y to get on the bike.",
            moved="Stand still while the bike gets ready. Press Y again.",
            off_board="Press Y to ride again.",
            board="Press Y to ride again.",
            ride_again="Press Y to ride again.",
            let_go="Let go of every control for a moment, then press Y.",
            close_menus="Close menus and let go of the controls, then press Y.",
            -- In bike mode a second Y is the likely mistake. y_button.lua keeps Y from the game while a Mount waits with
            -- nothing asked of the game's input, but it cannot while the step-off's own Y or the mount is under way,
            -- and a Y the game sees then steps the rider off or brings out the board and ends the attempt. So these
            -- two lines say not to press it.
            help={fallen="The ride ended. Press Y to ride again.",
                preflight_refused="No room here or too steep: move, then press Y.",
                blocked="That didn't finish. Press Y to ride again.",
                spent="That didn't finish. Press Y to ride again.",
                stepping_off="Stepping off the board for the bike: stand still and don't press Y.",
                mounting="Getting on the bike: let go of the controls and don't press Y.",
                -- A remount's step-off that reads the rider standing on foot, for the second before help_line asks
                -- them for Y: stepping_off is said only to a rider on the board.
                remount_on_foot="Getting back on the bike."}}}
    local words=WORDS.lb_a
    local RIDE_RETURNING="The ride stopped. Going back to the skateboard."
    local stock_retries,stock_retry_at=0,nil
    local second_prepare_pending,second_terrain_pending=false,false
    local second_admitted_at,second_quiet_at,second_quiet_last,second_quiet_samples=nil,nil,nil,0
    -- The SDK has eight native body slots a game launch, shared by every plugin; input leases are cleared at their
    -- acknowledgement and cost nothing. An SDK that cannot reuse a parked body spends a slot on every mount, so the
    -- cap stays at eight. Spawn asks to re-activate this VM's parked bike instead, and the first create that says where
    -- its body came from (Spawn's origin) lifts the cap: the SDK's own refusal then says when no body is left. The
    -- cap is a defensive check: a ReSkate without world.physics.reuse refuses the manifest, so never loads the mod.
    local attempt_limit=two_cycle and 8 or 1
    -- Whether the SDK reports an origin: nil until a create has made a body.
    local body_reuse=nil
    -- Mounts whose create the SDK refused for a retry: it made no body and reserved nothing, so they spend none of
    -- the cap. attempts_used still counts them, since it also says which cycle comes next. One a Mount at most.
    local unspent,mount_refunded=0,false
    local function mount_left() return attempt_limit==nil or attempts_used-unspent<attempt_limit end
    local fallen,recover_pending,recover_wait_context=nil,false,nil
    -- The automatic remount after a crash, fall or knock-down: auto_mount is set only while Recover's own Mount runs,
    -- and second_recovering says the step-off now waiting is that Mount's. second_off_board says that step-off's last
    -- sample read the rider off the board.
    local auto_mount,second_recovering,second_off_board=false,false,false
    -- Whether that last sample read the rider standing on foot (504, not ragdolled), who gets back on the board only
    -- with a Y, rather than one the game still has down; and since when the samples have read them standing.
    local second_off_standing,second_off_since=false,nil
    -- What the HUD says while blocked when the failure knows more than the general line does. Both are keys of words,
    -- so a line still up says the controls picked since.
    local blocked_help=nil
    -- What the HUD says while a first ride's Mount waits on where the rider is, in place of the terrain line.
    local refused_help=nil
    -- A hold on the game's input from elsewhere in the mod (set_input_hold): y_button.lua's, true while it keeps Y from
    -- the game. While any button is hidden the SDK refuses every input lease, capture and pulse as interference
    -- (input_capture.cpp input_pulse_available), so the two calls that hand the game's input on, the step-off's
    -- prepare_next_mount and the mount's request_mount, wait for it to end. hold_waiting: one of them is waiting for
    -- it, and for nothing else. It ends as soon as that call waits for something else as well, a menu or a new quiet.
    local input_hold,hold_waiting=nil,false
    local stopped,cancel_sent,cancelled,unloaded,ticking=false,false,false,false,false
    local generation,latest,known=0,nil,false
    local prep_at,prep_last,prep_calls,survey=nil,nil,0,nil
    local object={}
    local return_plan,return_position
    -- Terrain refusals of one Mount intent: each new intent starts a new list.
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
    -- What to tell the rider when the SDK made no body and left nothing to clean up (bike_spawn.lua create_refusal).
    -- A level change does not help the "change_level" refusals here: rides do not carry on past one in this launch.
    local NO_BODY={restart="No bike is left this launch: restart the game to ride again.",
        change_level="The bike can't be made here: restart the game to ride again."}
    -- A retry refusal is told only as the ride stops: the chain stays clean, so the next Mount asks again.
    local NOT_READY="The bike was not ready: mount again."
    local function refusal()
        local b=known and plain(latest) and latest.spawn
        return plain(b) and b.creation_refusal or nil
    end
    local function no_body() local class=refusal();return class and NO_BODY[class] or nil end
    -- Whether the hold is on now. Only a plain true holds, so an Entry no one set a hold on is as before.
    local function held_input()
        if input_hold==nil then return false end
        local out=call(input_hold)
        return out[1] and out[2]==true
    end
    -- Where a button kept from the game costs the Mount under way nothing (y_button.lua): the stock state the rider
    -- waits in while nothing of the game's input is live or asked for, and nothing will be without asking the hold
    -- first. 100 while a later ride waits for released controls before its step-off; 504 while a ride prepares,
    -- surveys and waits to ask for the bike. nil everywhere else (a step-off armed, a mount asked for, a ride, a
    -- Return), and while a hand-over waits for the hold, so that it is let go. A hand-over that then waits for a menu
    -- or a new quiet names its state again (hold_waiting).
    local function hold_state()
        if hold_waiting or cancelled or unloaded or mount_issued or return_pending or stock_attempted then return nil end
        if phase=="stepping_off" then return second_prepare_pending and 100 or nil end
        if phase=="preparing" or phase=="surveying" or phase=="awaiting_mount" then return 504 end
        return nil
    end
    -- Whether the settings key holds the setting main.lua writes, read now.
    local function settings_kept()
        local stored=call(R.storage and R.storage.get,settings_key)
        return stored[1] and stored.n==2 and settings_valid(stored[2])
    end
    local function preflight_clear()
        if attempts_used>=2 and two_cycle then
            if not used or mount_issued or return_pending or stock_attempted or second_prepare_pending
                or stopped or cancel_sent or cancelled or unloaded or not known or not clean(latest)
                or not finite(second_admitted_at) then return false end
            local observed=call(owner.status,owner)
            if not observed[1] or observed.n~=2 or not clean(observed[2]) then return false end
            -- The same old owner proves a NEW504 ACK and no successor request.
            -- Its ledger is legitimately nonempty; do not reuse the cold proof.
            local ready=call(owner.second_preflight_ready,owner,second_admitted_at)
            return ready[1] and ready.n==3 and ready[2]==true and finite(ready[3])
                and ready[3]%1==0 and ready[3]>=2
        end
        if attempts_used~=1 or not used or mount_issued or return_pending or stock_attempted
            or stopped or cancel_sent or cancelled or unloaded or not known or not inert(latest) then return false end
        local out=call(owner.status,owner)
        if not out[1] or out.n~=2 or not inert(out[2]) then return false end
        local keys=call(R.storage and R.storage.keys)
        if not keys[1] or keys.n~=2 or not plain(keys[2]) then return false end
        local first,name=next(keys[2])
        if first==nil then return true end
        -- The bike mode setting is the one key a first ride may find: no ride writes it, so it says nothing about one.
        -- Any other key, or a second one beside it, still refuses.
        if type(first)=="string" then name=first end
        if settings_key==nil or name~=settings_key or next(keys[2],first)~=nil then return false end
        return settings_kept()
    end
    local function stop_once(why,cancel)
        if cancel then if cancel_sent then return end;cancel_sent=true
        else if stopped then return end;stopped=true end
        local out=call(owner.request_stop,owner,why)
        if not out[1] or out[2]~=true then detail="Stop requested; cleanup status must remain visible." end
    end
    local function fail(why)
        phase,detail="blocked",text(why,"Operation failed; no retry in this session.")
        blocked_help=nil
        return_pending=false;second_prepare_pending=false;second_terrain_pending=false;recover_pending=false;generation+=1
        -- A preparation that never asked for a bike used none of the launch's mounts.
        if mount_charged and not mount_issued then attempts_used-=1 end
        mount_charged=false
        -- The log keeps why. The rider is shown the blocked help line, which says what to do next, and a notice still
        -- up from before, such as a ride's end, is cleared so that it cannot hide that line.
        trace("Stopped: "..detail)
        notice=nil
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
    -- A Mount that cannot start says why on the HUD for a few seconds, rather than doing nothing. The log says it
    -- too, so a report that Mount did nothing can be read from it.
    local function tell(message)
        trace("told: "..message)
        notice,notice_until=message,(clock() or 0)+NOTICE_MS
        return false,message
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
    -- Every button up and both sticks and triggers at rest. An unreadable pad delays nothing.
    local function pad_released()
        local pad=call(R.input and R.input.gamepad)
        local p=pad[2]
        if not pad[1] or pad.n~=2 or not plain(p) or not plain(p.buttons) then return true end
        for _,name in {"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"} do
            if p.buttons[name]==true then return false end
        end
        for _,name in {"left_x","left_y","right_x","right_y","left_trigger","right_trigger"} do
            if not finite(p[name]) then return true end
        end
        return p.left_x^2+p.left_y^2<=(7849/32767)^2 and p.right_x^2+p.right_y^2<=(8689/32767)^2
            and p.left_trigger<=30/255 and p.right_trigger<=30/255
    end
    -- Whether the game could take the stock switch: focused, in play, no menu open. No Y may be sent otherwise.
    -- An unreadable answer says yes, so a Return's time limit still runs when this cannot be told.
    local function switch_possible()
        local f=call(R.input and R.input.focus)
        local m=call(R.menu and R.menu.game)
        if not f[1] or f.n~=2 or not plain(f[2]) or not m[1] or m.n~=2 or not plain(m[2]) then return true end
        return not (f[2].focused==false or f[2].gameplay==false or f[2].interface_open==true or m[2].open==true)
    end
    local function state()
        local out=call(R.skater and R.skater.telemetry)
        if not out[1] or out.n~=2 or not plain(out[2]) or not plain(out[2].watch)
            or (out[2].watch.state~=100 and out[2].watch.state~=504) then
            -- Mid grind, mid fall, mid air: the stock switch waits for a state it can act on.
            detail="Waiting for the rider to settle.";return nil
        end
        -- The second answer: the game still has the rider down, ragdolled or in the air, which Core's switch refuses
        -- until it is over (bike_admission.lua upright, bike_runtime_core.lua request_stock_toggle).
        local w=out[2]
        return w.watch.state,w.watch.ragdoll==true or w.airborne==true
    end
    local function fresh_namespace()
        local out=call(R.storage and R.storage.keys)
        if not out[1] or out.n~=2 or not plain(out[2]) then
            phase,detail="blocked","Unreadable lifecycle storage; no Mount in this session."
            return false
        end
        -- Records from an earlier launch describe a ride that ended with that game. Left here they would refuse
        -- every later Mount, here and in Core's marker check. What they say goes to the log first, the one place it lasts.
        local previous=call(R.storage and R.storage.get,"bmx_bike_lifecycle_v1")
        if previous[1] and plain(previous[2]) then trace("previous launch: "..lifecycle_line(previous[2])) end
        for key,value in pairs(out[2]) do
            local name=type(key)=="string" and key or value
            -- The bike mode setting outlives the launch on purpose. Anything else under its name is cleared, so a
            -- malformed one leaves bike mode off.
            if settings_key==nil or name~=settings_key or not settings_kept() then
                local cleared=call(R.storage.set,name,nil)
                if not cleared[1] then
                    phase,detail="blocked","Earlier lifecycle storage could not be cleared; no Mount in this session."
                    return false
                end
            end
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
        -- Something in the way is somewhere to move away from, the same as a slope: no mount has been asked for.
        if plain(verdict) and verdict.pass==false and survey and (survey.misses~=0 or survey.hits~=0
            or survey.unavailable~=0 or verdict.blocked~=0) then return true end
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
        generation+=1;refused_help=nil
        phase,detail="preflight_refused","Terrain preflight "..tostring(count)..": "..why
            ..". No mount requested. Move to a flat clear area, then choose Mount again."
        return true
    end
    -- On the first ride nothing is asked of the game before request_mount, and preflight_clear proves the owner still
    -- holds nothing, so a Mount undone only by where the rider is (on the board, or off the spot the survey checked)
    -- waits for their next Mount and a new survey, as a terrain refusal does, rather than ending the launch's rides.
    -- A later cycle has its own step-off proof and keeps its rule.
    -- message is a key of words, kept so the HUD line follows a change of controls.
    local function first_ride_retry(why,message)
        if attempts_used~=1 then return false end
        local version=generation
        local clear=preflight_clear()
        if generation~=version or cancelled or unloaded then return true end
        if not clear then return false end
        generation+=1;refused_help=message
        phase,detail="preflight_refused",why
        tell(words[message])
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
        -- With a menu open the request waits for the menu, not for the hold, so hold_waiting ends as the step-off's
        -- does. Nothing waits here once the menu closes: the request is asked for on that tick, before y_button.lua
        -- could keep Y again.
        if not environment(false) then hold_waiting=false;return end
        if state()~=504 then
            if phase~="blocked" and not first_ride_retry("Mount needs the rider on foot; no mount requested."
                .." Step off the skateboard, then choose Mount again.","step_off") then
                fail("Start on foot for this experimental ride.")
            end
            return
        end
        local a=actor();if not a then return end
        local fresh,why=Survey.survey_fresh(survey,a,now)
        if not fresh then
            -- Moved or turned since the survey is only where the rider is. A survey too old to trust, or one that
            -- cannot be read, is not, and still ends the attempt.
            local moved=type(why)=="string" and (string.find(why,"^rider moved")~=nil or string.find(why,"^rider turned")~=nil)
            if not (moved and first_ride_retry(text(why).."; no mount requested. Stand still, then choose Mount again.","moved")) then
                fail(text(why,"Survey is no longer fresh."))
            end
            return
        end
        if generation~=version or cancelled or unloaded then return end
        -- The mount's lease and capture would be refused under a hidden button: wait until it is given back, which
        -- y_button.lua does once Y is up. The survey's own age limit still applies.
        if held_input() then hold_waiting=true;return end
        hold_waiting=false
        mount_issued=true -- Burn before callback, even if the owner refuses or raises.
        mount_charged=false
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
        -- Reserve the existing native5s queue lifetime plus100ms observed
        -- convergence INSIDE the original stop+20s window, never after it.
        -- A switch whose Y waited for a held controller, or for the game to be in front, can match its target with
        -- less than that left. Nothing has been placed, so the caller goes on without the placement ("unplaced").
        if not return_position.attempted and (not now or now<return_plan.stop_ms or now+5100>=return_plan.expires_ms) then
            return false,"unplaced"
        end
        -- A placement the game has finished with cannot land later, so one that never held still at its target is not
        -- a reason to stop. In loop5 (2026-11-04), on a grade, the rider was placed on the board, which turned and rolled
        -- 5.7 m downhill: the 20 s ran out on a rider already on the skateboard, and the Return blocked. A rider the
        -- game is done placing who then holds on the board for 1 s already went on before this, from where they were
        -- ("settled", below). What reaches the deadline is a rider who had not held on the board for a second by then
        -- (in the air, grinding, down, off the board, or only just back on it): that Return also goes on from where the
        -- rider is ("unconfirmed"), and the ordinary path waits for a downed rider to get up. One the game may still be carrying out stays blocked, as does one whose read cannot say.
        local function late(why)
            if return_position.queued and not return_position.observed then
                local watch=call(R.skater and R.skater.telemetry);if not live() then return false,"cancelled" end
                if watch[1] and watch.n==2 and plain(watch[2]) and watch[2].teleport_pending==false then return false,"unconfirmed" end
            end
            return false,why
        end
        if not now or now<return_plan.stop_ms then return false,"Return position deadline expired; final Return blocked" end
        if now>=return_plan.expires_ms then return late("Return position deadline expired; final Return blocked") end
        if not environment(false) or not live() then return false,"Return position context lost" end
        if return_position.last_poll and now-return_position.last_poll<50 then return false,"pending" end
        return_position.last_poll=now
        local allowed=call(R.input and R.input.allowed);if not live() then return false,"cancelled" end
        local level=call(R.level and R.level.current);if not live() then return false,"cancelled" end
        if not allowed[1] or allowed.n~=2 or allowed[2]~=true or not level[1] or level.n~=2
            or not plain(level[2]) or level[2].name~=return_plan.level then return false,"Return permission or level changed" end

        if not return_position.attempted then
            local p=return_plan.ground
            -- This location came from the live epoch-bound qualified batch,
            -- not a post-park or unclassified ray and not a static-world pin.
            local watch=call(R.skater and R.skater.telemetry);if not live() then return false,"cancelled" end
            local w=watch[2]
            if not watch[1] or watch.n~=2 or not plain(w) or w.skater~=true or w.teleport_pending~=false or w.airborne~=false
                or not plain(w.watch) or w.watch.valid~=true or w.watch.state~=100 or w.watch.ragdoll_known~=true
                or w.watch.ragdoll~=false or w.watch.wipeouts~=return_plan.wipeouts then return false,"Fresh grounded-stock Return context unavailable" end
            now=clock();if not live() then return false,"cancelled" end
            -- The reads above take time too; a window that closed during them is the same as one closed before.
            if not now or now+5100>=return_plan.expires_ms then return false,"unplaced" end
            return_position.attempted=true;return_position.unknown=true -- burn before callback; never retry
            return_position.target=table.freeze({p[1],p[2]+return_plan.actor_floor_clearance_m,p[3]})
            return_position.sent_ms=now;return_position.pending_seen=false
            local q=return_position.target
            -- The generic per-request option preserves the intended stock
            -- equipment target; actual100 convergence is required while the game may still carry the placement out.
            -- Once the game is done with it (its pending flag read true and then false, or false 5.1 s after this send,
            -- past the SDK's 5 s queue lifetime) a rider who holds on the board for 1 s ends the Return where they are,
            -- on the target or not (loop7, below the observation reads).
            local sent=call(R.skater and R.skater.teleport,vector.create(q[1],q[2],q[3]),return_plan.heading,{on_board=true})
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
        if not now then return false,"Return position observation crossed original deadline" end
        if now>=return_plan.expires_ms then return late("Return position observation crossed original deadline") end
        local w,a=watch[2],actor[2]
        -- Last-value diagnostics from these EXISTING reads only. Absence is
        -- unknown, never zero/false; this projection grants no effect authority.
        local previous_sample_ms=return_position.sample_ms
        return_position.sample_ms=now
        return_position.actual_state=nil;return_position.actual_pending=nil
        return_position.actual_position=nil;return_position.actual_heading_rad=nil
        return_position.horizontal_error_m=nil;return_position.vertical_error_m=nil;return_position.heading_error_deg=nil
        if watch[1] and watch.n==2 and plain(w) then
            if type(w.teleport_pending)=="boolean" then return_position.actual_pending=w.teleport_pending end
            if plain(w.watch) and w.watch.valid==true and finite(w.watch.state) and w.watch.state%1==0 then
                return_position.actual_state=w.watch.state
            end
        end
        if actor[1] and actor.n==2 and plain(a) and typeof(a.position)=="vector"
            and finite(a.position.x) and finite(a.position.y) and finite(a.position.z) and finite(a.heading) then
            local p=return_position.target
            local dx,dy,dz=a.position.x-p[1],a.position.y-p[2],a.position.z-p[3]
            return_position.actual_position=table.freeze({a.position.x,a.position.y,a.position.z})
            return_position.actual_heading_rad=a.heading
            return_position.horizontal_error_m=math.sqrt(dx*dx+dz*dz);return_position.vertical_error_m=dy
            return_position.heading_error_deg=math.deg((a.heading-return_plan.heading+math.pi)%(2*math.pi)-math.pi)
        end
        local state_text=return_position.actual_state~=nil and tostring(return_position.actual_state) or "unknown"
        local pending_text=return_position.actual_pending~=nil and tostring(return_position.actual_pending) or "unknown"
        local errors=return_position.horizontal_error_m and string.format(" h%.3fm v%+.3fm yaw%+.2fdeg",
            return_position.horizontal_error_m,return_position.vertical_error_m,return_position.heading_error_deg) or " pose unknown"
        return_position.diagnostic="state "..state_text.." pending "..pending_text..errors
        detail="Return observation: "..return_position.diagnostic
        if watch[1] and watch.n==2 and plain(w) and w.teleport_pending==true then return_position.pending_seen=true end
        -- What both endings below need of the rider: on the board, out of ragdoll, not crashed since the stop.
        local rider=watch[1] and watch.n==2 and plain(w) and w.skater==true and type(w.teleport_pending)=="boolean"
            and plain(w.watch) and w.watch.valid==true and w.watch.ragdoll_known==true and w.watch.ragdoll==false
            and w.watch.wipeouts==return_plan.wipeouts and w.watch.state==100
            and actor[1] and actor.n==2 and plain(a)
        -- Sparse samples do not establish a sustained suffix, for either ending.
        -- Use the equipment owner's existing maximum observation gap.
        local broken=not previous_sample_ms or now<=previous_sample_ms or now-previous_sample_ms>250
        local matched=false
        if rider and typeof(a.position)=="vector"
            and finite(a.position.x) and finite(a.position.y) and finite(a.position.z) and finite(a.heading) then
            local p=return_position.target
            local dx,dy,dz=a.position.x-p[1],a.position.y-p[2],a.position.z-p[3]
            local turn=(a.heading-return_plan.heading+math.pi)%(2*math.pi)-math.pi
            matched=w.teleport_pending==false and a.airborne==false and w.airborne==false
                and dx*dx+dz*dz<=.25*.25 and math.abs(dy)<=.25 and math.abs(turn)<=math.rad(5)
        end
        if matched then
            return_position.first_settled=nil;return_position.settled_samples=0
            if broken then return_position.first_match=nil;return_position.samples=0 end
            return_position.first_match=return_position.first_match or now
            return_position.samples=(return_position.samples or 0)+1
            if now-return_position.first_match>=100 and return_position.samples>=3 then
                return_position.observed=true;return_position.phase="observed"
                return_position.observed_ms=now;return_position.position=table.freeze({a.position.x,a.position.y,a.position.z})
                detail="Grounded100 Return position observed after the stock target and ACK."
                return true
            end
            return false,"pending"
        end
        return_position.first_match=nil;return_position.samples=0
        -- A rider the game is done placing who stays on the board ends the Return where they are. loop7 (2026-11-04
        -- 22:35, the log's 2 s CHOP_BEAT details): the placement read pending at 16.8, just after the switch; by 18.8 it
        -- was done and the rider was grinding 1.7 m above the target and 2.8 m from it (state 403, the game's grind
        -- state, held over two reads, so on a ledge or rail rather than falling); from 22.8 they were on the board
        -- 7 m off it, turned 70 deg, and stood almost still in a traffic lane with Mount unavailable while the Return
        -- waited out its 20 s. Just before the deadline they were slammed (the feed showed a Light and a Harsh Slam, a
        -- traffic SUV stopped beside them), most likely by a car. "Done placing" is a pending flag read true and then
        -- false, or false 5.1 s after the send: an earlier false may only be a request the SDK has not taken yet. The
        -- rider may roll on the board, as on loop5's grade, so there is no stillness rule, only a held second of reads.
        local done=rider and w.teleport_pending==false
            and (return_position.pending_seen==true or now-return_position.sent_ms>=5100)
        if done and a.airborne==false and w.airborne==false and return_position.queued==true and not return_position.observed then
            if broken then return_position.first_settled=nil;return_position.settled_samples=0 end
            return_position.first_settled=return_position.first_settled or now
            return_position.settled_samples=(return_position.settled_samples or 0)+1
            if now-return_position.first_settled>=1000 and return_position.settled_samples>=3 then
                return_position.phase="settled";return_position.settled_ms=now
                return false,"settled"
            end
        else return_position.first_settled=nil;return_position.settled_samples=0 end
        return false,"pending"
    end
    local function return_step()
        local version=generation
        local started=clock()
        local open=switch_possible()
        if generation~=version or cancelled or unloaded then return end
        -- Only a tick that the game could take the switch at both ends counts toward the limit. Time in another
        -- window or a menu, when no Y may be sent, does not run out a Return that is waiting to send one. A gap
        -- between ticks, as when the game stops ticking out of focus, counts as no more than 250 ms.
        if started and return_seen and started>return_seen and open and return_open then
            local spent=math.min(started-return_seen,250)
            return_total+=spent
            if not return_down then return_used+=spent end
        end
        return_seen,return_open=started,open
        if return_used>=RETURN_LIMIT_MS or return_total>=RETURN_HARD_MS then
            return_used,return_total,return_seen,return_open,return_down=0,0,nil,false,false
            fail("Return did not finish: "..text(known and latest.detail,"lifecycle unknown"));return
        end
        if not known or not clean(latest) then detail="Returning: waiting for confirmed cleanup; no stock input sent.";return end
        if return_plan and stock_attempted and not return_position.attempted then
            -- The stock press can end with no Y in the game: the SDK revokes or expires it in warmup while the
            -- controller is held. That transaction let go of everything and matched no target, and nothing has
            -- been placed, so this Return goes on without its placement, the same as one that measured no
            -- position. The ordinary path below finds the rider still on foot and re-arms the switch.
            local e=latest.equipment
            if plain(e) and (e.phase=="done" or e.phase=="idle") and e.retained==false and e.unloaded==false
                and e.storage_fault==false and e.outcome~="target_observed" and e.outcome~="unresolved" then
                return_plan,return_position=nil,nil
            end
        end
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
                if not ready and why=="unplaced" then
                    -- The switch matched its target, so the rider is on the board, but too late to place them. The
                    -- Return goes on as one that measured no position: the rider stays where the switch left them and
                    -- the ordinary path below finishes on the skateboard.
                    trace("Return placement skipped: the stock switch finished too late in its 20 s window.")
                    return_plan,return_position=nil,nil
                elseif not ready and why=="settled" then
                    -- The game is done with the placement and the rider has held on the board for a second, off the
                    -- target. Waiting out the 20 s left them standing in the road in loop7, so the Return finishes
                    -- where they are now, as below, and the next Mount surveys that ground.
                    -- "Done with" rather than "placed": the SDK may have dropped the request instead of carrying it out.
                    trace("The game is done with the Return placement, off its target ("..text(return_position.diagnostic,"pose unknown")
                        .."); the rider is on the board, so the Return finishes there.")
                    return_plan,return_position=nil,nil
                elseif not ready and why=="unconfirmed" then
                    -- The game placed the rider, or dropped the placement, and in the whole 20 s the rider neither held
                    -- still at the target nor held on the board for a second: in the air, grinding, down or off the
                    -- board at the end, as the slammed rider of loop7 was, or only just back on it. Where they are is where the Return goes on from: the ordinary path
                    -- below waits for them to get up, and the next Mount surveys that ground.
                    trace("Return placement not confirmed in its 20 s window ("..text(return_position.diagnostic,"pose unknown")
                        .."); the Return goes on from where the rider is.")
                    return_plan,return_position=nil,nil
                elseif not ready then
                    if why~="pending" then
                        return_position.phase="blocked";return_position.reason=why
                        return_position.unknown=return_position.unknown or return_position.queued and not return_position.observed
                        fail(why..(return_position.diagnostic and "; "..return_position.diagnostic or ""))
                    end
                    return
                end
        end
        -- During a queued placement handback_step tolerates missing/transient
        -- samples without admitting an effect. A queued placement reaches this
        -- fresh state check and final Return path only after its actual100
        -- convergence, once the game is done with it and the rider has held on
        -- the board for a second ("settled"), or at the deadline once a fresh
        -- read says the game no longer has it pending ("unconfirmed"). The last
        -- two drop the plan.
        local observed,down=state();if generation~=version or cancelled or unloaded then return end
        -- Mid fall or mid air the rider is down; on the board or on foot only while the game still has them ragdolled
        -- or in the air. A rider standing with a control held is not down: the line below tells them to let go, and
        -- that time counts toward RETURN_LIMIT_MS.
        local was_down=return_down
        return_down=observed==nil or down
        -- Logged once per spell down, so a trial can tell a crash's wait from an ordinary Return passing through.
        if return_down and not was_down then
            trace("Return waits for the rider: "..(observed==nil and "neither on the board nor on foot" or "ragdolled or in the air")..".")
        end
        if observed==nil then return end
        if observed==100 then
            if return_plan and (not stock_attempted or return_position.observed~=true) then return_plan,return_position=nil,nil end
            return_pending=false
            if two_cycle and mount_left() then
                local ready=call(owner.can_prepare_next_mount,owner)
                if generation~=version or cancelled or unloaded then return end
                if not ready[1] or ready[2]~=true then
                    recover_pending=false
                    phase,detail="spent",no_body() or "Skateboard observed; prior cycle did not qualify a clean successor. No further attempt."
                    return
                end
            end
            phase,detail="skateboard",two_cycle and mount_left() and "Skateboard observed. Mount first obtains on-foot504 again." or "Skateboard observed; the bounded attempts are spent."
            return
        end
        if stock_attempted then
            -- Pressing something during the switch ends it on foot. A few more goes before giving up.
            stock_retries+=1
            if stock_retries>STOCK_RETRIES then fail("Stock transition ended without an observed skateboard.");return end
            stock_attempted=false;return
        end
        if not environment(false) then return end
        if generation~=version or cancelled or unloaded then return end
        local retry_clock=clock()
        if stock_retry_at and (not retry_clock or retry_clock<stock_retry_at) then return end
        -- The stock switch fails if the rider is still holding anything, and someone who has just crashed usually is.
        if not pad_released() then detail="Let go of the controls to go back to the skateboard.";return end
        if return_plan then
            local now=clock()
            if generation~=version or cancelled or unloaded then return end
            if not now or now<return_plan.stop_ms or now+5100>=return_plan.expires_ms then
                return_plan,return_position=nil,nil
            end
        end
        stock_attempted=true -- One existing equipment transaction, never a per-tick pulse.
        local out=call(owner.request_stock_toggle,owner,slot)
        if generation~=version or cancelled or unloaded then return end
        if not out[1] or out[2]~=true then
            -- Still moving or just landed: no transaction started, so this tries again as the rider settles. Core
            -- refuses a rider still down after a crash (bike_runtime_core.lua request_stock_toggle), and the read above
            -- has already kept that wait out of the Return's time.
            stock_attempted=false;stock_retry_at=(clock() or 0)+STOCK_RETRY_MS;detail="Waiting for the rider to settle.";return
        end
        return_down=false
        phase,detail="returning","Stock transition armed. Release all controls and wait for the skateboard."
    end
    local function reset_second_quiet()
        second_quiet_at,second_quiet_last,second_quiet_samples=nil,nil,0
    end
    local function second_quiet(now,expected)
        expected=expected or 100
        -- This aggregate pad observation can only delay admission. It proves no
        -- selected-slot identity or native consumption; the original equipment
        -- owner still supplies every selected-slot baseline, pulse and ACK guard.
        local pad=call(R.input and R.input.gamepad)
        local a=call(R.skater and R.skater.get)
        local telemetry=call(R.skater and R.skater.telemetry)
        local p,w=pad[2],telemetry[2]
        local watch=plain(w) and w.watch or nil
        if not pad[1] or pad.n~=2 or not plain(p) or not plain(p.buttons)
            or not a[1] or a.n~=2 or not plain(a[2]) or type(a[2].airborne)~="boolean"
            or not telemetry[1] or telemetry.n~=2 or not plain(w) or w.skater~=true
            or type(w.airborne)~="boolean" or type(w.teleport_pending)~="boolean"
            or not plain(watch) or watch.valid~=true or not finite(watch.state)
            or watch.state<0 or watch.state%1~=0 or watch.state>4294967295
            or watch.ragdoll_known~=true or type(watch.ragdoll)~="boolean" then
            fail("Fresh released controls and grounded stock readiness unavailable.");return false
        end
        local released=true
        for _,name in {"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"} do
            if type(p.buttons[name])~="boolean" then fail("Pad release observation is malformed.");return false end
            released=released and not p.buttons[name]
        end
        for _,name in {"left_x","left_y","right_x","right_y"} do
            if not finite(p[name]) or math.abs(p[name])>32768/32767 then fail("Pad stick observation is malformed.");return false end
        end
        for _,name in {"left_trigger","right_trigger"} do
            if not finite(p[name]) or p[name]<0 or p[name]>1 then fail("Pad trigger observation is malformed.");return false end
        end
        -- Match the SDK's circular XInput rest thresholds, including noise.
        released=released and p.left_x^2+p.left_y^2<=(7849/32767)^2
            and p.right_x^2+p.right_y^2<=(8689/32767)^2
            and p.left_trigger<=30/255 and p.right_trigger<=30/255
        if expected==504 and (watch.state~=504 or watch.ragdoll) then
            fail("Terrain retry lost its acknowledged on-foot504 baseline.");return false
        elseif expected==100 and (watch.state==504 or watch.state==300 or watch.ragdoll) then
            local sample="state "..tostring(watch.state).." ragdoll "..tostring(watch.ragdoll)
            if second_recovering then
                -- The remount after a crash waits for a rider the game has not put on the board yet: in the user's
                -- crash of 2026-11-02 the board read once, then the rider read off it 1.1 s later. This waits, with
                -- the quiet window started again, inside the step-off's existing 60 s admission deadline.
                -- A rider standing on foot does not go back to the board by themselves: the HUD asks for Y (help_line).
                if not second_off_board then trace("Recover step-off waits for the board: "..sample..".") end
                local standing=watch.state==504 and watch.ragdoll==false
                if standing and not (second_off_board and second_off_standing) then second_off_since=now end
                second_off_board,second_off_standing=true,standing
                reset_second_quiet();return false
            end
            trace("Step-off sample off the board: "..sample..".")
            fail("Attempt two lost its stock100 baseline before admission.");return false
        end
        if expected==100 then second_off_board=false end
        if not released or watch.state~=expected or a[2].airborne or w.airborne or w.teleport_pending then
            reset_second_quiet();return false
        end
        if not second_quiet_last or now<=second_quiet_last or now-second_quiet_last>250 then
            second_quiet_at,second_quiet_samples=now,1
        else second_quiet_samples+=1 end
        second_quiet_last=now
        return now-second_quiet_at>=600 and second_quiet_samples>=10
    end
    local function second_terrain_step(now)
        local version=generation
        if not second_admitted_at or now<second_admitted_at or now-second_admitted_at>=60000 then
            fail("Second Mount admission deadline expired; no terrain retry.");return
        end
        if now-prep_at>=30000 then fail("Preparation timed out; no mount was requested.");return end
        if not environment(false) then reset_second_quiet();return end
        if generation~=version or cancelled or unloaded then return end
        local quiet=second_quiet(now,504)
        if generation~=version or cancelled or unloaded then return end
        if not quiet then
            if phase~="blocked" then detail="Release controls and settle on acknowledged504 before the new full terrain survey." end
            return
        end
        local clear=preflight_clear()
        if generation~=version or cancelled or unloaded then return end
        if not clear then fail("Second preflight owner or acknowledged504 proof lost; no retry.");return end
        local checked=clock()
        if not checked or generation~=version or cancelled or unloaded then return end
        if checked<second_admitted_at or checked-second_admitted_at>=60000 then
            fail("Second Mount admission deadline expired; no terrain retry.");return
        end
        second_terrain_pending=false -- no Y, archive or admission callback here
        prep_step(checked)
    end
    -- A remount after a crash whose step-off ran out of time with the rider off the board says plainly what to do.
    local function second_expired(why)
        local stranded=phase=="stepping_off" and second_recovering and second_off_board
        fail(why)
        if stranded then blocked_help="off_board";announce(words.off_board) end
    end
    local function step_off(now)
        local version=generation
        if second_prepare_pending then
            if not second_admitted_at or now<second_admitted_at or now-second_admitted_at>=60000 then
                second_expired("Second Mount admission deadline expired; no step-off request.");return
            end
            -- A menu or a control touched after the quiet passed starts a new quiet, and the step-off no longer waits
            -- for the hold but for that: hold_waiting ends, so hold_state() names 100 again and y_button.lua keeps Y
            -- from the game for it. Left set, Y stayed the game's through the new 600 ms, and a Y there stepped the
            -- rider off and ended the attempt (the second review of 1827ac54).
            if not environment(false) then reset_second_quiet();hold_waiting=false;return end
            if generation~=version or cancelled or unloaded then return end
            if not known or not clean(latest) then fail("Previous Return is no longer fully clean.");return end
            local quiet=second_quiet(now)
            if generation~=version or cancelled or unloaded then return end
            if not quiet then
                hold_waiting=false
                if phase~="blocked" then detail="Release controls and settle on stock100 before the single guarded step-off." end
                return
            end
            -- The step-off's own Y would be refused under a hidden button. The controls have just read released, so
            -- the hold can end at once; the quiet above still holds on the next tick, and the 60 s still runs.
            if held_input() then hold_waiting=true;return end
            hold_waiting=false
            -- Intent was spent at the Mount action. Release of that same chord
            -- must precede admission; preserve its original60s equipment arm.
            second_prepare_pending=false
            local prepared=call(owner.prepare_next_mount,owner,slot,second_admitted_at)
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
    -- What the player can do about cleanup that has not finished, or that nothing they do will help.
    local function waiting_text()
        local e=known and plain(latest) and latest.equipment
        local s=known and plain(latest) and latest.source
        if plain(e) and e.retained==true and e.phase~="done" then return words.let_go end
        if plain(s) and s.phase~="complete" and s.phase~="idle" then return words.close_menus end
        return "The bike is stuck: restart the game to ride again."
    end
    -- What decides a Mount outside a terrain retry before anything is asked of the rider: whether a ride that ended
    -- can be reopened, whether a mount is left, whether the mod is free, and which state the ride starts from. It
    -- changes nothing, so next_start_state() can ask it every tick, and mount() acts on its answers: nil and the
    -- start state, or a refusal, "waiting" (cleanup has not finished), "stuck" (no clean successor), "spent" (no
    -- mount left) or "busy". The third answer says the phase is one a Mount reopens.
    local function mount_gate()
        local reopen=(phase=="blocked" or phase=="spent" or phase=="fallen") and attempts_used>=1 and two_cycle
        if reopen then
            if not known or not clean(latest) then return "waiting" end
            local ready=call(owner.can_prepare_next_mount,owner)
            if not ready[1] or ready[2]~=true then return "stuck" end
        end
        if not mount_left() then return "spent",nil,reopen end
        if unloaded or ticking or cancelled or not namespace_clear
            or used and (not two_cycle or not reopen and phase~="skateboard") then return "busy",nil,reopen end
        -- The first ride of a launch starts on foot. Every later one starts on the skateboard: its step-off is the
        -- mod's own Y, whose target and ACK prove the rider went from 100 to 504.
        return nil,attempts_used>=1 and 100 or 504,reopen
    end
    -- Whether a terrain retry can be asked for at all; mount() and next_start_state() share it.
    local function retry_open() return not (unloaded or ticking or cancelled or not namespace_clear) end
    function object:mount()
        if not admitted then return false,"Experimental source admission is closed." end
        -- Riding the board to a better spot ends that step-off: this Mount starts again from the board.
        if phase=="preflight_refused" and attempts_used>=2 and state()==100 then fail("Moved on the board after the step-off.") end
        if phase=="preflight_refused" then
            if not retry_open() then return false,"Preflight retry unavailable." end
            local version=generation
            -- In a later cycle this press is a new Mount intent with its own 60 s: finding a flat spot can take a
            -- rider longer than the press that began the cycle allowed. The proof below then reads the new time.
            if attempts_used>=2 and two_cycle then
                local pressed=clock()
                if not pressed or generation~=version or cancelled or unloaded then return false,detail end
                pressed=math.floor(pressed)
                local renewed=call(owner.renew_second_admission,owner,second_admitted_at,pressed)
                if generation~=version or cancelled or unloaded then return false,detail end
                if not renewed[1] or renewed[2]~=true then
                    fail(text(renewed[3],"Terrain retry could not renew its Mount time."));return false,detail
                end
                second_admitted_at=pressed
            end
            local clear=preflight_clear()
            if generation~=version or cancelled or unloaded then return false,detail end
            if not clear then fail("Preflight owner or storage proof lost; no retry.");return false,detail end
            local current=state()
            if generation~=version or cancelled or unloaded then return false,detail end
            if current~=504 then
                -- Riding the board to a better spot is what a refusal asks for. On the first ride nothing has been
                -- asked of the game yet (the proof above), so this says to step off first and the retry stays open.
                if attempts_used==1 then refused_help="step_off";return tell(words.step_off) end
                fail("Preflight retry requires on-foot504; no retry.");return false,detail
            end
            local now=clock()
            if not now or generation~=version or cancelled or unloaded then return false,detail end
            if attempts_used>=2 and (not second_admitted_at or now<second_admitted_at or now-second_admitted_at>=60000) then
                fail("Second Mount admission deadline expired; no terrain retry.");return false,detail
            end
            -- Keep the reserved attempt; the deadline is this press's (above).
            -- Only a NEW survey/preparation is allowed; no old-owner Y repeats.
            generation+=1;prep_at=now;prep_last=nil;prep_calls=0;survey=nil;hold_waiting=false
            second_terrain_pending=attempts_used>=2
            if second_terrain_pending then reset_second_quiet() end
            phase,detail="preparing","Retrying terrain preflight; stay on foot and still. Prior refusals remain recorded."
            return true
        end
        -- A Return that could not finish leaves a cleaned-up ride: Mount from the board may go again.
        local refused,start,reopen=mount_gate()
        if refused=="waiting" then return tell(waiting_text()) end
        if refused=="stuck" then return tell(no_body() or "The bike is stuck: restart the game to ride again.") end
        local reopened=reopen and phase or nil
        if reopen then phase="skateboard" end
        if refused=="spent" then return tell("All "..attempt_limit.." mounts are used: restart the game to ride again.") end
        if refused then return false,"Consumed, busy or retained attempt; not available." end
        if state()~=start then
            if start==504 then return tell(words.step_off) end
            -- A Mount from a blocked or spent ride that cannot start yet leaves it as it was, so its help line stays
            -- up rather than an empty one for 'skateboard'. A fall keeps 'skateboard': Recover and auto-return read it.
            if reopened=="blocked" or reopened=="spent" then phase=reopened end
            return tell(words.board)
        end
        attempts_used+=1;used=true;generation+=1;stop_told=nil;mount_refunded=false;hold_waiting=false
        -- A fall belongs to the ride that fell. Kept into this one, a stop before it rides, such as a refused capture or
        -- lease, read as a second fall and the mod got back on by itself after every refusal (the capture-retry review,
        -- 2026-11-05).
        fallen=nil
        terrain_refusals={}
        mount_charged=attempts_used>=2
        local version=generation
        if attempts_used>=2 then
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
            local now=clock()
            if not now or generation~=version or cancelled or unloaded then return false,detail end
            second_admitted_at=math.floor(now);reset_second_quiet()
            second_recovering,second_off_board,second_off_standing,second_off_since=auto_mount,false,false,nil
            second_prepare_pending=true
            return true
        end
        phase,detail="preparing","Preparing, then surveying the clear area. Stay on foot and still."
        prep_at=clock()
        if not prep_at or cancelled or unloaded or phase~="preparing" then return false,detail end
        return true
    end
    -- The state a Mount pressed now starts from: 504 on foot for the first ride of a launch and for a terrain retry,
    -- 100 on the skateboard for every later ride. nil when mount() would refuse for a reason other than where the
    -- rider is. It is mount()'s own rule (mount_gate, retry_open) and changes nothing, so y_button.lua asks it every
    -- tick; the proofs mount() runs once the rider is in that state stay mount()'s. A later cycle's terrain retry
    -- answers 504 though mount() also takes the board there, ending that step-off for a new one: 504 keeps it.
    function object:next_start_state()
        if not admitted then return nil end
        if phase=="preflight_refused" then return retry_open() and 504 or nil end
        local refused,start=mount_gate()
        if refused then return nil end
        return start
    end
    -- Which controls the rider's lines name: "lb_a", the default, or "y" for main.lua's bike mode.
    function object:set_controls(kind)
        if type(kind)~="string" or not WORDS[kind] then return false end
        words=WORDS[kind]
        return true
    end
    -- fn() answers true while the mod keeps a game button from the game (y_button.lua); nil takes the hold away.
    -- Nothing is handed the game's input while it answers true, and status().hold_state says where a hold costs nothing.
    function object:set_input_hold(fn)
        if fn~=nil and type(fn)~="function" then return false end
        input_hold=fn
        return true
    end
    function object:return_to_skateboard()
        if unloaded or ticking or cancelled or not mount_issued or return_pending or stock_attempted then
            return false,"Return is unavailable; Cancel may stop an unfinished preparation."
        end
        return_pending=true;return_plan=nil;return_position=nil;stock_retries=0;stock_retry_at=nil;return_used,return_seen,return_open=0,nil,false
        return_total,return_down=0,false
        generation+=1;phase,detail="returning","Stopping the bike before returning to the skateboard."
        if type(owner.request_return)=="function" then
            stopped=true -- one capture/stop callback, even if it refuses or raises
            local version=generation
            local out=call(owner.request_return,owner)
            if generation~=version or cancelled or unloaded then return false,"Return cancelled" end
            if not out[1] or out[2]~=true or out.n~=2 and out.n~=3 then
                -- Core stops the bike even when it cannot measure where to put the rider, and its status then carries
                -- why (return_capture_issue) beside the stop. That Return goes on as one that measured no position,
                -- the same as Return after a fall, which Core also answers with no position: the switch still waits
                -- for Core's finished cleanup and passes Core's own checks.
                if out[1] and out[2]==false then
                    local s=call(owner.status,owner)
                    if generation~=version or cancelled or unloaded then return false,"Return cancelled" end
                    if s[1] and s.n==2 and plain(s[2]) and s[2].stop_latched==true and type(s[2].return_capture_issue)=="string"
                        and s[2].unloaded==false and s[2].session_retired~=true then
                        trace("Return goes on without a placement: "..text(out[3],"capture refused"))
                        return true
                    end
                end
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
    local function recovery_stock_wait(version)
        -- Only a positively known fallen300 may wait; this grants no stock
        -- input authority and never changes the ordinary Return state contract.
        -- A rider the game is still standing up, which after a knock-down can read any state for a while, is left to
        -- that ordinary Return rather than stopped here: it waits for a state it can act on, Core refuses its switch
        -- until the rider is upright and on the ground, and that wait does not run out its time limit.
        local out=call(R.skater and R.skater.telemetry)
        if generation~=version or cancelled or unloaded then return false end
        local w=out[2];local watch=plain(w) and w.watch or nil
        if not out[1] or out.n~=2 or not plain(w) or not plain(watch) or watch.valid~=true
            or not finite(watch.state) or watch.state%1~=0
            or watch.state~=300 and watch.state~=100 and watch.state~=504 then
            return false
        end
        if not recover_wait_context and watch.state~=300 then return false end
        local initial=known and latest.initial_readiness
        if not out[1] or out.n~=2 or not plain(w) or w.skater~=true or w.teleport_pending~=false
            or type(w.airborne)~="boolean" or not plain(watch) or watch.valid~=true
            or watch.ragdoll_known~=true or type(watch.ragdoll)~="boolean"
            or not plain(initial) or type(initial.level)~="string" or #initial.level==0 or #initial.level>200
            or not finite(initial.wipeouts) or initial.wipeouts<0 or initial.wipeouts%1~=0
            or not finite(latest.stop_ms) or latest.stop_ms<0
            or latest.stop_latched~=true or latest.stock_requested~=false then
            fail("Fall recovery needs known same-owner stock context and original stop time.");return false
        end
        if not recover_wait_context then
            recover_wait_context={stop_ms=latest.stop_ms,level=initial.level,wipeouts=initial.wipeouts}
        end
        local c=recover_wait_context
        local level=call(R.level and R.level.current)
        if generation~=version or cancelled or unloaded then return false end
        local now=clock()
        if generation~=version or cancelled or unloaded then return false end
        if not now or now<c.stop_ms then
            fail("Original fall cleanup deadline expired before stock recovery.");return false
        end
        if latest.stop_ms~=c.stop_ms or initial.level~=c.level
            or not level[1] or level.n~=2 or not plain(level[2]) or level[2].name~=c.level then
            fail("Fall recovery stock context changed; no switch was sent.");return false
        end
        -- Past the original cleanup window a rider still down is the ordinary Return's to wait for, as above.
        if now>=c.stop_ms+20000 then return false end
        if watch.state==300 then
            detail="Fall recovery: waiting for known stock300 to settle within the original cleanup window."
            return_down=true;return true
        end
        -- Still ragdolled or in the air on the board or on foot: Core refuses the switch until the rider stands.
        return false -- Existing Return, stock target/ACK and successor checks decide.
    end
    local function recoverable()
        return admitted and two_cycle and attempts_used>=1 and mount_left() and mount_issued and fallen~=nil
            and not recover_pending and not return_pending and not unloaded and not ticking and not cancelled
            and namespace_clear and known and latest.cleanup_unknown==false
            and (phase=="fallen" or phase=="skateboard")
    end
    function object:recover()
        if not recoverable() then return false,"Recovery needs a known fall, a cleanable attempt and a mount left." end
        recover_pending=true -- One explicit intent before any Return callback can reenter.
        recover_wait_context=nil
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
        cancelled=true;return_pending=false;second_prepare_pending=false;second_terrain_pending=false;recover_pending=false;generation+=1
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
            -- The first body made settles it for the launch: an origin lifts the cap, a body without one keeps it.
            local b=known and two_cycle and body_reuse==nil and plain(latest.spawn) and latest.spawn or nil
            if b and type(b.origin)=="string" then body_reuse=true;attempt_limit=nil
            elseif b and (b.body==true or b.follow_handed_off==true) then body_reuse=false end
            if not cancelled and phase~="blocked" then
            if return_pending then
                if recover_pending and not stock_attempted and known and clean(latest) then
                    local version=generation
                    local waiting=recovery_stock_wait(version)
                    if generation~=version or cancelled or unloaded or phase=="blocked" then return end
                    if waiting then return end
                end
                return_step()
            elseif phase=="stepping_off" or phase=="preparing" or phase=="surveying" or phase=="awaiting_mount" then
                local now=clock()
                if now then
                    if attempts_used>=2 and (not second_admitted_at or now<second_admitted_at or now-second_admitted_at>=60000) then
                        second_expired("Second Mount admission deadline expired; no new survey or mount.");return
                    end
                    if phase=="stepping_off" then step_off(now)
                    elseif phase=="preparing" then
                        if second_terrain_pending then second_terrain_step(now) else prep_step(now) end
                    elseif phase=="surveying" then
                        local version=generation
                        if environment(true) and generation==version and not cancelled and not unloaded and phase=="surveying" then survey_step(now) end
                    elseif phase=="awaiting_mount" then mount_step(now) end
                end
            elseif mount_issued and known and phase~="skateboard" and phase~="spent" then
                if latest.phase=="following" and latest.stop_latched~=true then
                    fallen=nil;phase,detail="riding","One-session bike active. Return or Cancel remains available."
                elseif latest.stop_latched==true or latest.phase=="done" then
                    -- A refused create is not a fall, even on the remount after one: the board comes back, and a
                    -- retry refusal waits for the rider's Mount rather than asking again by itself.
                    fallen=fall_cause(latest) or not refusal() and fallen or nil
                    if two_cycle and refusal()=="retry" and not mount_refunded then mount_refunded=true;unspent+=1 end
                    local refused=not fallen and (no_body() or refusal()=="retry" and NOT_READY) or nil
                    local why=fallen or refused or text(latest.stop_reason,"Ride stopped")
                    if why~=stop_told then
                        stop_told,last_stop=why,why
                        -- A fall or knock-down says the rider came off and what comes next; a refusal already says
                        -- what to do. Core's reason goes to the log, the menu page and the dedupe above.
                        local told=refused or fallen and "The rider came off. "..(not auto_return and words.ride_again
                            or mount_left() and "Getting back on the bike." or "Going back to the skateboard.")
                            or auto_return and RIDE_RETURNING or words.ride_stopped
                        announce(told,not refused and "Ride ended: "..why or nil)
                    end
                    if fallen then phase,detail="fallen","Bike stopped after a fall: "..fallen
                        ..(mount_left() and ". Recover can return and mount again."
                            or ". No mounts are left; Return remains available.")
                    else phase,detail="stopped",refused or text(latest.stop_reason,"Ride stopped; cleanup continues. Return remains available.") end
                end
            end
            end
        end
        local advanced=pcall(advance)
        ticking=false
        -- One line for each change of what Entry and Core say, and none for the ticks of a ride.
        if known and not (phase=="riding" and logged_phase=="riding") then
            local line="entry="..phase.." attempts="..attempts_used.." "..lifecycle_line(latest)
            if line~=logged_line then logged_line=line;trace(line.." pad="..(pad_released() and "rest" or "held")) end
        end
        logged_phase=phase
        -- A crash can leave the rider lying after the mod has stopped waiting for them: in loop5 (2026-11-04) the
        -- board rolled away on a grade, the Return blocked, and the rider lay on the road under 'Get on your
        -- skateboard' for four minutes. A down rider reads state 504 with ragdoll set (chain2); only the ragdoll is
        -- used, so a rider in the air or mid grind is not told to get up.
        if DOWN_WAITS[phase] and not cancelled and not unloaded then
            local now=clock()
            if now and (not down_read_at or now<down_read_at or now-down_read_at>=250) then
                down_read_at=now
                local out=call(R.skater and R.skater.telemetry)
                rider_down=out[1] and out.n==2 and plain(out[2]) and plain(out[2].watch) and out[2].watch.ragdoll==true
            end
        else rider_down,down_read_at=false,nil end
        if not advanced then known=false;fail("Entry step failed; cleanup remains required.")
        -- A ride that ended on its own hands the player back straight away: a fall gets back on the bike, anything
        -- else returns to the skateboard, ready to mount again. A fall with no mount left to spend, which happens only
        -- with an SDK that cannot reuse a parked body, is anything else.
        elseif auto_return and phase=="fallen" and recoverable() then call(self.recover,self)
        elseif auto_return and (phase=="stopped" or phase=="fallen" and not mount_left())
            and not return_pending and not recover_pending and not cancelled and not unloaded then
            call(self.return_to_skateboard,self)
        elseif recover_pending and not cancelled and not unloaded and phase=="skateboard" then
            recover_pending=false -- Consume before fresh Mount callbacks; no automatic retry.
            auto_mount=true
            local out=call(self.mount,self)
            auto_mount=false
            if not out[1] or out[2]~=true then fail(text(out[3],"Recovery Mount refused; the intent is spent.")) end
        end
    end
    -- Core already detached this small score view in the last normal step.
    -- HUD reads never poll the lifecycle or turn presentation into evidence.
    -- What the player should be doing while the mod is busy, in plain words for the HUD. The lines for a ride that
    -- ended or a Mount that did not start name the controls, so they are in words.help.
    local HELP={preparing="Getting the bike ready: stand still.",surveying="Checking for room: stand still.",
        awaiting_mount="Close menus and let go of the controls.",mounting="Getting on the bike: let go of the controls.",
        stepping_off="Stepping off the board: stand still and let go of the controls.",
        returning="Going back to the skateboard: let go of the controls."}
    function object:help_line()
        if notice then
            local now=clock()
            if now and now<notice_until then return notice end
            notice=nil
        end
        -- Letting go of the controls cannot help a rider the game has not stood up yet. The game leaves a crashed rider
        -- lying until a button is pressed: in crash1 (2026-11-04) the rider was still down after four minutes with the
        -- controller at rest, and in getup1 one A tap stood them up and the Return went on. So the line says to press A.
        if phase=="returning" and return_down then return "Press A to get up." end
        -- A remount after a crash whose step-off reads the rider off the board waits for them (second_quiet). One the
        -- game still has down is waited for. One standing on foot gets back on the board only with a Y, which is said
        -- once the standing reads have lasted 1 s, so that a single odd read does not ask a rider on the board for Y.
        if phase=="stepping_off" and second_recovering and second_off_board then
            if not second_off_standing then return "Press A to get up." end
            local now=clock()
            if now and second_off_since and now-second_off_since>=1000 then
                return "Press Y for your skateboard, then let go of the controls."
            end
            -- Bike mode's step-off line says not to press Y, which holds only for a rider on the board: this one is
            -- asked for Y in a moment. Until then the line says only what is under way.
            if words.help.remount_on_foot then return words.help.remount_on_foot end
        end
        -- Whatever this phase asks for next, a rider still lying down has to get up first.
        if rider_down and DOWN_WAITS[phase] then return "Press A to get up." end
        -- A first ride that ended before Core was made leaves nothing a Mount can reopen: mount() never finds a
        -- finished cleanup on the facade's own status (bike_runtime.lua status, bike_admission.lua snapshot), so it
        -- answers that the bike is stuck. The HUD says the same rather than asking for a Mount that cannot start.
        -- Core's own status reports core_ready, so later rides keep their lines.
        if phase=="blocked" and attempts_used>=1 and known and plain(latest) and plain(latest.startup)
            and latest.startup.core_ready==false and latest.startup.pending==false then
            return "The bike is stuck: restart the game to ride again."
        end
        if phase=="blocked" and blocked_help then return words[blocked_help] end
        if phase=="preflight_refused" and refused_help then return words[refused_help] end
        return words.help[phase] or HELP[phase]
    end
    function object:score_view()
        local ride=known and plain(latest) and latest.ride or nil
        if not plain(ride) then return nil,"ride_unavailable","unavailable" end
        return ride.mod_score,ride.mod_score_issue,ride.mod_landing_phase
    end
    function object:status()
        local history=table.clone(terrain_refusals);table.freeze(history)
        return table.freeze({phase=phase,detail=detail,admitted=admitted,slot=slot,mount_intent_used=used,
            terrain_refusal_count=#history,terrain_refusal_limit=MAX_TERRAIN_REFUSALS,terrain_refusals=history,
            preflight_retry_available=phase=="preflight_refused" and not cancelled and not unloaded,
            mount_requested=mount_issued,return_requested=return_pending,stock_attempted=stock_attempted,cancelled=cancelled,
            fall_reason=fallen,last_stop=last_stop,recovery_pending=recover_pending,recovery_available=recoverable(),
            prepare_calls=prep_calls,survey_state=survey and survey.state or "not_started",
            core_phase=known and latest.phase or "unknown",return_position=return_position and table.freeze(table.clone(return_position)) or nil,
            lifecycle_detail=known and (plain(latest.spawn) and text(latest.spawn.detail,nil) or text(latest.detail,nil)
                or text(latest.stop_reason,"Lifecycle status observed.")) or "Lifecycle status is unknown; no stock switch is allowed.",
            bike_authority=not known or latest.bike_authority~=false,
            attempts_used=attempts_used,attempt_limit=attempt_limit,body_reuse=body_reuse,
            new_allocation_each_cycle=two_cycle and body_reuse~=true,
            cleanup_pending=not known or latest.cleanup_pending~=false,cleanup_unknown=not known or latest.cleanup_unknown~=false,
            stock_toggle_blocked=not known or latest.stock_toggle_blocked~=false,session_reusable=false,
            hold_state=hold_state(),hold_waiting=hold_waiting})
    end
    function object:unload()
        if unloaded then return end
        if return_position and return_position.queued and not return_position.observed then
            return_position.unknown=true;return_position.phase="interrupted"
        end
        unloaded=true;cancelled=true;return_pending=false;second_prepare_pending=false;second_terrain_pending=false;recover_pending=false;generation+=1
        local out=call(owner.unload,owner)
        if out[1] and out.n==2 and plain(out[2]) then latest=out[2];known=true else known=false end
        phase,detail="unloaded","Unloaded; native cleanup remains with the lifecycle and SDK."
    end
    return table.freeze(object)
end
return table.freeze(Entry)
