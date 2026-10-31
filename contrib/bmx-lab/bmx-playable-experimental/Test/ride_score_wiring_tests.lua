-- Actual pure Ride/mapper/adapter/ledger over constructed native boundaries.
-- The landing service below is explicitly a fixture, never game evidence.
local Fixtures=require("./ride_runtime_tests")
local Identity=require("./lease_identity")
local Score=require("./score_runtime")
local Tests={}
local function copy(v)
    if type(v)~="table" then return v end
    local out={} for k,c in pairs(v) do out[k]=copy(c) end return out
end
local function inc(v)
    local out,carry={},1
    for i=#v,1,-1 do
        local n=string.byte(v,i)-48+carry;out[i]=string.char(48+n%10);carry=n>=10 and 1 or 0
    end
    return (carry==1 and "1" or "")..table.concat(out)
end
local function fixture(options)
    options=options or {}
    local f
    local landing={cancelled=0,steps=0}
    function landing:step(frame,contact,proof)
        self.steps+=1
        assert(#proof.applied_successors<=3,"same native pending bound")
        assert(type(proof.authored_steer)=="number" and proof.authored_steer==proof.authored_steer and math.abs(proof.authored_steer)<=1,"captured accepted steering fact")
        for _,p in ipairs(proof.applied_successors) do
            assert(p.request.sequence==p.receipt.sequence and p.request.serial==p.receipt.requested_serial
                and p.receipt.outcome=="applied" and p.receipt.successor,"actual full validated receipt projection")
        end
        local land=f.want_land and contact.grounded
        local quality=land and {available=true,qualified=true,scope="measured_mod_landing_v1",
            serial=frame.serial,physics_epoch=frame.physics_epoch,source_observation_serial=frame.source.observation_serial,
            grounded=true,support_known=true,observations_complete=true,owned_bodies_excluded=true,native_landing=false,
            body_up_alignment=1,support_up_alignment=1,heading_cos=1,closing_normal_speed=0,
            settled_seconds=.06666666666666667,settled_samples=4} or nil
        return {serial=frame.serial,phase=land and "landed" or contact.grounded and "grounded" or "airborne",
            landed=land==true,quality=quality,accepting_catches=not contact.grounded}
    end
    function landing:cancel() self.cancelled+=1 end
    local models={tricks=false,score_landing=landing}
    if options.no_landing then models.score_landing=false end
    if options.disabled then models.scoring=false end
    if options.throw_score then
        local real=Score.new()
        models.scoring={
            queue=function() error("constructed scoring fault") end,
            observe=function(_,...) return real:observe(...) end,
            land=function(_,...) return real:land(...) end,
            cancel=function(_,...) return real:cancel(...) end,
            view=function() return real:view() end,
        }
    end
    f=Fixtures.fixture({models=models});f.landing=landing
    local decode=f.contact.decode
    function f.contact.decode(...)
        local out=decode(...);out.status="available"
        out.query.accounting_known=true;out.query.measurements_complete=true
        return out
    end
    f.native={};f.rows={};f.commands={};f.next_sequence="9007199254745001"
    local function refresh()
        for _,r in ipairs(f.native) do
            if r.outcome=="queued" and Identity.compare(f.serial,r.produced)>=0 then r.outcome="applied" end
            if r.outcome=="applied" and not r.successor and Identity.compare(f.serial,r.produced)>0 then r.successor=copy(f.sample()) end
        end
    end
    function f.api.submit(epoch,command)
        refresh();assert(epoch==f.read.epoch,"same actual constructed admission")
        f.next_sequence=inc(f.next_sequence)
        local r={sequence=f.next_sequence,requested=f.serial,produced=inc(f.serial),outcome="queued"}
        f.rows[r.sequence]=r;f.native[#f.native+1]=r;f.commands[#f.commands+1]=copy(command)
        return true,nil,r.sequence
    end
    function f.api.receipt(sequence)
        refresh();local r=f.rows[sequence];assert(r,"same retained constructed sequence")
        local applied=r.outcome=="applied"
        return {sequence=r.sequence,requested_serial=r.requested,produced_serial=applied and r.produced or "0",
            outcome=r.outcome,force_attempted=applied,torque_attempted=applied,retained=false,quarantined=false,
            cleanup_disposition="none",successor=r.successor}
    end
    function f.api.acknowledge(sequence)
        refresh();assert(f.native[1] and f.native[1].sequence==sequence,"unchanged oldest-first ACK")
        table.remove(f.native,1);return true
    end
    function f.tick(grounded,selection)
        if f.started then f.advance() end
        f.started=true;f.clear=not grounded
        f.pad.right_x=0;f.pad.right_y=selection=="bar_left" and -1 or 0
        f.pad.buttons.lb=selection=="bar_left";f.pad.buttons.rb=false
        f.pad.left_trigger=0;f.pad.right_trigger=0
        return f.observe()
    end
    return f
end
local function catch(f,check)
    f.tick(true);f.tick(false);f.tick(false,"bar_left")
    for _=1,48 do
        local row=f.tick(false)
        check(not row.stop_requested,"constructed ordinary drive remains active")
        if row.presentation_trick and row.presentation_trick.authored_events then return row end
    end
    error("bounded authored catch did not complete")
end
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function case(name,body)
        cases+=1;local ok,why=pcall(body);if not ok then error(name..": "..tostring(why),0) end
    end
    case("scoring changes no force command and waits for applied successor plus local landing",function()
        local f,g=fixture(),fixture({disabled=true})
        local function tick(grounded,selection)
            local a,b=f.tick(grounded,selection),g.tick(grounded,selection)
            check(not a.stop_requested and not b.stop_requested,"both drive owners active")
            check(#f.commands==#g.commands,"same command count")
            local x,y=f.commands[#f.commands],g.commands[#g.commands]
            check(x.force==y.force and x.torque==y.torque and x.impulse==y.impulse,"same physical command")
            return a,b
        end
        tick(true);tick(false);tick(false,"bar_left")
        local caught
        for _=1,48 do
            local a=tick(false)
            if a.presentation_trick and a.presentation_trick.authored_events then caught=a;break end
        end
        check(caught and caught.mod_score and caught.mod_score.tricks==1,"completed regrip queues pending local entry")
        check(caught.mod_score.banked_total==0 and caught.mod_score.observed_command_tricks==0,"queue is not application or landed points")
        tick(false);local observed=tick(false)
        check(observed.mod_score.observed_command_tricks==1 and observed.mod_score.eligible_pending_score==300
            and observed.mod_score.banked_total==0,"matching appliedN+1 and fullN+2 establish only eligibility")
        f.want_land=true;local landed=tick(true)
        check(landed.mod_score.banked_total==300 and landed.mod_score.last_closed.outcome=="landed"
            and landed.mod_score.calibration=="C0_UNRUN" and not landed.mod_score.native_score,"fixture-qualified local bank only")
        local view,why,phase=f.ride:score_view()
        check(view.banked_total==300 and why=="none" and phase=="landed" and table.isfrozen(view),"small immutable score view")
        local stopped=f.ride:stop("constructed switch")
        check(stopped.mod_score.stopped and stopped.mod_score.banked_total==300 and f.landing.cancelled==1,"stop cancels pending service, retains local landed total")
        g.ride:stop("constructed disabled cleanup")
    end)
    case("missing landing producer clears pending air without guessing credit",function()
        local f=fixture({no_landing=true});local row=catch(f,check)
        check(row.mod_score.active and row.mod_score.banked_total==0,"pending HUD remains useful")
        f.tick(false);f.tick(false)
        local landed=f.tick(true)
        check(not landed.stop_requested and not landed.mod_score.active and landed.mod_score.banked_total==0,"known recontact without quality discards pending")
        check(landed.mod_score.last_closed.reason=="landing_quality_unavailable","truthful unavailable landing")
        f.ride:stop("constructed missing producer cleanup")
    end)
    case("a scoring fault never replaces drive or native cleanup",function()
        local f=fixture({throw_score=true});local row=catch(f,check)
        check(not row.stop_requested and row.mod_score.stopped and row.mod_score.banked_total==0,"point service disabled only")
        local before=#f.commands;local ack=row.acknowledged
        for _=1,5 do row=f.tick(false) end
        check(not row.stop_requested and #f.commands>before and row.acknowledged>ack,"existing command and ACK pipeline continues")
        check(string.find(row.mod_score.issue,"mod score queue unavailable",1,true)~=nil,"score fault retained in bounded view")
        f.ride:stop("constructed scoring fault cleanup")
    end)
    return {cases=cases,assertions=assertions,constructed=true,native_authority=false,qualification="SOURCE_FIXTURE_ONLY"}
end
return Tests
