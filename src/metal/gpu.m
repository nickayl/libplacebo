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
        .thread_safe        = true,

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

    for (int s = 0; s < PL_TEX_SAMPLE_MODE_COUNT; s++) {
        for (int a = 0; a < PL_TEX_ADDRESS_MODE_COUNT; a++)
            [p->samplers[s][a] release];
    }

    pl_spirv_destroy(&p->spirv);
    pl_free((void *) gpu);
}

void mtl_blit_sync(struct mtl_ctx *ctx, void (^block)(id<MTLBlitCommandEncoder> enc))
{
    @autoreleasepool {
        id<MTLCommandBuffer> cmdbuf = [ctx->queue commandBuffer];
        id<MTLBlitCommandEncoder> enc = [cmdbuf blitCommandEncoder];
        block(enc);
        [enc endEncoding];
        [cmdbuf commit];
        [cmdbuf waitUntilCompleted];
    }
}

static int mtl_desc_namespace(pl_gpu gpu, enum pl_desc_type type)
{
    // Single namespace: bindings are unique across all descriptor types, so
    // each binding number maps 1:1 onto the Metal argument-table indices
    return 0;
}

static void mtl_gpu_finish(pl_gpu gpu)
{
    // no-op (no work is submitted yet)
}

static const struct pl_gpu_fns pl_fns_mtl = {
    .destroy        = mtl_gpu_destroy,
    .tex_create     = mtl_tex_create,
    .tex_destroy    = mtl_tex_destroy,
    .tex_clear_ex   = mtl_tex_clear_ex,
    .tex_blit       = mtl_tex_blit,
    .tex_upload     = mtl_tex_upload,
    .tex_download   = mtl_tex_download,
    .buf_create     = mtl_buf_create,
    .buf_destroy    = mtl_buf_destroy,
    .buf_write      = mtl_buf_write,
    .buf_read       = mtl_buf_read,
    .buf_copy       = mtl_buf_copy,
    .desc_namespace = mtl_desc_namespace,
    .pass_create    = mtl_pass_create,
    .pass_destroy   = mtl_pass_destroy,
    .pass_run       = mtl_pass_run,
    .gpu_finish     = mtl_gpu_finish,
};
