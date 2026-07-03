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

struct pl_gpu_mtl {
    struct pl_gpu_fns impl;
    struct mtl_ctx *ctx;
};

pl_gpu mtl_gpu_create(struct mtl_ctx *ctx)
{
    id<MTLDevice> dev = ctx->dev;

    struct pl_gpu_t *gpu = pl_zalloc_obj(NULL, gpu, struct pl_gpu_mtl);
    gpu->log = ctx->log;

    struct pl_gpu_mtl *p = PL_PRIV(gpu);
    p->impl = pl_fns_mtl;
    p->ctx = ctx;

    // Shaders are consumed as vulkan-dialect SPIR-V and cross-compiled to MSL
    gpu->glsl = (struct pl_glsl_version) {
        .version = 450,
        .vulkan = true,
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
        .align_vertex_stride = 4,
        .fragment_queues    = 1,
    };

    mtl_setup_formats(gpu, dev);
    return pl_gpu_finalize(gpu);
}

static void mtl_gpu_destroy(pl_gpu gpu)
{
    pl_free((void *) gpu);
}

// Stub implementations, replaced by the real resource/pass code as the
// backend grows. They fail loudly instead of crashing.

static pl_tex mtl_tex_create(pl_gpu gpu, const struct pl_tex_params *params)
{
    PL_ERR(gpu, "Texture creation is not yet implemented for Metal GPUs");
    return NULL;
}

static void mtl_tex_destroy(pl_gpu gpu, pl_tex tex)
{
    pl_free((void *) tex);
}

static bool mtl_tex_upload(pl_gpu gpu, const struct pl_tex_transfer_params *params)
{
    PL_ERR(gpu, "Texture upload is not yet implemented for Metal GPUs");
    return false;
}

static bool mtl_tex_download(pl_gpu gpu, const struct pl_tex_transfer_params *params)
{
    PL_ERR(gpu, "Texture download is not yet implemented for Metal GPUs");
    return false;
}

static pl_buf mtl_buf_create(pl_gpu gpu, const struct pl_buf_params *params)
{
    PL_ERR(gpu, "Buffer creation is not yet implemented for Metal GPUs");
    return NULL;
}

static void mtl_buf_destroy(pl_gpu gpu, pl_buf buf)
{
    pl_free((void *) buf);
}

static void mtl_buf_write(pl_gpu gpu, pl_buf buf, size_t buf_offset,
                          const void *data, size_t size)
{
    PL_ERR(gpu, "Buffer write is not yet implemented for Metal GPUs");
}

static bool mtl_buf_read(pl_gpu gpu, pl_buf buf, size_t buf_offset,
                         void *dest, size_t size)
{
    PL_ERR(gpu, "Buffer read is not yet implemented for Metal GPUs");
    return false;
}

static void mtl_buf_copy(pl_gpu gpu, pl_buf dst, size_t dst_offset,
                         pl_buf src, size_t src_offset, size_t size)
{
    PL_ERR(gpu, "Buffer copy is not yet implemented for Metal GPUs");
}

static int mtl_desc_namespace(pl_gpu gpu, enum pl_desc_type type)
{
    return 0; // safest behavior: never alias bindings
}

static pl_pass mtl_pass_create(pl_gpu gpu, const struct pl_pass_params *params)
{
    PL_ERR(gpu, "Render passes are not yet implemented for Metal GPUs");
    return NULL;
}

static void mtl_pass_destroy(pl_gpu gpu, pl_pass pass)
{
    pl_free((void *) pass);
}

static void mtl_pass_run(pl_gpu gpu, const struct pl_pass_run_params *params)
{
    PL_ERR(gpu, "Render passes are not yet implemented for Metal GPUs");
}

static void mtl_gpu_finish(pl_gpu gpu)
{
    // no-op (no work is submitted yet)
}

static const struct pl_gpu_fns pl_fns_mtl = {
    .destroy        = mtl_gpu_destroy,
    .tex_create     = mtl_tex_create,
    .tex_destroy    = mtl_tex_destroy,
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
