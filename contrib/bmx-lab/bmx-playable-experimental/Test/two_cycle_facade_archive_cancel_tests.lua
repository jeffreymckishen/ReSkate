local Support=require("./two_cycle_facade_test_support")
local T={}
function T.run()
    local n=0;local function check(v,why)n+=1;assert(v,why)end
    local f=Support.new(check)    f.on_archive=function()f.manager:request_stop("callback Cancel")end
    check(not f.manager:prepare_next_mount(0),"Cancel in archive callback refuses second preparation")
    check(f.stock_requests==0 and f.aborted,"no stock pulse after cancelled archive")
    check(not f.manager:prepare_next_mount(0),"spent second preparation remains closed")    return {cases=1,assertions=n,constructed=true,native_authority=false}
end
return T