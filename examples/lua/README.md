# Lua examples

`example-lua` is a host application that runs Lua scripts on top of slang-rhi. It opens a
single window on a single graphics API (Vulkan unless told otherwise). The host owns the
window, the device, the swapchain and the frame loop; a script decides what gets
created and drawn, and reacts to input. Scripts and shaders reload while the program runs,
so most iteration happens without a rebuild.

All examples are scripts, in `scripts/`:

| Script | What it shows |
| --- | --- |
| `showcase.lua` | every scene in `assets/scenes/` in one window, one after another: the physics with a player, the splats, the depth composite, cached SDFs; ShaderToy shaders as 2D overlays over any of them (the scene viewer, in the showcase's order and with its keys) |
| `physics.lua` | rigid body physics on Jolt: a ball, a ramp, dominoes, a box pyramid and a tower, and a player character to smash them, steered with a Steam Controller the way Darksiders is -- the host simulates and draws, instanced |
| `surface.lua` | clearing the window |
| `scene.lua` | a lit 3D scene: a GPU-generated spherified cube, a cube and a floor, with a point light, realtime shadow mapping and a second camera composited into the corner -- built as a render graph the host runs without Lua |
| `shader-toy.lua` | ShaderToy-style compute shaders blitted to the window |
| `splat.lua` | Gaussian splatting with compute shaders: loads `assets/gsplats/skull.ply` (1.9 million splats), projects, sorts and draws them every frame |
| `fusion.lua` | the scene, the splats and a raymarched SDF composition in one picture: each rendered with its own depth buffer, combined per pixel by depth; shadows between all of them |
| `sdf-cache.lua` | an SDF composition raymarched from its DAG or from a cache baked into 3D textures, with GPU timings of both |
| `scenes.lua` | the scene viewer: scenes described in JSON (`assets/scenes/`), built from entities, components and prefabs (`assets/prefabs/`) by the scene system (`lib/scene/`) |

## Layout

```
examples/lua/
  example-lua.cpp      the host
  physics.h/.cpp       rigid body physics for the host, on Jolt Physics
  splat-lod.h/.cpp     levels of detail for Gaussian splats, built when a PLY is loaded
  audio.h/.cpp         sound for the host, on miniaudio
  README.md
  scripts/             runnable scripts, one per example
    lib/               Lua modules used by scripts (rhi.include), not run on their own
      scene/           the scene system: JSON, entities, the loader, systems, the renderer
    behaviors/         Lua behaviors that scene entities run (spin, burst, player)
  shaders/             every shader, shared by all scripts
    common/            Slang libraries: math, quaternions, transforms, SDFs, splines, the
                       `time` builtin (time.slang), ...
    mesh/              the vertex format, and mesh generators (spherified-cube)
    scene/             the scene's lighting and shadows (scene-common, shadow, lit,
                       shadow-lookup)
    splat/             Gaussian splatting (ply, splat-common, preprocess, render,
                       lod, clip, shadow-casters, shadow-select, shadow, lighting)
    sort/              GPU sorting (bitonic)
    sdf/               SDF compositions: smooth booleans (smooth-ops), the DAG evaluator
                       (sdf-dag), placement in the world (sdf-world), and the
                       raymarching pass (raymarch)
    post/              full-screen passes (composite, depth-composite, crosshair,
                       ssao and ssao-apply: ambient occlusion and indirect light)
    shader-toy/        the ShaderToy framework (shader-toy.slang) and the toys
    ui/                2D user interface: rectangles and text (ui), the bitmap font (font)
  tools/               make-font.py: generates shaders/ui/font.slang
  assets/              data files the scripts load (gsplats/skull.ply, audio/timelapse.mpeg)
    scenes/            scene files (*.scene: JSON with comments) for the scene viewer
    prefabs/           prefabs (*.prefab, the same format): entities that scenes use and
                       override
    overlays/          2D overlays (*.overlay, the same format): ShaderToy shaders in a
                       panel, over any scene (O)
```

**How paths resolve:**

- **Shaders:** scripts name shaders relative to `shaders/`, e.g. `"scene/lit.slang"`. A path
  is looked up next to the script first, so a script can also keep private shaders
  beside it.
- **Includes:** `#include "..."` is resolved relative to the including file, then
  relative to `shaders/`. Shaders in any folder can therefore use the libraries, e.g.
  `#include "common/sdfs.slang"`.
- **Lua modules:** `rhi.include` paths are relative to the script.
- **Assets:** `rhi.load_ply` paths are looked up next to the script, then in `assets/`.

## Running

```
example-lua                        # the showcase, on Vulkan
example-lua scene                  # scripts/scene.lua
example-lua showcase               # scripts/showcase.lua
example-lua path/to/my.lua         # any script
example-lua --api d3d12 scene      # pick the graphics API
example-lua --help                 # usage, APIs and the list of examples
```

A name is looked up as `scripts/<name>.lua`.
In Visual Studio, `example-lua` is the startup project and runs the showcase.

### Graphics API

The API is the first of:

1. **`--api <name>`** on the command line.
2. **`config.device`** in the script.
3. **`vulkan`**.

Names are case-insensitive: `d3d11`, `d3d12`, `vulkan`, `metal`, `cpu`, `cuda`, `wgpu`. If
the chosen API is unavailable, or lacks a feature the script requires, the program says so
and exits. It doesn't fall back to another API.

### The showcase

The showcase is the [scene viewer](#the-scenes): the scene files in `assets/scenes/`, one at
a time, in this order: the physics, the splats, the depth composite, the SDF benchmark,
the SDF gallery (and any other scene files after them). O puts a
[2D overlay](#2d-overlays) over whichever scene is shown: the ShaderToy shaders Controller
and 2D SDFs.

| Input | Action |
| --- | --- |
| Left / Right arrow, Page Up / Page Down | previous / next scene |
| `1` .. `9` | jump to a scene |
| Steam Controller LB / RB | previous / next scene |
| V | show everything / the meshes / the splats / the SDFs / the depth buffers (/ the ambient occlusion / the indirect light / the bodies' motion vectors, with the effects on) |
| Tab | hide or show the insets |
| O | 2D overlays: none, Controller, 2D SDFs |
| Escape, Steam Controller Menu | the [pause menu](#the-pause-menu) |
| F11 | toggles fullscreen |
| everything else | the scene's: see [the scenes](#the-scenes) |

#### The pause menu

Escape (or the Steam Controller's Menu button) pauses the showcase, the scene viewer or any
of the standalone scripts, and opens a menu over it: **Resume**, **Settings** and **Quit**. While it is open the scene
waits: its behaviors and cameras don't update, its physics doesn't step, its sounds pause,
and the shaders' `time` stops, so everything animated by it holds still too.

| Setting | Choices | |
| --- | --- | --- |
| Resolution | the monitor's video modes from 800 x 600 | the window's size; with fullscreen, the monitor's video mode |
| Fullscreen | Off, On | fullscreen on the primary monitor, at the resolution |
| Max splats | 250,000 .. 2,000,000 | the splats' budget: the levels of detail fit what is drawn to it (a scene's own `splatBudget`, if lower, still holds) |
| Shadow quality | Low (256), Medium (512), High (1024), Ultra (2048) | the shadow maps' texels per cube face; the scene (or script) is loaded again with them |
| Ambient occlusion | GTAO, Off, SSAO | [GTAO or SSAO](#ambient-occlusion-and-indirect-light): darker where surfaces are close to others; GTAO by default |
| Indirect light | Off, On | [SSGI](#ambient-occlusion-and-indirect-light): light bounced from the surfaces seen nearby |
| Effects quality | Half, Mixed, Full | the resolution SSAO and SSGI are computed at: both at half; AO at full and GI at half; both at full |

Each script shows the settings it has:

| Script | Settings |
| --- | --- |
| `showcase.lua`, `scenes.lua` | all seven |
| `fusion.lua` | resolution, fullscreen, max splats, shadow quality |
| `physics.lua`, `scene.lua` | resolution, fullscreen, shadow quality |
| `splat.lua` | resolution, fullscreen, max splats |
| `sdf-cache.lua`, `shader-toy.lua`, `surface.lua` | resolution, fullscreen |

| Input | Action |
| --- | --- |
| Up / Down, D-pad | choose |
| Left / Right, D-pad | change a setting |
| Enter, Space, A | pick a button; a setting's next choice |
| Escape, B | back a page; from the first, resume |
| mouse | point to choose; click a button, or a setting's left half (back) or right half (forward) |

- **Saved:** every change applies at once and is saved to
  `%LOCALAPPDATA%/slang-rhi-lua-settings.json` (`$HOME` elsewhere), and the next run (or
  reload) starts with it. Delete the file to go back to the defaults.
- **Files:** `scripts/lib/pause-menu.lua` (the menu), `scripts/lib/settings.lua` (the
  settings, their file and choices), `scripts/lib/ui.lua` and `shaders/ui/` (drawing).
- **In a script of your own:** one call at the end of the script, after its callbacks:

  ```lua
  rhi.include("lib/pause.lua").install {
      only = { "resolution", "fullscreen", "splatBudget" }, -- default: the first two
      onPause = function(paused) end,  -- e.g. pause its music
      apply = function(values) end,    -- after init, and when max splats changes
  }
  ```

  It wraps the script's `update`, `draw` and input callbacks. While the menu is open,
  `update` isn't called and the input goes to the menu. The menu is drawn from `draw`,
  which runs after the graph, so it shows over either kind of script. A new shadow quality
  reloads the script (`rhi.reload`); `settings.shadowFaceSize()` gives the size to build
  shadow maps with.
- **F11** still toggles a borderless fullscreen at the monitor's current mode.

- **Title:** the window title shows the scene, its entities and systems, and its keys.
- **Splats:** a scene with splats loads them (about a second for the 454 MB file, once its
  levels of detail are cached) each time it is shown.
- **Other examples:** the lit scene (`scene.lua`), the ShaderToy shaders Circle and Ocean
  (`shader-toy.lua`), and the examples the scenes started from (`physics.lua`,
  `splat.lua`, `fusion.lua`, `sdf-cache.lua`) still run on their own.

### The depth composite

`example-lua fusion`. The showcase shows it as a scene: `composite.scene`.

| Input | Action |
| --- | --- |
| Drag with the left mouse button | orbit the camera |
| Mouse wheel | zoom |
| V | show: combined / mesh only / splats only / SDFs only / the depth buffers |
| L | splats lit by the point light / as captured (only shadowed) / only the light reaching them, white to black (to see the shadows) |
| J / K | every blend radius of the SDF composition ÷1.25 / ×1.25 (down to hard booleans) |
| `[` / `]` | splat size |
| `,` / `.` | splat budget ÷1.25 / ×1.25 (see the splats) |
| `/` | tint the splats by level of detail |
| Tab | hide or show the second camera's square in the lower right corner (meshes, SDFs and splats, as in the main view) |
| the scene's keys | change the scene as in its own mode (subdivision, radius, light) |

How it works is described in [Example: combining passes by
depth](#example-combining-passes-by-depth).

### The scenes

`example-lua scenes`, or the showcase (in its own order): the scene files in
`assets/scenes/`, one at a time, built by the [scene system](#the-scene-system).

| Input | Action |
| --- | --- |
| Page Up / Page Down | previous / next scene |
| V | show everything / the meshes / the splats / the SDFs / the depth buffers (/ the ambient occlusion / the indirect light / the bodies' motion vectors, with the effects on) |
| Tab | hide or show the insets |
| O | 2D overlays (`assets/overlays/`): none, then each in turn |
| everything else | the scene's: its behaviors (below), its orbit camera (drag, wheel), M to mute its sounds |

Each scene stands for one of the examples; its keys come from behaviors in the scene.

| Scene | Example | | Keys |
| --- | --- | --- | --- |
| `physics.scene` | `physics.lua` | the ramp, the dominoes, the pyramid, the tower, the player | the player's; B drop boxes; P pause, T slow motion, R reset |
| `splats.scene` | `splat.lua` | a grid of skulls carved per pixel by moving shapes, with music | `,` `.` budget, `/` LOD tint, `[` `]` size, L lighting, C clip mode, M mute |
| `composite.scene` | `fusion.lua` | meshes, the skull's splats and an SDF sculpture merged by depth, a second camera in the corner | the splats' (as above, but C), J K blend |
| `sdf-benchmark.scene` | `sdf-cache.lua` | a turning spiral of 64 shapes around a core, 129 nodes, cached | C DAG / cache / cache error, `[` `]` resolution, B benchmark, J K blend, Space stop the camera |
| `sdf-gallery.scene` | | three SDF sculptures and an arch, baked into one cache | as `sdf-benchmark.scene` |

Some details differ from the examples, which still run on their own:

- **SDF benchmark:** its shape count is fixed by the file, not changed by keys.
- **Splat grid:** so is its grid's size.
- **Physics:** R loads the whole scene again rather than only the bodies.

#### 2D overlays

The ShaderToy shaders 2D SDFs and Controller (`shader-toy.lua` runs them over the whole
window) are 2D overlays: O shows one, framed in a panel, over any scene, and goes on to the
next, then none. Each is a file in `assets/overlays/`, `<name>.overlay` (JSON with
comments, as scene files are), read by `lib/scene/overlays.lua`:

```jsonc
{
    "name": "2D SDFs",
    "shader": "sdfs2d.slang", // required: in shaders/shader-toy/
    "size": 0.4,              // the panel: this fraction of the window's width and height
    "corner": "top-left",     // or "top-right", "bottom-left", "bottom-right"
}
```

- **Lifetime:** the viewer loads the overlays once; their pipelines, images and time go on
  across scenes. Each scene's graph gets every overlay's passes, after its insets, all off
  but the one shown.
- **Inputs:** ShaderToy's, as `shader-toy.lua` gives them, but for the panel: `iResolution`
  is its size and `iMouse` is in its pixels (from its top left corner). Clicks on the panel
  go to the overlay, not to the scene's camera or behaviors.
- **Errors:** an overlay whose shader doesn't compile shows a dark red panel until it does;
  a file that doesn't load is reported (`[overlay] ...`) and left out.

Saving a scene or prefab file reloads it. A scene that fails to load (bad JSON, an unknown
component or field) says why in the window title, and the viewer goes on.

Missing assets don't stop a scene; each is replaced until it is there (its path is
watched, so the scene reloads when it turns up), with a warning:

| Missing | In its place |
| --- | --- |
| a splat file | a blue checkered cube of splats (`rhi.load_ply`), placed, fitted, clipped and lit as the splats would be |
| a prefab file | a blue checkered box (a `mesh`, `pattern` 3); the instance's components that need the prefab's fields are left out |
| a sound file | nothing: silence |
| a behavior | nothing: the entity runs no behavior |

#### Ambient occlusion and indirect light

Every view of a scene can have screen-space ambient occlusion, by GTAO or SSAO, and
screen-space indirect light (SSGI), switched in the [pause menu](#the-pause-menu) (GTAO
is on by default, SSGI off). They work on whatever the view shows: meshes, SDFs and splats, from
the depth buffers the depth composite merges.

| Pass | |
| --- | --- |
| depth composite | as before, but into a linear texture of the view's size rather than the window |
| effects (`post/ssao.slang`, `effectsMain`) | at the quality's resolution: each pixel's position and normal, rebuilt from the nearest depth, and 12 directions over the normal's hemisphere (cosine-weighted, turned per pixel by a 4 x 4 pattern, and a little more each frame) |
| blur (`blurMain`) | 5 x 5, weighted to similar depths: the pattern's noise averaged out, edges kept |
| temporal (`temporalMain`) | blended with the frames before: the pixel's surface is found where the last frame's camera saw it, and that frame's result there taken 90 to 10, where its depth agrees |
| history (`historyMain`) | the result and its depths, kept for the next frame |
| apply (`post/ssao-apply.slang`) | the image times the visibility, plus the indirect light, into the window (or the inset's texture), filtered up by depth from a smaller resolution |

Each effect at its resolution is a chain of the four effect passes; "Mixed" with both on
has two (AO at full resolution, GI at half), the others one.

- **Temporal accumulation:** every frame turns the samples (by the golden ratio), and the
  temporal pass keeps 90% of the frames before, so each pixel averages about the last ten
  frames, over a hundred samples. To follow the camera, each view keeps its last frame's
  camera (`view.cameraValue`, from the camera system), and the pass reprojects by it.
  What the history saw at a different depth (disoccluded, or something moved in front)
  isn't taken: it starts over from this frame.
- **Motion vectors:** what moves on its own is followed too, so a falling box takes its
  own history with it rather than leaving a trail. The pass finds where the pixel's surface
  was the frame before by the motion of whichever surface is nearest there:
  - **Bodies** (physics, and the visual ones Lua moves, as `spin.lua` does): the host
    keeps each body's previous transform in the group's buffer, and a motion pass per view
    (`scene/motion.slang`, through the mesh system's `addMotion`) draws the bodies again,
    writing each pixel's world-space motion: where its point was minus where it is.
  - **SDFs:** the composition's spin, from its block (`sdfOrigin`, `sdfSpin`) and the
    host's `timeDelta`.
  - **Splats** don't move (their clip shapes do, which changes what is shown, not where).

  V shows the bodies' motion vectors too ("motion vectors": the motion's size per axis,
  a body moving 1 cm a frame at 0.3). A resize or a new graph starts the
  history over too. While the pause menu is open the frames go on accumulating, so a
  paused image settles to its smoothest.
- **Depth-aware upsampling:** at half resolution, each pixel takes the 4 nearest effect
  texels weighted by how near their surface's depth is to its own (a joint bilateral
  upsample), and where none is near, the nearest of them in depth. So the effects don't
  bleed across silhouettes.

- **Occlusion, GTAO** (ground-truth ambient occlusion, Jimenez et al. 2016; the default):
  3 slices a pixel, planes through the view direction turned per pixel and frame. Along
  each, 6 steps each way within 1 unit find the highest horizon the depth buffer has, and
  the arc of sky between the two horizons is integrated against the normal projected into
  the plane, in closed form: the cosine-weighted visibility. It shades the objects'
  own creases and undersides and their contact with the floor, without the halos SSAO
  leaves round foreground objects, for about 0.35 ms more than SSAO at Half.
- **Occlusion, SSAO:** a point a short way (1 unit) along each direction is occluded where
  the depth buffer has a surface in front of it. A surface much nearer the camera than the
  pixel counts less, so that foreground objects don't cast halos on what is behind them.
- **Indirect light:** a point a longer way (2.5 units) along each direction; where the
  direction is blocked, and the surface blocking it faces the pixel, that surface's light
  (from the merged image) arrives by the cosine at the pixel and a falloff with distance.
  It is what the camera sees of the scene, so a surface off screen, or behind another,
  bounces nothing.
- **Tuning:** the radii and strengths are `renderer.EFFECT_PARAMS` in
  `scripts/lib/scene/renderer.lua` (`gtaoPower`: GTAO's visibility raised to it, 1.5;
  `aoStrength`: SSAO's).
- **Seeing them:** V goes on to the ambient visibility and the indirect light alone, when
  they are on. The window title gives the effects' GPU time (all their passes).
- **Cost** at 1600 x 900 on an RTX 3050 Laptop GPU, at Half (D3D12, Vulkan, D3D11):
  GTAO alone 1.0, 1.3, 1.4 ms; SSAO alone 0.7, 0.9, 0.9 ms. With SSGI as well (SSAO), D3D12
  took about 1.1 ms at Half, 3.1 ms at Mixed and 4.2 ms at Full.

### The SDF cache

`example-lua sdf-cache`. The showcase shows it as a scene: `sdf-benchmark.scene`.

| Input | Action |
| --- | --- |
| Drag with the left mouse button | orbit the camera |
| Mouse wheel | zoom |
| V | raymarch the DAG / the cache / show the cache's error |
| `-` / `=` | fewer / more shapes in the composition: 4 to 128 (32 to start) |
| `[` / `]` | cache resolution ÷2 / ×2: 32 to 256 voxels a side (128 to start) |
| B | benchmark: the raymarching's GPU time with the DAG, then the cache; both shown in the title |
| Space | stop or start the camera turning |

The title shows the composition's node count, the cache's size and bake time, and the
raymarching pass's GPU time. How it works is described in [Example: caching an
SDF](#example-caching-an-sdf).

### The splats

`example-lua splat`. The showcase shows it as a scene: `splats.scene`.

| Input | Action |
| --- | --- |
| Drag with the left mouse button | orbit the camera |
| Mouse wheel | zoom |
| `[` / `]` | splat size ÷1.1 / ×1.1 |
| `,` / `.` | splat budget ÷1.25 / ×1.25: the most splats drawn per frame, over all instances (1 million to start, 50,000 to 2,097,152) |
| `-` / `=` | fewer / more instances: a grid of 1 × 1 up to 5 × 5 skulls (3 × 3 to start); the camera backs off to fit them |
| C | clip the splats per pixel by spheres and boxes moving through the grid: carve them out (to start) / keep only what is inside them / off |
| M | mute / unmute the music (`assets/audio/timelapse.mpeg`, looped while this mode shows) |
| `/` | tint the splats by level of detail: grey for the file's own, then blue, green, yellow, orange, red, ... for each level of merged ones |
| F | flip the scene upside down (for captures that aren't y-down) |

How it renders is described in [Example: Gaussian splatting](#example-gaussian-splatting).

### The physics

`example-lua physics`. The showcase shows it as a scene: `physics.scene`. You play a horned, caped warrior with
a big sword, with the camera behind them, in the style of Darksiders.

| Steam Controller | Keyboard and mouse | Action |
| --- | --- | --- |
| Left stick | W A S D | move, relative to the camera (the stick walks to a run) |
| Right stick, right trackpad | drag with the left mouse button | turn the camera |
| A | Space | jump; again in the air: double jump (with a flip); hold while falling after it: glide |
| B | Left Shift | dodge roll, toward the stick (or forward) |
| X | F | sword combo: forehand, backhand, overhead slam. In the air: plunge to the ground, with a shockwave |
| Y | G | launcher: an upward swing that throws what it hits into the air |
| R3 (press the right stick) | Q | toggle aim mode: the camera goes over the right shoulder, a crosshair appears, the character faces where the camera looks and strafes |
| RT | E | throw a fireball (a heavy ball): at the crosshair in aim mode (hold to keep throwing), else straight ahead |
| Gyro | | in aim mode: turning the controller from where it was when aim mode began turns the aim as much, on top of the right stick |
| LT | C | camera back behind the character |
| | Mouse wheel | camera distance |
| View | B | drop a burst of 24 boxes and balls from the sky |
| Menu | R | reset: the bodies and the player back where they started |
| | P | pause the simulation |
| | T | slow motion (a quarter of the speed) |

LB and RB switch the showcase's scenes. The crosshair turns orange over anything that can
move.

How it works is described in [Example: rigid body physics](#example-rigid-body-physics).

### The scene

`example-lua scene`. The depth composite (`fusion.lua`) builds on it.

| Input | Action |
| --- | --- |
| Drag with the left mouse button | orbit the camera |
| Mouse wheel | zoom |
| Up / Down | sphere subdivision +1 / −1 |
| Page Up / Page Down | sphere subdivision ×2 / ÷2 (1 to 128) |
| `+` / `-` | sphere radius |
| Space | pause or resume the light |
| Tab | hide or show the second camera |

The lower right corner shows what a second camera sees. The window title shows the
sphere's parameters. How the scene renders is described in [Example: a scene as a render
graph](#example-a-scene-as-a-render-graph).

## A first script

```lua
config = { title = "Hello" }

function draw(frame)
    frame:clear(0.2, 0.4, 0.8)
end
```

Save it anywhere and run `example-lua path/to/hello.lua`. Change the color, save, and the
window updates.

## How a script runs

1. **Load.** The host runs the script's top level. This is where `config` and the callback
   functions are defined. GPU resources can't be created yet (there is no device).
2. **Device and window.** The host reads `config`, then creates the device, the window and
   its surface. (To pick the API, the host first runs the script's top level once on its
   own to read `config.device`, so keep the top level free of side effects.)
3. **`init()`** is called once the device exists. Create pipelines and resources here.
4. **Every frame**: input events are delivered (`on_key`, `on_mouse_move`, ...), then
   `update(time, dt)`. Then the [render graph](#render-graphs) runs, if the script set one,
   followed by `draw(frame)`.
5. **`shutdown()`** is called when the program exits, and before a reload replaces the
   script.

All callbacks are optional. A script with neither a render graph nor `draw` presents
nothing.

### config

```lua
config = {
    title = "My example",            -- window title; the API and GPU are appended
    device = "vulkan",               -- graphics API (default); --api overrides it
    features = { "rasterization" },  -- required device features
    width = 640, height = 360,       -- initial window size
}
```

- **`device`**: the graphics API, see [Graphics API](#graphics-api).
- **`features`**: slang-rhi feature names as returned by `IRHI::getFeatureName` (e.g.
  `rasterization`, `ray-tracing`, `ray-query`). `surface` is always required. Anything that
  draws (`frame:clear`, `frame:draw`) needs `rasterization`, which the CUDA and CPU
  backends don't have.
- **Reloading**: `config` is read only at startup. A change to it needs a restart.

### Callbacks

| Function | Called |
| --- | --- |
| `init()` | after the device is created, and after each reload |
| `update(time, dt)` | every frame; `time` is seconds since start, `dt` the time since the last frame |
| `draw(frame)` | every frame, after `update`, while the window is visible |
| `shutdown()` | at exit and before a reload |
| `on_key(key, action, mods)` | a key changes; compare with `keys.*` and `input.PRESS/RELEASE/REPEAT` |
| `on_mouse_button(button, action, mods)` | a mouse button changes; `input.MOUSE_LEFT/RIGHT/MIDDLE` |
| `on_mouse_move(x, y)` | the pointer moves; window coordinates in pixels, origin top-left |
| `on_scroll(x, y)` | the mouse wheel moves |
| `on_resize(width, height)` | the window's framebuffer changes size (0 x 0 when minimized) |
| `on_controller_button(slot, button, pressed)` | a Steam Controller button changes; compare with `buttons.*` |
| `on_controller_connect(slot, connected)` | a Steam Controller connects or disconnects |

## Resources: `rhi`

Create resources in `init()` (or later). Store them in variables: a resource is freed once
the script no longer references it.

### Pipelines

```lua
-- Compute: one entry point.
local toy = rhi.compute_pipeline("my-shader.slang", "mainCompute")

-- Render: vertex + fragment entry points, and the vertex layout.
local draw = rhi.render_pipeline {
    shader = "my-mesh.slang",
    vertex = "vertexMain",          -- default "vertexMain"
    fragment = "fragmentMain",      -- default "fragmentMain"
    layout = { { "POSITION", "rgb32f" }, { "COLOR", "rgb32f" } },
    topology = "triangles",         -- triangles | triangle-strip | lines | line-strip | points
    depth = false,                  -- test and write the target's depth buffer
    format = nil,                   -- color target format; default: the window's
    blend = "none",                 -- none | alpha | premultiplied | additive | accumulate
}
```

- **Paths**: shader paths are relative to `shaders/` (or to the script, if the file is
  there); see [Layout](#layout).
- **`layout`**: describes one interleaved vertex stream. Each attribute's offset follows the
  one before it, and the stride is the sum of all of them. Leave `layout` out for shaders
  that generate their vertices from `SV_VertexID`.
- **`blend`**: how the pipeline's output combines with what the target holds:

  | Value | Result |
  | --- | --- |
  | `none` | replaces it |
  | `alpha` | `color * a + target * (1 - a)` |
  | `premultiplied` | `color + target * (1 - a)`, for shaders that output color already multiplied by alpha |
  | `additive` | `color + target` |
  | `accumulate` | rgb: `color + target`; alpha: `min(a, target a)`, to sum values and keep a nearest distance in one target |
- **`format`**: the color format the pipeline writes. Leave it out to draw into the
  window. Set it to a texture's format to draw into that texture (see [Drawing into a
  texture](#drawing-into-a-texture)).
- **`depth = true`**: the pipeline tests and writes a depth buffer (32-bit float, closer is
  smaller, compare less). By default the host keeps one depth buffer per destination: one
  for the window and one for each texture drawn into, each the size of its destination.
  A render graph pass can use a depth target of the script's own instead (see
  [Depth targets](#depth-targets)). Without `depth`, depth testing is off.
- **`format = "none"`**: no color output at all, for depth-only passes; implies
  `depth = true`. The fragment shader returns nothing (`void`), and may `discard`.
- **Caching**: the host caches pipelines. Asking for the same one again returns the
  existing pipeline, including after a script reload, so it isn't recompiled.
- **Fields**:
  - `pipeline.built` is `true` once the pipeline has compiled.
  - `pipeline.version` counts successful builds. It goes up each time a hot reload
    succeeds, so a script can redo work that depends on the shader (see [Generating
    geometry on the GPU](#generating-geometry-on-the-gpu)).
  - `pipeline.thread_group_size` is `{x, y, z}` from `[numthreads]` (compute only).
- **Compile failures**: a pipeline that fails to compile is still returned. It just doesn't
  run, and it is retried whenever one of its files is saved.

### Textures and buffers

```lua
local target = rhi.render_target("rgba32f")       -- always the size of the window
local small = rhi.render_target("rgba16f", 0.3)   -- always 0.3 times the window's size
local square = rhi.render_target("rgba16f", 0.3, "square") -- 0.3 x the window's height, both sides
local depth = rhi.depth_target()                  -- a depth buffer the size of the window
local tex = rhi.texture { width = 256, height = 256, format = "rgba32f" }
local volume = rhi.texture { width = 64, height = 64, depth = 64, format = "r16f" } -- 3D
local linear = rhi.sampler { filter = "linear", address = "clamp" } -- for Sample()
local vb = rhi.vertex_buffer { 0, 0, 0,  1, 0, 0,  ... }  -- floats
local buf = rhi.buffer(1024)                      -- 1024 bytes, zeroed
local buf2 = rhi.buffer { 1, 2, 3, 4 }            -- floats
```

- **Formats**: `r32f`, `rg32f`, `rgb32f` (vertex layouts only), `rgba32f`, `rgba16f`,
  `r16f`, `rgba8`, `r32u`.
- **3D textures:** `depth` makes `rhi.texture` a 3D texture (`Texture3D` and
  `RWTexture3D` in shaders). It can be read, written and sampled, but not drawn into or
  blitted, and its contents start out undefined: whatever uses it writes it first.
  `texture.depth` gives its depth.
- **Samplers:** `rhi.sampler{ filter = "linear" | "point", address = "clamp" | "wrap" }`
  is bound like any parameter, to a `SamplerState`, for shaders that filter textures with
  `Sample` / `SampleLevel` rather than `Load` them.
- **Textures** can be read and written by shaders, drawn into, and blitted. They start out
  zeroed. `texture.width` and `texture.height` give their size. A render target is
  reallocated when the window resizes, and its old contents are lost.
- **Square targets:** `"square"` as the third argument of `rhi.render_target` (the second of
  `rhi.depth_target`) makes both sides `scale` times the window's height, for an image
  that keeps its aspect whatever the window's shape. The side is rounded to the nearest
  pixel, as `math.floor(height * scale + 0.5)` (at least 1).
- **`rhi.buffer`** creates a read/write structured or byte-address buffer.
  `rhi.vertex_buffer` is only for vertex input.

#### Depth targets

`rhi.depth_target([scale = 1 [, "square"]])` creates a 32-bit float depth buffer that follows
the window size (times `scale`), like a render target.

- **Writing:** a render graph pass draws depth into it when given `depth_target = it`.
- **Reading:** any shader can read it, as a `Texture2D<float>` of depth values in [0, 1]
  (`z / w` of the clip position).
- **Clearing:** it is cleared by the first pass that uses it each frame, or by a pass's
  `clear`, as the host's own depth buffers are.

A depth buffer the script owns can therefore be read after it is drawn: by a later
pass's shader, to combine images by depth, or for any screen-space effect.

### Other

| Call | |
| --- | --- |
| `rhi.device()` | the backend's name, e.g. `"Vulkan"` |
| `rhi.time()` | seconds since start |
| `rhi.set_title(text)` | sets the window title; the backend and GPU are appended |
| `rhi.set_paused(paused)`, `rhi.paused()` | stops (or restarts) the shaders' `time` and the physics; `update` and input still run, with real time. A reload unpauses |
| `rhi.show_pointer(shown)` | keeps the mouse pointer visible whatever Escape and clicks do (a menu's); `false` hides it over the window again |
| `rhi.display()` | `{ width, height, fullscreen, modes }`: the window's size, whether it is fullscreen, and the primary monitor's video modes (`{ {w, h}, ... }`, distinct, smallest first) |
| `rhi.set_display{ width, height, fullscreen }` | sizes the window, or with `fullscreen`, switches the primary monitor to that video mode (the nearest it has) with the window covering it; leaving fullscreen puts the window back where it was. Call it from `update`, not from inside an input callback |
| `rhi.quit()` | closes the window: the program ends after this frame |
| `rhi.reload()` | runs the script again from the start before the next frame, as saving it does |
| `rhi.include(path)` | runs a Lua file (relative to the script) and returns its result; saving that file reloads the script |
| `rhi.window_srgb()` | `true` if the window's format encodes sRGB itself (as `frame.srgb`, but usable in `init`) |
| `rhi.window_size()` | the window's size in pixels, `width, height` (usable in `init`) |
| `rhi.params{...}`, `rhi.graph()`, `rhi.set_graph(graph)` | see [Render graphs](#render-graphs) |
| `rhi.load_ply(path [, { lod = true }])` | loads a PLY file's vertices into a buffer; see below |
| `rhi.sound(path [, { loop, volume, play }])` | a sound from a file; see [Sound](#sound) |
| `rhi.read_asset(path)` | a text file's contents, looked up as `rhi.load_ply`'s are; the file is watched, so saving it reloads the script (a missing file is an error, but is watched too) |
| `rhi.list_assets(folder [, extension])` | the names of the files in `assets/<folder>` (and in `<folder>` next to the script), sorted |

`rhi.load_ply(path)` reads the vertex element of a binary little-endian PLY file whose
vertex properties are all floats, which is the format Gaussian splatting scenes come in. It
uploads them unchanged, one record per vertex, and returns:

| Field | |
| --- | --- |
| `buffer` | the floats, for a `StructuredBuffer<float>`: vertex `i`'s property at offset `o` is element `i * stride + o` |
| `count` | the number of vertices |
| `stride` | floats per vertex |
| `properties` | the offset of each property by name, e.g. `properties.x`, `properties.opacity` |
| `center`, `radius` | the mean of `x`, `y`, `z`, and the square root of their summed variances, for framing a camera (when the file has `x`, `y` and `z`) |
| `lod` | levels of detail, for a file of Gaussian splats; see below |

Shaders then read whatever properties they need, at offsets the script passes in.

**Missing files.** A file that is missing, or doesn't read as a PLY file, doesn't stop the
script: `rhi.load_ply` warns once and returns a stand-in, a cube of side 1 at the origin
whose faces are 6,144 flat splats in a blue checker (with levels of detail, uncached). Its
`missing` field then says why. The path is watched, so the script reloads once the file
is there. `splat.lua`, `fusion.lua` and the scenes show the cube in the file's place and
say so in the window title.

**Levels of detail.** A file of Gaussian splats (with `x`, `y`, `z`, `scale_0..2`,
`rot_0..3`, `opacity` and `f_dc_0..2`) gets levels of detail automatically, unless the
second argument says `lod = false`. They are merged splats, appended to `buffer` after the
file's `count` records in the same layout, so any shader reads them as it reads the
file's. The file's records are reordered to the tree's order, so that siblings are next
to each other. `lod` then holds:

| Field | |
| --- | --- |
| `count` | all records: the file's splats and the merged ones |
| `nodes`, `levels` | how many merged splats there are, and the tree's depth (the file's splats are level 0) |
| `bounds` | a buffer of a `float4` per merged splat: its bounding sphere (center, radius), in the file's frame |
| `parents` | a buffer of a `uint` per record: its parent's record (`0xFFFFFFFF` at the root) |
| `level` | a buffer of a `uint` per record: its level |
| `seconds` | how long building (or reading) them took |

They are built once per file and cached in the temp directory
(`%TEMP%/slang-rhi-lua-lod/<file>.lod`). The cache is keyed by the file's size and
modification time. For `skull.ply`, the build takes 1.8 s in Release and 11–16 s in Debug,
and reading the cache (and reordering the records) takes 0.5–2 s. How they are built and drawn is in [Levels of
detail](#levels-of-detail).

#### Sound

`rhi.sound(path [, options])` loads a sound: WAV, FLAC or MP3, recognized by its contents
whatever the extension. The path is looked up like `rhi.load_ply`'s: next to the script,
then in `assets/`. It is streamed from disk as it plays, and mixed with any others on the
default audio device. A missing file (or one that doesn't decode) gives `nil` instead, with
a warning; the path is watched, and the script reloads once the file is there.

| Option | Default | |
| --- | --- | --- |
| `loop` | `false` | start over at the end |
| `volume` | 1 | 1 is as recorded; 0 silent |
| `play` | `false` | start playing at once |

| On a sound | |
| --- | --- |
| `sound:play()`, `sound:pause()` | from where it is; it stays where it is |
| `sound:stop()` | pauses, back to the start |
| `sound:seek(seconds)` | from the start |
| `sound.playing`, `sound.position`, `sound.length` | read only; seconds |
| `sound.volume`, `sound.loop` | settable |

- **When it stops:** a sound stops when its handle is collected, so a script reload
  silences the old script's sounds.
- **No audio device:** without one (or if it fails to start), sounds still load and
  answer, silently, and the host says so once. A script runs the same everywhere.
- **Implementation:** `examples/lua/audio.h` and `audio.cpp`, on miniaudio (see
  [Implementation](#implementation)).

The splats (`splat.lua`, `scripts/lib/splat-mode.lua`) play `assets/audio/timelapse.mpeg`
looped while they show, as does the splat scene (`splats.scene`, through a `sound`
component); M mutes it.

`rhi.include` is for sharing Lua code between scripts in different folders. `fusion.lua`
uses it to run `scripts/lib/scene-mode.lua`, the scene that `scene.lua` runs on its own.
`require` works too, but a file loaded with `require` isn't watched for edits.

## Drawing: the `frame`

`draw(frame)` receives the frame being recorded. Operations run in the order they are
called. They target the window's image unless given a `target` texture. The frame is only
valid during `draw`: keeping it and using it later is an error.

| Call | |
| --- | --- |
| `frame.width`, `frame.height` | size of the window image |
| `frame.index` | frames drawn so far |
| `frame.srgb` | `true` if the window's format encodes sRGB itself; if `false`, shaders should apply gamma |
| `frame:clear(r, g, b [, a = 1 [, target]])` | clears the window, or a texture |
| `frame:dispatch(pipeline [, params [, x, y, z]])` | runs a compute pipeline over `x * y * z` threads (default: one per pixel) |
| `frame:draw(pipeline [, options])` | draws with a render pipeline |
| `frame:blit(texture)` | copies a texture onto the window, scaled to fit |

### `frame:dispatch`

`x`, `y` and `z` are thread counts, not group counts. The host divides them by the
shader's `[numthreads]` and rounds up, so the shader should bounds-check if the image size
isn't a multiple of the group size.

### `frame:draw`

```lua
frame:draw(pipeline, {
    vertices = vb,               -- optional vertex buffer
    count = 3,                   -- vertex count; default: what `vertices` holds, else 3
    clear = { r, g, b, a },      -- optional: clear the destination first, else draw over it
    params = { ... },            -- shader parameters
    target = texture,            -- optional: draw into a texture instead of the window
    viewport = { x, y, w, h },   -- optional: the area to draw into, in pixels; default: all of it
})
```

With a `depth = true` pipeline, the destination's depth buffer is cleared the first time it
is used in a frame. It is cleared again after any clear of that destination (`frame:clear`
or a `clear` option). Draws in between share it, so several depth-tested draws occlude each
other.

### Drawing into a texture

Pass `target = texture` to draw into a texture instead of the window. The pipeline's
`format` must match the texture's, or `draw` raises an error. Each draw is its own render
pass, and the host inserts the barriers between passes. So a texture drawn into early in
`draw` can be read by a shader later in the same frame (bind it like any texture).

`viewport` limits a draw to part of the destination. This packs several views into one
texture, like the six faces of the scene's shadow atlas.

### Common patterns

The usual compute pattern renders into a texture, then blits it to the window:

```lua
frame:dispatch(toy, { texture = target, iTime = time })
frame:blit(target)
```

#### Generating geometry on the GPU

A compute shader can write a mesh into a buffer that a render pipeline then draws. Write
the mesh as a plain triangle list into a `RWStructuredBuffer`. The vertex shader reads the
same buffer as a `StructuredBuffer`, indexed by `SV_VertexID`. The render pipeline then
needs no `layout` and no index buffer. The scene does this for its spherified cube:

```lua
-- init(): allocate once, for the largest mesh
generate = rhi.compute_pipeline("mesh/spherified-cube.slang", "generateMain")
mesh = rhi.render_pipeline { shader = "my-mesh.slang", depth = true }
vertices = rhi.buffer(maxVertexCount * 32)

-- draw(): regenerate only when an input changed
if subdivision ~= last.subdivision or generate.version ~= last.version then
    frame:dispatch(generate, { subdivision = subdivision, radius = radius, vertices = vertices },
                   subdivision, subdivision, 6) -- one thread per quad, per face
    last = { subdivision = subdivision, version = generate.version }
end
frame:draw(mesh, { count = vertexCount(subdivision), params = { vertices = vertices } })
```

The host inserts the barriers between the compute write and the vertex read.

- **Allocate once**: allocate the buffer for the largest mesh up front rather than on every
  change. Otherwise each change creates and uploads a new buffer, and the old one lingers
  until Lua's garbage collector frees it.
- **Padding**: keep the vertex struct to `float4`s. A `float3` is padded differently by D3D
  and Vulkan structured buffers.

Small meshes can also be built in Lua and uploaded with `rhi.buffer{ floats... }` in the
same format. The scene builds its cube and floor this way.

## Render graphs

The `frame` API above runs Lua every frame: `draw` issues every dispatch and draw itself.
A render graph is the alternative for anything that doesn't change shape from frame to
frame.

- **Built once:** the script describes the frame (its passes, what each draws, and with
  which parameters) in `init()`.
- **Run natively:** the host runs that description every frame, without calling into Lua.
- **Rebuilt on reload:** reloading the script rebuilds the graph.

```lua
function init()
    local camera = rhi.params { camera = { eye = { 0, 1, -5 }, target = { 0, 0, 0 }, fovY = 0.9 } }
    local view = rhi.render_target("rgba16f", 0.3)

    local graph = rhi.graph()
    local main = graph:render_pass { name = "main", clear = { 0, 0, 0, 1 } }
    main:draw { pipeline = lit, count = 36, params = { cubeBlock, camera } }

    local inset = graph:render_pass { name = "inset", target = view, clear = { 0, 0, 0, 1 } }
    inset:draw { pipeline = litRgba16f, count = 36, params = { cubeBlock, otherCamera } }

    local corner = graph:render_pass { name = "composite", viewport_fraction = { 0.68, 0.66, 0.3, 0.3 } }
    corner:draw { pipeline = composite, count = 3, params = { source = view } }

    rhi.set_graph(graph)
end

function on_scroll(x, y)
    camera.camera = { eye = { 0, 1, -5 + y }, target = { 0, 0, 0 }, fovY = 0.9 } -- next frame uses it
end
```

### Building a graph

| Call | |
| --- | --- |
| `rhi.graph()` | a new, empty graph |
| `graph:render_pass{ name, target, depth_target, color, clear, viewport \| viewport_fraction }` | adds a render pass, run in the order added |
| `pass:draw{ pipeline, count, vertices, params, instances }` | adds a draw to a render pass, run in the order added; `instances` is a number, or a body group (as many as it has bodies, frame by frame) |
| `graph:dispatch{ name, pipeline, params, threads = {x, y, z} \| "window" \| texture, once, timed }` | adds a compute dispatch; `"window"` runs one thread per window pixel, a texture one per texel, both following resizes |
| `rhi.set_graph(graph)` | makes the host run `graph` every frame, before `draw`; `nil` stops it |

- **`render_pass` options:**
  - `target`: a texture to draw into. Leave it out to draw into the window.
  - `depth_target`: a [depth target](#depth-targets) to use as the pass's depth buffer,
    instead of the host's buffer for the target. The pass then leaves its depth there for
    later passes to read.
  - `color = false`: a depth-only pass. It has no color target, only its
    `depth_target`, and its draws use pipelines with `format = "none"`.
  - `clear`: clears the target first (and its depth buffer). For a depth-only pass, any
    `clear` table clears the depth buffer. A pass's `depth_target` is cleared by its
    `clear` even if nothing in the pass is drawn with depth.
  - `viewport` is in pixels. `viewport_fraction` is in fractions of the target's size, so
    it follows window resizes.
- **Depth:** a pass uses its target's depth buffer when any of its draws' pipelines has
  `depth = true`. All draws in one pass should agree on depth.
- **`dispatch` threads:** with `"window"` or a texture, the dispatch's `viewportSize` is
  that size too. Otherwise it is the window's, which a parameter block can override.
- **`dispatch` with `once = true`:** the dispatch runs on the first frame, then again only
  after `node:rerun()` or when its pipeline is rebuilt by a hot reload.

### Changing a graph after init

The graph's shape is fixed, but its values can change. Every handle the building calls
return can be adjusted later, typically from an input handler:

| Handle | Settable |
| --- | --- |
| pass | `enabled`, `clear`, `viewport`, `viewport_fraction`, `timed` |
| dispatch | `enabled`, `threads`, `timed`, and `:rerun()` |

**GPU timing.** A render pass or dispatch created with `timed = true` (or set later) is
timed on the GPU: the host writes a timestamp before and after it, and reads the pair back
three frames later, without waiting. `node.gpu_time` is then its time in milliseconds,
smoothed over frames (a `once` dispatch's is its last run's), or `nil` until the first
measurement arrives. Frame times stop at the display's refresh rate and say nothing below
it; this measures the work itself. A device without timestamp queries says so once, and
leaves `gpu_time` `nil`.
| draw | `count`, `enabled`, `instances` |
| parameter block | any value: `block.name = value`, or `block:set{ ... }` |

### Parameter blocks

`rhi.params{ name = value, ... }` creates a block of named shader parameters, converted
from the Lua values as described in [Shader parameters](#shader-parameters).

- **`params` option:** a draw or dispatch takes one block, a list of blocks and plain
  tables, or one plain table.
- **Order:** blocks are applied in order, so a later block overrides an earlier one.
- **Sharing:** a block is shared, not copied. Changing a value in it changes every draw
  that lists it, from the next frame on. One camera block can serve every draw of a pass.
- **Replacing values:** `block.name = value` replaces that value. To change one field of a
  struct, assign the whole table again.
- **Errors:** a value that doesn't fit its shader parameter is reported once, naming the
  pass. The draw still runs, and the other values are applied.

### Motion without Lua

Nothing in a graph calls Lua, so anything that moves continuously should be computed in
the shaders. The host provides `time` (seconds) to every draw and dispatch that declares
it; see [Shader parameters](#shader-parameters). It counts only while the script isn't
paused (`rhi.set_paused`), so a pause menu stops everything animated by it. The scene computes its light's orbit and
the cube's spin from `time`, and Lua only changes the speeds. Lua then only has to react
to events (input, reloads), never to frames.

A script can still define `draw` alongside a graph, e.g. for overlays. It runs after the
graph, in the same frame.

## Physics

The host has rigid body physics, on Jolt Physics (github.com/jrouwe/JoltPhysics, v5.6.0),
which CMake clones and builds with the example host.

- **The host simulates:** it steps the world every frame and writes each group's
  transforms straight into a GPU buffer.
- **Lua sets up:** a script builds the world and its bodies, then only reacts to input.
- **No Lua per frame:** neither the physics nor the drawing calls into Lua. A script that
  steers a character does so from its own `update`.

| Call | |
| --- | --- |
| `rhi.physics_world{ gravity = {0, -9.81, 0}, max_bodies = 4096 }` | a new world |
| `world:group{ capacity = 256 }` | a group of bodies drawn together, with a GPU buffer for up to `capacity` |
| `group:add{ ... }` | adds a body, see below; returns its index in the group, or `nil` when full |
| `group:clear()` | removes every body of the group |
| `group:set_velocity(i, {x, y, z})`, `group:impulse(i, {x, y, z})` | push body `i` |
| `group:position(i)` | its current position, `x, y, z` |
| `group.count`, `group.capacity`, `group.buffer` | bodies in the group; its size; its transforms (6 `float4`s a body, as `scene/scene-common.slang` reads them: position, rotation, scale, color, and the frame before's position and rotation, for motion vectors) |
| `rhi.set_physics(world)` | makes the host step `world` every frame; `nil` stops it |
| `world.paused`, `world.time_scale`, `world.gravity` | settable |
| `world:character{ ... }` | a character, see below |
| `world:raycast(origin, direction, max_distance)` | the nearest hit: `distance, point, normal, moving` (whether the body hit can move); `nil` if none. Characters are ignored |
| `group:set_transform(i, position [, rotation [, scale]])` | places visual body `i` (and rescales it: half extents, or the radius on all three axes) |

`group:add` takes:

| Field | Default | |
| --- | --- | --- |
| `shape` | `"box"` | `"box"` with `half_extents = {x, y, z}`, or `"sphere"` with `radius` |
| `motion` | `"dynamic"` | `"dynamic"`, `"static"`, `"kinematic"` (moved by its velocity, never pushed), or `"visual"`: no physics at all, only drawn, where `group:set_transform` puts it |
| `position`, `rotation` | origin, none | `rotation` is a quaternion `{x, y, z, w}` |
| `velocity`, `angular_velocity` | 0 | initial |
| `friction`, `restitution`, `density` | 0.5, 0, 1000 | density in kg/m³; with the shape's volume, it gives the mass |
| `color`, `pattern` | grey, 0 | how it is drawn (`pattern` as `Material.pattern` in `scene/lit.slang`) |

**Stepping.** The world steps at a fixed 1/60 s whatever the frame rate: steps accumulate
over frames, at most four per frame. A long frame therefore slows the simulation down
rather than stalling it.

**Characters.** `world:character{ radius = 0.35, height = 1.8, position, max_slope = 50,
mass = 90, strength = 600 }` adds a capsule a script steers: Jolt's `CharacterVirtual`,
with an inner rigid body so that the bodies collide with it too.

- **What it does:** it walks on the bodies, slides along walls, steps up small steps,
  sticks to slopes and won't climb ones steeper than `max_slope` (degrees). It pushes what
  it walks into, with up to `strength` newtons.
- **Each step:** the host moves it before the bodies. Its velocity is its `move`, plus its
  vertical velocity under gravity, plus the velocity of whatever it stands on.

| Field or call | |
| --- | --- |
| `character.move = {x, z}` | the horizontal velocity to move with (m/s), until changed |
| `character:jump(speed)` | sets the vertical velocity on the next step, on the ground or not |
| `character.gravity_scale`, `character.max_fall_speed` | gravity's multiplier; the fastest it falls (0: no limit) |
| `character.position`, `character.velocity` | the feet's position and the velocity; setting the position teleports it |
| `character.on_ground`, `character.ground` | standing on something? `"ground"`, `"steep"`, `"unsupported"` or `"air"` |

**Drawing bodies.**

- **The buffer:** every frame, before the graph runs, the host writes each group's bodies
  into its buffer. Each body takes four `float4`s: position, rotation, the scale that turns
  the unit mesh into the body (its half extents, or its radius), and color with pattern.
- **The draw:** draws with `instances = group` and a unit mesh (`lib/meshes.lua`: a cube from
  −1 to 1, a sphere of radius 1). They draw instance `i` as body `i`, through the
  `bodyVertexMain` entry points of `scene/lit.slang` and `scene/shadow.slang`.
- **Lighting:** bodies are therefore lit and shadowed like the scene's meshes, by the same
  code.

## Example: rigid body physics

`scripts/physics.lua` (in `scripts/lib/physics-mode.lua`; the showcase's `physics.scene`) is a
test scene for the physics, with a player character in it:

- **The chain reaction:** a ball at the top of a ramp rolls down into a row of 14
  dominoes. They topple one after another, and the last falls into a seven-level box
  pyramid.
- **The tower:** beside them stands a tower of 12 layers of three boards, each layer turned
  a quarter turn.
- **The bursts:** Space rains random boxes and spinning balls onto all of it.

**Bodies.** Three groups, each drawn by one instanced draw per pass:

| Group | Bodies | Mesh |
| --- | --- | --- |
| statics | the floor, the ramp and its rails (static) | cube |
| boxes | dominoes, pyramid, tower, dropped boxes | cube |
| balls | the rolling ball, thrown and dropped balls | sphere |
| the player's parts | the figure's boxes (visual) | cube |
| the player's orb | the glow in its hand in aim mode (visual) | sphere |

**The graph:** six shadow passes into its own shadow atlas, then the lit pass into the
window, as in the scene, then the crosshair (`post/crosshair.slang`, alpha-blended, its
pass enabled in aim mode only). The splat and SDF inputs of the shadow lookup are
switched off, and bound to placeholders.

**What Lua does after `init`:** steers and poses the player every frame (below), adds
bodies (fireballs, bursts), clears and re-adds them (reset), and sets `world.paused` and
`world.time_scale`. Every draw follows its group's body count by itself.

### The player

`scripts/lib/player.lua` plays like a third-person action game, Darksiders in particular.
Every frame, in `update`, it reads the controller (or the keyboard), steers the character,
runs the attacks, moves the camera and poses the figure.

- **The body:** a character (`world:character`), 1.85 m tall, with 1.7 times the scene's
  gravity, for snappy jumps of about 1.7 m (1.3 m more with the double jump). The physics
  steps happen in the host; Lua sets `move` and calls `jump`.
- **Moving:** the left stick's direction is taken relative to the camera, and the steered
  velocity follows it quickly on the ground and slowly in the air. The character turns to
  face where it runs. A short window after leaving a ledge still allows a normal jump.
  Holding jump while falling after the double jump glides: `max_fall_speed` drops to
  1.7 m/s.
- **Attacks:** each swing lunges forward a little, and hits once, partway through. It sets
  the velocity of every box and ball in range, in an arc in front of the character, out
  and along the swing. Pressing X during a swing queues the next one of the combo. The
  overhead slam, the launcher and the plunge throw things around in a circle or upward.
  Hits shake the camera.
- **The camera:** it orbits a point that trails the character, closely sideways and
  loosely up and down, so that jumps don't bob the view.
  - **Following:** when the player runs and leaves the camera alone for a moment, it
    eases round behind the character.
  - **Obstacles:** a ray cast from that point pulls it in front of anything in the way,
    and it eases back out.
  - **Aim mode:** blends it over the right shoulder (2.7 m back, 0.8 m to the side, the
    field of view from 55° to 42°).
- **Throwing:** in aim mode, a ray cast from the camera through the crosshair finds the
  target, and the fireball flies from the character's hand to that point. It is a heavy
  ball, so it knocks things over.
- **The figure:** 21 boxes and a sphere, visual bodies in two groups, posed every frame
  with a few quaternions.
  - **Its frames:** hips, torso, head, arms, legs and sword, each relative to the last.
  - **Animations:** a run cycle with a bob and a lean; poses for jumping and gliding; the
    rolls of the dodge and the double jump; the swings. Each swing goes from a wind-up to
    a strike, a follow-through and a recovery.
  - **Drawing:** the host draws it like any other bodies, so it is lit and casts shadows.
- **The gyro:** the Steam Controller's gyro is taken as ±2000°/s over its range, yaw on z
  and pitch on x, as SDL maps the Steam Deck's. The controller tested here read a
  constant offset (−0.147 on x, about 5 rad/s) at rest. So the player tracks the offset
  while not aiming, and subtracts it.
  - **An offset from a base pose:** entering aim mode takes the controller's orientation
    (`controller.quat`) as the base pose. From then on, the aim is the right stick's plus
    the controller's turn since that pose, without limit, except that the total pitch
    stays within the camera's range.
  - **Measuring the turn:** the relative rotation from the base pose turns the controller's
    forward axis. Where that axis points gives the yaw (about the yaw axis) and the
    pitch (toward it). Measured from the orientation itself, it doesn't drift.
  - **Without an orientation:** only "Ibex" firmware reports one. The controller tested
    here doesn't: its `quat` stays the identity. For such a controller, the turn is the
    gyro's rates, added up since aim mode began.
  - **Following the aim:** the camera, the throws and the character's facing all follow
    the combined aim.
  - **Leaving aim mode:** the offset is folded into the camera, so the view stays where
    it was aimed. The next aim mode starts from a new base pose.
  - **Tuning:** the gain (`GYRO_AIM_GAIN`, 1: the aim turns as much as the controller)
    and the axis signs are constants at the top of `player.lua`, untested against real
    motion.

**Cost:** about 8.3 ms per frame (≈120 fps) on an RTX 3050 Laptop GPU, Release, with about
280 bodies, the player running. That covers the physics on the CPU (Jolt's job system uses
all but one core), the player's Lua, and the eight passes.

## Example: a scene as a render graph

`scripts/scene.lua` renders a small scene lit by an orbiting point light with realtime
shadows. A second camera's view is composited into the lower right corner. All of it is
one render graph, built in `init()`:

| File | Role |
| --- | --- |
| `scripts/scene.lua` | runs the scene on its own |
| `scripts/lib/scene-mode.lua` | the scene itself: builds the graph, and handles input |
| `shaders/mesh/mesh-vertex.slang` | the vertex format shared by all meshes |
| `shaders/mesh/spherified-cube.slang` | compute shader that generates the sphere |
| `shaders/scene/scene-common.slang` | the light, object transforms (both animated by `time`), and the shadow atlas layout |
| `shaders/scene/shadow.slang` | shadow pass: writes distances from the light |
| `shaders/scene/lit.slang` | lit pass: shading, attenuation and the shadow lookup |
| `shaders/post/composite.slang` | copies a texture into a viewport, with a border |

The graph's passes, in order:

| Pass | Target | Reads |
| --- | --- | --- |
| generate sphere (dispatch, `once`) | the sphere's vertex buffer | |
| shadow face 0 .. 5 | the shadow atlas, one `viewport` cell each | |
| main camera | the window | the shadow atlas |
| second camera | a `rgba16f` render target, 0.3 × the window | the shadow atlas |
| composite | the window, `viewport_fraction` in the lower right | the second camera's texture |

The passes are composed through the textures they share. The shadow atlas is rendered once
and read by both cameras. The second camera's image is rendered at the size of its corner,
then drawn there by the composite pass.

- **Same shader, two formats:** `lit.slang` is built as two pipelines, because a pipeline
  is built for one target format. One draws into the window, the other into the `rgba16f`
  texture.
- **Gamma:** the second camera's texture holds linear color, and the composite pass
  gamma-encodes it only if the window doesn't (`rhi.window_srgb()`).

**Parameter blocks:**

- **Shared blocks:** the light, the shadow atlas and each camera have a block, shared by
  every draw that needs it.
- **Per-object blocks:** each object has a block with its vertex buffer, transform and
  material.

The draws of one object in the shadow pass, the main camera and the second camera list
the same object block with different camera blocks.

**What Lua does after `init`**, all from input handlers:

| Input | Change |
| --- | --- |
| drag, wheel | `mainCamera.camera = ...` |
| subdivision keys | the generator block's `subdivision`, the dispatch's `threads` and `:rerun()`, the sphere draws' `count` |
| radius keys | the generator block's `radius` and `:rerun()`, the sphere's and marker's transforms |
| Space | the light block's `speed` and `phase` |
| Tab | `enabled` of the second-camera and composite passes |

The light's orbit and the cube's spin are computed in `scene-common.slang` from `time`.
Pausing the light sets its speed to 0 and its phase to where it is now. That keeps it in
place, because the shader computes the angle as `phase + speed * time` with the same clock
as `rhi.time()`.

**The shadows themselves:**

- **The shadow map is a cube.** A point light sees in every direction, so its shadow map
  is six 90° views, one along each axis.
- **The atlas.** The views are stored side by side in one `r32f` texture, 3 × 2 cells of
  512 × 512 texels. Each cell is rendered by its own pass, with that cell as the pass's
  `viewport`.
- **Clearing.** The first of those passes clears the whole atlas to a huge distance, which
  means nothing is in the way.
- **What is stored.** The fragment shader writes the distance from the light. Depth testing
  keeps the nearest surface.
- **Lit pass shading:** diffuse and specular light from the point light, falling off with
  the square of the distance and fading to zero at the light's range.
- **Shadow lookup:** the direction from the light to the pixel picks the cube face and the
  texel. If the stored distance is shorter than the pixel's own distance, something is in
  the way.
- **Soft edges:** 9 neighbouring texels are averaged (a 3 × 3 sample), clamped to the
  face's cell.
- **No self-shadowing:** the lookup point is pushed off the surface along its normal (more
  where the light grazes it), plus a small constant bias. Without this, surfaces would
  shadow themselves in a speckled pattern ("shadow acne").
- **Matching projections:** both passes share the projection code in `scene-common.slang`.
  A direction is projected by `cubeFaceClip` when rendering and by `shadowFaceTexel` when
  looking up, using the same face basis, so the two always agree.
- **The light's marker** is the sphere mesh scaled down. It follows the light
  (`followLight`), is drawn unlit, and is left out of the shadow passes, because the light
  sits inside it.

## Example: Gaussian splatting

`scripts/splat.lua` (the showcase's `splats.scene`) renders a 3D Gaussian splatting scene.
The method is Kerbl et al., "3D Gaussian Splatting for Real-Time Radiance Field Rendering"
(2023). The scene is `assets/gsplats/skull.ply`: 1.9 million Gaussians, each with a position,
rotation, scale, opacity, and degree-3 spherical harmonics for view-dependent color.

| File | Role |
| --- | --- |
| `scripts/splat.lua` | runs it on its own |
| `scripts/lib/splat-mode.lua` | loads the file, builds the render graph, handles input |
| `shaders/splat/ply.slang` | reads splats from the PLY data and places them in the world |
| `splat-lod.h/.cpp` | the host: builds the levels of detail when the file is loaded |
| `shaders/splat/lod.slang` | compute: picks the cut through the levels of detail that fits the splat budget |
| `shaders/splat/clip.slang` | clipping the splats per pixel by a signed distance field, the splats' `clip()` |
| `shaders/splat/preprocess.slang` | compute: projects each splat in the cut, evaluates its color, packs the drawn ones |
| `shaders/sort/bitonic.slang` | compute: sorts the keys |
| `shaders/splat/render.slang` | draws the sorted splats as blended quads |
| `shaders/post/composite.slang` | puts the result on the window |

**Loading.** `rhi.load_ply` uploads the file's floats unchanged (454 MB). The script reads
the property offsets from `properties` and passes them to the preprocess shader as a
`PlyLayout` struct. The shader then reads each splat's fields wherever the file put
them.

**Every frame**, as a render graph built once in `init()`:

1. **Levels of detail** (`shaders/splat/lod.slang`): three dispatches pick this frame's
   cut through the tree, the finest that fits the budget (see [Levels of
   detail](#levels-of-detail)).
2. **Preprocess** (one thread per splat and instance, merged splats included; threads x:
   splats, y: instances):
   - **Level of detail:** a splat goes on only if it is part of this frame's cut.
   - **Covariance:** builds the splat's 3D covariance, `R S Sᵀ Rᵀ` from its rotation and
     scale.
   - **Projection:** projects the covariance to a 2D ellipse on screen through the
     Jacobian of the perspective projection (EWA splatting). It adds 0.3 pixels² so every
     splat covers about a pixel.
   - **Color:** evaluates the spherical harmonics in the direction from the camera.
   - **Culling:** splats behind the camera, off screen, or nearly transparent are skipped.
   - **Outputs:** each drawn splat writes its ellipse (center and two half axes at 3σ,
     from the eigenvectors of the 2D covariance) and its color. It also writes a sort key,
     the negated view depth.
   - **Packing:** a drawn splat takes the next slot from an atomic counter (`drawCount`,
     reset to 0 by a one-thread dispatch first). Its ellipse, its color, which splat and
     instance it is, and its sort key go in that slot. So the drawn splats end up at the
     front, in no order. The buffers hold 2²¹ slots, more than the largest budget.
3. **Pad** (`padMain`): after the drawn splats, up to the next power of two (at least 1024),
   keys that sort last.
4. **Sort** the keys with their slots, on the GPU, with a bitonic sort.
   - **Only the drawn splats:** the sort works on that power of two. Its threads past it
     return at once, and never read what is there. Every longer step would leave the
     sorted front as it is, so the graph's dispatches stay the same whatever the count.
   - **Dispatches:** sorting takes 78 dispatches (for the 2²¹ slots). One sorts each block
     of 1024 in group shared memory. Then, for every longer sequence length, there is one dispatch per long-range
     step, plus one block dispatch for the remaining short-range steps.
   - **Built in Lua:** Lua creates these dispatches as graph nodes in `init()`, each with a
     parameter block holding its step.
5. **Draw** in one draw of six vertices per slot, in sorted order, so back to front.
   - **Quads:** the vertex shader places a quad over the splat's ellipse.
   - **Falloff:** the fragment shader applies the Gaussian falloff.
   - **Blending:** the pipeline blends with `premultiplied` alpha.
   - **Past the drawn splats:** the slots after `drawCount` become zero-area quads.
6. **Composite** the result onto the window.

**Color.** Splats are trained against photos, so their colors are display-space values,
and the reference renderer blends them as such. They are blended here the same way, in an
`rgba16f` texture rather than in the window. If the window encodes sRGB itself, the
composite pass converts to linear first (`decodeGamma`), so the window's encoding gives
back the original values.

**Instances.** Every splat shader places the splats through `shaders/splat/ply.slang`, by
an instance (a buffer of placements: position, yaw and scale) and then by the view's
`model`. The mode's own graph draws a grid of skulls, each turned its own way about its
own center; other graphs (the depth composite) draw one instance, placed by `model`.
`-` and `=` rebuild the instances block and set the per-instance dispatches' `threads`.

**Input** only changes parameter blocks (the view, the budget, the instances) and those
dispatch sizes. The flip is needed because COLMAP-based captures are y-down.

### Levels of detail

**The tree** (`splat-lod.cpp`, built by `rhi.load_ply`):

- **Clusters:** the splats are split top-down, three times per level at the median of
  the longest axis of their centers, so each node has up to eight children. That
  continues down to single splats, the leaves. `skull.ply`'s 1,924,114 splats get
  299,593 nodes, in 8 levels.
- **Merging:** each node is one more Gaussian, merged from its children (leaves or
  nodes). Each child is weighted by its opacity times its area (`s₀s₁ + s₁s₂ + s₀s₂`, from
  its scales).
  - **Shape:** the merged mean and covariance are the children's weighted mean, and the
    weighted sum of their covariances plus their spread around that mean (moment
    matching). The covariance's eigenvectors and eigenvalues give the merged splat's
    rotation and scales.
  - **Opacity:** the children's opacity times area, spread over the merged splat's area,
    but at least the most opaque child's, and at most 0.99.
    - **Why the floor:** the merged Gaussian is wider and softer than the children it
      stands for. Spreading their opacity over all of it alone would let a solid surface
      turn see-through: specks of background in a coarse cut, light leaking through the
      shadow maps.
  - **Color:** every other property, the spherical harmonics among them, is the weighted
    average of the children's.
- **Bounds:** each node also gets a bounding sphere, which contains its children's
  spheres (a leaf's is 3σ of its largest scale), and every record knows its parent.
- **Order:** the file's splats are stored in the order the splits left them, so siblings
  are next to each other, and neighboring GPU threads read the same parent.

**Choosing what to draw: a budget.** The cut is held to a fixed number of splats, over all
instances, and chosen by camera distance. So the frame costs about the same whatever the
view and however many instances there are.

- **Size:** a sphere's size is its radius over the distance to its nearest point, in
  pixels at the camera's focal length. Off screen (a sphere wholly outside the frustum),
  it counts 64 times less, so that what isn't seen gets the coarsest splats.
- **Bins:** sizes are binned on a log scale, 8 bins per doubling, 160 bins in all. A
  file's splat is in bin 0; the root's parent is past the last bin.
- **The cut for bin B:** every splat whose own bin is at most B and whose parent's is
  above B. A child's sphere lies inside its parent's (and if the parent is off screen, so
  is the child), so its bin is never higher. So along every path from the root to a
  file's splat, exactly one splat is in the cut, for every B: no region is drawn twice,
  and none is left out, without any splat looking at another.
- **Counting** (`lodHistogramCameraMain`): one thread per splat and instance adds 1 at its
  own bin and −1 at its parent's. The running sum up to bin B is then the cut's size for
  B. Each group counts in group shared memory first, then adds its counts to the
  histogram once per bin.
- **Picking** (`lodPickMain`): one thread walks the bins, and takes the first B whose cut
  fits the budget: the finest cut that fits. Coarser bins only make smaller cuts.
- **No finer than the view resolves** (`lodFinest`): the pick never goes below the bin of
  a bounds radius of half a pixel (the camera) or one texel (the shadow maps). Finer
  detail costs splats and shows nothing. And a view that needs fewer splats than the
  budget gets a cut that doesn't change with the budget.
- **Drawing** (preprocess): a splat goes on if it is in the cut for that B. The choice
  never leaves the GPU.
- **What it looks like:** `/` tints each splat by its level. The nearest skull's horns
  show the file's splats with level-1 merges; farther skulls go to levels 2 and 3, the
  farther the coarser.
- **Views share the budget by size:** a graph can give a view a share of the budget
  (`addPasses`' `budgetScale`). The depth composite's second camera, a small square, gets
  a tenth.

**Performance.** On an RTX 3050 Laptop GPU, Release, at the default window size, with the
budget at 1 million splats:

| | frame |
| --- | --- |
| one skull, every splat projected, sorted, drawn (before the levels of detail) | 31 ms |
| 1 skull | 12.2 ms |
| 3 × 3 skulls | 15.7 ms (15.2 ms with the resolution floor) |
| 5 × 5 skulls (48 million splats with every detail) | 21.5 ms |
| 5 × 5, zoomed in (12 wheel steps) / out (10 steps) | 21.4 / 22.5 ms |
| 3 × 3, budget 0.41 million / 1.95 million | 10.8 / 24.2 ms |

- **What stays the same:** the frame time doesn't follow the view: zooming in or out
  over the 5 × 5 grid changes it by a millisecond. The budget sets it.
- **What doesn't:** each instance adds about 0.4 ms. The histogram and preprocess still
  run one thread per splat and instance (2.2 million each), most of which only find
  they aren't in the cut. A top-down traversal of the tree would skip whole subtrees
  instead.

The frame time is GPU-bound. The usual next steps, not done here:

- a radix sort in place of the bitonic one
- indirect dispatches and draws sized by `drawCount`, instead of full-size ones whose
  threads past it return at once
- tile-based compute rasterization, as in the paper, in place of blended quads

### Clipping

`splat.lua` (and the showcase's `splats.scene`) cuts the skulls with a signed distance field, per pixel: the splats' equivalent of
`clip()` in a fragment shader (`shaders/splat/clip.slang`). C carves the field's shapes out
of the splats, keeps only what is inside them, or turns it off.

**The field:** a union (min) of spheres and boxes, three `float4`s each in a buffer
(`clipShapes`): center and kind, size and turning speed, movement and its speed. They move
to and fro across the grid and the boxes turn, all computed from `time` in the shaders, so
the field needs no Lua per frame. `clipMode` says what is kept: 0 everything, 1 where the
field is ≥ 0 (outside the shapes), 2 where it is < 0.

**A position per pixel.** A splat's fragment isn't a point on a surface: it is the 3D
Gaussian integrated along the pixel's ray. Its position is taken where the Gaussian is
densest along that ray, which has a closed form:

```
t* = dot(μ − o, Σ⁻¹ d) / dot(d, Σ⁻¹ d),   p = o + t* d
```

with `o` the camera, `d` the pixel's ray, `μ` the splat's center and `Σ` its covariance. For
the flat, surface-hugging splats a capture is made of, `p` lies on the reconstructed
surface. The fragment is then discarded where the field doesn't keep `p`, as `clip()`
would. Every pixel tests its own ray, so the cut follows the field exactly across a
splat, however large: the edge is as sharp as a mesh's, not ragged by whole splats.

**Only the splats across the surface pay.** A signed distance field changes by at most the
distance moved, so a splat whose center is farther from the surface than its 3σ extent is
wholly kept or wholly cut (`clipClassify`).

- **Preprocess:** splats wholly cut away are dropped there, before the sort. Those across
  the surface are flagged (`ProjectedSplat.axis2.w`).
- **Draw:** for a flagged splat, the vertex shader hands its fragments which splat it is
  (one flat value). Those fragments read its center and covariance again, invert the
  covariance and clip. Every other splat draws as before.
- **Why not hand down the splat's data:** passing the center and inverse covariance down
  from every vertex (ten values) cost about 2 ms in `splat.lua` and 6 ms in the depth composite
  even with clipping off. Splat quads are many and tiny, so per-vertex outputs are
  expensive.

**Everything else follows the clip:**

- **The depth pass** (`depthFragmentMain`), for graphs that composite by depth, clips
  alike.
- **Shadows:** the shadow maps clip the same way, along rays from the light, so cut-away
  parts cast no shadow. (`splat.lua` has no light; the depth composite uses the same code
  without a field.)
- **Levels of detail:** a node wholly cut away counts 64 times smaller, as if off screen,
  so the budget isn't spent on it. A node across the surface counts 4 times larger, so
  the cut is finer along the clipped edge. Both keep sizes from growing parent to
  child: a sphere inside one that is cut away is cut away, and one across the surface
  lies in a parent across it.

**Cost** (RTX 3050 Laptop GPU, Release, the 3 × 3 grid, budget 1 million): off 15.5 ms,
carving 16.8 ms, keeping inside 18.4 ms. The depth composite, without a field: 33.2 ms
(32.0 before clipping).

**What the cut shows:** Gaussian splatting reconstructs surfaces, so a cut opens a hollow
shell: the inside of the far wall, and whatever the training left inside. Splats long
along the ray are clipped by their densest point only, which is the same approximation a
hard `clip()` makes on any volume.

## The scene system

The examples above build their worlds and render graphs in code, each its own way. The scene
system (`scripts/lib/scene/`) builds them from data instead. A scene file says what is in
the world; systems turn that into GPU resources, parameter blocks and one render graph,
which handles any mix of meshes, splats and SDFs, any number of cameras, and their shadows
on each other.

| File | |
| --- | --- |
| `lib/scene/json.lua` | a JSON reader that also takes `//` and `/* */` comments and trailing commas |
| `lib/scene/ecs.lua` | the entities and components |
| `lib/scene/transform.lua` | transforms: position, rotation (a quaternion), uniform scale |
| `lib/scene/loader.lua` | scene files to a world: prefabs, children, repeats, schema checks |
| `lib/scene/systems/*.lua` | one per kind of component: light, mesh (and body), sdf, splat, behavior, camera, sound |
| `lib/scene/renderer.lua` | the render graph, from what the systems contribute |
| `lib/scene/scene.lua` | a loaded scene: load, enter, leave, update, input |
| `lib/scene/overlays.lua` | the [2D overlays](#2d-overlays): ShaderToy shaders in a panel, over any scene |
| `lib/pause-menu.lua`, `lib/pause.lua`, `lib/settings.lua`, `lib/ui.lua` | the [pause menu](#the-pause-menu), its wrapper for standalone scripts, the settings it saves, and the 2D drawing it uses |
| `lib/scene-viewer-mode.lua` | the viewer (the showcase; `scenes.lua`) |
| `scripts/behaviors/*.lua` | behaviors: Lua that entities run |

### Entities, components and systems

An **entity** is a number with an optional name. A **component** is a plain table of data
(a mesh, a light, a camera...), at most one of each type per entity. Every entity has a
`transform`. A **system** holds the behavior for one or more component types: it declares
their fields, loads what the entities with them need, and contributes to the frame.

This is an entity-component system in its data model, not in its performance model: a
scene has tens to hundreds of entities, and the per-element work is on the GPU (splats,
LOD), in Jolt (bodies), or in instanced draws. The store is a small Lua table per component
type; queries walk the entities in creation order.

### Scene files

Scenes are `assets/scenes/<name>.scene` and prefabs `assets/prefabs/<name>.prefab` (and
the [2D overlays](#2d-overlays) `assets/overlays/<name>.overlay`): all are JSON with
comments (`//`, `/* */`) and trailing commas allowed. The viewer lists the
`.scene` files; an entity's `"prefab": "floor"` reads `floor.prefab`. (For an editor's
syntax colors, associate the three extensions with JSONC.)

```jsonc
{
  "name": "Depth composite",
  "settings": { "background": [0.015, 0.018, 0.025], "splatBudget": 1000000 },
  "prefabs": { },                        // optional: inline prefabs, before assets/prefabs/
  "entities": [
    { "id": "light", "transform": { "position": [0, 0.4, 0] },
      "light": { "intensity": 9, "range": 14, "orbitRadius": 2.3, "speed": 0.5 } },
    { "id": "floor", "prefab": "floor", "transform": { "position": [0, -1.25, 0] } },
    { "id": "skull", "prefab": "skull", "transform": { "position": [-0.2, -0.4, 1.5], "rotation": [0, -60, 0] } },
    { "id": "domino", "prefab": "domino", "transform": { "position": [3.6, 0.42, 0] },
      "repeat": { "count": 14, "step": [-0.46, 0, 0],
                  "vary": { "mesh": { "color": [[0.9, 0.35, 0.28], [0.3, 0.55, 0.9]] } } } },
    { "id": "camera", "camera": { "controller": "orbit", "target": [0, -0.3, 0.5], "distance": 6.5 } }
  ]
}
```

An entity's keys are component types, plus:

| Key | |
| --- | --- |
| `id` | a name, unique in the scene; children's get their parent's in front (`ramp/rail`), repeats a number after (`domino#2`) |
| `prefab` | the entity starts as this prefab (`assets/prefabs/<name>.prefab`, or the scene's inline `prefabs`); its own keys override it: objects merge key by key, other values replace, children add up. Prefabs can start from prefabs |
| `transform` | `position`, `rotation` ([pitch, yaw, roll] in degrees: roll first, then pitch, then yaw), `scale` (uniform); for children, in the parent's frame |
| `children` | entities placed in this one's frame |
| `repeat` | copies: `count` (n, or [nx, ny, nz]), each moved by `step` per index along each axis (so a plain n is a row along x; [1, n, 1] a column up y), turned by `rotationStep` per copy, and given the values of `vary` (component, field, a list of values) in turn |
| `_...` | a comment, ignored |

**Checks.** Every component is checked against its system's schema (each field's type, a
default, whether it is required). An unknown component or field, a wrong type, or a
missing required field stops the load, with the entity and the field in the message, e.g.
`floor.mesh: unknown field 'colour' (known: color, pattern, radius, shape, size)`.

### Components

| Component | Fields (defaults) | System |
| --- | --- | --- |
| `light` | `color`, `intensity` (9), `range` (14), `orbitRadius` (0), `speed` (0, radians per second), `phase`, `bob` | one point light, orbiting the entity's position; one per scene |
| `mesh` | `shape` ("box" or "sphere"), `size` (a box's, whole: [1, 1, 1]), `radius` (0.5), `color`, `pattern` (0 plain, 1 stripes, 2 checker on the floor, 3 checker on every face) | instanced, lit and shadowed boxes and spheres |
| `body` | `motion` ("dynamic", "static", "kinematic"), `density` (1000), `friction` (0.5), `restitution` (0), `velocity`, `angularVelocity` | a Jolt body for the mesh; without it, the mesh is visual (placed by Lua) |
| `splat` | `file` (required), `fit` (a radius to scale to; 0: as is), `grid` ([nx, nz] copies), `spacing`, `turn` (degrees per copy), `clip` (`mode` "carve" or "keep", `shapes`: spheres and boxes with `position`, `move`, `speed`, `spin`) | Gaussian splats with LOD, lighting, shadows, clipping; one renderer per file, entities as its instances |
| `sdf` | `shape` (required: a node, below), `cache` (0: the DAG; or voxels a side), `sharpness` (8, of soft shadows), `blend` (0: how smoothly the entities' shapes join one another) | all entities' shapes as one composition, raymarched (timed on the GPU), shadowing everything; cached if any asks |
| `camera` | `fov` (50), `controller` ("orbit", "fixed", "player"), `target`, `distance`, `yaw`, `pitch` (degrees), `turn` (degrees per second: an orbit that turns by itself), `inset` (0: the main view; else a square of that fraction of the window's height), `corner` | the views |
| `sound` | `file` (required), `loop` (true), `volume` (1), `autoplay` (true) | played while the scene shows |
| `script` | `file` (required: in `scripts/behaviors/`), `params` | a behavior |

**SDF nodes** (the `sdf` component's `shape`): one primitive or operation, with optional
`position`, `rotation`, `scale` and `color`. Primitives: `{"sphere": r}`,
`{"box": [w, h, d]}`, `{"cube": s}`, `{"ellipsoid": [rx, ry, rz]}`,
`{"capsule": {"radius", "a", "b"}}`, `{"cylinder": {"radius", "height"}}`,
`{"prism": {"sides", "height"}}`. Operations: `{"union": [nodes]}`,
`{"intersect": [nodes]}`, `{"subtract": [a, b]}`, each with an optional `"smooth": k`. Sizes
are whole, as for meshes. `assets/prefabs/sculpture.prefab` is the depth composite's
sculpture in this form.

**SDF cache everywhere.** With `cache`, the composition is baked once (`sdf/sdf-bake.slang`)
and sampled not only by the raymarching but by every soft shadow: `sdf-world.slang`'s
`sdfFieldDistance` and `sdfFieldColor` read the DAG or the cache, by `sdfUseCache`, for all
of them.

### Behaviors

A behavior is Lua for one entity: a file in `scripts/behaviors/` returning a constructor
`function(ctx, id, params)`, whose result may have `update(dt)`, input handlers (which
return true when they handle the event), `addOverlays(graph)`, `enter()`, `leave()` and
`describe()`.

- **When it runs:** constructors run after the meshes and bodies exist and before the graph
  is built. A behavior can therefore add bodies, give the renderer groups of its own to
  draw (`ctx.mesh.addGroup`), and provide a camera (`ctx.cameraProviders`).
- **What it costs:** only behaviors (and a player-controlled camera) run Lua per frame;
  everything else is parameter blocks and a graph the host runs.

| Behavior | |
| --- | --- |
| `spin.lua` | turns a visual mesh about an axis (`speed` in degrees per second, `axis`) |
| `burst.lua` | drops boxes and balls from above the entity on a key (`key`, `button`, `count`, `area`, `height`) |
| `player.lua` | the player character (`lib/player.lua`): spawns at the entity, hits and throws at the dynamic bodies, provides the "player" camera, draws the crosshair |
| `physics-controls.lua` | P pause, T slow motion, R reset (asks the viewer to load the scene again: `ctx.requestReload`) |
| `splat-controls.lua` | for every splat file: `,` `.` budget, `/` LOD tint, `[` `]` size, L lighting (lit / as captured / light visibility), C clip mode |
| `sdf-controls.lua` | J K blend radii; with a cache: C DAG / cache / the cache's error, `[` `]` resolution (baked again), B a benchmark of the raymarching's GPU time with both, Space stop turning cameras |

### The frame

`lib/scene/renderer.lua` builds one graph per scene from what the systems contribute:

| Stage | Who | |
| --- | --- | --- |
| prepasses | sdf | the cache's bake, once |
| shadow faces 0..5 | renderer, mesh | the light's cube shadow map; the meshes draw their casters into it |
| shadow passes | splat | the splats' translucent shadow maps |
| per view: opaque | renderer, mesh | color and depth; the meshes draw into it |
| per view: surfaces | sdf, splat | the raymarching (stopping at the meshes' depth), the splats |
| per view: depth composite | renderer | the view's surfaces merged by depth (`post/depth-composite.slang`), into the window or the inset's texture |
| per view: motion | renderer, mesh | with SSAO or SSGI on, after the opaque pass: the bodies' motion vectors (`scene/motion.slang`), with a depth buffer of their own |
| per view: effects | renderer | with SSAO or SSGI on: the composite goes to a texture, then the effects, their blur, their history, and their application into the window or the inset's texture |
| overlays | behaviors | over the main view: the crosshair |
| insets | renderer, camera | each inset framed in its corner, stacked if several share one |
| 2D overlays | the viewer's overlays | each overlay's shader and its framed panel, all off but the one shown |

- **One light and one shadow block:** every surface reads the same light block and the same
  shadow block. Systems add their fields to the shadow block: the SDF composition, whether
  splats cast shadows. So meshes, splats and SDFs light and shadow one another the same way
  in every scene, whatever is in it.
- **Missing surfaces:** with no SDFs or no splats, their targets stay empty and the
  composite passes them over. The splats' depth buffer is cleared every frame, since the
  composite reads it.
- **Per frame:** nothing in the renderer runs; systems change parameter blocks, and the
  host runs the graph.
- **Cost:** `composite.scene` runs at 33–34 ms per frame on the RTX 3050 Laptop GPU (Release),
  against 31–32 ms for the hand-built `fusion.lua` it reproduces. Some details differ (its SDF
  doesn't spin; its bounds are larger; a behavior spins the cube from Lua).

### Adding a component

1. Write a system in `lib/scene/systems/`: `components` (the schema) and the functions it
   needs from `load`, `shadowFields`, `addPrepasses`, `addShadowCasters`,
   `addShadowPasses`, `addOpaque`, `addSurfaces`, `addOverlays`, `enter`, `leave`,
   `update`, input handlers and `describe`.
2. Add it to `SYSTEMS` in `lib/scene/scene.lua`, where its place in the list is its place
   in loading and in the frame.

## Example: caching an SDF

`scripts/sdf-cache.lua` (in `scripts/lib/sdf-cache-mode.lua`; the showcase's `sdf-benchmark.scene`)
raymarches one SDF composition two ways, and times both on the GPU:

- **The DAG:** evaluated at every sample, node by node (`shaders/sdf/sdf-dag.slang`), as
  the depth composite does. Its cost grows with the composition.
- **The cache:** the same DAG baked once into 3D textures, then sampled
  (`shaders/sdf/sdf-cache.slang`). One trilinear fetch per sample, whatever the
  composition.

**The composition:** a sculpture of N shapes on a rising spiral around a core, all
smoothly joined (`lib/sdf.lua`): spheres, boxes and capsules, colored around the color
wheel. Its DAG has 2N + 1 nodes; `-` and `=` choose N from 4 to 128.

**The graph:**

| Node | |
| --- | --- |
| bake (`shaders/sdf/sdf-bake.slang`, `once`, `timed`) | one thread per voxel: evaluates the DAG at the voxel's center and stores the distance (`r16f`) and the color (`rgba8`) |
| compare (`shaders/sdf/sdf-compare.slang`, `timed`) | one thread per pixel: the sculpture on a floor under a sun, from the DAG or from the cache |
| present | the image onto the window |

**The cache:**

- **What it covers:** a cube 1.25 to either side of the composition's origin, in the
  composition's own space, at 32 to 256 voxels a side.
- **When it is baked:** again whenever the composition or the resolution changes (the
  bake's `:rerun()`, after new textures for a new resolution).
- **Reading it:** sampled with a linear, clamped sampler.
  - **Inside the cube:** filtering gives back a blend of the eight nearest voxels'
    distances. That smooths corners and edges finer than a voxel, and can come out a
    little larger than the true distance near them, so marches step 0.9 of it.
  - **Outside the cube:** nothing is cached. The distance to the cube, or the cached
    distance at the cube's nearest point less the way there, are both lower bounds, so a
    march steps by the larger.

**The comparison pass:**

- **Same work, two sources:** both sources do the same work. Each pixel marches the
  field to a hit, takes its normal from four more samples, then marches it again toward
  the sun for a soft shadow and samples it five times for ambient occlusion. The floor's
  pixels get the shadow and the occlusion too. A pixel therefore samples the field a few
  dozen to a couple of hundred times, as a real renderer would.
- **Bounding:** the DAG gets the cache's cube as a bounding volume, so both start and stop
  marching in the same places.
- **The error view** (V): marched with the DAG, and where it hits, the cached distance
  there, which should be 0. Blue is exact, green an eighth of a voxel off, red a quarter
  or more. At 128³, most of the surface is green or bluer. Flat faces show trilinear
  banding, and sharp box edges go red: what the cache rounds off.

**Results** (RTX 3050 Laptop GPU, Release, Vulkan, default window size, the raymarching
pass's GPU time averaged by the benchmark; single runs vary by tens of percent with the
view):

| Shapes (nodes) | Cache | Bake | DAG | Cache |
| --- | --- | --- | --- | --- |
| 4 (9) | 128³, 12 MB | 2.3 ms | 1.0 ms | 0.31 ms |
| 8 (17) | 128³ | 12.7 ms | 2.5 ms | 0.34 ms |
| 16 (33) | 128³ | 15.7 ms | 2.8 ms | 0.16 ms |
| 32 (65) | 128³ | 12.5 ms | 8.3 ms | 0.12 ms |
| 64 (129) | 128³ | 22.9 ms | 14.6 ms | 0.13 ms |
| 128 (257) | 128³ | 46.4 ms | 28.3 ms | 0.14 ms |
| 32 (65) | 32³, 0.2 MB | 0.2 ms | 8.5 ms | 0.09 ms |
| 32 (65) | 64³, 1.5 MB | 1.5 ms | 8.0 ms | 0.10 ms |
| 32 (65) | 256³, 96 MB | 92.7 ms | 8.6 ms | 0.27 ms |

- **The DAG** costs in proportion to its nodes.
- **The cache** costs about the same whatever the composition: from 3 times faster
  than the DAG at 4 shapes to 200 times at 128. Only at 256³, whose 96 MB no longer fit
  the GPU's caches, does it slow down noticeably.
- **Baking** 128³ voxels (two million evaluations of the DAG) costs about one and a half
  frames of the DAG, and only when something changes.
- **Other APIs:** a check at 32 shapes and 128³ gave the same pattern on D3D12 (DAG 15.5
  ms, cache 0.26 ms) and D3D11 (4.0 ms, 0.12 ms); the DAG's cost varies most between them.

**When to cache:** an SDF that changes rarely, and is sampled many times per frame (by
many pixels, by shadows, by occlusion), is worth baking. The price is memory (resolution³
× 6 bytes) and detail finer than a voxel. An SDF that changes every frame would pay
for a bake every frame. The depth composite's spinning composition doesn't change shape,
and could be cached the same way.

## Example: combining passes by depth

`scripts/fusion.lua` (the showcase's `composite.scene`) draws three kinds of surface into one
picture: the mesh scene, the Gaussian splats, and a raymarched composition of SDF shapes
(see [SDF compositions](#sdf-compositions)). They are rendered completely separately,
each into its own color texture and its own depth buffer. A last pass then combines the
images per pixel, by which one is nearer the camera:

| Pass | Writes | Reads |
| --- | --- | --- |
| scene: generate sphere, shadow faces | the shadow atlas (the meshes) | |
| splats: shadow casters (once) | each splat's center, opacity and covariance, merged ones included | the PLY data |
| splats: shadow reset, shadow select | the splats the shadow maps draw: a level-of-detail cut seen from the light | the casters' bounds, the light |
| splats: shadow faces | the splat shadow atlas: optical depth and nearest distance | the casters, the selection |
| splats: shadow layers faces | the splats' deep opacity map | the casters, the selection, the splat shadow atlas |
| mesh | `meshColor` (rgba16f), `meshDepth` | the shadow atlas |
| raymarch | `sdfColor` (rgba16f), `sdfDepth` (r32f) | the SDF node buffer, `meshDepth`, all shadow maps |
| splats: preprocess, lighting, sort | the projected splats, lit and shadowed, sorted | the PLY data, the light, all shadow maps |
| splats: color | `splatColor` (rgba16f, transparent background) | the sorted splats |
| splats: depth (`color = false`) | `splatDepth` | the sorted splats |
| depth composite | the window | all six |
| second camera: mesh … depth composite | the same, from the second camera, into square targets | as above |
| second camera inset | the window's lower right corner, with a border | the second camera's composite |

**The second camera.** The scene's second camera sees all of it too: the meshes, the
SDFs and the splats.

- **The same passes:** `addView` in `lib/fusion-mode.lua` adds the mesh, raymarch, splat
  and depth composite passes for one view. It is called twice: for the main camera into
  the window, and for the second camera into a linear rgba16f texture.
- **Square targets:** the second camera's six targets and its composite are square
  (`rhi.render_target(format, 0.3125, "square")`): 0.3125 × the window's height on both
  sides, whatever the window's shape. 0.3125 is exact in binary, so the Lua side
  computes the same side as the host.
- **Its view block:** the second camera's passes see the main view block and then one of
  their own, with the second camera and `viewportSize` set to the square. The splats'
  preprocess is a dispatch over the splats, whose `viewportSize` would be the window's.
  The raymarch dispatch has `threads = sdfColor`, so it covers the square anyway.
- **The inset:** the composite (`post/composite.slang`) frames that texture in a pixel
  `viewport` in the lower right corner. `on_resize` (and entering the mode) moves the
  viewport and updates the block's `viewportSize`.
- **Shared work:** the shadow maps, the splats' shadow casters and the SDF node buffer
  are shared. The splats are preprocessed, lit and sorted a second time, after the main
  view has drawn them.
- **Tab** switches all of the second camera's passes off and on.

**Two depth buffers.**

- **The mesh's** is an ordinary depth buffer: the `mesh` pass's `depth_target`.
- **The splats'** needs a pass of its own. Blended splats have no single depth per pixel,
  and a depth test in the color pass would cut away the far splats that blending needs.
  So the splats are drawn a second time, by `depthFragmentMain` in
  `shaders/splat/render.slang`, with depth testing and no color. Wherever a splat is at
  least 30% opaque at a pixel, it writes its depth, and depth testing keeps the nearest.
  The result is a depth buffer of the splats' visible surface.

**Same space.** Both sides look through one parameter block with the `camera`, so they
render the same view. Both write depth over the same near and far planes (0.1 and 100):
`scene/lit.slang`'s projection, and `depthFromViewZ` in `splat/splat-common.slang`. The same
block carries the splats' `model` transform, which places the skull in the scene: scaled,
turned to face the starting camera, and sunk a little into the floor.

**The composite** (`shaders/post/depth-composite.slang`) turns every depth value back into a
view distance and compares them per pixel:

- **The opaque layer:** the mesh, or the SDFs where they are nearer.
- **Splats nearer than it:** the splats go over it by their alpha. Their display-space
  premultiplied color is linearized first.
- **Splats behind it:** hidden.

So the horns pass in front of the sphere, the floor cuts off the jaw, and orbiting the
camera moves each in front of or behind the other. Light and shadow go both ways: the
skull shadows the floor, the cube and the sphere, and the meshes and the skull itself
shadow the skull (see [Splat shadows](#splat-shadows)). V shows the inputs: the mesh, the
splats or the SDFs alone, or the depth buffers, with the mesh's in blue, the SDFs' in green,
the splats' in orange, and nearer shown brighter.

**Limits of this approach.**

- **Hard edges:** the splats' depth is per pixel and per splat (each splat's center depth,
  for all of it), and the comparison is either/or. Where a mesh crosses a splat surface,
  the edge is hard.
- **Splats inside a surface:** faint splats in front of a nearer mesh surface are dropped
  with the rest.
- **Splat lighting is approximate:** the splats have no normals and their colors have
  the capture's lighting baked in; see [Lighting the splats](#lighting-the-splats).
- **Cost:** about 32 ms per frame on an RTX 3050 Laptop GPU (Release, default window
  size), against 12 ms for the splats alone. Both views and the splat shadows draw the
  splats with [levels of detail](#levels-of-detail), each with its own budget: 1 million
  splats for the main view, a tenth of that for the second camera's square, half for the
  shadows. Before the levels of detail, it was about 73 ms.
  - **The second camera:** before the levels of detail, it cost about 29 ms of a 73 ms
    frame. Its pixels are few, but it repeats all the per-splat work: preprocess,
    lighting and the sort. With the levels of detail, it draws far fewer splats: its
    view is small, so coarser levels are small enough.
  - **Splats:** the splats' second, depth-only draw, their shadows both ways, and their
    lighting.
  - **SDFs:** the raymarching and the receivers' soft-shadow marches. Most of those rays
    miss the composition's bounding sphere and don't march at all.

### Splat shadows

Shadows go both ways between the splats and the meshes, and the splats shadow each
other:

| Caster | Receiver | Through |
| --- | --- | --- |
| meshes | meshes | the shadow map (scene/shadow.slang) |
| splats | meshes | the splats' translucent shadow map and its deep opacity layers |
| meshes | splats | the shadow map |
| SDF shapes | meshes, splats, SDF shapes (soft) | a march through the distance field toward the light, per receiving point |
| splats | splats (self-shadowing) | the deep opacity layers |

Every receiver looks the light up through the same function, `shadowVisibility` in
`shaders/scene/shadow-lookup.slang`: the lit pass for the meshes, and
`shaders/splat/lighting.slang` for the splats.

#### The splats as a translucent medium

A Gaussian has no hard surface: light passing through splats is dimmed by each in turn, to
a transmittance of `∏(1 - αᵢ)`. That is the technique used for hair and smoke. It needs to
know, for a point, how much of the splats lies between it and the light, so it builds
two maps per cube face, in the meshes' atlas layout:

1. **Translucent shadow map** (`rgba16f`, `accumulate` blend):
   - **r:** the optical depth, `Σ -ln(1 - α)`, of all splats in that direction.
   - **a:** the distance to the nearest of them (min).
   - **Which splats set the distance:** only splats at least 20% opaque there count as the
     nearest. A few faint strays in front of a surface would otherwise put all of it
     "behind".
2. **Deep opacity map** (`rgba16f`, `additive` blend; Yuksel & Keyser 2008): the same
   splats again, now that the nearest distances are known.
   - **What each channel holds:** channel k holds the optical depth of the splats within
     0.05, 0.15, 0.4 and 1.2 units past the nearest.
   - **Between the layers:** the depth is interpolated linearly. Past the last layer, all
     the splats in that direction count.
   - **Layer spacing:** the layers are close together near the surface and farther apart
     behind it, so a point on the far side of the skull is dimmed by the near side, and a
     point on the lit side isn't.

The light that reaches a point is then the light not blocked by a mesh, times
`exp(-optical depth in front of it)`, averaged over 3×3 texels for soft edges.

#### How the splats' shadow maps are drawn

1. **Casters** (`shaders/splat/shadow-casters.slang`, compute, once):
   - **What it stores:** each splat's center, opacity and 3D covariance, in the file's
     frame (only flipped), for the merged splats of the [levels of
     detail](#levels-of-detail) too.
   - **Placement:** it goes through `shaders/splat/ply.slang`, the same code that places
     and shapes the drawn splats, so the shadows match them exactly.
   - **When it runs:** again when the splat size changes or the shader is edited.
2. **Selection** (`shaders/splat/shadow-select.slang`, compute, every frame): which splats
   the maps draw.
   - **A cut seen from the light:** a budget cut through the levels of detail, as the
     camera's ([Levels of detail](#levels-of-detail)), with the same histogram and pick,
     but measured from the light: in texels of a cube face (whose focal length is half
     its 512 texels), over every direction.
   - **Budget:** half the camera's, so `,` and `.` change both, and never finer than a
     texel (`lodFinest`). The list holds up to 2²⁰.
   - **Packing:** the picked splats and their instances are packed into a list, with an
     atomic counter. Every face of both maps draws from it; triangles past its count draw
     nothing.
   - **Placement:** the casters are in the file's frame; the vertex shader places each
     splat by its instance and `model`, center and covariance.
   - **Every frame:** the light moves, so the selection runs every frame, while the
     casters stay as they are.
3. **Shadow faces and shadow layers faces** (`shaders/splat/shadow.slang`, six passes each):
   - **Shape:** each splat is drawn as its actual Gaussian seen from the light. Its
     covariance is projected onto the plane facing the light, and a triangle covers the
     resulting ellipse out to 3σ.
   - **Entry points:** `fragmentMain` fills the first map. `layersFragmentMain` fills the
     second, reading the first.

#### Lighting the splats

The point light lights the splats as it lights the meshes: `shaders/splat/lighting.slang`
runs between preprocessing and sorting, one thread per drawn splat (the first `drawCount`
of the packed sort values), and changes the color preprocess wrote.

- **Shadows, sized by the splat:** it looks up the light at the splat's center with
  `shadowVisibilitySpread` (`scene/shadow-lookup.slang`), the meshes' lookup with a wider
  filter. A drawn splat may be one of the file's or a merged one standing in for a whole
  cluster, so the lookup is sized by the splat's extent (3σ of its largest scale):
  - **Bias:** the splat counts as nearer to the light by `shadowBias` (0.02), plus half
    its extent, plus 1.5 shadow map texels at its distance (`shadowTexelSize`). So the
    splats of a surface, or of the light's coarser cut of it, don't shadow it ("shadow
    acne").
  - **Filter:** the 3 × 3 texels it averages are spaced as far apart as half its
    footprint in the map (1 to 8 texels). So a merged splat gets the light over the area
    it covers, not at one spot of it.
- **A normal:** splats have none, but the Gaussians of a surface lie flat along it, so a
  splat's shortest axis stands in for its normal (`splatWorldNormal` in
  `shaders/splat/ply.slang`), turned to face the camera.
  - **Trust:** how far it is trusted depends on how flat the splat is, from 0 for a round
    splat to 1 for a flat one. For a round splat, whose shortest axis means nothing, the
    diffuse term fades toward a neutral 0.5.
- **Material:** the captured color stands in for the albedo. It is converted to linear
  color and lit with the meshes' formula from `scene/lit.slang`: ambient, inverse-square
  falloff faded to zero at the light's range, diffuse, and shadows. It is then tone mapped
  the same way and converted back to display space.

The captured colors have the lighting of the capture baked in, so lighting them again is
an approximation, and a white skull reads greyer than captured. `relight` blends between the
two looks, and L in the depth composite switches it:

| L | Result |
| --- | --- |
| lit (default) | `relight` 1: lit by the point light, as above |
| as captured | `relight` 0: the colors as captured, only darkened where something shadows them, down to `1 - shadowStrength` (0.75 darker) |
| light visibility | `showVisibility` 1: only how much light reaches each splat, white (lit) to black (shadowed), for looking at the shadows alone |

The values live in the splat module's lighting block. `splat.setRelight(amount)` and
`splat.setShowVisibility(show)` change the first two; `shadowStrength`, `shadowBias`,
`shadowBiasExtent` and `shadowBiasTexels` sit next to them in `lib/splat-mode.lua`.

#### Wiring

- **The scene** owns the splats' two shadow textures (`scene.splatShadowAtlas()`) and binds
  them for every lit draw.
  - **When they are read:** only where a view sets `splatShadows = 1`. In the Scene mode
    they are never read, even after the Depth Composite mode has drawn into them.
  - **For other receivers:** `scene.shadowBlock()` hands all shadow maps to them.
- **The fusion module** sets `splatShadows = 1` in its view block. It adds the shadow
  passes with `splat.addShadowPasses()`, and the lighting pass through
  `splat.addPasses{ lighting = { scene.lightBlock(), scene.shadowBlock() } }`.

#### Limits

- **Resolution:** at 512 texels per cube face, the far ends of long shadows show their
  texels.
- **Fixed layers:** the four layers are spaced for an object about the skull's size. Much
  larger or smaller splat scenes would want them rescaled (`kSplatLayerBounds` in
  `shadow-lookup.slang`).
- **One value per splat:** a splat is lit and shadowed at its center only, so a large
  splat straddling a shadow edge is shaded all one way.
- **Approximate normals:** the shortest-axis normal is noisy where splats are round or
  overlap at odd angles, which shows as grain in the lit result. There is no specular term.

### SDF compositions

The fusion example also raymarches a composition of signed distance fields (SDFs): shapes
defined by the distance to their surface, combined with smooth booleans. The composition is
built in Lua, compiled into a buffer of nodes, and evaluated by the raymarching shader.
Nothing about it is hard-coded in a shader.

| File | Role |
| --- | --- |
| `shaders/common/sdfs.slang` | the primitives (your SDF library) |
| `shaders/sdf/smooth-ops.slang` | smooth union, intersection and subtraction, blending colors too |
| `shaders/sdf/sdf-dag.slang` | the node format, and the evaluator that runs a node buffer at a point |
| `shaders/sdf/sdf-world.slang` | where the composition sits and spins, and its bounding sphere |
| `shaders/sdf/raymarch.slang` | the raymarching pass, from the camera |
| `scripts/lib/sdf.lua` | building compositions in Lua, and compiling them into node buffers |

#### Building a composition in Lua

```lua
local sdf = rhi.include("lib/sdf.lua")

local body = sdf.smoothUnion(0.12,
    sdf.sphere(0.34):color(0.95, 0.55, 0.15),
    sdf.box(0.24, 0.24, 0.24):rotate("y", math.pi / 4):color(0.2, 0.55, 0.95))
local rod = sdf.cylinder(0.09, 1.4)
local cross = sdf.union(rod, rod:rotate("x", math.pi / 2), rod:rotate("z", math.pi / 2))
local shape = sdf.smoothSubtract(0.03, body, cross)

local program = sdf.compile(shape)   -- { floats, nodeCount, resultSlot, slotCount }
local nodes = rhi.buffer(program.floats)
```

- **Primitives:** the 3D shapes of `common/sdfs.slang`:
  - `sphere(r)`, `cube(halfSize)`, `box(x, y, z)`, `ellipsoid(x, y, z)`
  - `capsule(r, a, b)`, `plane(point, normal)`
  - `cylinder(r, height)`, `prism(sides, height)`, `tetrahedron(a, b, c, d)`
- **Booleans:**
  - `smoothUnion(k, ...)`, `smoothIntersect(k, ...)`, `smoothSubtract(k, a, b)`, with blend
    radius `k` in world units.
  - `union`, `intersect`, `subtract` are the hard versions (`k = 0`).
- **Placement:** `:translate(x, y, z)`, `:rotate("x"|"y"|"z", angle)`, `:scale(s)` (uniform).
- **Color:** `:color(r, g, b)` colors every primitive below it that has no nearer color of
  its own.
- **Shapes are values:** transforming one returns a new shape, so one shape can be placed
  several times.

#### Compiling: from a tree to a DAG in a buffer

`sdf.compile(shape)` turns the Lua shape into nodes for `sdf-dag.slang`:

1. **Placement down to the leaves:** every transform and color is pushed down to the
   primitives. Each primitive node gets the world-to-local transform of its whole path,
   and the factor that scales its local distances back into world units.
2. **Sharing:** a shape (the same Lua value) used more than once with the same placement is
   emitted once, and every operator that uses it reads the same result. That is what makes
   the node list a DAG rather than a tree. In the example, the rod cross is used twice, to
   drill the body and for the rods' ends, but evaluated once.
3. **Order:** nodes are emitted after the nodes they read, so the shader evaluates them in
   one pass from first to last.
4. **Registers:** each node writes its result to a slot, one of 16 in the shader, and
   operators read their operands from slots. A slot is reused once its last reader has
   run, so a composition needs only as many slots as results are alive at once. The
   example's 18 nodes need 3. `compile` raises an error if a composition needs more than
   16.

Each node is eight `float4`s: op code and slots, three parameter vectors, the 3×4
world-to-local transform, and color plus distance scale. `sdf-dag.slang` documents the
layout, and `sdf.lua` has the same op code table. The buffer is made once, with
`rhi.buffer(program.floats)`. Changing the composition means compiling and uploading it
again, which a script would do on a key press or a reload, not every frame.

#### Smooth booleans

`smooth-ops.slang` implements the polynomial smooth minimum (as popularized by Inigo
Quilez). It rounds off the crease where two shapes meet over the blend radius `k`:

| Operator | Hard version | Smooth version |
| --- | --- | --- |
| union | `min(a, b)` | `lerp(b, a, h) - k h (1 - h)`, with `h = saturate(0.5 + 0.5 (b - a) / k)` |
| intersection | `max(a, b)` | `lerp(b, a, h) + k h (1 - h)`, with `h = saturate(0.5 - 0.5 (b - a) / k)` |
| subtraction | `max(a, -b)` | the smooth intersection of `a` and `-b` |

Every sample carries a color as well as a distance, blended with the same weight `h`. A
rounded joint therefore fades from one shape's color to the other's, and a subtraction's cut
faces take the color of the shape that was cut away. The shader multiplies every `k` by
`smoothScale`, a parameter J and K change at run time without recompiling.

#### The raymarching pass

`shaders/sdf/raymarch.slang` runs one thread per pixel of its target (`threads = sdfColor`):
the window's size for the main view, the square for the second camera.

- **Ray:** each pixel's ray comes from the same camera block as the meshes.
- **Marching:** it sphere-traces the composition, stepping by the distance to the
  nearest surface, for up to 128 steps.
- **Stopping at the meshes:** a ray also stops at the mesh pass's depth, because beyond it a
  mesh is in front anyway. That saves the steps a hidden ray would take.
- **Placement:** the composition sits at `sdfOrigin` and turns at `sdfSpin` radians per
  second, from the host's `time` (`sdf-world.slang`).
- **Bounding sphere:** it lies within `sdfBoundsRadius` of its origin, so a ray that misses
  that sphere misses it, and most pixels stop before marching a single step.

On a hit:

- **Normal:** from the distance field's gradient, four extra samples.
- **Lighting:** lit with `scene/lit.slang`'s formula: ambient, falloff, diffuse, specular.
- **Shadows:** shadowed through `scene/shadow-lookup.slang`, by the meshes and the splats.
- **Depth:** written as the meshes write it (`z/w` over the same planes) into an `r32f`
  texture, and the composite compares it with the others.

#### Soft shadows from the SDFs

The SDFs cast soft shadows, with penumbrae that widen with distance from the caster, as a
real light's do. A shadow map can't give that: it holds only where a light ray first hits.
So the SDFs aren't in a map at all. Each receiving point asks the distance field itself
instead (the SDF soft-shadow technique from Inigo Quilez's articles):

1. **March:** the point marches toward the light through the composition, for up to 64
   steps.
2. **Clearance:** at each step, `d / t` is how closely the ray passes the surface, seen from
   the point: `d` is the distance to the surface, `t` the distance travelled. The
   narrowest, scaled by `sdfShadowSharpness`, gives the light that gets past.
   - **Graze:** a ray that just grazes the shape leaves the point half lit.
   - **Hit:** a ray that hits leaves it in full shadow.
3. **Smoothing:** the result is smoothed with smoothstep and multiplies the light from the
   shadow maps.

This lives in `sdfSoftShadow` in `scene/shadow-lookup.slang`, inside `shadowVisibility`, the
function every receiver already calls. So the SDFs shadow the meshes, the splats (through
their lighting pass), and themselves, with no change to those passes.

**Cost.** Marching a distance field per point is expensive, so a point whose path to the
light misses the composition's bounding sphere doesn't march. That covers most points:
everything except what lies in or near the composition's shadow.

**Wiring.**

- **The scene:** binds harmless placeholders for the composition's inputs, with
  `sdfShadows = 0`, so its own mode never marches.
- **The fusion example:** its view block, which every one of its passes gets after the
  scene's shadow block, carries the real node buffer and placement, with
  `sdfShadows = 1`.

`sdfShadowSharpness` (8) stands for the light's size: larger values give harder, narrower
penumbrae, like a smaller light.

#### The SDF library

Three of the 3D primitives in `shaders/common/sdfs.slang` weren't valid as signed distance
fields, and raymarching them would have failed:

- **Cylinder and Prism:** they combined their caps with `min`, which is the union of the
  half-spaces rather than their intersection, so the shape had no bounds.
  - **Cylinder:** its cap normals also weren't unit length.
  - **Prism:** it ignored its `height`.
  - **Now:** both use `max`, with unit cap normals at ±height/2.
- **Tetrahedron:** it used `min` too, and its face normals pointed in or out depending on
  the vertex order. Each face now turns its normal away from the opposite vertex, and the
  faces combine with `max`.

The 2D primitives (`Square`, `Polygon`, `Circle`, used by the ShaderToy `sdfs2d.slang`)
are unchanged.

#### Limits

- **Approximate penumbrae:** the soft shadows come from the closest approach along a
  single ray, not from integrating over the light's area. They are plausible rather than
  exact, and the meshes' and splats' shadows stay as hard or translucent as before.
- **Bounding radius:** `sdfBoundsRadius` is set by hand in `lib/fusion-mode.lua`. A
  composition that grows past it is cut off where it does, and so is its shadow.
- **Box distances:** `Cube`, `Box3D` and the prism's sides return lower bounds outside the
  shape (Chebyshev-style distances), so rays near their edges take more steps. They are
  still safe to march.
- **Fixed register count:** a composition can need at most 16 result slots at once.

## Shader parameters

`params` is a table that maps shader parameter names to Lua values. Each value is converted
to the type the shader declares:

| Shader type | Lua value |
| --- | --- |
| `float`, `int`, `uint`, `bool`, `double`, 64-bit ints | number or boolean |
| `float3`, `int2`, ... | `{x, y, z}`; missing components are 0 |
| `float4x4`, ... | 16 numbers, row by row (a flat table, or a table of rows) |
| `struct` | a table of fields: `{ color = {1, 0, 0}, intensity = 2 }` |
| arrays | a table of elements, each converted by the element type |
| `Texture2D`, `RWTexture2D<...>` | a texture |
| `StructuredBuffer`, `RWByteAddressBuffer`, ... | a buffer |
| `ControllerState` | `input.controller()` |

- **Unknown names are ignored.** A shader that doesn't declare a parameter (or whose
  compiler optimized it away) just doesn't receive it. That lets one params table feed
  several shaders.
- **Type mismatches** name the parameter, e.g. passing a number for a struct. With
  `frame:draw` and `frame:dispatch` they raise a script error. In a render graph they are
  printed once.
- **Values from the host:** if a shader declares them, the host sets these before the
  script's values (which can override them), in render graphs and in `frame` calls alike:

  | Name | Value |
  | --- | --- |
  | `time` | seconds since start, the same clock as `rhi.time()`; it stops while paused (`rhi.set_paused`) |
  | `timeDelta` | the seconds `time` moved since the last frame (0 while paused) |
  | `viewportSize` | the size in pixels of the viewport being drawn into (the window's size for dispatches) |
- **Matrices** are written tightly packed. That is exact for `float4x4`; smaller matrices in
  constant buffers may be padded differently.

The ShaderToy uniforms in `shaders/shader-toy/shader-toy.slang` are a complete example:

```lua
frame:dispatch(pipeline, {
    iResolution = { frame.width, frame.height, 1 },
    iTime = time,
    iFrame = frame.index,
    iMouse = { mx, my, down and 1 or 0, clicked and 1 or 0 },
    iController = input.controller(),
    texture = target,
})
```

## Input: `input`, `keys`, `buttons`

| Call | |
| --- | --- |
| `input.mouse()` | `x, y` pointer position in window pixels |
| `input.mouse_down(button)` | is a mouse button held (`input.MOUSE_LEFT`, ...) |
| `input.key_down(key)` | is a key held (`keys.SPACE`, ...) |
| `input.controller([slot])` | a live view of a Steam Controller; without `slot`, the primary (lowest connected) one |

The controller view always reads the current state:

| Field | |
| --- | --- |
| `connected` | boolean |
| `buttons` | bitfield of `buttons.*` |
| `controller:button(buttons.A)` | is a button held |
| `left_stick`, `right_stick` | `{x, y}` in [-1, 1] |
| `left_trigger`, `right_trigger` | [0, 1] |
| `left_pad`, `right_pad` | `{x, y, pressure}` |
| `accel`, `gyro` | `{x, y, z}` |
| `quat` | `{w, x, y, z}` orientation |

Constants:

- **`keys`**:
  - `keys.A` .. `keys.Z`, `keys["0"]` .. `keys["9"]`, `keys.F1` .. `keys.F12`
  - `SPACE`, `ESCAPE`, `ENTER`, `TAB`, `BACKSPACE`, `LEFT`, `RIGHT`, `UP`, `DOWN`
  - `PAGE_UP`, `PAGE_DOWN`, `HOME`, `END`, `LEFT_SHIFT`, `LEFT_CONTROL`, `LEFT_ALT`
  - `MINUS`, `EQUAL` (the `-` and `=`/`+` key), `LEFT_BRACKET`, `RIGHT_BRACKET`,
    `KP_ADD`, `KP_SUBTRACT`
- **`input`**: `PRESS`, `RELEASE`, `REPEAT`, `MOUSE_LEFT`, `MOUSE_RIGHT`, `MOUSE_MIDDLE`.
- **`buttons`**: the `SteamControllerButtons` bits from `examples/base/steam-controller.h`:
  - `A`, `B`, `X`, `Y`, `LB`, `RB`
  - `DPadUp`, `DPadDown`, `DPadLeft`, `DPadRight`
  - `Menu`, `View`, `Steam`, `QAM`, `L3`, `R3`, `L4`, `L5`, `R4`, `R5`
  - `LeftPadClick`, `RightTriggerClick`, ...

**Reserved keys**: the host handles Escape (release the pointer) and F11 (fullscreen).
Scripts still receive these keys. The scene viewer and the showcase use Escape for their
pause menu as well.

**Steam desktop mode**: a Steam Controller in desktop mode types arrow keys and Escape. The
host recognizes those keystrokes and drops them, so the d-pad never reaches `on_key` as
arrows. Use `on_controller_button` for the controller.

## Live reload and errors

The host checks for changes several times a second. A file counts as changed once its new
timestamp has held for one more check, so a half-written save isn't compiled.

- **Shaders**: saving a shader, or any file it pulls in with `#include "..."`, recompiles
  every pipeline that uses it. The host splices includes into the source itself, so it
  knows each pipeline's files and always reads them fresh. Errors still point at the real
  file and line. If the new version doesn't compile, the errors are printed and the
  previous build keeps running.
- **The script**: saving the script loads it into a fresh Lua state. If it loads, the old
  script's `shutdown()` runs, then the new one's `init()`.
  - **State resets**: script variables start over (the showcase returns to its first
    scene).
  - **Kept by the host**: pipelines (from the cache), the window and the device.
  - **Load failure**: if the new version doesn't load, the old one keeps running.
- **Script errors**: an error in a callback prints the message with a Lua traceback. The
  script then pauses until the file is saved again: no more callbacks. A render graph it
  set up keeps running, since it doesn't need the script; otherwise the window stops
  updating.
- **Graphs and reloads**: reloading the script drops its render graph, and the new
  script's `init()` builds and sets a new one. The pipelines are reused from the cache, so
  rebuilding is quick.
- **Errors at startup**: if the script fails to load on startup, no window opens and the
  program exits.

Logs go to the console. Debug builds also enable the slang-rhi validation layer, and its
messages appear in the same log. Release builds on Windows have no console.

## Writing an example

1. Create `scripts/<name>.lua`. It then runs with `example-lua <name>`.
2. Put its shaders in a folder of their own under `shaders/` (e.g. `shaders/<name>/`). Put
   anything other examples could use in `common/`, `mesh/` or `post/`.
3. Start from `config` plus `init` and `draw`. The smallest complete example is
   `surface.lua`. `lib/scene-mode.lua` shows a complete 3D setup as a render graph.
4. For a scene of meshes, splats, SDFs, lights and cameras, write no Lua at all: a scene
   file in `assets/scenes/` (see [the scene system](#the-scene-system)) shows in the
   showcase and in `scenes.lua`. Behaviors (`scripts/behaviors/`) add code where a scene
   needs it.
5. Shared Lua code goes in `scripts/lib/` and is loaded with `rhi.include("lib/...")`,
   which watches it for edits. `require` works too, but isn't watched.

## Implementation

Everything is in `examples/lua/example-lua.cpp`, apart from the physics
(`examples/lua/physics.h` and `physics.cpp`), the splats' levels of detail
(`splat-lod.h`, `splat-lod.cpp`) and sound (`audio.h`, `audio.cpp`).

- **Base layer**: the window, input and Steam Controller handling are the shared example
  base (`examples/base/example-base.h`).
- **Lua build**: Lua 5.4 is fetched by CMake and compiled as C++. A Lua error therefore
  unwinds through the host as an exception, which releases GPU objects and closes any open
  pass.
- **Jolt build**: CMake clones Jolt Physics v5.6.0 from GitHub (`FetchContent`, its
  `Build/` project) and builds only the library:
  - **Runtime:** against the same dynamic MSVC runtime as everything else (Jolt's default
    is the static one, which wouldn't link).
  - **No link-time optimization:** it would slow every build of the examples.
  - **Isolation:** `physics.h` keeps Jolt's headers out of the host. Jolt is compiled
    without RTTI or exceptions (its defaults), while the host needs exceptions for Lua.
- **miniaudio build**: CMake clones miniaudio 0.11.25 from GitHub (`FetchContent`) for its
  one header only; `audio.cpp` compiles the implementation. Its own CMake project isn't
  built. On Windows it plays through WASAPI, with no extra libraries; on Linux it loads
  ALSA or PulseAudio at run time (linking `dl`, `pthread` and `m`). `audio.h` keeps its
  header out of the host.
- **Adding a function**:
  1. Write a `static int api...(lua_State*)` in `LuaApp`.
  2. Add it to the matching `luaL_Reg` table in `registerApi`.
  3. Document it here.
