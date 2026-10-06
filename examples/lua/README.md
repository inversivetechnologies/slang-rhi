# Lua examples

`example-lua` is a host application that runs Lua scripts on top of slang-rhi. It opens a
single window on a single graphics API (Vulkan unless told otherwise). The host owns the
window, the device, the swapchain and the frame loop; a script decides what gets
created and drawn, and reacts to input. Scripts and shaders reload while the program runs,
so most iteration happens without a rebuild.

All examples are scripts:

| Script | What it shows |
| --- | --- |
| `examples/lua/showcase.lua` | every mode below in one window, switchable at runtime |
| `examples/surface/surface.lua` | clearing the window |
| `examples/scene/scene.lua` | a lit 3D scene: a GPU-generated spherified cube, a cube and a floor, with a point light, realtime shadow mapping and a second camera composited into the corner -- built as a render graph the host runs without Lua |
| `examples/shader-toy/shader-toy.lua` | ShaderToy-style compute shaders blitted to the window |

## Running

```
example-lua                        # the showcase, on Vulkan
example-lua scene                  # examples/scene/scene.lua
example-lua showcase               # examples/lua/showcase.lua
example-lua path/to/my.lua         # any script
example-lua --api d3d12 scene      # pick the graphics API
example-lua --help                 # usage, APIs and the list of examples
```

A name is looked up as `examples/<name>/<name>.lua`, then as `examples/lua/<name>.lua`.
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
| `1` .. `6` | jump to a mode |
| Steam Controller LB / RB | previous / next mode |
| Left mouse button | moves `iMouse` in the ShaderToy modes |
| Escape | gives the mouse pointer back (click the window to hide it again) |
| F11 | toggles fullscreen |

The modes are Surface, Scene, and the ShaderToy shaders Circle, Ocean, 2D SDFs and
Controller. The current mode is shown in the window title. A ShaderToy mode whose shader
doesn't compile shows dark red until it does.

### The scene

`example-lua scene`, or mode 2 of the showcase.

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
}
```

- **Paths**: shader paths are relative to the script.
- **`layout`**: describes one interleaved vertex stream. Each attribute's offset follows the
  one before it, and the stride is the sum of all of them. Leave `layout` out for shaders
  that generate their vertices from `SV_VertexID`.
- **`format`**: the color format the pipeline writes. Leave it out to draw into the
  window. Set it to a texture's format to draw into that texture (see [Drawing into a
  texture](#drawing-into-a-texture)).
- **`depth = true`**: the pipeline tests and writes a depth buffer (32-bit float, closer is
  smaller, compare less). The host keeps one depth buffer per destination: one for the
  window and one for each texture drawn into, each the size of its destination. Without
  `depth`, depth testing is off.
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
- **`rhi.buffer`** creates a read/write structured or byte-address buffer.
  `rhi.vertex_buffer` is only for vertex input.

### Other

| Call | |
| --- | --- |
| `rhi.device()` | the backend's name, e.g. `"Vulkan"` |
| `rhi.time()` | seconds since start |
| `rhi.set_title(text)` | sets the window title; the backend and GPU are appended |
| `rhi.include(path)` | runs a Lua file (relative to the script) and returns its result; saving that file reloads the script |
| `rhi.window_srgb()` | `true` if the window's format encodes sRGB itself (as `frame.srgb`, but usable in `init`) |
| `rhi.params{...}`, `rhi.graph()`, `rhi.set_graph(graph)` | see [Render graphs](#render-graphs) |

`rhi.include` is for sharing Lua code between scripts in different folders. The showcase
uses it to run `examples/scene/scene-mode.lua`. Within one folder, `require` works too,
but a file loaded with `require` isn't watched for edits.

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
needs no `layout` and no index buffer. `examples/scene` does this for its spherified cube:

```lua
-- init(): allocate once, for the largest mesh
generate = rhi.compute_pipeline("spherified-cube.slang", "generateMain")
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
| `graph:render_pass{ name, target, clear, viewport \| viewport_fraction }` | adds a render pass, run in the order added |
| `pass:draw{ pipeline, count, vertices, params }` | adds a draw to a render pass, run in the order added |
| `graph:dispatch{ name, pipeline, params, threads = {x, y, z}, once }` | adds a compute dispatch |
| `rhi.set_graph(graph)` | makes the host run `graph` every frame, before `draw`; `nil` stops it |

- **`render_pass` options:**
  - `target`: a texture to draw into. Leave it out to draw into the window.
  - `clear`: clears the target first (and its depth buffer).
  - `viewport` is in pixels. `viewport_fraction` is in fractions of the target's size, so
    it follows window resizes.
- **Depth:** a pass uses its target's depth buffer when any of its draws' pipelines has
  `depth = true`. All draws in one pass should agree on depth.
- **`dispatch` with `once = true`:** the dispatch runs on the first frame, then again only
  after `node:rerun()` or when its pipeline is rebuilt by a hot reload.

### Changing a graph after init

The graph's shape is fixed, but its values can change. Every handle the building calls
return can be adjusted later, typically from an input handler:

| Handle | Settable |
| --- | --- |
| pass | `enabled`, `clear`, `viewport`, `viewport_fraction` |
| dispatch | `enabled`, `threads`, and `:rerun()` |
| draw | `count`, `enabled` |
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

## Example: a scene as a render graph

`examples/scene` renders a small scene lit by an orbiting point light with realtime
shadows. A second camera's view is composited into the lower right corner. All of it is
one render graph, built in `init()`:

| File | Role |
| --- | --- |
| `scene.lua` | runs the scene on its own |
| `scene-mode.lua` | the scene itself: builds the graph, and handles input |
| `mesh-vertex.slang` | the vertex format shared by all meshes |
| `spherified-cube.slang` | compute shader that generates the sphere |
| `scene-common.slang` | the light, object transforms (both animated by `time`), and the shadow atlas layout |
| `shadow.slang` | shadow pass: writes distances from the light |
| `lit.slang` | lit pass: shading, attenuation and the shadow lookup |
| `composite.slang` | copies a texture into a viewport, with a border |

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

The ShaderToy uniforms in `examples/shader-toy/shader-toy.slang` are a complete example:

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

1. Create `examples/<name>/<name>.lua` next to the example's shaders. It then runs with
   `example-lua <name>`.
2. Start from `config` plus `init` and `draw`. The smallest complete example is
   `surface.lua`. `scene/scene-mode.lua` shows a complete 3D setup as a render graph.
3. For several modes in one script, follow `showcase.lua`:
   - **Modes**: each mode is a table with `name`, a lazy `init()` and `draw(frame)`.
   - **Shared state**: lives in locals.
   - **Switching**: `switchTo(index)` initializes a mode on first use and updates the
     title with `rhi.set_title`.
   - **Forwarding**: `update`, `draw` and the input callbacks are passed on to the current
     mode.
   - **Graphs**: a mode with a render graph sets it in `on_enter()` and clears it in
     `on_leave()`.
4. Shared Lua code can go in a module loaded with `rhi.include` (watched for edits). Code
   next to the script can also be loaded with `require` (not watched).

## Implementation

Everything is in `examples/lua/example-lua.cpp`.

- **Base layer**: the window, input and Steam Controller handling are the shared example
  base (`examples/base/example-base.h`).
- **Lua build**: Lua 5.4 is fetched by CMake and compiled as C++. A Lua error therefore
  unwinds through the host as an exception, which releases GPU objects and closes any open
  pass.
- **Adding a function**:
  1. Write a `static int api...(lua_State*)` in `LuaApp`.
  2. Add it to the matching `luaL_Reg` table in `registerApi`.
  3. Document it here.
