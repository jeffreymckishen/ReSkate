# Wheel contact prototype checkpoint

This branch preserves an unfinished measured-wheel contact prototype. It is not a playable release and is not merged into BMX.

The focused steering suite currently FAILS its added 120 mm curb traversal at 1.25 m/s with one-step delayed commands. A fixed 14-ray lower-arc stencil admits a measured wheel penetration beyond the unchanged 100 mm limit. Ordinary steering and the earlier landing cases execute before that failure; the complete suite does not pass.

The next implementation measures both top and wall facets, constructs a locally witnessed convex edge, and couples at most two contact patches per wheel through the existing body and two rotor degrees of freedom. Finite queries cannot prove arbitrary native topology or continuous sweep coverage. Unknown or inconsistent measured geometry remains unavailable. No force, torque, penetration, input, lifetime or cleanup limit is raised.

The failed source, outputs and diagnostic runs remain preserved under the development evidence folder. Production admission remains false. Passing source or constructed tests will not establish native riding or BMX Streets parity.
