/*
 * This file is part of libplacebo.
 *
 * libplacebo is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * libplacebo is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with libplacebo.  If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef LIBPLACEBO_METAL_H_
#define LIBPLACEBO_METAL_H_

#include <libplacebo/gpu.h>
#include <libplacebo/swapchain.h>

PL_API_BEGIN

// Opaque Metal object handles. When this header is consumed from Objective-C
// these are the real typed objects; from plain C/C++ they degrade to void
// pointers that can be bridged from `id<MTLDevice>` etc. by the caller.
#ifdef __OBJC__
@protocol MTLDevice;
@protocol MTLTexture;
@class CAMetalLayer;
typedef id<MTLDevice> pl_mtl_device;
typedef id<MTLTexture> pl_mtl_tex;
typedef CAMetalLayer *pl_mtl_layer;
#else
typedef void *pl_mtl_device;
typedef void *pl_mtl_tex;
typedef void *pl_mtl_layer;
#endif

// Structure representing the actual Metal device and associated GPU instance
typedef const struct pl_mtl_t {
    pl_gpu gpu;

    // The Metal device in use. Retained by libplacebo for the lifetime of
    // this object. The user is free to use it for their own purposes.
    pl_mtl_device device;
} *pl_mtl;

struct pl_mtl_params {
    // The Metal device to use. Optional, if NULL then libplacebo will use the
    // system default device (`MTLCreateSystemDefaultDevice`). If set,
    // libplacebo takes its own reference to the device.
    pl_mtl_device device;
};

// Default/recommended parameters. Should generally be safe and efficient.
#define PL_MTL_DEFAULTS \
    .device = NULL,

#define pl_mtl_params(...) (&(struct pl_mtl_params) { PL_MTL_DEFAULTS __VA_ARGS__ })
PL_API extern const struct pl_mtl_params pl_mtl_default_params;

// Creates a new Metal device based on the given parameters, or wraps an
// existing device, and initializes a new GPU instance. If params is left as
// NULL, it defaults to &pl_mtl_default_params. Returns NULL on failure.
PL_API pl_mtl pl_mtl_create(pl_log log, const struct pl_mtl_params *params);

// Release the Metal device.
//
// Note that all libplacebo objects allocated from this pl_mtl object (e.g.
// via `mtl->gpu`) *must* be explicitly destroyed by the user before calling
// this.
PL_API void pl_mtl_destroy(pl_mtl *mtl);

// For a `pl_gpu` backed by `pl_mtl`, this function can be used to retrieve
// the underlying `pl_mtl`. Returns NULL for any other type of `gpu`.
PL_API pl_mtl pl_mtl_get(pl_gpu gpu);

// Frame-mirror callback for Picture in Picture / AirPlay: invoked after each presented frame with
// the frame's backing IOSurface (as a void* IOSurfaceRef, retained for the duration of the call)
// plus its pixel dimensions, so a host can wrap it in a CVPixelBuffer and enqueue it into an
// AVSampleBufferDisplayLayer. Fired on a GPU-completion thread once the frame has finished
// rendering; the host must hop to its own queue. `priv` is `frame_callback_priv` from the params.
typedef void (*pl_mtl_frame_cb)(void *priv, void *iosurface, int width, int height);

struct pl_mtl_swapchain_params {
    // The CAMetalLayer to present to. Required. libplacebo takes a reference
    // to the layer and configures its device and pixel format.
    pl_mtl_layer layer;

    // Optional. When set, each presented frame's backing IOSurface is mirrored to this callback
    // (see pl_mtl_frame_cb). Requires the layer to allow IOSurface-backed drawables (libplacebo
    // sets `framebufferOnly = NO`). NULL disables mirroring with zero overhead.
    pl_mtl_frame_cb frame_callback;
    void *frame_callback_priv;
};

#define pl_mtl_swapchain_params(...) (&(struct pl_mtl_swapchain_params) { __VA_ARGS__ })

// Creates a new Metal swapchain presenting to the given CAMetalLayer.
// Returns NULL on failure.
PL_API pl_swapchain pl_mtl_create_swapchain(pl_mtl mtl,
    const struct pl_mtl_swapchain_params *params);

// Sets (or clears, with w or h == 0) the crop applied to mirrored frames, in surface pixels.
// When set, the frame callback receives a BGRA8 copy of the crop region (GPU blit, converting
// from HDR formats as needed) instead of the full surface — e.g. the video rect inside a
// letterboxed surface. Thread-safe; no-op on non-Metal swapchains. Full frame by default.
PL_API void pl_mtl_swapchain_set_frame_mirror_crop(pl_swapchain sw, int x, int y, int w, int h);

struct pl_mtl_wrap_params {
    // The MTLTexture to wrap. Must have been created by the same device used
    // by `gpu`, with a pixel format corresponding to one of the GPU's `pl_fmt`
    // formats, and must not be mipmapped or multisampled.
    pl_mtl_tex tex;
};

#define pl_mtl_wrap_params(...) (&(struct pl_mtl_wrap_params) { __VA_ARGS__ })

// Wraps an external texture into a pl_tex abstraction. `pl_mtl_wrap` takes a
// reference to the texture, which is released when `pl_tex_destroy` is called.
// The resulting capabilities are inferred from the texture's usage flags and
// storage mode. Returns NULL on failure.
PL_API pl_tex pl_mtl_wrap(pl_gpu gpu, const struct pl_mtl_wrap_params *params);

PL_API_END

#endif // LIBPLACEBO_METAL_H_
