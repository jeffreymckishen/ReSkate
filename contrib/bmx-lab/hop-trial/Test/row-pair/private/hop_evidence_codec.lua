-- TEST-ONLY pure cost proxy. Production Codec bytes are preserved in _real.
-- New-row encoding, decoded values and all non-fault calls delegate unchanged.
local Real=require("./hop_evidence_codec_real")
local Control=require("./hop_pair_fault_control")
local Proxy={};for key,value in pairs(Real) do Proxy[key]=value end
function Proxy.wire_bytes(wire)
    local value,why=Real.wire_bytes(wire);local mode=Control.mode()
    if mode and type(wire)=="table" and wire[12]==true then
        Control.hit("wire")
        if mode=="wire_nil" then return nil,"injected paired wire preflight failure" end
        if mode=="wire_oversize" then return 12289 end
        if mode=="wire_nan" then return 0/0 end
        if mode=="wire_string" then return "not a byte count" end
    end
    return value,why
end
function Proxy.state_bytes(row)
    local value,why=Real.state_bytes(row);local mode=Control.mode()
    if mode and type(row)=="table" and row.paired==true then
        Control.hit("state")
        if mode=="state_nil" then return nil,"injected paired state preflight failure" end
        if mode=="state_budget" then return value+524288 end
        if mode=="state_fractional" then return value+.5 end
        if mode=="state_negative" then return -1 end
    end
    return value,why
end
return table.freeze(Proxy)
