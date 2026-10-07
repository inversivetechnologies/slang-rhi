# Lua examples

`example-lua` is a host application that runs Lua scripts on top of slang-rhi. It opens a
single window on a single graphics API (Vulkan unless told otherwise). The host owns the
window, the device, the swapchain and the frame loop; a script decides what gets
created and drawn, and reacts to input. Scripts and shaders reload while the program runs,
so most iteration happens without a rebuild.

All examples are scripts, in `scripts/`:

| Script | What it shows |
| --- | --- |
| `showcase.lua` | the physics, the ShaderToy shaders, the splats and the depth composite in one window, switchable at runtime |
| `physics.lua` | rigid body physics on Jolt: a ball, a ramp, dominoes, a box pyramid and a tower; throw balls, drop boxes -- the host simulates and draws, instanced |
| `surface.lua` | clearing the window |
| `scene.lua` | a lit 3D scene: a GPU-generated spherified cube, a cube and a floor, with a point light, realtime shadow mapping and a second camera composited into the corner -- built as a render graph the host runs without Lua |
| `shader-toy.lua` | ShaderToy-style compute shaders blitted to the window |
| `splat.lua` | Gaussian splatting with compute shaders: loads `assets/skull.ply` (1.9 million splats), projects, sorts and draws them every frame |
| `fusion.lua` | the scene, the splats and a raymarched SDF composition in one picture: each rendered with its own depth buffer, combined per pixel by depth; shadows between all of them |

## Layout

```
examples/lua/
  example-lua.cpp      the host
  physics.h/.cpp       rigid body physics for the host, on Jolt Physics
  README.md
  scripts/             runnable scripts, one per example
    lib/               Lua modules used by scripts (rhi.include), not run on their own
  shaders/             every shader, shared by all scripts
    common/            Slang libraries: math, quaternions, transforms, SDFs, splines, ...
    mesh/              the vertex format, and mesh generators (spherified-cube)
    scene/             the scene's lighting and shadows (scene-common, shadow, lit,
                       shadow-lookup)
    splat/             Gaussian splatting (ply, splat-common, preprocess, render,
                       shadow-casters, shadow, lighting)
    sort/              GPU sorting (bitonic)
    sdf/               SDF compositions: smooth booleans (smooth-ops), the DAG evaluator
                       (sdf-dag), placement in the world (sdf-world), and the
                       raymarching pass (raymarch)
    post/              full-screen passes (composite, depth-composite)
    shader-toy/        the ShaderToy framework (shader-toy.slang) and the toys
  assets/              data files the scripts load (skull.ply)
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

| Input | Action |
| --- | --- |
| Left / Right arrow | previous / next mode |
| `1` .. `5` | jump to a mode |
| Steam Controller LB / RB | previous / next mode |
| Left mouse button | moves `iMouse` in the ShaderToy modes; orbits the camera in the physics, the splats and the depth composite |
| Escape | gives the mouse pointer back (click the window to hide it again) |
| F11 | toggles fullscreen |

The modes are Physics, the ShaderToy shaders 2D SDFs and Controller, Gaussian Splats, and
Depth Composite. The lit scene (`scene.lua`) has no mode of its own any more, but the Depth
Composite builds on it. The other ShaderToy shaders (Circle, Ocean) are in
`example-lua shader-toy`. The current mode is shown in the window title. A
ShaderToy mode whose shader doesn't compile shows dark red until it does. The splats load
(about a second for the 454 MB file) the first time a mode showing them is shown. The
Gaussian Splats and Depth Composite modes share the loaded file.

### The depth composite

`example-lua fusion`, or mode 5 of the showcase.

| Input | Action |
| --- | --- |
| Drag with the left mouse button | orbit the camera |
| Mouse wheel | zoom |
| V | show: combined / mesh only / splats only / SDFs only / the depth buffers |
| L | splats lit by the point light / as captured (only shadowed) |
| J / K | every blend radius of the SDF composition ÷1.25 / ×1.25 (down to hard booleans) |
| `[` / `]` | splat size |
| Tab | hide or show the second camera's square in the lower right corner (meshes, SDFs and splats, as in the main view) |
| the scene's keys | change the scene as in its own mode (subdivision, radius, light) |

How it works is described in [Example: combining passes by
depth](#example-combining-passes-by-depth).

### The splats

`example-lua splat`, or mode 4 of the showcase.

| Input | Action |
| --- | --- |
| Drag with the left mouse button | orbit the camera |
| Mouse wheel | zoom |
| `[` / `]` | splat size ÷1.1 / ×1.1 |
| F | flip the scene upside down (for captures that aren't y-down) |

How it renders is described in [Example: Gaussian splatting](#example-gaussian-splatting).

### The physics

`example-lua physics`, or mode 1 of the showcase.

| Input | Action |
| --- | --- |
| Drag with the left mouse button | orbit the camera |
| Mouse wheel | zoom |
| E | throw a ball from the camera, toward the point it looks at |
| Space | drop a burst of 24 boxes and balls from the sky |
| R | reset: the dynamic bodies back where they started |
| P | pause the simulation |
| T | slow motion (a quarter of the speed) |

How it works is described in [Example: rigid body physics](#example-rigid-body-physics).

### The scene

`example-lua scene`. It is no longer a showcase mode, but the depth composite (mode 5)
builds on it.

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
local vb = rhi.vertex_buffer { 0, 0, 0,  1, 0, 0,  ... }  -- floats
local buf = rhi.buffer(1024)                      -- 1024 bytes, zeroed
local buf2 = rhi.buffer { 1, 2, 3, 4 }            -- floats
```

