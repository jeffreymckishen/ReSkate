-- These dependencies are already cached by the copied facade's startup list.
local Base=require("./force_stage")
local Context=require("./hop_context")
local Stage={}
local Object={};Object.__index=Object
local states=setmetatable({},{__mode="k"})
function Stage.new(...)
    local original=Base.new(...)
    local self=setmetatable({hop_policy=original.hop_policy,tuning=original.tuning},Object)
    states[self]=original
    return table.freeze(self)
end
function Object:reset(...) return states[self]:reset(...) end
function Object:invalidate_continuity(...) return states[self]:invalidate_continuity(...) end
function Object:admit_measured(...) return states[self]:admit_measured(...) end
function Object:preview(h,body,wheels,samples,controls,...)
    local original=states[self]
    local result=table.pack(original:preview(h,body,wheels,samples,controls,...))
    local ok=pcall(Context.observe_preview,h,body,controls,result[1],result[2])
    if not ok then Context.observer_failed() end
    -- Keep every actual return, including trailing nils. Guard refusal only
    -- revokes the later SDK submission; it never invents a model or acceptance.
    return table.unpack(result,1,result.n)
end
function Object:_adopt(...) return states[self]:_adopt(...) end
return table.freeze(Stage)
