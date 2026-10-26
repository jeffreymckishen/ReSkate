-- Actual Core transport with constructed callbacks and opaque test identities.
-- No gate is flipped, SDK function is called, or native receipt is qualified.
local Core=require("./bike_runtime_core")
local Identity=require("./lease_identity")
local Tests={}
local function increment(value)
    local digits,carry={},1
    for i=#value,1,-1 do
        local n=string.byte(value,i)-48+carry
        if n==10 then n,carry=0,1 else carry=0 end
        table.insert(digits,1,string.char(48+n))
    end
    if carry==1 then table.insert(digits,1,"1") end
    return table.concat(digits)
end
local function fixture()
    local f={body=newproxy(),epoch=newproxy(),serial="9007199254741001",next_sequence="9007199254744001",
        calls={},guards=0,afters=0,unknowns=0,guard_ok=true}
    f.current_body=f.body
    f.binding={owner=table.freeze({body=f.body})}
    local function stop(why) f.stopped=true;f.reason=f.reason or why end
    f.api=Core.force_transaction_adapter(Identity,f.binding,
        function(epoch)
            f.guards+=1
            -- A recoverable constructed refusal tests the adapter's admission
            -- bookkeeping only; real Core's owner guard latches a terminal stop.
            if not f.guard_ok then return false end
            if f.stopped or f.current_body~=f.body or epoch~=f.epoch then stop("owner unavailable");return false end
            return true
        end,
        function() return f.serial end,
        function(operation,body,...)
            local args=table.pack(...)
            table.insert(f.calls,{operation=operation,body=body,args=args})
            if f[operation] then return f[operation](f,body,table.unpack(args,1,args.n)) end
            if operation=="submit" then
                local sequence=f.next_sequence;f.next_sequence=increment(sequence)
                return table.pack(true,true,nil,sequence)
            elseif operation=="receipt" then return table.pack(true,{sequence=args[1]})
            else return table.pack(true,true) end
        end,
        function(epoch) f.afters+=1;return not f.stopped and f.current_body==f.body and epoch==f.epoch end,
        stop,function() f.unknowns+=1 end)
    function f:advance() self.serial=increment(self.serial);self.epoch=newproxy() end
    function f:publish() return self.api.submit(self.epoch,{force=vector.create(0,0,0),torque=vector.create(0,0,0)}) end
    function f:fill(n)
        local sequences={}
        for i=1,n do
            if i>1 then self:advance() end
            local ok,why,sequence=self:publish();assert(ok==true and why==nil)
            sequences[i]=sequence
        end
        return sequences
    end
    return f
end
local function count(f,operation)
    local n=0;for _,row in ipairs(f.calls) do if row.operation==operation then n+=1 end end;return n
