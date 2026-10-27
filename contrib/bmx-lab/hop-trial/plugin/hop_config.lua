-- This source package cannot mount. Only an explicitly reviewed staged copy
-- may change admission, phase and run identity; caps are fixed review inputs.
return table.freeze({
    schema=1,
    admission_enabled=false,
    phase="P0",
    run_id="unreviewed",
    source_commit="062db162248d6b21c686f588924e0abc5954e99c",
    slot=0,
    ride_window_ms=1500,
    caps=table.freeze({force=6000,speed=3,torque=2000,vertical_speed=3}),
    hop_strength=.25,
    mass=106,
    max_hop_attempts=1,
})
