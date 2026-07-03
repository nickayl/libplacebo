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

#include "common.h"

static const struct pl_gpu_fns pl_fns_mtl;
static void mtl_gpu_destroy(pl_gpu gpu);

pl_gpu mtl_gpu_create(struct mtl_ctx *ctx)
{
    id<MTLDevice> dev = ctx->dev;

    struct pl_gpu_t *gpu = pl_zalloc_obj(NULL, gpu, struct pl_gpu_mtl);
    gpu->log = ctx->log;

    struct pl_gpu_mtl *p = PL_PRIV(gpu);
    p->impl = pl_fns_mtl;
    p->ctx = ctx;

    // External MTLTextures (e.g. from CVMetalTextureCache) can be imported
    gpu->import_caps.tex = PL_HANDLE_MTL_TEX;

    const MTLSize max_group = dev.maxThreadsPerThreadgroup;

    // Shaders are consumed as vulkan-dialect SPIR-V and cross-compiled to MSL.
    // 512 is a conservative per-pipeline total-threads floor; the queryable
    // device maximum only holds for pipelines without register pressure.
    gpu->glsl = (struct pl_glsl_version) {
        .version = 450,
        .vulkan = true,
        .compute = true,
        .max_shmem_size = dev.maxThreadgroupMemoryLength,
        .max_group_threads = 512,
        .max_group_size = { max_group.width, max_group.height, max_group.depth },
    };

    uint32_t max_tex_2d = 8192;
    if ([dev supportsFamily:MTLGPUFamilyApple3] ||
        [dev supportsFamily:MTLGPUFamilyMac2])
    {
        max_tex_2d = 16384;
    }

    gpu->limits = (struct pl_gpu_limits) {
        // The pending-use tracking is not internally synchronized
        .thread_safe        = false,

        // pl_buf
        .max_buf_size       = dev.maxBufferLength,
        .max_ubo_size       = dev.maxBufferLength,
        .max_ssbo_size      = dev.maxBufferLength,
        .max_vbo_size       = dev.maxBufferLength,
        .max_mapped_size    = dev.maxBufferLength,
        .host_cached        = true,

        // pl_tex
        .max_tex_1d_dim     = max_tex_2d,
        .max_tex_2d_dim     = max_tex_2d,
        .max_tex_3d_dim     = 2048,
        .buf_transfer       = true,
        .align_tex_xfer_pitch = 1,
        .align_tex_xfer_offset = 16,

        // pl_pass
        .max_pushc_size     = 4096, // setBytes limit
        .align_vertex_stride = 4,
        .max_dispatch       = { 65535, 65535, 65535 },
        .fragment_queues    = 1,
        .compute_queues     = 1,
    };

    const uint32_t spirv_ver = PL_MAX_SPIRV_VER;
    p->spirv = pl_spirv_create(ctx->log, (struct pl_spirv_version) {
        .env_version = pl_spirv_version_to_vulkan(spirv_ver),
        .spv_version = spirv_ver,
    });

    if (!p->spirv) {
        PL_FATAL(ctx, "Failed initializing a GLSL to SPIR-V compiler!");
        goto error;
    }

    @autoreleasepool {
        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        static const MTLSamplerAddressMode address_modes[PL_TEX_ADDRESS_MODE_COUNT] = {
            [PL_TEX_ADDRESS_CLAMP]  = MTLSamplerAddressModeClampToEdge,
            [PL_TEX_ADDRESS_REPEAT] = MTLSamplerAddressModeRepeat,
            [PL_TEX_ADDRESS_MIRROR] = MTLSamplerAddressModeMirrorRepeat,
        };

        for (int s = 0; s < PL_TEX_SAMPLE_MODE_COUNT; s++) {
            const MTLSamplerMinMagFilter filter = s == PL_TEX_SAMPLE_LINEAR
                ? MTLSamplerMinMagFilterLinear
                : MTLSamplerMinMagFilterNearest;
            for (int a = 0; a < PL_TEX_ADDRESS_MODE_COUNT; a++) {
                sd.minFilter = filter;
                sd.magFilter = filter;
                sd.sAddressMode = address_modes[a];
                sd.tAddressMode = address_modes[a];
                sd.rAddressMode = address_modes[a];
                p->samplers[s][a] = [dev newSamplerStateWithDescriptor:sd];
                if (!p->samplers[s][a]) {
                    PL_FATAL(ctx, "Failed creating sampler states!");
                    [sd release];
                    goto error;
                }
            }
        }
        [sd release];
    }

    mtl_setup_formats(gpu, dev);
    return pl_gpu_finalize(gpu);

error:
    mtl_gpu_destroy(gpu);
    return NULL;
}

