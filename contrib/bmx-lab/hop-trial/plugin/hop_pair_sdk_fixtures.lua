-- Independent exact SANITIZED SDK DTO fixtures, grounded in input-lease builders.
-- No SDK call, runtime knowledge or acceptance is conferred by constructed data.
local F={A="input.lease_state",B="input.lease_capture_state"}
F.state_fields=table.freeze({"call","arity","call_ok","sequence","user","source_epoch","context_generation","status","reason","terminal",
    "requested_ms","expires_ms","observed_ms","last_observation","renewals","source_released","capture_reserved","orphaned","capturing","report_debt"})
F.capture_fields=table.freeze({"call","arity","call_ok","sequence","user","source_epoch","context_generation","phase","reason","terminal",
    "quarantined","capturing","report_debt","generation","revision","expires_ms","publications","neutral_releases"})
function F.lease_state(sequence)
    return {call=F.A,arity=1,call_ok=true,sequence=sequence or "1",user=0,source_epoch="7",context_generation="9",
        status="active",reason="none",terminal=false,requested_ms="1000",expires_ms="2000",observed_ms="1010",last_observation="1010",
        renewals="0",source_released=false,capture_reserved=true,orphaned=false,capturing=false,report_debt=false}
end
function F.capture_state(phase,sequence)
    phase=phase or "capturing";local capturing=phase=="capturing"
    return {call=F.B,arity=1,call_ok=true,sequence=sequence or "2",user=0,source_epoch="7",context_generation="9",
        phase=phase,reason="none",terminal=false,quarantined=false,capturing=capturing,report_debt=capturing,
        generation="3",revision="4",expires_ms="2000",publications=capturing and "1" or "0",neutral_releases="0"}
end
function F.data(call,sequence)
    if call==F.A then return F.lease_state(sequence) end
    assert(call==F.B,"fixture call must be an exact SDK projection")
    return F.capture_state("capturing",sequence)
end
function F.copy(value)
    if type(value)~="table" then return value end
    local out={};for k,v in pairs(value) do out[k]=F.copy(v) end;return out
end
function F.same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b and (type(a)~="number" or a~=0 or 1/a==1/b) end
    for k,v in pairs(a) do if not F.same(v,rawget(b,k)) then return false end end
    for k in pairs(b) do if rawget(a,k)==nil then return false end end;return true
end
function F.freeze(value)
    if type(value)=="table" and not table.isfrozen(value) then for _,v in pairs(value) do F.freeze(v) end;table.freeze(value) end
    return value
end
function F.logical(data,first,last,repeats,paired)
    return {kind="lease",data=data,first_call=first,last_call=last or first,repeats=repeats or 1,
        critical=false,incomplete=false,paired=paired}
end
return table.freeze(F)
