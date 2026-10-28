-- UNRUN source regression complement. Integrated Core/adapter tests are separate.
local Tests={}
function Tests.run(context)
    local Factory,Identity=context.PredicateFactory,context.Identity
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function fixture(n)
        n=n or 1
        local state={stop_latched=true,ride_construct_attempted=true,now=1000,stop_at=900}
        local source={lease_handle=newproxy(),generation=1,user=0,sequence="1",source_epoch="2",context_generation="3"}
        table.freeze(source)
        local owner=table.freeze({body=newproxy(),follow=newproxy(),generation=1,source=source,incarnation=table.freeze({})})
        local binding={owner=owner,inflight=false,pending={},sequence="11"}
        local row={stop_requested=true,force_pending=true,unknown=false,pending_limit=3,pending_count=n,
            submitted=n,acknowledged=0,pending_sequence="11",pending_commands={}}
        for i=1,n do
            local sequence,serial=tostring(10+i),tostring(100+i)
            binding.pending[i]={sequence=sequence,serial=serial,ack_attempted=false}
            row.pending_commands[i]={sequence=sequence,serial=serial,ack_attempted=false,acknowledged=false,unknown=false}
        end
        state.ride_status=row
        return {state=state,binding=binding,row=row,ride={},record={cleanup_unknown=true,force_cleanup_clear=false},
            source={cleanup_unknown=false},spawn={cleanup_unknown=false,creation_unknown=false},equipment={outcome="idle"}}
    end
    local function classify(f,identity)
        return Factory(f.state,f.ride,f.binding)(f.record,f.source,f.spawn,f.equipment,identity or Identity)
    end
    local function case(why,mutate,expected,n)
        cases+=1;local f=fixture(n);if mutate then mutate(f) end
        check(classify(f)==expected,why)
    end
    case("one exact known pending row is reportable",nil,true)
    case("three exact pending rows are bounded",nil,true,3)
    case("explicit false transport unknown is clear",function(f) f.binding.unknown=false end,true)
    case("cancelled current ownership does not erase original retained capability",function(f)
        f.state.body=nil;f.state.follow=nil;f.state.generation=999
    end,true)
    local negatives={
        {"legacy false is not reclassified",function(f) f.record.cleanup_unknown=false end},
        {"already force-clear is not pending",function(f) f.record.force_cleanup_clear=true end},
        {"missing Ride construction",function(f) f.state.ride_construct_attempted=nil end},
        {"missing Ride",function(f) f.ride=nil end},
        {"missing binding",function(f) f.binding=nil end},
        {"binding in flight",function(f) f.binding.inflight=true end},
        {"missing inflight proof",function(f) f.binding.inflight=nil end},
        {"genuine binding unknown",function(f) f.binding.unknown=true end},
        {"nonboolean binding unknown",function(f) f.binding.unknown="false" end},
        {"missing source proof",function(f) f.source=nil end},
        {"source unknown",function(f) f.source.cleanup_unknown=true end},
        {"missing spawn proof",function(f) f.spawn=nil end},
        {"spawn creation unknown",function(f) f.spawn.creation_unknown=true end},
        {"unresolved equipment",function(f) f.equipment.outcome="unresolved" end},
        {"missing equipment proof",function(f) f.equipment=nil end},
        {"cached Ride unknown",function(f) f.row.unknown=true end},
        {"cached pending mismatch",function(f) f.row.pending_count=2 end},
        {"submitted/ACK mismatch",function(f) f.row.submitted=2 end},
        {"cached pending sequence mismatch",function(f) f.row.pending_sequence="12" end},
        {"transport head mismatch",function(f) f.binding.sequence="12" end},
        {"transport ACK attempt",function(f) f.binding.pending[1].ack_attempted=true end},
        {"cached ACK attempt",function(f) f.row.pending_commands[1].ack_attempted=true end},
        {"cached acknowledged",function(f) f.row.pending_commands[1].acknowledged=true end},
        {"cached per-row unknown",function(f) f.row.pending_commands[1].unknown=true end},
        {"absent cached false flag",function(f) f.row.pending_commands[1].unknown=nil end},
        {"sequence mismatch",function(f) f.row.pending_commands[1].sequence="12" end},
        {"serial mismatch",function(f) f.row.pending_commands[1].serial="102" end},
        {"malformed uint64",function(f) f.binding.pending[1].sequence="18446744073709551616" end},
        {"extra array key",function(f) f.binding.pending.extra=true end},
        {"hole in bounded array",function(f) f.binding.pending[1]=nil end},
        {"no retained rows",function(f) f.row.pending_count=0 end},
        {"excess retained rows",function(f) f.row.pending_count=4 end},
        {"clock rollback",function(f) f.state.now=899 end},
        {"watchdog exact expiry",function(f) f.state.now=20900 end},
        {"missing clock",function(f) f.state.now=nil end},
        {"clock outside exact domain",function(f) f.state.now=9007199254740992 end},
        {"not stopped",function(f) f.state.stop_latched=false end},
        {"already complete",function(f) f.state.bike_cleanup_complete=true end},
        {"unloaded",function(f) f.state.unloaded=true end},
        {"busy",function(f) f.state.busy=true end},
        {"saving",function(f) f.state.saving=true end},
        {"Source callback in flight",function(f) f.state.source_inflight=true end},
    }
    for _,test in ipairs(negatives) do case(test[1],test[2],false) end
    case("coherent malformed sequence cannot hide behind mismatch",function(f)
        local bad="18446744073709551616"
        f.binding.pending[1].sequence=bad;f.row.pending_commands[1].sequence=bad
        f.binding.sequence=bad;f.row.pending_sequence=bad
    end,false)
    case("coherent malformed serial cannot hide behind mismatch",function(f)
        local bad="18446744073709551616"
        f.binding.pending[1].serial=bad;f.row.pending_commands[1].serial=bad
    end,false)
    for _,field in ipairs({"sequence","serial"}) do
        for _,regressed in ipairs({false,true}) do
            case("coherent "..field.." duplicate/regression",function(f)
                local bad=regressed and "1" or f.binding.pending[1][field]
                f.binding.pending[2][field]=bad;f.row.pending_commands[2][field]=bad
            end,false,3)
        end
    end
    case("spawn cleanup unknown remains independent",function(f) f.spawn.cleanup_unknown=true end,false)
    for _,name in ipairs({"reload_blocked","marker_unknown","storage_fault","clock_unknown","handoff_unknown",
        "reserve_unknown","gear_unknown","cleanup_expired","protocol_unknown","ride_unknown","follow_unknown","removal_unknown"}) do
        case("genuine legacy reason remains unknown: "..name,function(f) f.state[name]=true end,false)
    end
    case("unconfirmed Follow ACK",function(f) f.state.ack_attempted=true;f.state.acknowledged=false end,false)
    case("unaccepted body release",function(f) f.state.release_attempted=true;f.state.release_accepted=false end,false)
    for _,name in ipairs({"body","follow"}) do
        for _,bad in ipairs({false,0,"opaque-lookalike",{}}) do
            case("original "..name.." must remain userdata",function(f)
                local old=f.binding.owner
                local body,follow=old.body,old.follow
                if name=="body" then body=bad else follow=bad end
                f.binding.owner=table.freeze({body=body,follow=follow,generation=old.generation,
                    source=old.source,incarnation=old.incarnation})
            end,false)
        end
    end
    for _,bad in ipairs({false,0,"opaque-lookalike",{}}) do
        case("original lease must remain userdata",function(f)
            local old=f.binding.owner
            local source=table.freeze({lease_handle=bad,generation=1,user=0,sequence="1",source_epoch="2",context_generation="3"})
            f.binding.owner=table.freeze({body=old.body,follow=old.follow,generation=old.generation,
                source=source,incarnation=old.incarnation})
        end,false)
    end
    case("source identity malformed",function(f)
        local old=f.binding.owner
        local source=table.freeze({lease_handle=newproxy(),generation=1,user=0,sequence="0",source_epoch="2",context_generation="3"})
        f.binding.owner=table.freeze({body=old.body,follow=old.follow,generation=1,source=source,incarnation=old.incarnation})
    end,false)
    return {cases=cases,assertions=assertions,scope="exact extracted private predicate only",tests_unrun_at_authoring=true,native_qualified=false}
end
return table.freeze(Tests)