static void mtl_gpu_destroy(pl_gpu gpu)
{
    struct pl_gpu_mtl *p = PL_PRIV(gpu);

    // Command buffers on one queue complete in FIFO order, so draining the
    // most recent commit drains everything
    if (p->ctx)
        mtl_pending_wait(p->ctx, &p->ctx->last_committed);

    for (int s = 0; s < PL_TEX_SAMPLE_MODE_COUNT; s++) {
        for (int a = 0; a < PL_TEX_ADDRESS_MODE_COUNT; a++)
            [p->samplers[s][a] release];
    }

    pl_spirv_destroy(&p->spirv);
    pl_free((void *) gpu);
}

pl_mtl pl_mtl_get(pl_gpu gpu)
{
    const struct pl_gpu_fns *impl = PL_PRIV(gpu);
    if (impl->destroy == mtl_gpu_destroy) {
        struct pl_gpu_mtl *p = (struct pl_gpu_mtl *) impl;
        return p->ctx->mtl;
    }

    return NULL;
}

void mtl_cmdbuf_check(struct mtl_ctx *ctx, id<MTLCommandBuffer> cmdbuf)
{
    if (cmdbuf.status == MTLCommandBufferStatusError) {
        PL_ERR(ctx, "Command buffer execution failed: %s",
               cmdbuf.error.localizedDescription.UTF8String);
    }
}

struct mtl_pending mtl_commit(struct mtl_ctx *ctx, id<MTLCommandBuffer> cmdbuf)
{
    struct mtl_pending use = { .cmdbuf = [cmdbuf retain] };

    if (ctx->event) {
        use.value = ++ctx->event_value;
        [cmdbuf encodeSignalEvent:ctx->event value:use.value];
    }

    [cmdbuf commit];
    mtl_mark_pending(&ctx->last_committed, &use);
    return use;
}

void mtl_mark_pending(struct mtl_pending *slot, const struct mtl_pending *use)
{
    [use->cmdbuf retain];
    [slot->cmdbuf release];
    *slot = *use;
}

void mtl_pending_release(struct mtl_pending *p)
{
    [p->cmdbuf release];
    *p = (struct mtl_pending) {0};
}

bool mtl_pending_busy(struct mtl_ctx *ctx, const struct mtl_pending *p)
{
    if (!p->cmdbuf)
        return false;
    if (ctx->event && p->value)
        return ctx->event.signaledValue < p->value;
    return p->cmdbuf.status < MTLCommandBufferStatusCompleted;
}

void mtl_pending_wait(struct mtl_ctx *ctx, struct mtl_pending *slot)
{
    if (!slot->cmdbuf)
        return;

    [slot->cmdbuf waitUntilCompleted];
    mtl_cmdbuf_check(ctx, slot->cmdbuf);
    mtl_pending_release(slot);
}

bool mtl_pending_wait_timeout(struct mtl_ctx *ctx, struct mtl_pending *slot,
                              uint64_t timeout)
{
    if (!slot->cmdbuf)
        return false;

    if (!mtl_pending_busy(ctx, slot)) {
        mtl_cmdbuf_check(ctx, slot->cmdbuf);
        mtl_pending_release(slot);
        return false;
    }

    if (!timeout)
        return true;

    if (timeout == UINT64_MAX) {
        mtl_pending_wait(ctx, slot);
        return false;
    }

    bool busy = true;
    if (ctx->event && slot->value) {
        if (@available(macOS 12.0, iOS 15.0, *)) {
            const uint64_t ms = (timeout + 999999) / 1000000;
            busy = ![ctx->event waitUntilSignaledValue:slot->value timeoutMS:ms];
        }
    }

    if (!busy) {
        mtl_cmdbuf_check(ctx, slot->cmdbuf);
        mtl_pending_release(slot);
    }

    return busy;
}

