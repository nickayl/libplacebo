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

struct mtl_sw_priv {
    struct pl_sw_fns impl;
    struct mtl_ctx *ctx;
    CAMetalLayer *layer;
    pl_fmt fbo_fmt;

    // in-flight frame state (between start_frame and submit_frame)
    id<CAMetalDrawable> drawable;
    pl_tex fbo;

    // most recently committed present, drained on destroy
    id<MTLCommandBuffer> last_present;
};

static const struct pl_sw_fns mtl_sw_fns;

pl_swapchain pl_mtl_create_swapchain(pl_mtl mtl,
                                     const struct pl_mtl_swapchain_params *params)
{
    struct mtl_ctx *ctx = PL_PRIV(mtl);
    pl_gpu gpu = mtl->gpu;

    CAMetalLayer *layer = params->layer;
    if (!layer) {
        pl_fatal(ctx->log, "pl_mtl_swapchain_params.layer must be set!");
        return NULL;
    }

    struct pl_swapchain_t *sw = pl_zalloc_obj(NULL, sw, struct mtl_sw_priv);
    sw->log = ctx->log;
    sw->gpu = gpu;

    struct mtl_sw_priv *p = PL_PRIV(sw);
    p->impl = mtl_sw_fns;
    p->ctx = ctx;
    p->layer = [layer retain];

    layer.device = ctx->dev;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // Drawables must also work as blit destinations, not just render targets
    layer.framebufferOnly = NO;

    for (int i = 0; i < gpu->num_formats; i++) {
        const struct pl_fmt_mtl *fmtp = PL_PRIV(gpu->formats[i]);
        if (fmtp->mtl_fmt == layer.pixelFormat) {
            p->fbo_fmt = gpu->formats[i];
            break;
        }
    }

    if (!p->fbo_fmt) {
        pl_fatal(ctx->log, "Failed finding a pl_fmt matching the layer's pixel format!");
        [p->layer release];
        pl_free(sw);
        return NULL;
    }

    return sw;
}

static void mtl_sw_destroy(pl_swapchain sw)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);

    // Drain all outstanding presents. Command buffers on the same queue
    // complete in FIFO order, so waiting on the last one suffices.
    [p->last_present waitUntilCompleted];
    [p->last_present release];

    if (p->fbo)
        pl_tex_destroy(sw->gpu, &p->fbo);
    [p->drawable release];

    [p->layer release];
    pl_free((void *) sw);
}

static bool mtl_sw_resize(pl_swapchain sw, int *width, int *height)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);

    @autoreleasepool {
        if (*width && *height)
            p->layer.drawableSize = CGSizeMake(*width, *height);

        const CGSize size = p->layer.drawableSize;
        *width = size.width;
        *height = size.height;
    }

    return true;
}

static bool mtl_sw_start_frame(pl_swapchain sw,
                               struct pl_swapchain_frame *out_frame)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);

    @autoreleasepool {
        // This blocks while all of the layer's drawables are in flight,
        // which is also what paces the rendering loop
        id<CAMetalDrawable> drawable = [[p->layer nextDrawable] retain];
        if (!drawable)
            return false;

        struct pl_tex_t *fbo = pl_zalloc_obj(NULL, fbo, struct pl_tex_mtl);
        struct pl_tex_mtl *texp = PL_PRIV(fbo);
        texp->tex = [drawable.texture retain];

        fbo->sampler_type = PL_SAMPLER_NORMAL;
        fbo->params = (struct pl_tex_params) {
            .w          = texp->tex.width,
            .h          = texp->tex.height,
            .format     = p->fbo_fmt,
            .renderable = true,
            .blit_dst   = true,
            .debug_tag  = PL_DEBUG_TAG,
        };

        p->drawable = drawable;
        p->fbo = fbo;

        struct pl_color_repr repr = pl_color_repr_rgb;
        repr.bits.sample_depth = 8;
        repr.bits.color_depth = 8;

        *out_frame = (struct pl_swapchain_frame) {
            .fbo = fbo,
            .flipped = false,
            .color_repr = repr,
            .color_space = pl_color_space_monitor,
        };
    }

    return true;
}

static bool mtl_sw_submit_frame(pl_swapchain sw)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    struct mtl_ctx *ctx = p->ctx;

    @autoreleasepool {
        id<MTLCommandBuffer> cmdbuf = [ctx->queue commandBuffer];
        [cmdbuf presentDrawable:p->drawable];

        struct mtl_pending use = mtl_commit(ctx, cmdbuf);
        [p->last_present release];
        p->last_present = [use.cmdbuf retain];
        mtl_pending_release(&use);
    }

    pl_tex_destroy(sw->gpu, &p->fbo);
    [p->drawable release];
    p->drawable = nil;

    return true;
}

static void mtl_sw_swap_buffers(pl_swapchain sw)
{
    // Pacing happens in `nextDrawable`, which blocks while the layer's
    // drawable pool is exhausted
}

static const struct pl_sw_fns mtl_sw_fns = {
    .destroy      = mtl_sw_destroy,
    .resize       = mtl_sw_resize,
    .start_frame  = mtl_sw_start_frame,
    .submit_frame = mtl_sw_submit_frame,
    .swap_buffers = mtl_sw_swap_buffers,
};
