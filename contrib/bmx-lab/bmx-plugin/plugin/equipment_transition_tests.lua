-- Deterministic model tests only. Requiring this module performs no tests or API calls.
local Transition=require("./equipment_transition")
local tests={}
function tests.run()
    local assertions,cases=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function copy(value)
        if type(value)~="table" then return value end
        local out={};for k,v in value do out[k]=copy(v) end;return out
    end
    local sequence="9007199254740994"
    local function frame(t,changes)
        local f={now_ms=t,context="world-a",slot=0,gesture_down=false,loaded=true,allowed=true,
            observation={focused=true,menu_closed=true,gameplay=true,local_player=true,teleport_pending=false,
                grounded=true,ragdoll_known=true,ragdoll=false,state=100,fallen=false}}
        for k,v in changes or {} do
            if k=="observation" then for field,value in v do f.observation[field]=value end else f[k]=v end
        end
        return f
    end
    local function receipt(status,changes)
        local r={sequence=sequence,status=status or "warming",reason="none",user=0,button=0x8000,
            requested_ms="9007199254740997",expires_ms="9007199254741997",observed_ms="9007199254741250",source_epoch="9007199254740995",
            transport="xinput",source_identity="observed_stream",publication_scope="process_outer_xinput_buffer",
            consumption="unobserved",semantic_completion="unobserved",first_rejection_mask=0,first_rejection_stage="none",
            press_candidates="0",press_publications="0",neutral_publications="0",original_failures="0",contentions="0",
            terminal=false,report_debt=false,claim_released=false,actor_retired=false,orphaned=false,quarantined=false,
            original_result_known=false}
        if status=="released" or status=="revoked" or status=="cancelled" or status=="expired" then
            r.terminal,r.claim_released=true,true
            r.press_candidates,r.press_publications,r.neutral_publications="7","7","1"
        end
        if status=="revoked" then r.reason,r.first_rejection_mask,r.first_rejection_stage="unavailable",1280,"core_plan" end
        if status=="cancelled" then r.reason="cancelled" end
        if status=="expired" then r.reason="deadline" end
        for k,v in changes or {} do r[k]=v end
        return r
    end
    local function actor_diagnostics(known,changes)
        local d={first_actor_observation_known=known,first_actor_owner_present=known,first_actor_call_active=false,
            first_actor_inspect_attempted=false,first_actor_inspect_succeeded=false,first_actor_equal=false,
            first_actor_clock_attempted=false,first_actor_clock_known=false,
            first_actor_enter_phase=known and "enter_claim" or "not_attempted",
            first_actor_enter_reason=known and "busy" or "none",
            first_actor_inspect_phase="not_attempted",first_actor_inspect_reason="none"}
        for k,v in changes or {} do d[k]=v end
        return d
    end
    local function start(initial)
        local p=Transition.new();initial=initial or 100
        check(not p:update(frame(0,{observation={state=initial}})).intents.request,"neutral only arms")
        local o=p:update(frame(1,{gesture_down=true,observation={state=initial}}))
        check(o.phase=="baseline" and not o.intents.request,"one gesture starts independent readiness qualification")
        for t=101,501,100 do
            o=p:update(frame(t,{gesture_down=true,observation={state=initial}}))
            check(not o.intents.request,"baseline cannot request before600ms")
        end
        o=p:update(frame(601,{gesture_down=true,observation={state=initial}}))
        check(o.intents.request and o.intents.request.attempt==1 and o.intents.request.user==0 and o.intents.request.button=="y",
            "qualified baseline emits one Y request")
        check(o.initial_state==initial and o.expected_state==(initial==100 and 504 or 100),"target freezes from initial stock state")
        return p
    end
    local function accepted(initial)
        local p=start(initial)
        local o=p:update(frame(602,{request_result={attempt=1,accepted=true,handle="pulse-a"},observation={state=initial or 100}}))
        check(o.intents.read and o.intents.read.read_id==1 and o.retained,"accepted opaque handle produces correlated read")
        return p,o.intents.read.read_id
    end
    local function read(p,t,r,read_id,changes)
        local f=frame(t,{receipt_result={attempt=1,handle="pulse-a",read_id=read_id or 1,receipt=r}})
        for k,v in changes or {} do
            if k=="observation" then for field,value in v do f.observation[field]=value end else f[k]=v end
        end
        return p:update(f)
    end
    local function saved_and_acked(p,status,initial)
        local o=read(p,603,receipt(status or "released"),1,{observation={state=initial or 100}})
        check(o.intents.store and o.intents.store.receipt.sequence==sequence and not o.intents.acknowledge,
            "complete terminal receipt is returned for storage before acknowledgement")
        check(not o.intents.read,"clean terminal does not launch a redundant in-flight read")
        o=p:update(frame(604,{store_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true},observation={state=initial or 100}}))
        check(o.intents.acknowledge and not o.intents.store,"confirmed storage emits exactly one acknowledgement")
        o=p:update(frame(605,{ack_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true},observation={state=initial or 100}}))
        check(o.phase=="settling" and o.acknowledged and not o.retained,"accepted acknowledgement starts separate wall-time observation")
        return o
    end
    local function settle(p,state)
        local o
        for t=805,3205,200 do
            o=p:update(frame(t,{observation={state=state}}))
            check(not o.qualified_transition,"suffix cannot complete before2.5s")
        end
        o=p:update(frame(3405,{observation={state=state}}))
        check(o.qualified_transition and o.outcome=="target_observed" and o.suffix.qualified_samples>=10 and o.suffix.seconds>=2.5,
            "a gap-bounded2.5s expected-state suffix qualifies the sampled transition")
        return o
    end

    do
        local p=Transition.new()
        for t=0,19 do check(not p:update(frame(t,{gesture_down=true})).intents.request,"startup held gesture never dispatches") end
        p:update(frame(20));local o=p:update(frame(20,{gesture_down=true}))
        check(o.phase=="idle","equal-clock press cannot start")
        check(p:update(frame(21,{gesture_down=true})).phase=="idle","equal-clock press is consumed rather than deferred")
        p:update(frame(22));check(p:update(frame(23,{gesture_down=true})).phase=="baseline","fresh neutral and press works")
        cases+=1
    end
    do
        local p=accepted();saved_and_acked(p,"revoked");local o=settle(p,504)
        check(o.terminal_receipt.status=="revoked" and o.terminal_receipt.reason=="unavailable"
            and o.terminal_receipt.first_rejection_mask==1280,"settled target never rewrites SDK rejection evidence")
        check(o.terminal_receipt.consumption=="unobserved" and o.terminal_receipt.semantic_completion=="unobserved",
            "sampled completion does not invent native semantic consumption")
        cases+=1
    end
    do
        for _,known in {false,true} do
            local p=accepted();local d=actor_diagnostics(known);local r=receipt("revoked",d)
            local o=read(p,603,r)
            check(o.intents.store and not o.intents.acknowledge,"complete actor diagnostics preserve store-before-ack")
            for k,v in d do
                check(o.receipt[k]==v and o.terminal_receipt[k]==v and o.intents.store.receipt[k]==v,
                    "complete actor fields, including unattempted inspect/clock, survive every retained snapshot: "..k)
            end
            r.first_actor_enter_reason="corrupt"
            o.receipt.first_actor_enter_phase="corrupt";o.intents.store.receipt.first_actor_clock_known=true
            o=p:update(frame(604,{store_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
            check(o.intents.acknowledge and o.receipt.first_actor_enter_phase==d.first_actor_enter_phase
                and o.terminal_receipt.first_actor_enter_reason==d.first_actor_enter_reason
                and not o.terminal_receipt.first_actor_clock_known,"caller mutation cannot alter the retained diagnostic witness")
            p:update(frame(605,{ack_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
            o=settle(p,504)
            check(o.terminal_receipt.status=="revoked" and o.terminal_receipt.first_rejection_mask==1280
                and o.terminal_receipt.first_actor_observation_known==known and o.qualified_transition,
                "known or unobserved diagnostics do not change existing sampled transition qualification")
        end
        cases+=1
    end
    do
        local p=accepted();local d=actor_diagnostics(false)
        local o=read(p,603,receipt("warming",d))
        check(o.receipt and not o.receipt.first_actor_observation_known,"complete not-yet-observed group is valid")
        p:update(frame(803));d=actor_diagnostics(true)
        o=read(p,804,receipt("revoked",d),2)
        check(o.intents.store and o.receipt.first_actor_observation_known and not o.receipt.first_actor_inspect_attempted
            and not o.receipt.first_actor_clock_attempted,"first known entry refusal retains truthful short-circuited observation flags")
        check(o.reason=="none" and o.terminal_receipt.first_actor_enter_reason=="busy",
            "diagnostic native reason does not replace the semantic model reason")
        cases+=1
    end
    do
        local d=actor_diagnostics(true)
        for field,value in d do
            local p=accepted();read(p,603,receipt("warming",d));p:update(frame(803))
            local changed=copy(d)
            if type(value)=="boolean" then changed[field]=not value
            elseif field:match("_phase$") then changed[field]="qualified"
            else changed[field]="actor_changed" end
            local o=read(p,804,receipt("revoked",changed),2)
            check(o.outcome=="unresolved" and o.retained and o.intents.cancel and not o.intents.store
                and not o.intents.acknowledge,"each first-known actor field is immutable across reads: "..field)
            for k,v in d do check(o.receipt[k]==v,"invalid replacement retains the first complete diagnostic witness: "..k) end
            check(not p:update(frame(805)).intents.cancel,"changed diagnostics do not repeat cancellation")
        end
        local p=accepted();read(p,603,receipt("warming",d));p:update(frame(803))
        local o=read(p,804,receipt("revoked"),2)
        check(o.outcome=="unresolved" and not o.intents.store and o.receipt.first_actor_observation_known,
            "legacy omission cannot erase an already-known actor witness")
        cases+=1
    end
    do
        local d=actor_diagnostics(true)
        local malformed={}
        for field,value in d do
            local partial=copy(d);partial[field]=nil;table.insert(malformed,partial)
            local wrong=copy(d);wrong[field]=type(value)=="boolean" and 0 or false;table.insert(malformed,wrong)
            if type(value)=="string" then
                for _,bad in {"invalid","future_phase","none\0suffix","",math.huge,0/0,{}} do
                    wrong=copy(d);wrong[field]=bad;table.insert(malformed,wrong)
                end
            end
        end
        for _,bad in malformed do
            local p=accepted();local o=read(p,603,receipt("released",bad))
            check(o.reason=="receipt_invalid" and o.outcome=="unresolved" and o.retained and o.intents.cancel
                and not o.intents.store and not o.intents.acknowledge,"partial, bad-type or unknown-enum diagnostics cannot authorize acknowledgement")
            check(o.receipt==nil and not p:update(frame(604)).intents.cancel,"malformed first witness is neither retained as valid nor retried")
        end
        local p=accepted();local o=read(p,603,receipt("released"))
        check(o.intents.store and o.receipt.first_actor_observation_known==nil,"all12 omitted remains compatible with old constructed receipts")
        cases+=1
    end
    do
        local p=accepted();local d=actor_diagnostics(false)
        d.report_debt,d.claim_released,d.quarantined=true,false,true
        local o=read(p,603,receipt("revoked",d))
        check(o.receipt and o.receipt.terminal and not o.intents.store,"quarantined terminal keeps diagnostic group without authorizing cleanup")
        p:update(frame(803));local changed=copy(d);changed.first_actor_owner_present=true
        o=read(p,804,receipt("revoked",changed),2)
        check(o.outcome=="unresolved" and o.intents.cancel and not o.intents.acknowledge
            and not o.receipt.first_actor_owner_present,"terminal actor fields stay immutable even before observation-known becomes true")
        cases+=1
    end
    do
        local p=accepted(504);saved_and_acked(p,"released",504);local o=settle(p,100)
        check(o.initial_state==504 and o.expected_state==100,"reverse target uses frozen baseline rather than current toggles")
        cases+=1
    end
    do
        local p=accepted();local o=read(p,603,receipt("cancelled"))
        check(o.intents.store and o.reason=="none","direct cancelled terminal is saved even without a local cancellation boundary")
        o=p:update(frame(604,{store_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
        check(o.intents.acknowledge,"direct cancelled terminal can retire the known clean retained record")
        o=p:update(frame(605,{ack_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true},observation={state=504}}))
        check(o.outcome=="failed" and o.reason=="transport_cancelled" and o.acknowledged and not o.retained,
            "cancelled transport never enters settling solely because publications are nonzero")
        for t=805,3805,200 do
            o=p:update(frame(t,{observation={state=504}}))
            check(not o.qualified_transition and not o.historical_transition and next(o.intents)==nil,
                "later stable expected state cannot turn cancelled cleanup into semantic success")
        end
        check(o.terminal_receipt.status=="cancelled" and o.terminal_receipt.press_publications=="7",
            "cancelled failure keeps the full unmodified publication receipt")
        cases+=1
    end
    do
        local p=accepted()
        local o=read(p,603,receipt("revoked",{report_debt=true,claim_released=false,quarantined=true}))
        check(o.retained and not o.intents.store and not o.intents.acknowledge,"terminal with source debt is not clean")
        for t=803,1403,200 do
            o=p:update(frame(t,{observation={state=504}}))
            check(o.retained and not o.qualified_transition and not o.intents.acknowledge,"expected state cannot excuse report debt")
        end
        cases+=1
    end
    do
        for _,bad in {
            {sequence="9007199254740993"},{press_publications="8"},{press_candidates="01"},{source_epoch="18446744073709551616"},
            {expires_ms="9007199254741998"},{first_rejection_mask=262144},{user=1},{button=0x1000},
            {consumption="consumed"},{semantic_completion="completed"},{unexpected=true},
        } do
            local p=accepted();local r=receipt("warming")
            -- Sequence is bound by a preceding real-shaped read before replacement.
            local o=read(p,603,r);o=p:update(frame(803));check(o.intents.read and o.intents.read.read_id==2,"next read has a new correlation")
            local changed=receipt("revoked",bad)
            o=read(p,804,changed,2)
            check(o.outcome=="unresolved" and o.retained and o.intents.cancel and not o.intents.store,
                "malformed/foreign receipt cannot authorize storage, acknowledgement or semantic success")
            check(not p:update(frame(805)).intents.cancel,"malformed reply triggers cancellation at most once")
        end
        cases+=1
    end
    do
        for _,bad_reply in {
            {attempt=2,handle="pulse-a",read_id=1,receipt=receipt("released")},
            {attempt=1,handle="foreign",read_id=1,receipt=receipt("released")},
            {attempt=1,handle="pulse-a",read_id=2,receipt=receipt("released")},
        } do
            local p=accepted();local o=p:update(frame(603,{receipt_result=bad_reply}))
            check(o.retained and o.outcome=="unresolved" and not o.intents.acknowledge,"foreign attempt/handle/read cannot join")
        end
        local p=accepted();read(p,603,receipt("warming",{press_candidates="2",press_publications="1"}))
        p:update(frame(803));local o=read(p,804,receipt("revoked",{press_candidates="1",press_publications="1"}),2)
        check(o.outcome=="unresolved" and not o.intents.store,"counter rollback cannot manufacture a zero-delivery retry")
        cases+=1
    end
    do
        for _,e in {{attempt=1,accepted=true},{attempt=1,accepted="unknown"},{attempt=1,accepted=false,handle="possibly-live",reason="busy"}} do
            local p=start();local o=p:update(frame(602,{request_result=e}))
            check(o.outcome=="unresolved" and o.retained and not o.intents.request,"unknown request outcome is retained")
            for t=603,610 do check(not p:update(frame(t,{gesture_down=t%2==1})).intents.request,"unknown outcome never retries on new gestures") end
        end
        local p=start();local o=p:update(frame(602,{request_result={attempt=1,accepted=false,reason="busy"}}))
        check(o.outcome=="failed" and not o.retained and not o.intents.request,"known refusal has no fabricated native handle")
        cases+=1
    end
    do
        for _,reply in {
            {attempt=1,handle="pulse-a",sequence=sequence,accepted=false},
            {attempt=1,handle="pulse-a",sequence=sequence},
            {attempt=1,handle="pulse-a",sequence="8",accepted=true},
        } do
            local p=accepted();read(p,603,receipt("released"))
            local o=p:update(frame(604,{store_result=reply}))
            check(o.retained and o.outcome=="unresolved" and not o.intents.acknowledge,"failed or unknown storage never acknowledges")
            o=p:update(frame(605,{store_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
            check(not o.intents.acknowledge and o.retained,"a second store result cannot repair the first failed/unknown join")
        end
        cases+=1
    end
    do
        local p=accepted();read(p,603,receipt("released"))
        p:update(frame(604,{store_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
        local o=p:update(frame(605,{ack_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=false}}))
        check(o.ack_failed and o.retained and not o.intents.acknowledge,"acknowledgement failure is retained and never retried")
        o=p:update(frame(606,{ack_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
        check(o.ack_failed and not o.acknowledged and o.retained,"duplicate changed acknowledgement cannot turn failure into success")
        cases+=1
    end
    do
        for _,changes in {
            {allowed=false},{observation={focused=false}},{observation={menu_closed=false}},
            {observation={fallen=true}},{observation={ragdoll=true}},{context="world-b"},{slot=1},
        } do
            local p=accepted();local o=p:update(frame(603,changes))
            check(o.intents.cancel and o.retained,"context/fall/readiness boundary cancels once")
            o=read(p,604,receipt("cancelled"))
            check(o.intents.store and not o.qualified_transition,"known clean cancelled receipt can be saved for cleanup")
            o=p:update(frame(605,{store_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
            check(o.intents.acknowledge,"clean failed-intent record may be acknowledged after storage")
            o=p:update(frame(606,{ack_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true},observation={state=504}}))
            check(o.outcome=="failed" and not o.retained and not o.qualified_transition,"cleanup never converts interrupted intent to success")
        end
        cases+=1
    end
    do
        local p=accepted();local o=p:update(frame(603,{loaded=false}))
        check(o.retained and next(o.intents)==nil,"unloaded caller retains duty without emitting API intents")
        o=p:update(frame(604));check(o.intents.cancel and not o.intents.request,"returning caller may only cancel old obligation")
        for _,t in {-1,.5,math.huge,0/0,"605",9007199254740992} do
            local q=accepted();o=q:update(frame(t))
            check(o.retained and o.intents.cancel and not o.intents.read and not o.intents.acknowledge,"invalid clock can stop assertions but cannot read/ack or qualify time")
        end
        local q=accepted();o=q:update(frame(601))
        check(o.intents.cancel and o.retained,"backward clock retains duty")
        check(not q:update(frame(602)).intents.cancel,"equal clock cannot repeat cancellation")
        cases+=1
    end
    do
        for _,phase in {"baseline","watching","saving","acknowledging","settling"} do
            for _,negative in {{context="world-b"},{loaded=false},{observation={focused=false}},{observation={fallen=true}}} do
                local p,t=Transition.new(),1
                if phase=="baseline" then p:update(frame(0));p:update(frame(1,{gesture_down=true}))
                else
                    p=accepted();t=602
                    if phase=="saving" or phase=="acknowledging" then read(p,603,receipt("released"));t=603 end
                    if phase=="acknowledging" then
                        p:update(frame(604,{store_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}));t=604
                    elseif phase=="settling" then
                        saved_and_acked(p);t=2805
                        for now=805,t,200 do p:update(frame(now,{observation={state=504}})) end
                    end
                end
                local f=frame(t,{observation={state=phase=="settling" and 504 or 100}})
                for k,v in negative do
                    if k=="observation" then for field,value in v do f.observation[field]=value end else f[k]=v end
                end
                local o=p:update(f)
                check(o.reason~="none" and not o.qualified_transition,"duplicate-time negative context/focus/fall is latched in every active phase")
                if phase=="settling" then check(o.suffix.qualified_samples==0 and o.suffix.seconds==0,"duplicate-time boundary discards the old suffix immediately") end
                o=p:update(frame(t+1,{observation={state=phase=="settling" and 504 or 100}}))
                check(o.reason~="none" and not o.qualified_transition and not o.intents.request,
                    "a fresh good frame cannot erase a duplicate-time negative boundary or retry")
                if phase=="settling" or phase=="baseline" then check(o.outcome=="failed","unowned interrupted phase finishes failed") end
            end
        end
        cases+=1
    end
    do
        local p=accepted();local o=read(p,602,receipt("released"))
        check(o.receipt and o.receipt.sequence==sequence and not o.intents.store,"equal-clock receipt joins without progressing effects")
        o=p:update(frame(603));check(o.intents.store and not o.intents.acknowledge,"next fresh time emits the saved-receipt intent")
        o=p:update(frame(603,{store_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
        check(not o.intents.acknowledge,"equal-clock storage confirmation cannot advance effect progression")
        o=p:update(frame(604));check(o.intents.acknowledge,"fresh time acknowledges the already joined storage result")
        o=p:update(frame(604,{ack_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
        check(o.acknowledged and not o.retained and o.phase=="acknowledging","equal-clock acknowledgement joins the actual cleanup result")
        o=p:update(frame(605));check(o.phase=="settling","positive observation phase begins only at fresh time")
        cases+=1
    end
    do
        local p=accepted();saved_and_acked(p)
        for t=805,2805,200 do p:update(frame(t,{observation={state=504}})) end
        local o=p:update(frame(2805,{observation={state=504,grounded=false}}))
        check(o.suffix.qualified_samples==0 and o.suffix.seconds==0,"duplicate-time loss of grounded qualification resets the suffix")
        o=p:update(frame(3005,{observation={state=504}}))
        check(o.suffix.qualified_samples==1 and o.suffix.seconds==0 and not o.qualified_transition,"next fresh sample starts a new suffix after duplicate-time loss")
        local q=Transition.new();q:update(frame(0));q:update(frame(1,{gesture_down=true}))
        for t=101,501,100 do q:update(frame(t)) end
        q:update(frame(501,{observation={grounded=false}}))
        o=q:update(frame(601))
        check(o.phase=="baseline" and not o.intents.request,"duplicate-time ungrounded baseline cannot borrow the prior dwell")
        cases+=1
    end
    do
        local p=accepted();saved_and_acked(p)
        for t=805,2805,200 do p:update(frame(t,{observation={state=504}})) end
        local o=p:update(frame(3005,{observation={state=103}}))
        check(o.suffix.seconds==0 and o.suffix.qualified_samples==0,"103 is transitional and resets settled-target suffix")
        for t=3205,5405,200 do o=p:update(frame(t,{observation={state=504}}));check(not o.qualified_transition,"new suffix cannot borrow earlier good samples") end
        o=p:update(frame(5605,{observation={state=504}}));check(not o.qualified_transition,"2.4s suffix remains incomplete")
        o=p:update(frame(5805,{observation={state=504}}));check(o.qualified_transition,"fresh complete suffix can qualify before hard bound")
        cases+=1
    end
    do
        local p=accepted();saved_and_acked(p)
        for t=805,2805,200 do p:update(frame(t,{observation={state=504}})) end
        local o=p:update(frame(3205,{observation={state=504}}))
        check(o.suffix.qualified_samples==1 and o.suffix.seconds==0,"gap over250ms restarts the suffix")
        o=p:update(frame(3205,{observation={state=504}}));check(o.suffix.qualified_samples==1,"duplicate timestamps cannot inflate observation count")
        o=p:update(frame(6606,{observation={state=504}}))
        check(o.outcome=="failed" and o.reason=="settle_deadline" and not o.qualified_transition,"late delivery past6s cannot qualify using a late endpoint")
        cases+=1
    end
    do
        local p=accepted();local o=p:update(frame(8601))
        check(o.intents.cancel and o.retained,"8s request watchdog only cancels, never declares release")
        o=p:update(frame(15001))
        check(o.outcome=="unresolved" and o.retained and not o.qualified_transition,"whole15s intent bound retains unknown native duty")
        o=read(p,15002,receipt("released"))
        check(o.retained and next(o.intents)==nil,"late terminal reply is retained but cannot dispatch beyond the closed intent bound")
        cases+=1
    end
    do
        for _,counts in {{press_candidates="0",press_publications="0",neutral_publications="0"},
            {press_candidates="1",press_publications="0",neutral_publications="1"}} do
            local p=accepted();local o=read(p,603,receipt("revoked",counts),1,{gesture_down=true})
            check(o.intents.store,"known clean zero/candidate-only result still requires storage")
            p:update(frame(604,{gesture_down=true,store_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
            o=p:update(frame(605,{gesture_down=true,ack_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
            check(o.outcome=="failed" and not o.retained,"no confirmed report pair is not sampled transition success")
            for t=606,620 do
                o=p:update(frame(t,{gesture_down=true}))
                check(not o.intents.request and o.attempt==1 and o.phase=="done","even zero-delivery does not automatically retry")
            end
        end
        cases+=1
    end
    do
        for _,changes in {{allowed=false},{loaded=false},{context="world-b"},{slot=1},{observation={grounded=false}},
            {observation={ragdoll=true}},{now_ms=-1},{now_ms="bad"}} do
            local p=accepted();saved_and_acked(p);settle(p,504)
            local f=frame(3406,{observation={state=504}})
            for k,v in changes do
                if k=="observation" then for field,value in v do f.observation[field]=value end else f[k]=v end
            end
            local o=p:update(f)
            check(o.historical_transition and not o.qualified_transition and o.acknowledged and not o.retained,
                "completed history does not grant current readiness across invalid or changed facts")
            check(next(o.intents)==nil,"old successful history emits no new effects")
        end
        cases+=1
    end
    do
        local p=accepted();local o=read(p,603,receipt("released"))
        o.receipt.sequence="corrupt";o.terminal_receipt.first_rejection_mask=999;o.intents.store.receipt.reason="corrupt"
        o=p:update(frame(604,{store_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}))
        check(o.receipt.sequence==sequence and o.terminal_receipt.reason=="none" and o.terminal_receipt.first_rejection_mask==0,
            "caller mutations cannot alter retained historical proof")
        p:update(frame(605,{ack_result={attempt=1,handle="pulse-a",sequence=sequence,accepted=true}}));settle(p,504)
        p:update(frame(3406,{context="world-b",observation={state=504}}))
        o=p:update(frame(3407,{context="world-b",gesture_down=true,observation={state=504}}))
        check(o.phase=="baseline" and o.attempt==2 and o.initial_state==504 and o.expected_state==100,
            "acknowledged old context cannot block a new explicit transaction or lend its target")
        cases+=1
    end
    do
        local p=Transition.new();p:update(frame(0));p:update(frame(1,{gesture_down=true}))
        local o=p:update(frame(602,{gesture_down=true}))
        check(o.phase=="baseline" and not o.intents.request,"baseline gap cannot fake600ms of qualification")
        o=p:update(frame(702,{observation={state=504}}))
        check(o.outcome=="failed" and not o.retained,"external baseline change stops rather than toggling the new state")
        local l=Transition.limits();l.baseline_ms=0
        check(Transition.limits().baseline_ms==600,"caller cannot weaken module limits")
        cases+=1
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return tests