struct mtl_pending mtl_blit_submit(struct mtl_ctx *ctx,
                                   void (^block)(id<MTLBlitCommandEncoder> enc))
{
    @autoreleasepool {
        id<MTLCommandBuffer> cmdbuf = [ctx->queue commandBuffer];
        id<MTLBlitCommandEncoder> enc = [cmdbuf blitCommandEncoder];
        block(enc);
        [enc endEncoding];
        return mtl_commit(ctx, cmdbuf);
    }
}

static int mtl_desc_namespace(pl_gpu gpu, enum pl_desc_type type)
{
    // Single namespace: bindings are unique across all descriptor types, so
    // each binding number maps 1:1 onto the Metal argument-table indices
    return 0;
}

static pl_timer mtl_timer_create(pl_gpu gpu)
{
    return pl_zalloc(NULL, sizeof(struct pl_timer_t));
}

static void mtl_timer_destroy(pl_gpu gpu, pl_timer timer)
{
    for (int i = 0; i < timer->num_pending; i++)
        mtl_pending_release(&timer->pending[i]);
    pl_free(timer);
}

void mtl_timer_record(pl_timer timer, const struct mtl_pending *use)
{
    if (!timer)
        return;

    // Best-effort: drop the oldest measurement when the ring is full
    if (timer->num_pending == MTL_TIMER_SLOTS) {
        mtl_pending_release(&timer->pending[0]);
        memmove(&timer->pending[0], &timer->pending[1],
                (MTL_TIMER_SLOTS - 1) * sizeof(timer->pending[0]));
        timer->num_pending--;
    }

    timer->pending[timer->num_pending] = (struct mtl_pending) {0};
    mtl_mark_pending(&timer->pending[timer->num_pending], use);
    timer->num_pending++;
}

static uint64_t mtl_timer_query(pl_gpu gpu, pl_timer timer)
{
    // Harvest all completed submissions, in order
    int done = 0;
    while (done < timer->num_pending) {
        id<MTLCommandBuffer> cmdbuf = timer->pending[done].cmdbuf;
        if (cmdbuf.status < MTLCommandBufferStatusCompleted)
            break;

        if (cmdbuf.status == MTLCommandBufferStatusCompleted &&
            timer->num_results < MTL_TIMER_SLOTS)
        {
            const double duration = cmdbuf.GPUEndTime - cmdbuf.GPUStartTime;
            if (duration > 0)
                timer->results[timer->num_results++] = duration * 1e9;
        }

        mtl_pending_release(&timer->pending[done]);
        done++;
    }

    if (done) {
        memmove(&timer->pending[0], &timer->pending[done],
                (timer->num_pending - done) * sizeof(timer->pending[0]));
        timer->num_pending -= done;
    }

    if (!timer->num_results)
        return 0;

    const uint64_t result = timer->results[0];
    timer->num_results--;
    memmove(&timer->results[0], &timer->results[1],
            timer->num_results * sizeof(timer->results[0]));
    return result;
}

static void mtl_gpu_finish(pl_gpu gpu)
{
    struct pl_gpu_mtl *p = PL_PRIV(gpu);
    mtl_pending_wait(p->ctx, &p->ctx->last_committed);
}

static const struct pl_gpu_fns pl_fns_mtl = {
    .destroy        = mtl_gpu_destroy,
    .tex_create     = mtl_tex_create,
    .tex_destroy    = mtl_tex_destroy,
    .tex_clear_ex   = mtl_tex_clear_ex,
    .tex_blit       = mtl_tex_blit,
    .tex_upload     = mtl_tex_upload,
    .tex_download   = mtl_tex_download,
    .tex_poll       = mtl_tex_poll,
    .buf_create     = mtl_buf_create,
    .buf_destroy    = mtl_buf_destroy,
    .buf_write      = mtl_buf_write,
    .buf_read       = mtl_buf_read,
    .buf_copy       = mtl_buf_copy,
    .buf_poll       = mtl_buf_poll,
    .desc_namespace = mtl_desc_namespace,
    .pass_create    = mtl_pass_create,
    .pass_destroy   = mtl_pass_destroy,
    .pass_run       = mtl_pass_run,
    .timer_create   = mtl_timer_create,
    .timer_destroy  = mtl_timer_destroy,
    .timer_query    = mtl_timer_query,
    .gpu_finish     = mtl_gpu_finish,
};
