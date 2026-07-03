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

#include "../pl_thread.h"

struct mtl_sw_priv {
    struct pl_sw_fns impl;
    struct mtl_ctx *ctx;
    CAMetalLayer *layer;
    pl_mutex lock;

    // current target configuration (see mtl_sw_configure)
    pl_fmt fbo_fmt;
    struct pl_color_space csp;

    // in-flight frame state (between start_frame and submit_frame)
    id<CAMetalDrawable> drawable;
    pl_tex fbo;

    // most recently committed present, drained on destroy
    id<MTLCommandBuffer> last_present;
};

static const struct pl_sw_fns mtl_sw_fns;

static pl_fmt mtl_sw_find_fmt(pl_gpu gpu, MTLPixelFormat pixfmt)
{
    for (int i = 0; i < gpu->num_formats; i++) {
        const struct pl_fmt_mtl *fmtp = PL_PRIV(gpu->formats[i]);
        if (fmtp->mtl_fmt == pixfmt)
            return gpu->formats[i];
    }

    return NULL;
}

// (Re)configures the layer's pixel format and color space for the hinted
// input color space, falling back to SDR for anything unsupported
static void mtl_sw_configure(pl_swapchain sw, const struct pl_color_space *csp)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    CAMetalLayer *layer = p->layer;

    MTLPixelFormat pixfmt = MTLPixelFormatBGRA8Unorm;
    CFStringRef space = kCGColorSpaceSRGB;
    bool edr = false;
    struct pl_color_space out = pl_color_space_monitor;
    const char *desc = "SDR";

    if (csp && pl_color_transfer_is_hdr(csp->transfer)) {
        if (@available(macOS 11.0, iOS 14.0, tvOS 14.0, *)) {
            switch (csp->transfer) {
            case PL_COLOR_TRC_PQ:
                pixfmt = MTLPixelFormatRGB10A2Unorm;
                space = kCGColorSpaceITUR_2100_PQ;
                edr = true;
                out = (struct pl_color_space) {
                    .primaries = PL_COLOR_PRIM_BT_2020,
                    .transfer = PL_COLOR_TRC_PQ,
                    .hdr = csp->hdr,
                };
                desc = "HDR (PQ)";
                break;
            case PL_COLOR_TRC_HLG:
                pixfmt = MTLPixelFormatRGB10A2Unorm;
                space = kCGColorSpaceITUR_2100_HLG;
                edr = true;
                out = (struct pl_color_space) {
                    .primaries = PL_COLOR_PRIM_BT_2020,
                    .transfer = PL_COLOR_TRC_HLG,
                    .hdr = csp->hdr,
                };
                desc = "HDR (HLG)";
                break;
            default:
                break; // e.g. scene-referred HDR curves: keep SDR + tonemap
            }
        }
    }

    pl_fmt fmt = mtl_sw_find_fmt(sw->gpu, pixfmt);
    if (!fmt) {
        pl_err(sw->log, "No pl_fmt for the requested swapchain pixel format!");
        return;
    }

    @autoreleasepool {
        layer.pixelFormat = pixfmt;
        CGColorSpaceRef cgspace = CGColorSpaceCreateWithName(space);
        layer.colorspace = cgspace;
        CGColorSpaceRelease(cgspace);

#if TARGET_OS_OSX
        layer.wantsExtendedDynamicRangeContent = edr;
#else
        if (@available(iOS 16.0, tvOS 16.0, *))
            layer.wantsExtendedDynamicRangeContent = edr;
#endif

        if (@available(macOS 10.15, iOS 16.0, tvOS 16.0, *)) {
            CAEDRMetadata *metadata = nil;
            if (out.transfer == PL_COLOR_TRC_PQ && out.hdr.max_luma > 0) {
                metadata = [CAEDRMetadata HDR10MetadataWithMinLuminance:out.hdr.min_luma
                                                           maxLuminance:out.hdr.max_luma
                                                     opticalOutputScale:10000];
            } else if (out.transfer == PL_COLOR_TRC_HLG) {
                metadata = [CAEDRMetadata HLGMetadata];
            }
            layer.EDRMetadata = metadata;
        }
    }

    if (p->fbo_fmt != fmt)
        pl_info(sw->log, "Configured swapchain for %s output", desc);

    p->fbo_fmt = fmt;
    p->csp = out;
}

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
    pl_mutex_init(&p->lock);

    layer.device = ctx->dev;
    // Drawables must also work as blit destinations, not just render targets
    layer.framebufferOnly = NO;

    mtl_sw_configure(sw, NULL);
    if (!p->fbo_fmt) {
        pl_mutex_destroy(&p->lock);
        [p->layer release];
        pl_free(sw);
        return NULL;
    }

    return sw;
}

static void mtl_sw_colorspace_hint(pl_swapchain sw, const struct pl_color_space *csp)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    pl_mutex_lock(&p->lock);
    mtl_sw_configure(sw, csp);
    pl_mutex_unlock(&p->lock);
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
    pl_mutex_destroy(&p->lock);
    pl_free((void *) sw);
}

static bool mtl_sw_resize(pl_swapchain sw, int *width, int *height)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    pl_mutex_lock(&p->lock);

    @autoreleasepool {
        if (*width && *height)
            p->layer.drawableSize = CGSizeMake(*width, *height);

        const CGSize size = p->layer.drawableSize;
        *width = size.width;
        *height = size.height;
    }

    pl_mutex_unlock(&p->lock);
    return true;
}

static bool mtl_sw_start_frame(pl_swapchain sw,
                               struct pl_swapchain_frame *out_frame)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    pl_mutex_lock(&p->lock);

    @autoreleasepool {
        // This blocks while all of the layer's drawables are in flight,
        // which is also what paces the rendering loop
        id<CAMetalDrawable> drawable = [[p->layer nextDrawable] retain];
        if (!drawable) {
            pl_mutex_unlock(&p->lock);
            return false;
        }

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

        const int bits = p->fbo_fmt->component_depth[0];
        struct pl_color_repr repr = pl_color_repr_rgb;
        repr.bits.sample_depth = bits;
        repr.bits.color_depth = bits;

        *out_frame = (struct pl_swapchain_frame) {
            .fbo = fbo,
            .flipped = false,
            .color_repr = repr,
            .color_space = p->csp,
        };
    }

    pl_mutex_unlock(&p->lock);
    return true;
}

static bool mtl_sw_submit_frame(pl_swapchain sw)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    struct mtl_ctx *ctx = p->ctx;
    pl_mutex_lock(&p->lock);

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

    pl_mutex_unlock(&p->lock);
    return true;
}

static void mtl_sw_swap_buffers(pl_swapchain sw)
{
    // Pacing happens in `nextDrawable`, which blocks while the layer's
    // drawable pool is exhausted
}

static const struct pl_sw_fns mtl_sw_fns = {
    .destroy          = mtl_sw_destroy,
    .resize           = mtl_sw_resize,
    .colorspace_hint  = mtl_sw_colorspace_hint,
    .start_frame      = mtl_sw_start_frame,
    .submit_frame     = mtl_sw_submit_frame,
    .swap_buffers     = mtl_sw_swap_buffers,
};
