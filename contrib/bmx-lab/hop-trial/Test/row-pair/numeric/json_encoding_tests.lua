-- Only the existing whitelisted suite receives the frozen JSON helper argument.
-- The dependency has no helper global and uses no test-runner API itself.
local Tests=require("./hop_integral_wire_tests")
return table.freeze({run=function(runner) return Tests.run(runner) end})
