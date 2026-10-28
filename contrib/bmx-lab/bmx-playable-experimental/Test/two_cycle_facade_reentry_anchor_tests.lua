local Support=require("./two_cycle_facade_test_support")
local T={}
function T.run()
    local n=0;local function check(v,why)n+=1;assert(v,why)end
    local f=Support.new(check)
    f.old.stop_at=2000
    check(f.manager:prepare_next_mount(0),"second preparation admitted")
    f.done504=true;f.state=504;f.old.phase="done"
    f.on_marker=function()check(not f.manager:request_mount(0),"nested Mount cannot admit another owner")end
    check(not f.manager:request_mount(0),"reentry in new-marker callback closes outer admission")
    check(f.aborted and f.core_count==1 and f.old.retired,"no successor after nested admission callback")
    check(f.old.stop_at==2000,"original stopped cycle watchdog anchor is never rewritten")
    check(not f.manager:request_mount(0),"spent private epoch cannot retry after reentry")
    return {cases=1,assertions=n,constructed=true,native_authority=false}
end
return T
