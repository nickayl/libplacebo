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
#include "../swapchain.h"
#include "../glsl/spirv.h"

#include <TargetConditionals.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <libplacebo/metal.h>

// Fixed argument-table layout: descriptor bindings map 1:1 onto the matching
// Metal buffer/texture/sampler indices, so the top slots stay reserved
#define MTL_VBUF_INDEX  29 // vertex data ([[stage_in]] layout)
#define MTL_PUSHC_INDEX 30 // push constants

// Note: this backend is built without ARC. Ownership of Objective-C objects
// is explicit: whatever is stored in these structs holds a retain reference,
// released by the matching destroy function.

// A (command buffer, shared event value) pair identifying one GPU submission
struct mtl_pending {
    id<MTLCommandBuffer> cmdbuf; // retained
    uint64_t value;              // `mtl_ctx.event` value signaled on completion
};

struct mtl_ctx {
    pl_log log;
    struct pl_mtl_t *mtl;
    id<MTLDevice> dev;
    id<MTLCommandQueue> queue;

    // Signaled by every committed command buffer with a monotonic counter,
    // enabling bounded-timeout waits on individual submissions
    id<MTLSharedEvent> event;
    uint64_t event_value;

    struct mtl_pending last_committed; // most recent commit on `queue`
};

struct pl_gpu_mtl {
    struct pl_gpu_fns impl;
    struct mtl_ctx *ctx;
    pl_spirv spirv;
    id<MTLSamplerState> samplers[PL_TEX_SAMPLE_MODE_COUNT][PL_TEX_ADDRESS_MODE_COUNT];
};

static inline struct mtl_ctx *mtl_ctx_of(pl_gpu gpu)
{
    struct pl_gpu_mtl *p = PL_PRIV(gpu);
    return p->ctx;
}

struct pl_fmt_mtl {
    MTLPixelFormat mtl_fmt;
    MTLVertexFormat mtl_vfmt; // MTLVertexFormatInvalid if not vertex-capable
};

struct pl_buf_mtl {
    id<MTLBuffer> buf;
    struct mtl_pending pending; // last GPU use
};

struct pl_tex_mtl {
    id<MTLTexture> tex;
    struct mtl_pending pending; // last GPU use
};

struct pl_pass_mtl {
    id<MTLRenderPipelineState> rps;  // raster passes
    id<MTLComputePipelineState> cps; // compute passes
    MTLPrimitiveType prim;
    MTLSize group_size;

    // Push constants staging: the cross-compiled MSL struct is padded to its
    // natural alignment, and Metal validates the bound length against the
    // padded size, so the bytes are staged into a zero-padded scratch
    size_t pushc_size;
    uint8_t *pushc;
};

#define MTL_TIMER_SLOTS 8

// Timings come from MTLCommandBuffer's GPUStartTime/GPUEndTime, which are
// only valid after completion: the timer keeps references to the timed
// submissions and harvests them lazily on query, so no completion handlers
// (and no lifetime hazards) are involved
struct pl_timer_t {
    struct mtl_pending pending[MTL_TIMER_SLOTS]; // in-flight timed submissions
    int num_pending;
    uint64_t results[MTL_TIMER_SLOTS]; // harvested durations, in ns
    int num_results;
};

// Tracks `use` as a timed submission of `timer` (NULL timer is a no-op)
void mtl_timer_record(pl_timer timer, const struct mtl_pending *use);

pl_gpu mtl_gpu_create(struct mtl_ctx *ctx);
void mtl_setup_formats(struct pl_gpu_t *gpu, id<MTLDevice> dev);

// GPU-GPU hazards are handled by Metal's automatic hazard tracking (all work
// goes through one queue); these helpers cover CPU<->GPU coherency. Every
// resource carries a `pending` slot referencing the last submission that
// used it on the GPU: CPU access waits on it, polls query it.

// Encodes the shared-event signal, commits `cmdbuf`, and tracks it as the
// most recent commit. Returns the submission, retained (+1)
struct mtl_pending mtl_commit(struct mtl_ctx *ctx, id<MTLCommandBuffer> cmdbuf);

// Retains `use` as the new pending use in `slot`
void mtl_mark_pending(struct mtl_pending *slot, const struct mtl_pending *use);

// Releases and clears a pending reference (without waiting)
void mtl_pending_release(struct mtl_pending *p);

// Whether the pending use (if any) is still executing
bool mtl_pending_busy(struct mtl_ctx *ctx, const struct mtl_pending *p);

// Blocks until the pending use (if any) completed, then clears the slot
void mtl_pending_wait(struct mtl_ctx *ctx, struct mtl_pending *slot);

// Waits for the pending use up to `timeout` nanoseconds (0 = never blocks,
// UINT64_MAX = blocks indefinitely). Returns whether it is still executing
bool mtl_pending_wait_timeout(struct mtl_ctx *ctx, struct mtl_pending *slot,
                              uint64_t timeout);

// Encodes `block` into a one-shot blit command buffer and commits it without
// waiting. Returns the submission, retained (+1)
struct mtl_pending mtl_blit_submit(struct mtl_ctx *ctx,
                                   void (^block)(id<MTLBlitCommandEncoder> enc));

// Logs an error if the completed command buffer failed to execute
void mtl_cmdbuf_check(struct mtl_ctx *ctx, id<MTLCommandBuffer> cmdbuf);

// pl_gpu_fns entry points implemented in gpu_buf.m / gpu_tex.m
pl_buf mtl_buf_create(pl_gpu gpu, const struct pl_buf_params *params);
void mtl_buf_destroy(pl_gpu gpu, pl_buf buf);
void mtl_buf_write(pl_gpu gpu, pl_buf buf, size_t buf_offset,
                   const void *data, size_t size);
bool mtl_buf_read(pl_gpu gpu, pl_buf buf, size_t buf_offset,
                  void *dest, size_t size);
void mtl_buf_copy(pl_gpu gpu, pl_buf dst, size_t dst_offset,
                  pl_buf src, size_t src_offset, size_t size);
bool mtl_buf_poll(pl_gpu gpu, pl_buf buf, uint64_t timeout);
pl_tex mtl_tex_create(pl_gpu gpu, const struct pl_tex_params *params);
void mtl_tex_destroy(pl_gpu gpu, pl_tex tex);
void mtl_tex_clear_ex(pl_gpu gpu, pl_tex tex, const union pl_clear_color color);
void mtl_tex_blit(pl_gpu gpu, const struct pl_tex_blit_params *params);
bool mtl_tex_upload(pl_gpu gpu, const struct pl_tex_transfer_params *params);
bool mtl_tex_download(pl_gpu gpu, const struct pl_tex_transfer_params *params);
bool mtl_tex_poll(pl_gpu gpu, pl_tex tex, uint64_t timeout);
pl_pass mtl_pass_create(pl_gpu gpu, const struct pl_pass_params *params);
void mtl_pass_destroy(pl_gpu gpu, pl_pass pass);
void mtl_pass_run(pl_gpu gpu, const struct pl_pass_run_params *params);
