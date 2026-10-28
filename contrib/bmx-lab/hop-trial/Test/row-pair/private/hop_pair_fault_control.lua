-- TEST ONLY: bounded pure cost-fault controls, never an SDK/runtime module.
local C={};local mode=false;local wire_hits,state_hits=0,0
function C.arm(value) assert(type(value)=="string");mode=value;wire_hits=0;state_hits=0 end
function C.clear() mode=false end
function C.mode() return mode end
function C.hit(which) if which=="wire" then wire_hits+=1 else state_hits+=1 end end
function C.status() return table.freeze({mode=mode,wire_hits=wire_hits,state_hits=state_hits}) end
return table.freeze(C)
