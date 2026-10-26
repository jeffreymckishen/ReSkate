-- IDs/names: Extension/Skater/skater_skeleton.h and plugin_api_world.cpp.
-- These are requested identifiers, not actor identity or a coherent pose.
local rows={
    {id=1,name="root",parent=0,alias="root"},
    {id=7,name="hips",parent=1,alias="hips"},
    {id=47,name="right_arm",parent=46},
    {id=48,name="right_fore_arm",parent=47},
    {id=49,name="right_hand",parent=48,alias="right_hand"},
    {id=276,name="left_arm",parent=275},
    {id=277,name="left_fore_arm",parent=276},
    {id=278,name="left_hand",parent=277,alias="left_hand"},
    {id=8,name="right_up_leg",parent=7},
    {id=9,name="right_leg",parent=8},
    {id=10,name="right_foot",parent=9},
    {id=341,name="left_up_leg",parent=7},
    {id=342,name="left_leg",parent=341},
    {id=343,name="left_foot",parent=342},
}
for _,row in ipairs(rows) do table.freeze(row) end
return table.freeze(rows)
