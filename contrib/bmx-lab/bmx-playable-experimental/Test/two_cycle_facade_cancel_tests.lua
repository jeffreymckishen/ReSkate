local Support=require("./two_cycle_facade_test_support")
local T={}
function T.run()
    local n=0;local function check(v,why)n+=1;assert(v,why)end
    local f=Support.new(check)    check(f.manager:prepare_next_mount(0),"second preparation admitted")
    f.done504=true;f.state=504;f.old.phase="done"
    f.on_marker=function()f.manager:request_stop("callback Cancel")end
    check(not f.manager:request_mount(0),"Cancel during new-marker callback refuses successor admission")
    check(f.aborted and f.core_count==1 and f.old.retired,"old pointer retirement cannot swallow Cancel into a new owner")
    check(not f.manager:request_mount(0) and f.archives==1,"cancelled private epoch cannot be retried")    return {cases=1,assertions=n,constructed=true,native_authority=false}
end
return T