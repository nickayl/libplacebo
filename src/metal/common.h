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
 * License along with libplacebo. If not, see <http://www.gnu.org/licenses/>.
 */

#pragma once

#include "../common.h"
#include "../log.h"
#include "../gpu.h"

#include <TargetConditionals.h>
#import <Metal/Metal.h>

#include <libplacebo/metal.h>

// Note: this backend is built without ARC. Ownership of Objective-C objects
// is explicit: whatever is stored in these structs holds a retain reference,
// released by the matching destroy function.

struct mtl_ctx {
    pl_log log;
    struct pl_mtl_t *mtl;
    id<MTLDevice> dev;
    id<MTLCommandQueue> queue;
};

struct pl_gpu_mtl {
    struct pl_gpu_fns impl;
    struct mtl_ctx *ctx;
};

static inline struct mtl_ctx *mtl_ctx_of(pl_gpu gpu)
{
    struct pl_gpu_mtl *p = PL_PRIV(gpu);
    return p->ctx;
}

struct pl_fmt_mtl {
    MTLPixelFormat mtl_fmt;
};

struct pl_buf_mtl {
    id<MTLBuffer> buf;
};

struct pl_tex_mtl {
    id<MTLTexture> tex;
};

pl_gpu mtl_gpu_create(struct mtl_ctx *ctx);
void mtl_setup_formats(struct pl_gpu_t *gpu, id<MTLDevice> dev);

// Encodes `block` into a one-shot blit command buffer and blocks until the
// GPU finished executing it
void mtl_blit_sync(struct mtl_ctx *ctx, void (^block)(id<MTLBlitCommandEncoder> enc));

// pl_gpu_fns entry points implemented in gpu_buf.m / gpu_tex.m
pl_buf mtl_buf_create(pl_gpu gpu, const struct pl_buf_params *params);
void mtl_buf_destroy(pl_gpu gpu, pl_buf buf);
void mtl_buf_write(pl_gpu gpu, pl_buf buf, size_t buf_offset,
                   const void *data, size_t size);
bool mtl_buf_read(pl_gpu gpu, pl_buf buf, size_t buf_offset,
                  void *dest, size_t size);
void mtl_buf_copy(pl_gpu gpu, pl_buf dst, size_t dst_offset,
                  pl_buf src, size_t src_offset, size_t size);
pl_tex mtl_tex_create(pl_gpu gpu, const struct pl_tex_params *params);
void mtl_tex_destroy(pl_gpu gpu, pl_tex tex);
bool mtl_tex_upload(pl_gpu gpu, const struct pl_tex_transfer_params *params);
bool mtl_tex_download(pl_gpu gpu, const struct pl_tex_transfer_params *params);
