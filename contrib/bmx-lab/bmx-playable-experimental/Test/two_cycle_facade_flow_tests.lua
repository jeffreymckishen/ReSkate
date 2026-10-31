local Support=require("./two_cycle_facade_test_support")
local T={}
function T.run()
    local n=0;local function check(v,why)n+=1;assert(v,why)end
    local f=Support.new(check)
    local admitted=math.floor(f.now)-700
    check(f.manager:prepare_next_mount(0,admitted),"actual facade archives then arms one504 request")
    check(f.gear_admission_at==admitted and f.old.gear_admission_at==nil,"original intent timestamp reaches existing Core admission and is restored after the call")
    check(f.archives==1 and f.stock_requests==1,"single old-owner preparation transaction")
    check(not f.manager:next_mount_ready(),"pending504 cannot advance")
    f.done504=true;f.state=504;f.old.phase="done"
    check(f.manager:next_mount_ready(),"new acknowledged504 is required")
    check(not f.manager:second_preflight_ready(admitted+1),"proof requires the original immutable intent timestamp")
    for _=1,3 do
        local ok,attempt=f.manager:second_preflight_ready(admitted)
        check(ok and attempt==2,"fresh old-owner NEW504 ACK proof is reusable before request only")
    end
    check(f.core_count==1 and f.archives==1 and f.stock_requests==1,"proof reads never allocate/archive or repeat Y")
    check(f.manager:request_mount(0),"actual facade issues private successor then fresh admission")
    check(f.marker_limit==2 and f.marker_session==2,"actual second admission marker preserves experimental two-attempt scope")
    check(f.marker_arm==admitted and f.marker_admitted==admitted,"actual facade startup and Core arm preserve the original second intent time")
    check(not f.manager:second_preflight_ready(admitted),"second native request closes terrain proof permanently")
    for _=1,80 do f.manager:step(16)end
    check(f.core_count==2 and f.old.retired,"second Core instantiated only after retirement")
    check(not f.manager:request_mount(0),"third actual facade request cannot reset VM attempt")
    local legacy=f.Runtime.new({}, {qualification_only=true})
    check(not legacy:request_mount(0),"legacy facade cannot bypass experimental consumed VM")
    local order={};for i,v in f.events do order[v]=order[v]or i end
    check(order.archive100<order.stock504 and order.archive504<order.retire and order.retire<order.newmarker,
        "production facade preserves archive/stock/retirement/marker ordering")    local expired=Support.new(check)
    local expired_at=math.floor(expired.now)
    check(expired.manager:prepare_next_mount(0,expired_at),"one original preparation before expiration")
    expired.done504=true;expired.state=504;expired.old.phase="done";expired.now=expired_at+60000
    check(not expired.manager:second_preflight_ready(expired_at),"expired original timestamp cannot refresh proof")
    check(not expired.manager:request_mount(0) and expired.core_count==1 and expired.stock_requests==1,
        "expiry refuses before successor construction or any repeated stock request")
    local unknown=Support.new(check)
    local unknown_at=math.floor(unknown.now)
    check(unknown.manager:prepare_next_mount(0,unknown_at),"one preparation before unknown ready callback")
    unknown.done504=true;unknown.state=504;unknown.old.phase="done"
    unknown.on_ready=function()error("constructed unknown cleanup result")end
    check(not unknown.manager:second_preflight_ready(unknown_at),"unknown private proof is not a retry")
    check(not unknown.manager:request_mount(0) and unknown.core_count==1 and unknown.stock_requests==1,
        "unknown proof permanently closes second successor admission")
    return {cases=3,assertions=n,constructed=true,native_authority=false}
end
return T