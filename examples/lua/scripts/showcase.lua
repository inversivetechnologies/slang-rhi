-- The examples in one window: the scenes in assets/scenes/, one after another -- rigid body
-- physics with a player, Gaussian splats, a lit scene combined with the
-- splats and SDF shapes by depth, and SDF compositions raymarched from a cache. Each is a
-- scene file (built by lib/scene/: entities, prefabs, systems and a render graph), shown by
-- the scene viewer (lib/scene-viewer-mode.lua).
--
--   Left / Right arrows     previous / next scene (as Page Up / Page Down)
--   1 .. 9                  jump to a scene
--   Steam Controller LB/RB  previous / next scene
--   V                       show everything / meshes / splats / SDFs / depth buffers
--   Tab                     hide / show the insets
--   O                       2D overlays (ShaderToy shaders in a panel): none, each in turn
--   Escape                  the pause menu: resume, settings (resolution, fullscreen, max
--                           splats, shadow quality), quit
--   everything else         the scene's: see the README's table of scenes
--
-- Edit this script, a scene or prefab file, or any of the shaders while it runs; they
-- reload when saved.

config = {
    title = "Showcase",
    features = { "rasterization" }, -- the meshes and the splats rasterize
}

-- The scenes in this order; any others in assets/scenes/ follow.
local ORDER = {
    "physics.scene",
    "splats.scene",
    "composite.scene",
    "many-lights.scene",
    "sdf-benchmark.scene",
    "sdf-gallery.scene",
}

local viewer = rhi.include("lib/scene-viewer-mode.lua")(function(details)
    rhi.set_title("Showcase | " .. details)
end, ORDER)

function init()
    viewer.init()
    viewer.on_enter()
end

function update(time, dt) viewer.update(time, dt) end

function on_key(key, action, mods)
    if viewer.menu_key(key, action, mods) then return end -- the pause menu first
    if action == input.PRESS and (key == keys.RIGHT or key == keys.LEFT) then
        viewer.step(key == keys.RIGHT and 1 or -1)
        return
    end
    for i = 1, math.min(viewer.count(), 9) do
        if action == input.PRESS and key == keys[tostring(i)] then
            viewer.show(i)
            return
        end
    end
    viewer.on_key(key, action, mods)
end

function on_mouse_button(button, action, mods) viewer.on_mouse_button(button, action, mods) end
function on_mouse_move(x, y) viewer.on_mouse_move(x, y) end
function on_scroll(x, y) viewer.on_scroll(x, y) end
function on_resize(width, height) viewer.on_resize(width, height) end

function on_controller_button(slot, button, pressed)
    -- The scene first: the player takes most buttons.
    if viewer.on_controller_button(slot, button, pressed) then return end
    if not pressed then return end
    if button == buttons.RB then
        viewer.step(1)
    elseif button == buttons.LB then
        viewer.step(-1)
    end
end
