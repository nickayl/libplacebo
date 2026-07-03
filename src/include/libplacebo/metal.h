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

struct pl_mtl_swapchain_params {
    // The CAMetalLayer to present to. Required. libplacebo takes a reference
    // to the layer and configures its device and pixel format.
    pl_mtl_layer layer;
};

#define pl_mtl_swapchain_params(...) (&(struct pl_mtl_swapchain_params) { __VA_ARGS__ })

// Creates a new Metal swapchain presenting to the given CAMetalLayer.
// Returns NULL on failure.
PL_API pl_swapchain pl_mtl_create_swapchain(pl_mtl mtl,
    const struct pl_mtl_swapchain_params *params);

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
