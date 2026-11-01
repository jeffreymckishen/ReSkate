-- Constructed board API contract only; never native board visibility/ownership proof.
-- Root must stage the actual candidate board_drop.lua, not the old canonical preimage.
local Board=require("./board_drop")
local Tests={}

local function fixture(mode)
    local f={calls={hide=0,bones=0,toss=0,clear=0},log={}}
    f.api={board={}}
    if mode~="missing" then
        function f.api.board.hide(...)
            f.calls.hide+=1
            f.log.hide=table.pack(...)
            if mode=="raised" then error("constructed hide uncertainty",0) end
            if mode=="malformed_nil" then return nil end
            if mode=="malformed_table" then return {} end
            if mode=="malformed_number" then return 1 end
            if mode=="false" then return false,"constructed other owner" end
            return true
        end
    end
    function f.api.board.bones()
        f.calls.bones+=1
        return {
            [1]={position=vector.create(0,5,0),rotation={0,0,0,1}},
            [2]={position=vector.create(0,5,0),rotation={0,0,0,1}},
        }
    end
    function f.api.board.toss(...)
        f.calls.toss+=1
        f.log.toss=table.pack(...)
        return true
    end
    function f.api.board.clear(...)
        f.calls.clear+=1
        f.log.clear=table.pack(...)
        if f.clear_raises then error("constructed clear uncertainty",0) end
    end
    return f
end

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function untouched(f)
        return f.calls.hide==0 and f.calls.bones==0 and f.calls.toss==0 and f.calls.clear==0
    end
    local function no_toss(f,d)
        local s=d:status()
        check(f.calls.bones==0 and f.calls.toss==0 and s.bones_calls==0 and s.toss_calls==0,
            "hide path never calibrates or tosses")
    end
    local function one_clear(f,d)
        local first=d:restore()
        check(first.called==true and f.calls.clear==1,"owned or uncertain presentation clears once")
        check(f.log.clear.n==0,"clear releases only the plugin-owned presentation with no fabricated bone")
        check(d:status().state=="restored" and d:status().clear_result=="cleared","successful clear is exposed")
        local second=d:restore()
        check(second.called==false and f.calls.clear==1,"repeated stop/restore cannot clear twice")
    end

    case("opt-in hide is inert until drop, local and once-only without a floor",function()
        local f=fixture("accepted")
        local d=Board.new(f.api,{presentation="hide"})
        check(untouched(f) and d:status().presentation=="hide","constructing hide calls no SDK")
        local before=d:restore()
        check(before.called==false and untouched(f),"pre-drop stop cannot clear an unowned board")
        local out=d:drop(nil)
        check(out.ok==true and out.called==true and out.state=="hidden","nil floor does not block opt-in hide")
        local s=d:status()
        check(s.state=="hidden" and s.hide_result=="accepted" and s.hide_calls==1,"accepted hide has truthful status")
        check(f.calls.hide==1 and f.log.hide.n==2 and f.log.hide[1]==2,"only deck mount 2 is requested once")
        local options=f.log.hide[2]
        local fields=0 for _ in pairs(options) do fields+=1 end
        check(fields==1 and options.others==false,"hide stays local; others is explicitly false")
        check(s.floor==nil and s.ground==nil and s.calibration==nil,"no fabricated floor or toss calibration")
        no_toss(f,d)
        local again=d:drop(0/0)
        check(again.called==false and f.calls.hide==1,"one-shot hide is not retried with another floor")
        one_clear(f,d)
        check(d:drop(0).called==false and f.calls.hide==1,"restore does not reopen hide admission")
    end)

    case("false or missing hide is unowned and must never clear",function()
        for _,mode in {"false","missing"} do
            local f=fixture(mode)
            local d=Board.new(f.api,{presentation="hide"})
            local out=d:drop(nil)
            local expected_calls=mode=="missing" and 0 or 1
            check(out.ok==false and out.state=="refused","missing/refused hide is not presented as success")
            check(out.called==(expected_calls==1) and f.calls.hide==expected_calls,"only an available hide function is called")
            check(d:status().hide_calls==expected_calls and d:status().hide_result==(mode=="missing" and "missing" or "refused"),
                "missing and explicit refusal remain distinct")
            no_toss(f,d)
            check(d:drop(0).called==false and f.calls.hide==expected_calls,"refusal remains one-shot")
            check(d:restore().called==false and d:restore().called==false and f.calls.clear==0,
                "unowned refusal cannot clear another presentation")
        end
    end)

    case("raised or malformed hide remains uncertain until one clear",function()
        for _,mode in {"raised","malformed_nil","malformed_table","malformed_number"} do
            local f=fixture(mode)
            local d=Board.new(f.api,{presentation="hide"})
            local out=d:drop(nil)
            local expected=mode=="raised" and "raised" or "malformed"
            check(out.ok==false and out.called==true and out.state=="unknown","call uncertainty is neither success nor unowned refusal")
            check(d:status().hide_result==expected and d:status().hide_calls==1 and f.calls.hide==1,
                "raised and malformed results keep their provenance")
            no_toss(f,d)
            check(d:drop(nil).called==false and f.calls.hide==1,"uncertainty cannot replay hide")
            one_clear(f,d)
        end
    end)

    case("clear uncertainty is never silently retried",function()
        for _,mode in {"raised","missing"} do
            local f=fixture("accepted")
            local d=Board.new(f.api,{presentation="hide"})
            check(d:drop(nil).ok==true,"constructed hide accepted before cleanup scenario")
            if mode=="raised" then f.clear_raises=true else f.api.board.clear=nil end
            local out=d:restore()
            check(out.ok==false and out.state=="restore_unknown","failed clear leaves cleanup unknown")
            check(d:status().clear_result==(mode=="raised" and "raised" or "missing"),"clear result remains truthful")
            local calls=f.calls.clear
            check(calls==(mode=="raised" and 1 or 0),"only available clear is called")
            f.api.board.clear=function() f.calls.clear+=1 end
            check(d:restore().called==false and f.calls.clear==calls,"later availability cannot reset one-shot cleanup")
            no_toss(f,d)
        end
    end)

    case("omitted options preserve the original calibrated toss",function()
        local f=fixture("accepted")
        local d=Board.new(f.api)
        check(untouched(f) and d:status().presentation=="toss","legacy constructor remains inert and defaults to toss")
        local out=d:drop(4)
        check(out.ok==true and out.called==true and out.state=="dropped","legacy toss remains accepted")
        check(f.calls.hide==0 and d:status().hide_calls==0 and f.calls.bones==1 and f.calls.toss==1,
            "legacy toss still calibrates once and never hides")
        local args=f.log.toss
        check(args.n==2 and #args[1]==1 and args[1][1]==Board.DECK_MOUNT,"legacy toss targets the same deck")
        local options=args[2]
        check(math.abs(options.ground-(4+Board.GROUND_OFFSET_M+Board.REST_LIFT_M))<1e-9,
            "legacy floor/lift arithmetic is unchanged")
        check(math.abs(options.velocity.y-Board.LIFT_MPS)<1e-6 and math.abs(options.spin.y-Board.SPIN_RADPS)<1e-6,
            "legacy velocity and spin remain unchanged")
        check(d:status().toss_result=="accepted" and d:status().bones_calls==1,"legacy status remains available")
        check(d:drop(4).called==false and f.calls.toss==1,"legacy toss remains one-shot")
        one_clear(f,d)
    end)
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false}
end
return Tests