-- Fitted anchors and authored collision proxies from our existing supplied-FBX
-- prototype. No game content is included. The installed native pack must match.
local G = {scale = .7737670588235294, com = {0, .9, -.05}}
local s = G.scale
local function scaled(x,y,z) return {x*s,y*s,z*s} end
G.wheel_radius = .34*s
G.wheelbase = 1.203956057050485*s
G.front_axle = scaled(0,.33993130346462175,.6019780285252407)
G.rear_axle = scaled(0,.3399312125684516,-.6019780285252407)
G.bottom_bracket = scaled(0,.4009181147792979,-.13677059002727915)
G.steering_pivot = scaled(0,.9602538008020781,.3685461188163388)
G.steering_axis = {0,.9601195908265842,-.279589648075517}
G.left_grip = scaled(.33457504536745686,1.2319480593290573,.3406239453545827)
G.right_grip = scaled(-.33457504173973396,1.2319480453628473,.34062398104089797)
G.pedals = {scaled(.084980725506,.211285091841,.011246842761),
    scaled(-.084980725506,.590551321670,-.284787818885)}
G.blueprints = {"reskate/bmx/frame","reskate/bmx/fork","reskate/bmx/rear_wheel",
    "reskate/bmx/front_wheel","reskate/bmx/cranks","reskate/bmx/handlebars",
    "reskate/bmx/left_pedal","reskate/bmx/right_pedal"}
local r = G.wheel_radius-.03-.005
G.capsules = {
    {a={0,G.front_axle[2]-.005,G.front_axle[3]},b={0,G.front_axle[2]+.005,G.front_axle[3]},radius=r},
    {a={0,G.rear_axle[2]-.005,G.rear_axle[3]},b={0,G.rear_axle[2]+.005,G.rear_axle[3]},radius=r},
    {a=scaled(0,.45,-.30),b=scaled(0,.60,.20),radius=.12*s},
    {a=G.right_grip,b=G.left_grip,radius=.055*s},
    {a=scaled(0,.73,-.31),b=scaled(0,.73,-.09),radius=.10*s},
    {a={-.12,.89,-.305},b={.12,.89,-.305},radius=.16},
    {a={0,.97,-.30},b={0,1.20,-.15},radius=.18},
    {a={0,1.30,.135},b={0,1.50,.135},radius=.16},
}
-- The original combined bike/rider model. It is proposed tuning, not mesh mass
-- or BMX Streets physics. These values must be qualified in the native trial.
G.mass, G.inertia = 106, {26,32,10}
return G
