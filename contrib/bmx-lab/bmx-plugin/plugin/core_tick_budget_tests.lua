-- Count-based guards for the per-tick budget (the S1 ride stopped at 4.01 ms a
-- tick against the Host's 2 ms). Nothing here is timed: each case counts SDK
-- calls, ledger encodes, posed visual points or copies, or checks that an
-- immutable table is shared rather than copied. Constructed fixtures only; no
-- Host, permission, native clock or game.
local Core=require("./bike_runtime_core")
local Spawn=require("./bike_spawn")
local Visual=require("./bike_visual")
local Forces=require("./forces")
local M=require("./force_math")
local Identity=require("./lease_identity")
local Tests={}

local function fake_spawn(f)
    local owner={phase="armed"}
    function owner:request() return true end
    function owner:update() if self.phase=="armed" then self.phase="spawned" end end
    function owner:status()
        return {phase=self.phase,cleanup_unknown=false,creation_unknown=false,body=false,visual_remove_requested=false}
    end
    function owner:handoff_follow() self.phase="follow_owned";return f.body,{serial="1"},nil end
    function owner:follow_visual() f.visuals+=1;return true end
    function owner:stop() self.phase="closed" end
    return owner
end
-- A constructed owner one tick before publication (as core_follow_lease_tests):
-- the next step publishes, and every later step is a following tick. Every SDK
-- function is wrapped so each call is counted by its path.
local function following_fixture()
    local f={now=10000,visuals=0,follow=newproxy(),body=newproxy(),published=false,calls={},encodes=0}
    local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
    function s.time.now() return f.now end
    function s.json.encode() f.encodes+=1;return "constructed bounded storage DTO" end
    function s.storage.get() return nil end
    function s.storage.set() end
    local P=s.world.physics
    function P.reserve_follow() return f.follow,nil end
    function P.read_follow()
        local following=f.published
        return {phase=following and "following" or "reserved",reason="none",park_reason="none",sequence="7",
            final_revision=following and "1" or "0",final_native_epoch=following and "5" or "0",
            returned_revision=following and "1" or "0",pending={},in_flight=0,claim_known=true,orphaned=false,
            park_observed=false,native_retirement_known=false,terminal=false}
    end
    function P.publish_follow() f.published=true;return true end
    function P.read() f.serial=(f.serial or 1)+1;return {serial=tostring(f.serial)} end
    function P.stop_follow() return true end
    function P.acknowledge_follow() return true end
    function P.release() return true end
    local function count(t,prefix)
        for key,value in pairs(t) do
            if type(value)=="function" then
                local name=prefix..key
                t[key]=function(...) f.calls[name]=(f.calls[name] or 0)+1;return value(...) end
            elseif type(value)=="table" then count(value,prefix..key..".") end
        end
    end
    count(s,"")
    local state={phase="spawning",detail="constructed spawned owner",generation=1,cancel_version=1,calls={},counts={},
        receipts={},omitted_calls=0,omitted_receipts=0,remove_attempted={},remove_accepted={},used=true,
        ledger_owned=true,spawn_requested=true,input_current=true,slot=0}
    local core=Core.new(s,{qualification_only=true},state)
    local original=Spawn.new
    Spawn.new=function() return fake_spawn(f) end
    local ok,bound=pcall(core.prepare_backend,core)
    Spawn.new=original
    assert(ok and bound==true,"constructed backend binds the stand-in spawn owner")
    function f.tick(at)
        if at then assert(at>=f.now,"fixture time is monotonic");f.now=at end
        table.clear(f.calls)
        local encodes=f.encodes
        local out=core:step(16)
        local n=0
        for _,c in pairs(f.calls) do n+=c end
        return out,n,f.encodes-encodes
    end
    return f,core,state
end
local function same_number(a,b) return a==b and (a~=0 or 1/a==1/b) end

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,run) cases+=1;run(name) end

    case("a following tick makes a fixed set of SDK calls and saves the ledger at most once a second",function()
        local f,_,state=following_fixture()
        local out=f.tick()
        check(out.phase=="following","the constructed owner publishes")
        local encodes,saves,ticks=0,0,0
        for i=1,30 do
            local status,calls,encoded=f.tick(state.publish_at+16*i)
            check(status.phase=="following","still following at +"..(16*i).." ms")
            -- Five clock reads (the tick, the window, after the receipt, after the
            -- body read and after the visual), one receipt read and one body read;
            -- a tick that saves the ledger adds its storage.set. No readiness facts
            -- here: this owner is not armed (active).
            local saved=f.calls["storage.set"] or 0
            check(encoded==0,"no ledger encode for the size check: the bound shows it fits")
            check(calls==7+saved and f.calls["time.now"]==5 and f.calls["world.physics.read_follow"]==1
                and f.calls["world.physics.read"]==1,"seven SDK calls a following tick and one more to save: "..calls)
            encodes+=encoded;saves+=saved;ticks+=1
        end
        -- 30 ticks over 480 ms of following: the 1 s throttle allows none after
        -- the publication's own save, where the 200 ms one made two and one a
        -- tick would be 30.
        check(saves==0 and encodes==0,"no tick-end save in 480 ms of following: "..saves.." in "..ticks.." ticks")
        -- The window ends: the stop is a state change, saved at once, unthrottled.
        local status,_,encoded=f.tick(state.publish_at+500)
        check(status.stop_reason=="ride window or Follow lease ended" and (f.calls["storage.set"] or 0)>=1 and encoded==0,
            "the stop is saved in its own tick, without an encode")
    end)
    case("the ledger bound covers the ledger it lets through and refuses what it cannot bound",function()
        local f,core,state=following_fixture()
        f.tick()
        for i=1,6 do f.tick(state.publish_at+16*i) end
        local ledger=core:status()
        local bound=Core.ledger_bound(ledger)
        check(type(bound)=="number" and bound>0 and bound<=48000,"a following ledger has a bound under the limit: "..tostring(bound))
        check(Core.ledger_bound(ledger)==bound,"the same ledger, the same bound (shared frozen rows keep theirs)")
        check(Core.ledger_bound({1,2,x=3})==nil and Core.ledger_bound({[2]=1})==nil and Core.ledger_bound({1/0})==nil
            and Core.ledger_bound("caf\195\169")==nil and Core.ledger_bound(newproxy())==nil
            and Core.ledger_bound(setmetatable({},{}))==nil,"mixed keys, holes, infinity, non-ASCII, userdata and metatables get none")
        local deep={}
        local at=deep
        for _=1,40 do at.next={};at=at.next end
        check(Core.ledger_bound(deep)==nil,"nesting past the writer's 32 levels gets none")
    end)

    case("a status shares the frozen call rows, receipts and readiness instead of copying them",function()
        local f,core,state=following_fixture()
        f.tick()
        for i=1,6 do f.tick(state.publish_at+16*i) end
        local a,b=core:status(),core:status()
        check(#a.calls==#state.calls and #a.calls>0,"the status carries the call history")
        check(a.calls~=b.calls and a.calls~=state.calls,"each status has its own call array")
        for i=1,#a.calls do
            check(rawequal(a.calls[i],b.calls[i]) and rawequal(a.calls[i],state.calls[i]) and table.isfrozen(a.calls[i]),
                "call row "..i.." is the ledger's own frozen row, shared")
        end
        check(#a.receipt_history>0,"receipts were read")
        for i=1,#a.receipt_history do
            check(rawequal(a.receipt_history[i],b.receipt_history[i]) and table.isfrozen(a.receipt_history[i]),
                "receipt "..i.." is shared")
        end
        check(rawequal(a.receipt,state.receipt),"the current receipt is shared")
        check(not table.isfrozen(a) and not table.isfrozen(a.startup) and a.startup~=b.startup,
            "the status itself and its startup table are fresh, as the facade writes startup")
        local changed=pcall(function() a.calls[1].call="changed" end)
        check(not changed and state.calls[1].call~="changed","a shared row cannot be changed through a status")
        local last=a.calls[#a.calls]
        check(last.call=="time.now" and last.called==true and last.returns==1 and last.first_type=="number",
            "the shared rows hold the same fields as before")
    end)

    case("the measured follow builds its posed points once and its matrices are the same numbers",function()
        local around=M.around
        local turns=0
        M.around=function(...) turns+=1;return around(...) end
        local sample={position=vector.create(3.25,101.5,-7.125),rotation={.1,.7,-.2,math.sqrt(1-.01-.49-.04)}}
        local ok,first=pcall(Visual.from_sample,sample)
        local after_first=turns
        local second_ok,second=pcall(Visual.from_sample,sample)
        local after_second=turns
        local reference_ok,reference
        do
            -- The explicit neutral pose takes the per-point path: every posed point
            -- is computed again, as every sample did before.
            local q=M.normalized(sample.rotation)
            local root=M.sub({3.25,101.5,-7.125},M.turn(q,require("./bike_geometry").com))
            reference_ok,reference=pcall(Visual.matrices,root,q,Visual.neutral())
        end
        local reference_turns=turns-after_second
        M.around=around
        check(ok and second_ok and reference_ok and first and second and reference,"all three build")
        check(after_first<=32 and after_second==after_first,"no posed point is computed for a later sample: "..after_first.." then "..(after_second-after_first))
        check(reference_turns==32,"the explicit-pose path computes all 32 posed points: "..reference_turns)
        for part=1,8 do for k=1,16 do
            check(same_number(first[part][k],reference[part][k]) and same_number(second[part][k],reference[part][k]),
                "matrix "..part.."["..k.."] is the same number")
        end end
    end)

    case("a kernel clone shares the fixed tuning and copies its history",function()
        local c=Forces.new()
        local copy=c:clone()
        check(rawequal(copy.tuning,c.tuning),"tuning is shared")
        check(copy.normals~=c.normals and copy.air~=c.air and copy.steering~=c.steering and copy.pump~=c.pump
            and copy.pedal_latch~=c.pedal_latch,"every history table is its own copy")
        check(getmetatable(copy)==getmetatable(c) and getmetatable(copy.pump)==getmetatable(c.pump),"the same classes")
        local fields,copied=0,0
        for key in pairs(c) do fields+=1;if copy[key]~=nil then copied+=1 end end
        check(fields==copied,"every field is carried")
    end)

    case("uint64 judgements stay exact past the remembered set's bound",function()
        for i=1,1500 do check(Identity.is_u64(tostring(1000000+i)) and Identity.is_nonzero_u64(tostring(i)),"serial "..i) end
        for _=1,2 do
            check(Identity.is_u64("18446744073709551615") and not Identity.is_u64("18446744073709551616")
                and not Identity.is_u64("01") and not Identity.is_u64("") and Identity.is_u64("0")
                and not Identity.is_nonzero_u64("0") and not Identity.is_u64("1e3") and not Identity.is_u64(12),
                "the edge cases keep their answers when judged again")
        end
        check(Identity.compare("100","99")==1 and Identity.compare("99","100")==-1 and Identity.compare("5","5")==0,
            "compare still orders by length then digits")
    end)
    return {cases=cases,assertions=assertions}
end
return Tests