end
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case() cases+=1 end
    case() do
        local f=fixture()
        check(#f.calls==0 and f.guards==0 and f.afters==0 and Core.force_pipeline_capacity==3,"construction is inert and capacity is fixed")
        check(Core.force_transactions_clear(f.binding) and f.binding.sequence==nil,"fresh transport owns no force debt")
        f.binding.inflight=true
        check(not Core.force_transactions_clear(f.binding),"an unresolved callback is cleanup debt even before it returns a sequence")
    end
    case() do
        local f=fixture();local ids=f:fill(3);f:advance()
        local serial,guards,calls=f.binding.last_submit,f.guards,#f.calls
        local ok,why=f:publish()
        check(ok==false and why=="force_pipeline_full" and #f.calls==calls and f.guards==guards,"full capacity is clean backpressure without SDK or Follow-read callbacks")
        check(not f.stopped and not f.binding.unknown and #f.binding.pending==3 and f.binding.last_submit==serial,"backpressure neither consumes this serial nor clears or poisons debt")
        check(f.binding.sequence==ids[1] and not Core.force_transactions_clear(f.binding),"the compatibility sequence names the oldest of three receipts")
        check(f.api.acknowledge(ids[1])==true and f.binding.sequence==ids[2],"one exact head ACK advances the ordered ledger")
        local accepted,reason,next_id=f:publish()
        check(accepted==true and reason==nil and next_id~=ids[3] and #f.binding.pending==3,"the unspent serial can publish after a slot clears")
        check(f.guards==guards+1 and count(f,"submit")==4,"only actual publication attempts spend a guard and SDK call")
    end
    case() do
        local f=fixture();f:fill(3);local before=#f.calls
        local ok,why=f:publish()
        check(ok==false and why=="one force transaction per measured serial" and f.stopped,"a duplicate serial is still refused at full capacity")
        check(#f.calls==before and #f.binding.pending==3 and not Core.force_transactions_clear(f.binding),"duplicate refusal leaves all existing debt")
    end
    case() do
        local f=fixture();local ids=f:fill(1);f:advance();f.guard_ok=false
        local serial,highest=f.binding.last_submit,f.binding.highest_sequence
        local calls,guards,afters=#f.calls,f.guards,f.afters
        local ok,why=f:publish()
        check(ok==false and why=="Core force publication guard refused before SDK call","fresh serial and free capacity still require owner authorization")
        check(#f.calls==calls and f.guards==guards+1 and f.afters==afters,"owner refusal invokes no SDK or post-submit callback")
        check(f.binding.last_submit==serial and f.binding.highest_sequence==highest and #f.binding.pending==1 and f.binding.sequence==ids[1],
            "owner refusal consumes no serial or sequence and preserves the existing receipt")
        check(not f.stopped and not f.binding.unknown and not Core.force_transactions_clear(f.binding),"recoverable constructed refusal leaves existing debt known and pending")
        f.guard_ok=true
        local accepted,reason,sequence=f:publish()
        check(accepted==true and reason==nil and Identity.compare(sequence,highest)==1 and f.binding.last_submit==f.serial
            and #f.binding.pending==2 and count(f,"submit")==2,"adapter can use the same unspent serial when its constructed owner callback recovers")
    end
    for _,bad in ipairs({"0","01","18446744073709551616",1,"9007199254741000"}) do case() do
        local f=fixture();f:fill(1);f.serial=bad;local before=#f.calls
        check(f:publish()==false and #f.calls==before and f.stopped,"invalid or regressed measured serial never reaches SDK")
        check(#f.binding.pending==1 and not f.binding.unknown,"a refused new serial cannot erase known old debt")
    end end
    case() do
        local f=fixture();local ids=f:fill(3);f.current_body=nil;f.stopped=true
        for _,i in ipairs({3,1,2}) do
            local row=f.api.receipt(ids[i])
            check(row.sequence==ids[i] and f.calls[#f.calls].body==f.body,"every known slot can be inspected on the original body after stop/body clearing")
        end
        for i=1,3 do
            check(f.api.acknowledge(ids[i])==true and f.calls[#f.calls].body==f.body,"ordered cleanup uses the original body independently of current ownership")
        end
        check(Core.force_transactions_clear(f.binding) and f.binding.sequence==nil and count(f,"acknowledge")==3,"all three exact ACKs are required for clean transport")
    end
    case() do
        local f=fixture();local ids=f:fill(3);local before=#f.calls
        check(f.api.acknowledge(ids[2])==false and #f.calls==before,"a non-head ACK is refused before SDK")
        check(f.binding.unknown and #f.binding.pending==3 and not f.binding.pending[1].ack_attempted,"out-of-order ACK preserves every row and marks unknown")
        for _,id in ipairs(ids) do check(f.api.acknowledge(id)==true,"known rows can still be cleaned in order after a protocol violation") end
        check(not Core.force_transactions_clear(f.binding) and f.binding.unknown,"cleaning known rows never erases unknown debt")
    end
    for _,outcome in ipairs({"refused","throw","extra"}) do case() do
        local f=fixture();local ids=f:fill(2)
        f.acknowledge=function()
            if outcome=="throw" then error("ACK may have happened",0) end
            if outcome=="extra" then return table.pack(true,true,"extra") end
            return table.pack(true,false,"not acknowledged")
        end
        pcall(f.api.acknowledge,ids[1])
        local attempts=count(f,"acknowledge")
        check(attempts==1 and f.binding.pending[1].ack_attempted and #f.binding.pending==2 and f.binding.unknown,"non-exact ACK retains attempted head and following debt")
        check(f.api.acknowledge(ids[1])==false and count(f,"acknowledge")==attempts,"an uncertain or refused ACK is never retried")
        check(f.api.receipt(ids[2]).sequence==ids[2] and not Core.force_transactions_clear(f.binding),"known receipts remain readable while unknown ACK debt blocks cleanup")
    end end
    case() do
        local f=fixture()
        f.submit=function(self)
            self.current_body=nil
            return table.pack(true,true,nil,self.next_sequence)
        end
        local ok,why,sequence=f:publish()
        check(ok==true and why==nil and sequence==f.next_sequence,"a late exact admission is returned when ownership changes during submit")
        check(f.afters==1 and f.stopped and f.reason=="Core guard changed during force publication",
            "only the post-submit owner check detects that change and invokes stop")
        check(f.binding.sequence==sequence and #f.binding.pending==1 and not Core.force_transactions_clear(f.binding),"late admission is recorded before the owner post-check")
        check(f.api.receipt(sequence).sequence==sequence and f.api.acknowledge(sequence)==true,"the original body can still drain that late admission")
        check(Core.force_transactions_clear(f.binding),"stop alone does not turn a known fully drained publication into unknown debt")
    end
    for _,bad_result in ipairs({
        function() error("submit may have happened",0) end,
        function() return table.pack(false,"SDK exception") end,
        function() return table.pack(true,true,nil,"01") end,
        function() return table.pack(true,true,nil,"0") end,
        function() return table.pack(true,true,nil,9007199254744003) end,
        function() return table.pack(true,true,nil,"18446744073709551616") end,
        function() return table.pack(true,true,nil,"9007199254744003","extra") end,
        function() return table.pack(true,nil,"ambiguous") end,
        function() return false end,
    }) do case() do
        local f=fixture();local ids=f:fill(2);f:advance();f.submit=bad_result
        check(not pcall(function() f:publish() end),"unknown or malformed admission is not exposed as clean success")
        check(f.binding.unknown and #f.binding.pending==2 and f.binding.sequence==ids[1],"unknown new admission preserves both earlier accepted rows")
        for _,id in ipairs(ids) do check(f.api.acknowledge(id)==true,"earlier known sequences remain available for exact cleanup") end
        check(not Core.force_transactions_clear(f.binding),"draining earlier rows cannot prove unknown admission clean")
    end end
    for _,retired in ipairs({false,true}) do case() do
        local f=fixture();local ids=f:fill(2)
        if retired then check(f.api.acknowledge(ids[1])==true,"prepare retired sequence reuse") end
        f:advance();f.submit=function() return table.pack(true,true,nil,ids[1]) end
        check(not pcall(function() f:publish() end) and f.binding.unknown,"pending or already retired sequence reuse is unknown admission")
        check(#f.binding.pending==(retired and 1 or 2) and f.binding.sequence==ids[retired and 2 or 1],"reuse cannot overwrite or fabricate a pending row")
        check(f.binding.highest_sequence==ids[2] and not Core.force_transactions_clear(f.binding),"exact monotonic high-water mark survives receipt retirement")
    end end
    case() do
        local f=fixture();local ids=f:fill(1);f:advance()
        f.submit=function() return table.pack(true,false,"backend inbox occupied") end
        local ok,why=f:publish()
        check(ok==false and why=="backend inbox occupied" and not f.binding.unknown,"an exact negative SDK tuple is known refusal")
        check(#f.binding.pending==1 and f.binding.sequence==ids[1] and not Core.force_transactions_clear(f.binding),"known refusal preserves earlier debt")
        local before=#f.calls
        check(f:publish()==false and #f.calls==before,"even a known SDK refusal cannot be retried on the same measured serial")
    end
    for _,bad_receipt in ipairs({
        function() error("receipt unknown",0) end,
        function() return table.pack(true,nil,"receipt unavailable") end,
        function() return table.pack(true,{sequence="9007199254744001"},"extra") end,
    }) do case() do
        local f=fixture();local ids=f:fill(2);f.receipt=bad_receipt
        pcall(f.api.receipt,ids[2])
        check(f.binding.unknown and #f.binding.pending==2 and f.binding.sequence==ids[1],"failed receipt lookup cannot erase either pending command")
        check(not Core.force_transactions_clear(f.binding),"malformed receipt retains cleanup debt")
    end end
    case() do
        local f=fixture();local ids=f:fill(1);local before=#f.calls
        check(f.api.receipt("01")==nil and #f.calls==before and f.binding.unknown,"noncanonical receipt lookup is refused before SDK and retains debt")
        check(f.api.receipt(ids[1]).sequence==ids[1],"valid pending receipt remains inspectable after the refused lookup")
    end
    case() do
        local f=fixture();local serial=f.serial
        f.submit=function(self)
            self:advance();self.nested=table.pack(self:publish())
            return table.pack(true,true,nil,self.next_sequence)
        end
        local ok,_,sequence=f:publish()
        check(ok==true and f.nested[1]==false and count(f,"submit")==1,"reentrant submit makes no second SDK call while preserving outer admission")
        check(f.binding.pending[1].serial==serial and f.binding.sequence==sequence and not Core.force_transactions_clear(f.binding),"late admission keeps its original measured serial after reentry")
    end
    case() do
        local f=fixture();local ids=f:fill(2)
        f.acknowledge=function(self)
            self.nested=self.api.acknowledge(ids[2]);return table.pack(true,true)
        end
        check(f.api.acknowledge(ids[1])==true and f.nested==false and count(f,"acknowledge")==1,"reentrant ACK cannot issue another SDK operation")
        check(f.binding.sequence==ids[2] and #f.binding.pending==1 and f.binding.unknown,"outer exact ACK retires only its head while preserving reentry uncertainty")
        check(not Core.force_transactions_clear(f.binding),"reentrant ACK never produces false clean state")
    end
    case() do
        local f=fixture();local ids=f:fill(2)
        f.receipt=function(self,_,sequence)
            self.nested=table.pack(self.api.acknowledge(ids[1]))
            return table.pack(true,{sequence=sequence})
        end
        local row=f.api.receipt(ids[2])
        check(row.sequence==ids[2] and f.nested[1]==false and count(f,"receipt")==1 and count(f,"acknowledge")==0,
            "receipt callback cannot reenter SDK ACK even for the valid oldest pending sequence")
        check(#f.binding.pending==2 and f.binding.sequence==ids[1] and not f.binding.pending[1].ack_attempted,
            "receipt reentry leaves both original rows and the unattempted head intact")
        check(f.binding.unknown and f.unknowns==1 and f.stopped and not Core.force_transactions_clear(f.binding),
            "inflight reentry retains unknown cleanup debt without a native ACK")
    end
    case() do
        local f=fixture();local ids=f:fill(1)
        local ok=pcall(Core.force_transaction_adapter,Identity,f.binding)
        check(not ok and #f.binding.pending==1 and f.binding.sequence==ids[1],"rebinding a transport cannot reset its existing debt")
    end
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests
