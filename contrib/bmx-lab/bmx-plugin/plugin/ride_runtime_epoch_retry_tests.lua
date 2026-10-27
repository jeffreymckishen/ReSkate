-- Actual Ride, mapping and force models over constructed SDK boundaries. A
-- successful Core reread is a continuity notice, never a fabricated body step.
local Fixtures=require("./ride_runtime_tests")
local Tests={}
local function count(f,name) local n=0 for _,v in ipairs(f.calls) do if v==name then n+=1 end end return n end
local function recovered(f)
    return {now_ms=f.now,focused=true,menu_open=false,loaded=true,body_read_recovered=true}
end
local function observe_invalidations(f)
    local invalidate,preview=f.force.invalidate_continuity,f.force.preview
    f.invalidations=0;f.order={}
    function f.force:invalidate_continuity()
        f.invalidations+=1;table.insert(f.order,"invalidate")
        return invalidate(self)
    end
    function f.force:preview(...)
        table.insert(f.order,"preview")
        return preview(self,...)
    end
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,run) cases+=1;run(name) end
    case("the first recovered observation invalidates before one preview",function()
        local f=Fixtures.fixture();observe_invalidations(f)
        local s=f.observe(recovered(f))
        check(not s.stop_requested and s.submitted==1,"coherent recovered observation still submits once")
        check(f.order[1]=="invalidate" and f.order[2]=="preview" and f.invalidations==1,"history invalidated before preview")
        check(s.continuity.body_read_recoveries==1 and s.continuity.invalidations==1
            and s.continuity.skipped_steps==0 and not s.continuity.pending,"reread does not invent a skipped command")
        check(count(f,"probe")==1 and #f.tricks.observed==1,"one real model observation")
    end)
    case("a recovered duplicate preserves receipt debt and defers invalidation",function()
        local f=Fixtures.fixture();observe_invalidations(f)
        local first=f.observe();local sequence=first.pending_sequence
        local s=f.observe(recovered(f))
        check(not s.stop_requested and s.continuity.pending and s.continuity.body_read_recoveries==1,"duplicate remembers continuity loss")
        check(s.pending_sequence==sequence and s.pending_count==1 and s.submitted==1 and s.acknowledged==0,"same unresolved exact transaction")
        check(f.invalidations==0 and count(f,"probe")==1 and #f.tricks.observed==1,"duplicate repeats no model or preview")
        f.advance();s=f.observe()
        check(not s.stop_requested and s.continuity.pending and f.invalidations==0,"queued receipt still defers preview")
        check(s.pending_sequence==sequence and count(f,"submit")==1,"no replay while pending")
        f.advance();f.mode="applied";f.successor=f.sample();s=f.observe()
        check(not s.stop_requested and s.acknowledged==1 and s.submitted==2,"the current epoch may submit after actual receipt ACK")
        check(f.invalidations==1 and s.continuity.invalidations==1 and not s.continuity.pending,"one invalidation at next real preview")
        check(f.order[#f.order-1]=="invalidate" and f.order[#f.order]=="preview","invalidation remains before next preview")
        check(s.continuity.body_read_recoveries==1,"ordinary later samples do not create recoveries")
    end)
    case("an accepted hop and its original receipt survive the recovery",function()
        local f=Fixtures.fixture();observe_invalidations(f);f.observe()
        f.pad.buttons.right_stick=true;f.advance();f.mode="applied"
        local s=f.observe();local hop=f.command.impulse_id;local sequence=f.sequence
        check(type(hop)=="number" and hop>0 and f.force:consumed_hop_event_id()==hop,"real accepted packet consumed its hop")
        check(s.pending_count==2 and s.acknowledged==0,"two accepted command receipts remain outstanding")
        s=f.observe(recovered(f))
        check(not s.stop_requested and s.pending_commands[2].sequence==sequence and s.pending_count==2,"recovered duplicate retains hop receipt")
        check(f.force:consumed_hop_event_id()==hop and s.submitted==2 and f.invalidations==0,"no hop replay or reset on duplicate")
        f.pad.buttons.right_stick=false;f.advance();f.successor=f.sample();s=f.observe()
        check(not s.stop_requested and f.invalidations==1 and s.acknowledged==1,"coherent next step resumes with history invalidated")
        check(f.command.impulse_id==nil and f.force:consumed_hop_event_id()==hop,"force history reset preserves consumed hop identity")
        f.advance();f.successor=f.sample();s=f.observe()
        check(not s.stop_requested and s.hop_disposition.id==hop and s.hop_disposition.disposition=="accepted"
            and s.hop_disposition.confirmed,"original hop receipt retires through its actual ACK")
        check(f.command.impulse_id==nil and f.invalidations==1,"later step neither replays the hop nor repeats the invalidation")
    end)
    case("recovery cannot grant an unobserved body gap",function()
        local f=Fixtures.fixture();f.observe();f.advance(2)
        local s=f.observe(recovered(f))
        check(s.stop_requested and s.issue=="unobserved native body step gap","gap remains a hard chronology refusal")
        check(s.model_steps==1 and #f.tricks.observed==1 and count(f,"submit")==1,"no manufactured skipped models or commands")
        check(s.force_pending and s.pending_count==1,"existing debt survives the stop")
    end)
    case("recovery cannot grant regression or changed duplicate",function()
        for _,variant in ipairs({"regression","duplicate"}) do
            local f=Fixtures.fixture();f.observe();local raw=f.sample()
            if variant=="regression" then raw.serial="9007199254741000";raw.time=.9 else raw.mass=107 end
            local s=f.observe(recovered(f),raw)
            check(s.stop_requested and count(f,"submit")==1 and #f.tricks.observed==1,"recovered "..variant.." still stops")
        end
    end)
    case("recovery cannot replace selected source or readiness",function()
        local f=Fixtures.fixture();f.observe();f.source_epoch="9007199254740996";f.advance()
        local s=f.observe(recovered(f))
        check(s.stop_requested and count(f,"probe")==1,"source replacement is refused before any new probe")
        f=Fixtures.fixture();f.observe();f.advance();local context=recovered(f);context.focused=false
        s=f.observe(context)
        check(s.stop_requested and count(f,"submit")==1,"lost focus cannot use recovery to continue")
    end)
    case("failed history invalidation stops before preview or submit",function()
        for _,variant in ipairs({"throw","extra_result"}) do
            local f=Fixtures.fixture()
            function f.force:invalidate_continuity()
                if variant=="throw" then error("constructed invalidation failure",0) end
                return true
            end
            local s=f.observe(recovered(f))
            check(s.stop_requested and s.unknown and s.issue=="force history continuity invalidation unavailable","failed invalidation is terminal")
            check(count(f,"submit")==0,"failed invalidation admits no packet")
        end
    end)
    case("a stopped unknown transaction cannot be revived by recovery",function()
        local f=Fixtures.fixture();f.on_submit=function() error("possibly admitted",0) end
        local first=f.observe();local calls=#f.calls
        local s=f.observe(recovered(f))
        check(first.stop_requested and first.unknown and first.force_pending,"control has unknown admission debt")
        check(s.stop_requested and s.unknown and s.force_pending and #f.calls==calls,"recovery never revives stopped unknown debt")
        check(count(f,"submit")==1,"uncertain admission is not replayed")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return Tests
