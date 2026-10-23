local Fixture = require("./fixture")
local diagnostic = Fixture.new(reskate, {
    id = "LuaEquipmentInterruption_20261023_v1",
    run_id = "69817dc1-c897-40aa-8920-b9a17d7496ed",
})

reskate.on("tick", function() diagnostic:update() end)
reskate.menu.page("Equipment interruption", function(ui)
    ui:warn("Intentional fall diagnostic. Stock equipment only; no BMX or automatic recovery.")
    ui:note("Fresh empty storage is required. Choose ONE mode, close the menu, and keep slot 0 neutral.")
    local status = diagnostic:status()
    if not status.used then
        if ui:button("arm_baseline", "A: interrupt board baseline") then diagnostic:arm("baseline") end
        if ui:button("arm_post_terminal", "B: interrupt acknowledged mount settling") then diagnostic:arm("post_terminal") end
    end
    ui:info("Phase", status.phase)
    ui:info("Verdict", status.verdict)
    ui:info("Detail", status.detail)
    ui:info("Cleanup resolved", tostring(status.cleanup_resolved))
    ui:note("Wipeout acceptance only queues a request. Coverage needs an observed fall and failed transition.")
    ui:note("A stopped diagnostic keeps ticking the production adapter for its original cleanup and deadlines.")
end)
reskate.on("unload", function() diagnostic:unload() end)
