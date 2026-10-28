local Support=require("./two_cycle_facade_test_support")
local T={}
function T.run()
    local n=0;local function check(v,why)n+=1;assert(v,why)end
    local f=Support.new(check)    check(f.manager:prepare_next_mount(0),"actual facade archives then arms one504 request")
    check(f.archives==1 and f.stock_requests==1,"single old-owner preparation transaction")
    check(not f.manager:next_mount_ready(),"pending504 cannot advance")
    f.done504=true;f.state=504;f.old.phase="done"
    check(f.manager:next_mount_ready(),"new acknowledged504 is required")
    check(f.manager:request_mount(0),"actual facade issues private successor then fresh admission")
    check(f.marker_limit==2 and f.marker_session==2,"actual second admission marker preserves experimental two-attempt scope")
    for _=1,80 do f.manager:step(16)end
    check(f.core_count==2 and f.old.retired,"second Core instantiated only after retirement")
    check(not f.manager:request_mount(0),"third actual facade request cannot reset VM attempt")
    local legacy=f.Runtime.new({}, {qualification_only=true})
    check(not legacy:request_mount(0),"legacy facade cannot bypass experimental consumed VM")
    local order={};for i,v in f.events do order[v]=order[v]or i end
    check(order.archive100<order.stock504 and order.archive504<order.retire and order.retire<order.newmarker,
        "production facade preserves archive/stock/retirement/marker ordering")    return {cases=1,assertions=n,constructed=true,native_authority=false}
end
return T