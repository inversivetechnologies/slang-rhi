-- Transforms for the scene system: position, rotation (a quaternion {x, y, z, w}) and a
-- uniform scale. Scene files write rotations as Euler angles in degrees: [pitch, yaw, roll]
-- (about x, y, z), applied roll first, then pitch, then yaw -- so a lone yaw turns a thing
-- about the vertical, as everywhere else in the examples.

local T = {}

function T.qmul(a, b)
    return {
        a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
        a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
        a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
        a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
    }
end

function T.qrotate(q, v)
    local tx = 2 * (q[2] * v[3] - q[3] * v[2])
    local ty = 2 * (q[3] * v[1] - q[1] * v[3])
    local tz = 2 * (q[1] * v[2] - q[2] * v[1])
    return {
        v[1] + q[4] * tx + q[2] * tz - q[3] * ty,
        v[2] + q[4] * ty + q[3] * tx - q[1] * tz,
        v[3] + q[4] * tz + q[1] * ty - q[2] * tx,
    }
end

local function axisAngle(x, y, z, degrees)
    local half = math.rad(degrees) / 2
    local s = math.sin(half)
    return { x * s, y * s, z * s, math.cos(half) }
end

-- [pitch, yaw, roll] in degrees to a quaternion.
function T.fromEuler(e)
    e = e or { 0, 0, 0 }
    return T.qmul(axisAngle(0, 1, 0, e[2] or 0), T.qmul(axisAngle(1, 0, 0, e[1] or 0), axisAngle(0, 0, 1, e[3] or 0)))
end

-- The turn about the vertical, in radians, of a rotation (for what only turns about y:
-- the splats).
function T.yawOf(q)
    local f = T.qrotate(q, { 0, 0, 1 })
    return math.atan(f[1], f[3])
end

T.identity = { position = { 0, 0, 0 }, rotation = { 0, 0, 0, 1 }, scale = 1 }

-- A scene file's transform ({ position, rotation (degrees), scale }) to a transform.
function T.fromSpec(spec)
    spec = spec or {}
    local p = spec.position or { 0, 0, 0 }
    return {
        position = { p[1] or 0, p[2] or 0, p[3] or 0 },
        rotation = T.fromEuler(spec.rotation),
        scale = spec.scale or 1,
    }
end

-- `child` placed in `parent`'s frame.
function T.compose(parent, child)
    local p = T.qrotate(parent.rotation, {
        child.position[1] * parent.scale, child.position[2] * parent.scale, child.position[3] * parent.scale,
    })
    return {
        position = { parent.position[1] + p[1], parent.position[2] + p[2], parent.position[3] + p[3] },
        rotation = T.qmul(parent.rotation, child.rotation),
        scale = parent.scale * child.scale,
    }
end

function T.apply(t, v)
    local p = T.qrotate(t.rotation, { v[1] * t.scale, v[2] * t.scale, v[3] * t.scale })
    return { t.position[1] + p[1], t.position[2] + p[2], t.position[3] + p[3] }
end

return T
