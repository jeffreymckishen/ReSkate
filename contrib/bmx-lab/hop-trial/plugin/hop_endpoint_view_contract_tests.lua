-- CONCRETE PROFILE4 endpoint tests. All author execution UNRUN.
-- Root binds exact reviewed producer/View source in a separate fresh fixture.
-- A view is a lazy reference, never an expanded Codec row array or copied payload.
local View=require("./hop_endpoint_view")
local Fixture=require("./hop_pair_sdk_fixtures")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local minus_zero=-1/math.huge
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function same(a,b)
        if type(a)~=type(b) then return false end
        if type(a)~="table" then return a==b and (type(a)~="number" or a~=0 or 1/a==1/b) end
        for k,v in pairs(a) do if not same(v,rawget(b,k)) then return false end end
        for k in pairs(b) do if rawget(a,k)==nil then return false end end;return true
    end
    local function frozen(value)
        if type(value)=="table" and not table.isfrozen(value) then for _,v in pairs(value) do frozen(v) end;table.freeze(value) end
        return value
    end
    local function row(kind,label,first,last,count,first_at,last_at,critical)
        return frozen({kind=kind,data={call=label,sequence=label=="A" and "1" or "2",user=0},
            first_call=first,last_call=last,repeats=count,first_at_ms=first_at,last_at_ms=last_at,
            critical=critical==true,incomplete=false})
    end
    local function opened(rows)
        local cursor,why=View.open(rows);check(type(cursor)=="table","valid immutable rows open: "..tostring(why))
        check(type(cursor.next)=="function" and type(cursor.lookup)=="function","explicit conditional cursor seam")
        return cursor
    end
    local function exact(view,original,call,at)
        check(type(view)=="table" and view.row==original and view.call_id==call,"endpoint is original immutable row reference plus exact call ID")
        check(view.row.data==original.data and same(view.at_ms,at),"payload is not copied and endpoint time presence/sign is exact")
        check(view.row.kind==original.kind and view.row.critical==original.critical and view.row.incomplete==original.incomplete,"classification comes from original row")
    end
    local function known(cursor,expected)
        for _,item in ipairs(expected) do
            local value,why=cursor:next();check(why==nil,"known iteration does not invent uncertainty: "..tostring(why))
            exact(value,item.row,item.call,item.at)
        end
        local value,why=cursor:next();check(value==nil and why==nil,"known endpoint iteration terminates without inventing interiors")
    end
    local function rejects(rows,why)
        local cursor,reason=View.open(rows);check(cursor==nil and type(reason)=="string" and #reason>0,why.." must refuse at open")
    end
    local function duplicate_refuses(rows,collision)
        local cursor,why=View.open(rows)
        if cursor==nil then check(type(why)=="string" and #why>0,"duplicate refusal has a reason");return end
        local refused=false
        for _=1,#rows*2+1 do
            local item,reason=cursor:next()
            if reason~=nil then check(item==nil and type(reason)=="string","duplicate refuses instead of yielding conflicting fact");refused=true;break end
            if item==nil then break end
            check(item.call_id<collision,"colliding known call is never yielded as an unambiguous endpoint")
        end
        check(refused,"duplicate known IDs refuse before misleading chronology, even if data matches")
    end
    case("one pair interleaves with B by global call ID",function()
        local a,b=row("lease","A",1,3,2,10,30),row("lease","B",2,2,1,20,20)
        local rows=frozen({a,b});local cursor=opened(rows)
        known(cursor,{{row=a,call=1,at=10},{row=b,call=2,at=20},{row=a,call=3,at=30}})
        check(#rows==2 and a.repeats==2,"no Codec output expansion or mutation")
    end)
    case("two interleaved pairs merge around a later changed singleton",function()
        local a,b,x=row("lease","A",1,3,2,10,30),row("lease","B",2,5,2,20,50),row("lease","X",4,4,1,40,40)
        local rows=frozen({a,b,x});local cursor=opened(rows)
        known(cursor,{{row=a,call=1,at=10},{row=b,call=2,at=20},{row=a,call=3,at=30},{row=x,call=4,at=40},{row=b,call=5,at=50}})
        check(rows[1]==a and rows[2]==b and rows[3]==x,"input remains original first-call order")
    end)
    case("absent and signed-zero endpoint times are not filled or sorted as clocks",function()
        local a,b=row("lease","A",1,3,2,nil,minus_zero),row("lease","B",2,2,1,0,0)
        known(opened(frozen({a,b})),{{row=a,call=1},{row=b,call=2,at=0},{row=a,call=3,at=minus_zero}})
        check(a.first_at_ms==nil and 1/a.last_at_ms==-math.huge,"original presence and sign survive")
    end)
    case("existing repeats2 has exact endpoints without an invented middle",function()
        local a=row("lease","A",1,4,2,100,10);local rows=frozen({a});local cursor=opened(rows)
        known(cursor,{{row=a,call=1,at=100},{row=a,call=4,at=10}})
        local unknown,why=cursor:lookup(2);check(unknown==nil and why=="UNKNOWN","missing global call is not inferred as a row occurrence or global absence")
    end)
    case("sparse legacy repeats3 exposes endpoints and UNKNOWN interior",function()
        local a,b,d=row("lease","A",1,5,3,10,50),row("body","B",2,2,1,20,20),row("body","D",4,4,1,40,40)
        local rows=frozen({a,b,d});local cursor=opened(rows)
        local middle,why=cursor:lookup(3);check(middle==nil and why=="UNKNOWN_INTERIOR","one opaque interior count does not invent its call, data membership or time")
        local inside,reason=cursor:lookup(2);check(reason==nil,"a known other-row endpoint inside the numeric span remains known");exact(inside,b,2,20)
        local outside,unknown=cursor:lookup(6);check(outside==nil and unknown=="UNKNOWN","no completeness certificate means no global absence claim")
        known(cursor,{{row=a,call=1,at=10},{row=b,call=2,at=20},{row=d,call=4,at=40},{row=a,call=5,at=50}})
        check(a.repeats==3 and a.first_call==1 and a.last_call==5,"exact legacy count/range is retained, not rewritten to two occurrences")
    end)
    case("contradictory known endpoint collision refuses before that call",function()
        local a,b,x=row("lease","A",1,3,2,10,30),row("body","B",2,2,1,20,20),row("lease","X",3,3,1,31,31)
        local rows=frozen({a,b,x});duplicate_refuses(rows,3)
        local cursor,why=View.open(rows)
        if cursor then
            local item,reason=cursor:lookup(3)
            check(item==nil and type(reason)=="string" and #reason>0,"lookup must refuse duplicate endpoints rather than silently return the first conflicting row")
        else check(type(why)=="string" and #why>0,"open may refuse duplicate endpoints before lookup") end
    end)
    case("even identical duplicate endpoint IDs are not deduplicated into facts",function()
        local a,b=row("lease","A",1,1,1,10,10),row("lease","A",1,1,1,10,10)
        duplicate_refuses(frozen({a,b}),1)
    end)
    case("malformed singleton and endpoint metadata cannot fabricate views",function()
        rejects(frozen({row("lease","A",1,3,1,10,30)}),"repeats1 with distinct first/last calls")
        rejects(frozen({row("lease","A",1,1,1,minus_zero,0)}),"singleton time endpoints disagree in zero sign")
        rejects(frozen({row("lease","A",1,1,1,nil,0)}),"singleton first time absent but last present")
        rejects(frozen({row("lease","A",1,1,1,0,nil)}),"singleton first time present but last absent")
        rejects(frozen({row("lease","A",1,1,2,10,10)}),"two occurrences with only one global call ID")
        rejects(frozen({row("lease","A",1,2,3,10,20)}),"count exceeds global call range")
    end)
    case("lookup is a bounded reference query and does not consume next",function()
        local a,b=row("lease","A",1,3,2,10,30),row("lease","B",2,2,1,20,20)
        local rows=frozen({a,b});local cursor=opened(rows)
        local last,why=cursor:lookup(3);check(why==nil,"known pair endpoint lookup");exact(last,a,3,30)
        local first,reason=cursor:next();check(reason==nil,"lookup leaves traversal at first endpoint");exact(first,a,1,10)
        local unknown,other=cursor:lookup(100);check(unknown==nil and other=="UNKNOWN","outside retained endpoints is not an asserted absence")
        check(table.isfrozen(a) and table.isfrozen(a.data) and rows[1]==a,"no payload clone, input sorting or thaw")
    end)
    case("input row and class caps stay2176 total2048 regular128 critical",function()
        local rows={};for i=1,2176 do rows[i]=row("lease","A",i,i,1,nil,nil,i>2048) end;frozen(rows)
        local cursor=opened(rows)
        for i=1,2176 do local item,why=cursor:next();check(why==nil,"legal maximum reference input");exact(item,rows[i],i,nil) end
        check(cursor:next()==nil and #rows==2176,"no larger decoded array is created")
        local excessive={};for i=1,2177 do excessive[i]=row("lease","A",i,i,1,nil,nil,i>2048) end
        rejects(frozen(excessive),"2177 input rows")
        local ordinary={};for i=1,2049 do ordinary[i]=row("lease","A",i,i,1) end;rejects(frozen(ordinary),"2049 regular input rows")
        local critical={};for i=1,129 do critical[i]=row("lease","A",i,i,1,nil,nil,true) end;rejects(frozen(critical),"129 critical input rows")
    end)
    case("new marked SDK pair keeps exact absent-first and present-last references",function()
        local a=Fixture.logical(Fixture.lease_state(),1,3,2,true);a.last_at_ms=16;frozen(a)
        local b=Fixture.logical(Fixture.capture_state("capturing"),2,2,1);b.first_at_ms=0;b.last_at_ms=0;frozen(b)
        local rows=frozen({a,b});local cursor=opened(rows)
        known(cursor,{{row=a,call=1},{row=b,call=2,at=0},{row=a,call=3,at=16}})
        check(a.paired==true and rawget(a,"first_at_ms")==nil and a.last_at_ms==16,"marker never invents a missing endpoint timestamp")
        check(b.data.report_debt==true and b.data.capturing==true and rawget(b,"paired")==nil,"known capture debt and legacy classification remain unchanged")
    end)
    case("mutable input refuses without freezing or copying caller trees",function()
        local immutable=row("lease","A",1,1,1,0,0);local outer={immutable}
        local value,why=View.open(outer);check(value==nil and type(why)=="string" and not table.isfrozen(outer),"mutable outer array is refused without freezing")
        local data={call="A",sequence="1",user=0}
        local partial=table.freeze({kind="lease",data=data,first_call=1,last_call=1,repeats=1,critical=false,incomplete=false})
        value,why=View.open(table.freeze({partial}))
        check(value==nil and type(why)=="string" and not table.isfrozen(data),"mutable subtree is refused without freezing or payload replacement")
        check(data.call=="A" and data.sequence=="1" and partial.data==data,"caller fields and references are unchanged")
        local mutable_row={kind="lease",data=table.freeze({call="A"}),first_call=1,last_call=1,repeats=1,critical=false,incomplete=false}
        value,why=View.open(table.freeze({mutable_row}))
        check(value==nil and type(why)=="string" and not table.isfrozen(mutable_row),"mutable row is refused without freezing")
    end)
    check(cases==12,"complete concrete12-case endpoint-view matrix")
    return {cases=cases,assertions=assertions,native_actions=0,implementation_qualified=false}
end
return table.freeze(Tests)
