-- Portable currentRecovery-only version; no production seam or historical Core copy.
-- The parent runner supplies separately pinned, independently loaded baseline and
-- proposal Core modules plus the same existing qualified test dependencies.
-- No production seam is added: shared_state is Core.new's existing test seam.
local Tests={}
-- Source pins precede only the parent's independently recorded, existing test
-- transformations. Luau cannot validate file hashes; the parent must verify them
-- before import and separately pin the transformed qualified fixture modules.
local source_pins={
    current_recovery={baseline="C3BD7813F3AEBDBDB42D1C7515CC2D14C9B49F75B60D6DAF48B4EC504CDE24C6",
        proposed="AD8E3446A32FFEAAA55B818A88C8BCB677474930A2323A6523D358B6E7010CD8"},
}
local KEY="bmx_bike_lifecycle_v1"
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function same(a,b)
    if typeof(a)~=typeof(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function without_public_uncertainty(row)
    local result=copy(row);result.cleanup_unknown=nil;return result
end
local function fixture(Core,context)
    local G,Identity=context.Geometry,context.Identity
    local f,s=context.Services.spawn_services()
    f.input_serial,f.body_serial=5,1
    f.native,f.transactions,f.packets,f.events={},{},{},{}
    f.force_acks,f.force_ack_attempts,f.pose_ends=0,0,0
    f.next_sequence=0;f.hold_successors=true;f.follow_done=false
    f.sdk,f.encodes,f.saves={},{},{}
    local opaque,opaque_count={},0
    local function normalized(value)
        local kind=typeof(value)
        if kind=="vector" then return {kind="vector",x=value.x,y=value.y,z=value.z} end
        if type(value)=="userdata" then
            if not opaque[value] then opaque_count+=1;opaque[value]="opaque:"..tostring(opaque_count) end
            return opaque[value]
        end
        if type(value)~="table" then return value end
        local result={};for k,v in pairs(value) do result[k]=normalized(v) end;return result
    end
    local function event(name,id) table.insert(f.events,{name=name,id=id,at=f.now}) end
    local read_source=s.input.lease_read
    function s.input.lease_read(handle)
        local row,why=read_source(handle)
        if not row then return nil,why end
        f.pad=f.pad or copy(row.pad)
        row.pad=copy(f.pad);row.observation_serial=tostring(f.input_serial)
        row.observed_ms=tostring(2000+f.input_serial);row.packet=f.input_serial
        return row
    end
    local state_source=s.input.lease_state
    function s.input.lease_state(handle)
        local row,why=state_source(handle)
        if not row then return nil,why end
        row.observed_ms=tostring(2000+f.input_serial);row.last_observation=tostring(f.input_serial)
        return row
    end
    function s.skater.pose(plan,weight)
        if plan==nil then f.pose_ends+=1;event("pose_end");return true end
        if weight==2 then error("a joint's place has a position, a rotation or both",0) end
        return true
    end
    function s.json.encode(record)
        local encoded=context.encode(record)
        table.insert(f.encodes,{at=f.now,record=copy(record),text=encoded})
        return encoded
    end
    function s.storage.set(key,record)
        local row={key=key,at=f.now,record=copy(record),text=context.encode(record)}
        table.insert(f.saves,row);f.records[key]=row.record
        -- Preserve the actual SDK's zero-return-value contract.
    end
    local P=s.world.physics
    local function measured()
        return {epoch=newproxy(),serial=tostring(f.body_serial),time=f.body_serial/60,seconds=1/60,
            position=f.definition.position,rotation=copy(f.definition.rotation),mass=G.mass,
            velocity=vector.create(0,0,1),angular_velocity=vector.create(0,0,0),
            inertia=vector.create(G.inertia[1],G.inertia[2],G.inertia[3])}
    end
    function P.read(body)
        assert(body==f.body and f.definition,"real Spawn/Core reads its exact constructed body")
        f.read=measured();return f.read
    end
    function P.reserve_follow(body,attachment)
        assert(body==f.body);table.insert(f.reserves,{body=body,attachment=attachment})
        f.follow=newproxy();f.follow_phase="reserved";event("follow_reserve");return f.follow,nil
    end
    function P.publish_follow(handle)
        assert(handle==f.follow);f.follow_phase="following";f.published=true;event("follow_publish");return true
    end
    function P.stop_follow(handle)
        assert(handle==f.follow);f.follow_phase="stopping";event("follow_stop");return true
    end
    function P.read_follow(handle)
        assert(handle==f.follow)
        local done=f.follow_phase=="stopping" and f.follow_done
        return {phase=done and "completed" or f.follow_phase,reason=f.follow_phase=="stopping" and "cancelled" or "none",
            park_reason=done and "none" or "unavailable",sequence="41",final_revision=f.published and "3" or "0",
            final_native_epoch=f.published and "9" or "0",returned_revision=done and "3" or "0",
            pending={},in_flight=0,claim_known=not done,orphaned=false,park_observed=done,
            native_retirement_known=false,terminal=done}
    end
    function P.acknowledge_follow(handle)
        assert(handle==f.follow and f.records[KEY] and f.records[KEY].terminal_receipt,
            "the exact terminal Follow receipt must be persisted before its ACK")
        event("follow_ack");return true
    end
    function P.probe_batch(body,epoch,rays,settings)
        assert(body==f.body and epoch==f.read.epoch and settings.require_contact and settings.exclude_local_actor)
        local batch={status="available",epoch=epoch,native_casts=#rays,budget_exhausted=false,
            local_actor_excluded=true,owned_bodies_excluded=true,rays={}}
        for i,ray in ipairs(rays) do
            if #rays==3 then batch.rays[i]={status="clear"}
            else
                local delta=ray.from-ray.to;local length=math.sqrt(delta.x*delta.x+delta.y*delta.y+delta.z*delta.z)
                batch.rays[i]={status="hit",position=ray.from+vector.create(0,-G.wheel_radius,0),
                    fraction=G.wheel_radius/length,normal=vector.create(0,1,0),surface_velocity=vector.create(0,0,0),
                    normal_available=true,surface_velocity_available=true,motion="measured"}
            end
        end
        return batch
    end
    local function refresh()
        for _,row in ipairs(f.native) do
            if row.outcome=="queued" and Identity.compare(tostring(f.body_serial),row.produced)>=0 then row.outcome="applied" end
            if row.outcome=="applied" and not row.successor and not f.hold_successors
                and Identity.compare(tostring(f.body_serial),row.produced)>0 then row.successor=measured() end
        end
    end
    function P.submit(body,epoch,command)
        assert(body==f.body and epoch==f.read.epoch and typeof(command.force)=="vector" and typeof(command.torque)=="vector")
        refresh();f.next_sequence+=1;local sequence=tostring(f.next_sequence)
        local row={sequence=sequence,requested=f.read.serial,produced=tostring(f.body_serial+1),outcome="queued"}
        f.transactions[sequence]=row;table.insert(f.native,row)
        table.insert(f.packets,{sequence=sequence,serial=row.requested,command=copy(command)})
        event("submit",sequence);return true,nil,sequence
    end
    function P.receipt(body,sequence)
        assert(body==f.body and f.transactions[sequence]);refresh();event("force_receipt",sequence)
        if f.bad_receipt then error("constructed receipt transport unknown",0) end
        local row=f.transactions[sequence];local applied=row.outcome=="applied"
        return {sequence=sequence,requested_serial=row.requested,produced_serial=applied and row.produced or "0",
            outcome=row.outcome,force_attempted=applied,torque_attempted=applied,retained=false,quarantined=false,
            cleanup_disposition="none",successor=row.successor}
    end
    function P.acknowledge(body,sequence)
        assert(body==f.body and f.native[1] and f.native[1].sequence==sequence,
            "real adapter must ACK the exact oldest retained row on its original body")
        refresh();assert(f.native[1].successor,"applied receipt requires its own later successor")
        f.force_ack_attempts+=1;event("force_ack_attempt",sequence)
        if f.ack_mode=="throw" then error("constructed ACK may have happened",0) end
        if f.ack_mode=="refuse" then return false,"constructed ACK refused" end
        if f.ack_mode=="malformed" then return true,"unexpected extra value" end
        table.remove(f.native,1);f.force_acks+=1;event("force_ack",sequence);return true
    end
    -- Capture every SDK-shaped invocation, return arity, value and failure. Opaque
    -- test identities are normalized by first encounter; no raw handle is forged.
    local function wrap(group,path)
        assert(type(group)=="table","fixture service group is unavailable: "..path)
        for name,original in pairs(group) do
            if type(original)=="function" then
                group[name]=function(...)
                    local row={name=path.."."..name,at=f.now,args=normalized(table.pack(...))}
                    table.insert(f.sdk,row)
                    local result=table.pack(pcall(original,...));row.result=normalized(result)
                    if not result[1] then error(result[2],0) end
                    return table.unpack(result,2,result.n)
                end
            end
        end
    end
    for _,name in ipairs({"time","input","skater","level","storage","json","menu","entities"}) do wrap(s[name],name) end
    wrap(P,"world.physics")
    local state={phase="armed",used=true,active=true,ledger_owned=true,level="sanvan",wipeouts=0,
        generation=1,cancel_version=0,arm_at=f.now,slot=0,calls={},counts={},receipts={},omitted_calls=0,
        omitted_receipts=0,remove_attempted={},remove_accepted={}}
    f.shared=state;f.core=Core.new(s,{qualification_only=true},state)
    assert(f.core:prepare_backend(),"parent-supplied qualified Core fixture must bind real staged models")
    function f:step()
        self.now+=16;self.input_serial+=1
        if self.follow_phase=="following" then self.body_serial+=1 end
        return self.core:step(16)
    end
    function f:following()
        local out=self.core:status()
        for _=1,220 do
            if out.phase=="following" or out.stop_latched then break end
            out=self:step()
        end
        assert(out.phase=="following","real Source/Spawn reaches actual Core Follow: "..tostring(out.stop_reason))
        return out
    end
    function f:accepted(n)
        self:following()
        local out=self.core:status()
        for _=1,8 do
            if #self.packets==n then break end
            out=self:step()
        end
        assert(#self.packets==n and out.ride and out.ride.pending_count==n,
            "actual Core/real force adapter must retain exactly the requested accepted rows")
        return out
    end
    function f:last_save()
        for i=#self.saves,1,-1 do if self.saves[i].key==KEY then return self.saves[i] end end
    end
    function f:permit_successors()
        self.hold_successors=false;self.body_serial+=2;self.follow_done=true
    end
    return f,s
end
local function public_calls(f,check)
    local before=#f.sdk
    local expected=f.core:status()
    for _,args in ipairs({table.pack(),table.pack(false),table.pack(true),table.pack(true,"ignored",{}),table.pack({report_public=false})}) do
        check(same(f.core.status(f.core,table.unpack(args,1,args.n)),expected),"public arguments cannot select a snapshot mode")
    end
    check(#f.sdk==before,"repeated public status calls perform no SDK-shaped invocation")
    return expected
end
local function compare_pair(pair,check,known_pending)
    local a,b=pair[1],pair[2]
    local old,new=public_calls(a,check),public_calls(b,check)
    check(same(without_public_uncertainty(old),without_public_uncertainty(new)),
        "every public field except the intentional uncertainty Boolean is byte-value equivalent")
    check(same(a.sdk,b.sdk),"complete ordered SDK invocation/result/arity transcript is equivalent")
    check(same(a.saves,b.saves),"default persisted DTO bytes, store order and timestamps remain legacy-equivalent")
    check(same(a.encodes,b.encodes),"real JSON fallback input/output/order is equivalent")
    check(a.shared.saved_at==b.shared.saved_at and a.shared.persist_dirty==b.shared.persist_dirty
        and a.shared.storage_fault==b.shared.storage_fault,"persist throttle and fault state is equivalent")
    if known_pending then
        check(old.cleanup_unknown==true and new.cleanup_unknown==false,
            "PRIMARY PREIMAGE FAILURE: only proposed public status subtracts positively proved known pending transport")
        check(old.cleanup_pending and new.cleanup_pending and not new.force_cleanup_clear and not new.force_cleanup_unknown
            and not new.bike_cleanup_complete and new.stock_toggle_blocked,"known pending remains blocked debt with no completion")
        check(new.ride.stop_requested and new.ride.force_pending and not new.ride.unknown,
            "the real subordinate ledger is stopped, pending, and known")
        for _,row in ipairs(new.ride.pending_commands) do
            check(row.ack_attempted==false and row.acknowledged==false and row.unknown==false,
                "v3 K4 uses exact cached false booleans, not absent fields")
        end
        check(a:last_save().record.cleanup_unknown==true and b:last_save().record.cleanup_unknown==true,
            "public known-pending correction never leaks into a stored legacy lifecycle DTO")
    else check(old.cleanup_unknown==new.cleanup_unknown,"outside K the uncertainty Boolean is identical") end
    return old,new
end
local function new_pair(context)
    local baseline=fixture(context.CoreBaseline,context)
    local proposed=fixture(context.CoreProposed,context)
    return {baseline,proposed}
end
local function stop_pair(pair,check)
    for _,f in ipairs(pair) do check(f.core:request_stop("known pending regression Stop"),"explicit stop is accepted") end
end
local function pad_record(f,bytes)
    -- Existing shared-state diagnostics seam, as used by ledger_size_tests.
    -- Forty fixed array entries keep structural/escaping cost constant while only
    -- ASCII content changes. Each string remains <=1200 and no JSON text is faked.
    local values={};for i=1,40 do values[i]="" end
    local left=bytes
    for i=1,40 do local n=math.min(left,1200);values[i]=string.rep("x",n);left-=n end
    assert(left==0,"requested boundary padding exceeds the copier-safe fixed capacity")
    f.shared.initial_facts=copy(f.shared.initial_facts or {})
    f.shared.initial_facts.boundary_padding=values
end
local function boundary_prepared(Core,context,padding)
    local f=fixture(Core,context);f:accepted(1)
    assert(f.core:request_stop("known pending regression Stop"))
    pad_record(f,padding)
    -- Stop is already latched, so this existing forced-save path does not replace
    -- cached Ride status or manufacture a new binding. It remains actual Core.
    assert(f.core:request_stop("boundary forced save"))
    return f
end
function Tests.run(context)
    assert(type(context)=="table" and context.CoreBaseline and context.CoreProposed and context.Services
        and context.Geometry and context.Identity and type(context.encode)=="function",
        "parent must supply pinned Core variants, existing qualified dependencies, and real SDK-compatible JSON encoder")
    local pins=source_pins[context.variant]
    assert(pins and context.baseline_source_sha256==pins.baseline and context.proposed_source_sha256==pins.proposed,
        "parent must independently verify and pass the current same-lineage pre/postimage pins before import")
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case(run) cases+=1;run() end
    for _,n in ipairs({1,3}) do case(function()
        local pair=new_pair(context)
        for _,f in ipairs(pair) do f:accepted(n) end
        compare_pair(pair,check,false);stop_pair(pair,check)
        local _,pending=compare_pair(pair,check,true)
        check(pending.ride.pending_count==n,"every exact accepted transport row survives Stop")
        for _=1,2 do
            for _,f in ipairs(pair) do f:step() end
            local _,held=compare_pair(pair,check,true)
            check(held.phase=="retained_unknown","existing retained phase remains unchanged even with a known public uncertainty view")
        end
        for _,f in ipairs(pair) do
            local calls=#f.sdk;local packets=#f.packets;local releases=#f.releases
            check(not f.core:request_stock_toggle(0),"known pending still refuses stock toggling")
            check(not f.core:request_mount(0),"known pending cannot rearm the one-shot mount")
            if context.variant=="current_recovery" then
                check(type(f.core.request_get_up)=="function","current recovery API remains present")
                check(not f.core:request_get_up(),"known pending still refuses current recovery get-up")
            end
            check(#f.packets==packets and #f.releases==releases and #f.sdk==calls,
                "refused stock/mount cannot publish, release or poll the SDK")
        end
        compare_pair(pair,check,true)
        local stop_reason=pending.stop_reason
        for _,f in ipairs(pair) do f:permit_successors() end
        local done
        for _=1,30 do
            for _,f in ipairs(pair) do f:step() end
            local _,out=compare_pair(pair,check,false);done=out
            if out.phase=="done" then break end
        end
        check(done.phase=="done" and done.bike_cleanup_complete and not done.cleanup_pending and not done.cleanup_unknown,
            "exact ordered successor/ACK drain reaches the unchanged full Core done conjunction")
        check(done.stop_reason==stop_reason,"drain preserves the original stop reason")
        for _,f in ipairs(pair) do
            check(f.force_acks==n and f.force_ack_attempts==n and #f.packets==n,
                "exactly the original n rows are ACKed once without another submit")
            local ack_index=0
            for _,event in ipairs(f.events) do
                if event.name=="force_ack" then
                    ack_index+=1
                    check(event.id==tostring(ack_index),"ordered ACK sequence identity remains exact")
                end
            end
            check((f.calls["input.pulse"] or 0)==0 and (f.forbidden["input.pulse"] or 0)==0,
                "cleanup never authorizes a stock pulse by changing a report")
        end
    end) end
    for _,mode in ipairs({"refuse","throw","malformed"}) do case(function()
        local pair=new_pair(context)
        for _,f in ipairs(pair) do f:accepted(1);f.ack_mode=mode end
        stop_pair(pair,check);compare_pair(pair,check,true)
        for _,f in ipairs(pair) do f:permit_successors();f:step() end
        local _,unknown=compare_pair(pair,check,false)
        check(unknown.cleanup_unknown and unknown.cleanup_pending and not unknown.bike_cleanup_complete,
            "genuine non-exact ACK remains unknown and blocked")
        for _,f in ipairs(pair) do f.ack_mode=nil;f:step();f:step() end
        local _,retained=compare_pair(pair,check,false)
        check(retained.cleanup_unknown and retained.ride.unknown,"later SDK readiness cannot erase genuine uncertainty")
        for _,f in ipairs(pair) do check(f.force_ack_attempts==1,"uncertain/refused/malformed ACK is never retried") end
    end) end
    case(function()
        local pair=new_pair(context)
        for _,f in ipairs(pair) do f:accepted(1) end
        stop_pair(pair,check);compare_pair(pair,check,true)
        -- These are existing shared-state reasons, not a new private binding API.
        for _,f in ipairs(pair) do f.shared.protocol_unknown=true;f.shared.removal_unknown=true end
        local _,mixed=compare_pair(pair,check,false)
        check(mixed.cleanup_unknown,"mixed genuine reasons prevent the pending-only exception")
        for _,f in ipairs(pair) do f:permit_successors();f:step();f:step() end
        local _,retained=compare_pair(pair,check,false)
        check(retained.cleanup_unknown and retained.force_cleanup_clear==true and not retained.bike_cleanup_complete,
            "exact force drain cannot erase other legacy unknown reasons")
    end)
    -- Calibrate with a separate fresh owner so a refused 48001-byte write cannot
    -- poison a later positive case. Fixed layout makes ASCII padding linear.
    for _,target in ipairs({48000,48001}) do case(function()
        local old_cal=boundary_prepared(context.CoreBaseline,context,0)
        local new_cal=boundary_prepared(context.CoreProposed,context,0)
        check(same(old_cal.saves,new_cal.saves),"unpadded calibration persistence remains byte-exact")
        local base=#old_cal:last_save().text;local padding=target-base
        check(padding>=0 and padding<=48000,"boundary is reachable within copier-safe bounded strings")
        local old=boundary_prepared(context.CoreBaseline,context,padding)
        local new=boundary_prepared(context.CoreProposed,context,padding)
        local pair={old,new}
        compare_pair(pair,check,target==48000)
        check(same(old.sdk,new.sdk) and same(old.encodes,new.encodes) and same(old.saves,new.saves),
            "actual boundary encoder/store transcripts and all preceding writes are identical")
        check(#old.encodes>0 and #old.encodes[#old.encodes].text==target,
            "actual Core JSON fallback reaches exactly the requested byte boundary")
        local encoded=old.encodes[#old.encodes]
        check(encoded.record.cleanup_unknown==true and #context.encode(encoded.record)==target,
            "boundary uses the legacy true Boolean and real encoder bytes")
        check((context.CoreBaseline.ledger_bound(encoded.record) or math.huge)>48000,
            "the test reaches the actual JSON fallback rather than only the conservative bound")
        local counterfactual=copy(encoded.record);counterfactual.cleanup_unknown=false
        check(#context.encode(counterfactual)==target+1,"the public Boolean would add one real JSON byte if leaked")
        if target==48000 then
            check(#old:last_save().text==48000 and not old.shared.storage_fault and not new.shared.storage_fault,
                "48000 real JSON bytes are accepted with unchanged save throttle")
        else
            check(old.shared.storage_fault==true and new.shared.storage_fault==true
                and #old:last_save().text<48001,"48001 real JSON bytes are refused without a replacement store")
            check(old.core:status().cleanup_unknown and new.core:status().cleanup_unknown,
                "storage refusal remains genuine public uncertainty")
        end
    end) end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false,
        scope="actual Core + real force adapter over constructed SDK services",source_draft=true}
end
return table.freeze(Tests)