- **Formats**: `r32f`, `rg32f`, `rgb32f` (vertex layouts only), `rgba32f`, `rgba16f`,
  `rgba8`, `r32u`.
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
| `rhi.include(path)` | runs a Lua file (relative to the script) and returns its result; saving that file reloads the script |
| `rhi.window_srgb()` | `true` if the window's format encodes sRGB itself (as `frame.srgb`, but usable in `init`) |
| `rhi.window_size()` | the window's size in pixels, `width, height` (usable in `init`) |
| `rhi.load_ply(path)` | loads a PLY file's vertices into a buffer; see below |

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

Shaders then read whatever properties they need, at offsets the script passes in.
| `rhi.params{...}`, `rhi.graph()`, `rhi.set_graph(graph)` | see [Render graphs](#render-graphs) |

`rhi.include` is for sharing Lua code between scripts in different folders. The showcase
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
| `graph:dispatch{ name, pipeline, params, threads = {x, y, z} \| "window" \| texture, once }` | adds a compute dispatch; `"window"` runs one thread per window pixel, a texture one per texel, both following resizes |
| `rhi.set_graph(graph)` | makes the host run `graph` every frame, before `draw`; `nil` stops it |

- **`render_pass` options:**
  - `target`: a texture to draw into. Leave it out to draw into the window.
  - `depth_target`: a [depth target](#depth-targets) to use as the pass's depth buffer,
    instead of the host's buffer for the target. The pass then leaves its depth there for
    later passes to read.
  - `color = false`: a depth-only pass. It has no color target, only its
    `depth_target`, and its draws use pipelines with `format = "none"`.
  - `clear`: clears the target first (and its depth buffer). For a depth-only pass, any
    `clear` table clears the depth buffer.
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
| pass | `enabled`, `clear`, `viewport`, `viewport_fraction` |
| dispatch | `enabled`, `threads`, and `:rerun()` |
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
it; see [Shader parameters](#shader-parameters). The scene computes its light's orbit and
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
- **No Lua per frame:** neither the physics nor the drawing calls into Lua.

| Call | |
| --- | --- |
| `rhi.physics_world{ gravity = {0, -9.81, 0}, max_bodies = 4096 }` | a new world |
| `world:group{ capacity = 256 }` | a group of bodies drawn together, with a GPU buffer for up to `capacity` |
| `group:add{ ... }` | adds a body, see below; returns its index in the group, or `nil` when full |
| `group:clear()` | removes every body of the group |
| `group:set_velocity(i, {x, y, z})`, `group:impulse(i, {x, y, z})` | push body `i` |
| `group:position(i)` | its current position, `x, y, z` |
| `group.count`, `group.capacity`, `group.buffer` | bodies in the group; its size; its transforms |
| `rhi.set_physics(world)` | makes the host step `world` every frame; `nil` stops it |
| `world.paused`, `world.time_scale`, `world.gravity` | settable |

`group:add` takes:

| Field | Default | |
| --- | --- | --- |
| `shape` | `"box"` | `"box"` with `half_extents = {x, y, z}`, or `"sphere"` with `radius` |
| `motion` | `"dynamic"` | `"dynamic"`, `"static"`, or `"kinematic"` (moved by its velocity, never pushed) |
| `position`, `rotation` | origin, none | `rotation` is a quaternion `{x, y, z, w}` |
| `velocity`, `angular_velocity` | 0 | initial |
| `friction`, `restitution`, `density` | 0.5, 0, 1000 | density in kg/m³; with the shape's volume, it gives the mass |
| `color`, `pattern` | grey, 0 | how it is drawn (`pattern` as `Material.pattern` in `scene/lit.slang`) |

**Stepping.** The world steps at a fixed 1/60 s whatever the frame rate: steps accumulate
over frames, at most four per frame. A long frame therefore slows the simulation down
rather than stalling it.

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

`scripts/physics.lua` (and mode 1 of the showcase, in `scripts/lib/physics-mode.lua`) is a
test scene for the physics:

- **The chain reaction:** a ball at the top of a ramp rolls down into a row of 14
  dominoes. They topple one after another, and the last falls into a seven-level box
  pyramid.
- **The tower:** beside them stands a tower of 12 layers of three boards, each layer turned
  a quarter turn. E throws heavy balls at it from the camera.
- **The bursts:** Space rains random boxes and spinning balls onto all of it.

**Bodies.** Three groups, each drawn by one instanced draw per pass:

| Group | Bodies | Mesh |
| --- | --- | --- |
| statics | the floor, the ramp and its rails (static) | cube |
| boxes | dominoes, pyramid, tower, dropped boxes | cube |
| balls | the rolling ball, thrown and dropped balls | sphere |

**The graph:** six shadow passes into its own shadow atlas, then the lit pass into the
window, as in the scene. The splat and SDF inputs of the shadow lookup are switched off,
and bound to placeholders.

**What Lua does after `init`:** adds bodies (E, Space), clears and re-adds them (R), and
sets `world.paused` and `world.time_scale` (P, T). Every draw follows its group's body
count by itself.

**Cost:** about 8 ms per frame (≈120 fps) on an RTX 3050 Laptop GPU, Release, with about
280 bodies. That covers the physics on the CPU (Jolt's job system uses all but one core)
and the seven passes.

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

`scripts/splat.lua` (and mode 4 of the showcase) renders a 3D Gaussian splatting scene.
The method is Kerbl et al., "3D Gaussian Splatting for Real-Time Radiance Field Rendering"
(2023). The scene is `assets/skull.ply`: 1.9 million Gaussians, each with a position,
rotation, scale, opacity, and degree-3 spherical harmonics for view-dependent color.

| File | Role |
| --- | --- |
| `scripts/splat.lua` | runs it on its own |
| `scripts/lib/splat-mode.lua` | loads the file, builds the render graph, handles input |
| `shaders/splat/ply.slang` | reads splats from the PLY data and places them in the world |
| `shaders/splat/preprocess.slang` | compute: projects each splat, evaluates its color, writes a sort key |
| `shaders/sort/bitonic.slang` | compute: sorts the keys |
| `shaders/splat/render.slang` | draws the sorted splats as blended quads |
| `shaders/post/composite.slang` | puts the result on the window |

**Loading.** `rhi.load_ply` uploads the file's floats unchanged (454 MB). The script reads
the property offsets from `properties` and passes them to the preprocess shader as a
`PlyLayout` struct. The shader then reads each splat's fields wherever the file put
them.

**Every frame**, as a render graph built once in `init()`:

1. **Preprocess** (one thread per splat):
   - **Covariance:** builds the splat's 3D covariance, `R S Sᵀ Rᵀ` from its rotation and
     scale.
   - **Projection:** projects the covariance to a 2D ellipse on screen through the
     Jacobian of the perspective projection (EWA splatting). It adds 0.3 pixels² so every
     splat covers about a pixel.
   - **Color:** evaluates the spherical harmonics in the direction from the camera.
   - **Culling:** splats behind the camera, off screen, or nearly transparent are skipped.
   - **Outputs:** each visible splat writes its ellipse (center and two half axes at 3σ,
     from the eigenvectors of the 2D covariance) and its color. It also writes a sort key,
     the negated view depth.
2. **Sort** the keys with their splat indices, on the GPU, with a bitonic sort.
   - **Padding:** the 1,924,114 splats are padded to 2²¹ with keys that sort last.
   - **Dispatches:** sorting them takes 78 dispatches. One sorts each block of 1024 in
     group shared memory. Then, for every longer sequence length, there is one dispatch
     per long-range step, plus one block dispatch for the remaining short-range steps.
   - **Built in Lua:** Lua creates these dispatches as graph nodes in `init()`, each with a
     parameter block holding its step.
3. **Draw** all splats in one draw of six vertices each, in sorted order, so back to front.
   - **Quads:** the vertex shader places a quad over the splat's ellipse.
   - **Falloff:** the fragment shader applies the Gaussian falloff.
   - **Blending:** the pipeline blends with `premultiplied` alpha.
   - **Culled splats:** they sort to the end and become zero-area quads.
4. **Composite** the result onto the window.

**Color.** Splats are trained against photos, so their colors are display-space values,
and the reference renderer blends them as such. They are blended here the same way, in an
`rgba16f` texture rather than in the window. If the window encodes sRGB itself, the
composite pass converts to linear first (`decodeGamma`), so the window's encoding gives
back the original values.

**Input** only changes the view block: camera, splat size, and the y/z flip. The flip is
needed because COLMAP-based captures are y-down.

**Performance.** On an RTX 3050 Laptop GPU, at the default window size, a frame takes
about 31 ms (≈ 32 fps), in both Debug and Release builds. The frame time is GPU-bound,
spent on projecting, sorting and blending all 1.9 million splats every frame. The usual
next steps, not done here:

- a radix sort in place of the bitonic one
- sorting and drawing only the splats that survive culling (with indirect dispatch and
  draw)
- tile-based compute rasterization, as in the paper, in place of blended quads

## Example: combining passes by depth

`scripts/fusion.lua` (and mode 5 of the showcase) draws three kinds of surface into one
picture: the mesh scene, the Gaussian splats, and a raymarched composition of SDF shapes
(see [SDF compositions](#sdf-compositions)). They are rendered completely separately,
each into its own color texture and its own depth buffer. A last pass then combines the
images per pixel, by which one is nearer the camera:

| Pass | Writes | Reads |
| --- | --- | --- |
| scene: generate sphere, shadow faces | the shadow atlas (the meshes) | |
| splats: shadow casters (once) | each splat's center, opacity and covariance | the PLY data |
| splats: shadow faces | the splat shadow atlas: optical depth and nearest distance | the casters |
| splats: shadow layers faces | the splats' deep opacity map | the casters, the splat shadow atlas |
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
- **Cost:** about 73 ms per frame on an RTX 3050 Laptop GPU (Release, default window
  size), against 31 ms for the splats alone.
  - **The second camera:** about 29 ms of it; with Tab, 43–48 ms (it varied between
    runs). Its pixels are few, but it repeats all the per-splat work: preprocess,
    lighting and the 78 sort dispatches.
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
   - **What it stores:** each splat's center, opacity and 3D covariance in the world.
   - **Placement:** it goes through `shaders/splat/ply.slang`, the same code that places
     and shapes the drawn splats, so the shadows match them exactly.
   - **When it runs:** again when the splat size changes or the shader is edited.
2. **Shadow faces and shadow layers faces** (`shaders/splat/shadow.slang`, six passes each):
   - **Shape:** each splat is drawn as its actual Gaussian seen from the light. Its
     covariance is projected onto the plane facing the light, and a triangle covers the
     resulting ellipse out to 3σ.
   - **Entry points:** `fragmentMain` fills the first map. `layersFragmentMain` fills the
     second, reading the first.

#### Lighting the splats

The point light lights the splats as it lights the meshes: `shaders/splat/lighting.slang`
runs between preprocessing and sorting, one thread per visible splat, and changes the color
preprocess wrote.

- **Shadows:** it looks up the light at the splat's center with `shadowVisibility`, as the
  meshes do. Each splat counts as 0.08 units nearer to the light than its center, so that
  the few splats making up a surface don't shadow each other ("shadow acne").
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

| `relight` | Result |
| --- | --- |
| 1 (default) | lit by the point light, as above |
| 0 | the colors as captured, only darkened where something shadows them, down to `1 - shadowStrength` (0.75 darker) |

The values live in the splat module's lighting block. `splat.setRelight(amount)` changes
`relight`, and `shadowStrength` and `shadowBias` sit next to it in `lib/splat-mode.lua`.

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
  | `time` | seconds since start, the same clock as `rhi.time()` |
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
Scripts still receive these keys.

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
    mode).
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
4. For several modes in one script, follow `showcase.lua`:
   - **Modes**: each mode is a table with `name`, a lazy `init()` and `draw(frame)`.
   - **Shared state**: lives in locals.
   - **Switching**: `switchTo(index)` initializes a mode on first use and updates the
     title with `rhi.set_title`.
   - **Forwarding**: `update`, `draw` and the input callbacks are passed on to the current
     mode.
   - **Graphs**: a mode with a render graph sets it in `on_enter()` and clears it in
     `on_leave()`.
5. Shared Lua code goes in `scripts/lib/` and is loaded with `rhi.include("lib/...")`,
   which watches it for edits. `require` works too, but isn't watched.

## Implementation

Everything is in `examples/lua/example-lua.cpp`, apart from the physics, which is in
`examples/lua/physics.h` and `physics.cpp`.

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
- **Adding a function**:
  1. Write a `static int api...(lua_State*)` in `LuaApp`.
  2. Add it to the matching `luaL_Reg` table in `registerApi`.
  3. Document it here.
