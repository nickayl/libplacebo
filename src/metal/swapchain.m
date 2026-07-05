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

#include <IOSurface/IOSurfaceRef.h>

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

    // optional frame-mirror callback (see pl_mtl_swapchain_params.frame_callback)
    pl_mtl_frame_cb frame_cb;
    void *frame_cb_priv;

    // offscreen mirror pool: keeps the mirror fed when the layer cannot vend drawables (e.g. the
    // app is backgrounded with Picture in Picture active). BGRA8 IOSurface-backed round-robin.
    IOSurfaceRef mirror_surfaces[3];
    id<MTLTexture> mirror_textures[3];
    int mirror_w, mirror_h;
    int mirror_idx;

    // IOSurface of the in-flight offscreen frame (NULL when rendering to a drawable)
    IOSurfaceRef frame_surface;

    // mirror crop in surface pixels (empty = full frame), see
    // pl_mtl_swapchain_set_frame_mirror_crop
    struct pl_rect2d mirror_crop;

    // cropped-mirror pool: BGRA8 blit targets handed to the callback when a crop is set
    IOSurfaceRef crop_surfaces[3];
    pl_tex crop_textures[3];
    int crop_w, crop_h;
    int crop_idx;
};

static const struct pl_sw_fns mtl_sw_fns;

static void mtl_sw_release_mirror_pool(pl_swapchain sw);
static void mtl_sw_release_crop_pool(pl_swapchain sw);

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
    p->frame_cb = params->frame_callback;
    p->frame_cb_priv = params->frame_callback_priv;
    pl_mutex_init(&p->lock);

    layer.device = ctx->dev;
    // Drawables must also work as blit destinations, not just render targets
    layer.framebufferOnly = NO;

    pl_info(ctx->log, "metal: swapchain bound to CAMetalLayer %p (device %s, drawableSize %dx%d)",
            (void *) layer, ctx->dev.name.UTF8String ? ctx->dev.name.UTF8String : "?",
            (int) layer.drawableSize.width, (int) layer.drawableSize.height);

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
    mtl_sw_release_mirror_pool(sw);
    mtl_sw_release_crop_pool(sw);

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
        pl_debug(sw->log, "metal: swapchain resize -> %dx%d", *width, *height);
    }

    pl_mutex_unlock(&p->lock);
    return true;
}

static void mtl_sw_release_mirror_pool(pl_swapchain sw)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    for (int i = 0; i < (int) PL_ARRAY_SIZE(p->mirror_textures); i++) {
        [p->mirror_textures[i] release];
        p->mirror_textures[i] = nil;
        if (p->mirror_surfaces[i]) {
            CFRelease(p->mirror_surfaces[i]);
            p->mirror_surfaces[i] = NULL;
        }
    }
    p->mirror_w = p->mirror_h = 0;
    p->mirror_idx = 0;
}

static bool mtl_sw_ensure_mirror_pool(pl_swapchain sw, int w, int h)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    struct mtl_ctx *ctx = p->ctx;
    if (p->mirror_w == w && p->mirror_h == h && p->mirror_textures[0])
        return true;

    mtl_sw_release_mirror_pool(sw);

    const uint32_t pixfmt = 0x42475241; // 'BGRA', kCVPixelFormatType_32BGRA
    const size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t) w * 4);

    for (int i = 0; i < (int) PL_ARRAY_SIZE(p->mirror_textures); i++) {
        NSDictionary *props = @{
            (__bridge NSString *) kIOSurfaceWidth: @(w),
            (__bridge NSString *) kIOSurfaceHeight: @(h),
            (__bridge NSString *) kIOSurfaceBytesPerElement: @4,
            (__bridge NSString *) kIOSurfaceBytesPerRow: @(bpr),
            (__bridge NSString *) kIOSurfacePixelFormat: @(pixfmt),
        };
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef) props);
        if (!surface)
            goto fail;

        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:w height:h mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> tex = [ctx->dev newTextureWithDescriptor:desc iosurface:surface plane:0];
        if (!tex) {
            CFRelease(surface);
            goto fail;
        }

        p->mirror_surfaces[i] = surface;
        p->mirror_textures[i] = tex;
    }

    p->mirror_w = w;
    p->mirror_h = h;
    p->mirror_idx = 0;
    pl_info(sw->log, "metal: created %dx%d offscreen mirror pool", w, h);
    return true;

fail:
    pl_err(sw->log, "metal: failed creating the %dx%d offscreen mirror pool", w, h);
    mtl_sw_release_mirror_pool(sw);
    return false;
}

static void mtl_sw_release_crop_pool(pl_swapchain sw)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    for (int i = 0; i < (int) PL_ARRAY_SIZE(p->crop_textures); i++) {
        if (p->crop_textures[i])
            pl_tex_destroy(sw->gpu, &p->crop_textures[i]);
        if (p->crop_surfaces[i]) {
            CFRelease(p->crop_surfaces[i]);
            p->crop_surfaces[i] = NULL;
        }
    }
    p->crop_w = p->crop_h = 0;
    p->crop_idx = 0;
}

static bool mtl_sw_ensure_crop_pool(pl_swapchain sw, int w, int h)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    struct mtl_ctx *ctx = p->ctx;
    if (p->crop_w == w && p->crop_h == h && p->crop_textures[0])
        return true;

    mtl_sw_release_crop_pool(sw);

    const uint32_t pixfmt = 0x42475241; // 'BGRA', kCVPixelFormatType_32BGRA
    const size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t) w * 4);

    for (int i = 0; i < (int) PL_ARRAY_SIZE(p->crop_textures); i++) {
        NSDictionary *props = @{
            (__bridge NSString *) kIOSurfaceWidth: @(w),
            (__bridge NSString *) kIOSurfaceHeight: @(h),
            (__bridge NSString *) kIOSurfaceBytesPerElement: @4,
            (__bridge NSString *) kIOSurfaceBytesPerRow: @(bpr),
            (__bridge NSString *) kIOSurfacePixelFormat: @(pixfmt),
        };
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef) props);
        if (!surface)
            goto fail;

        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:w height:h mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> tex = [ctx->dev newTextureWithDescriptor:desc iosurface:surface plane:0];
        if (!tex) {
            CFRelease(surface);
            goto fail;
        }

        pl_tex wrapped = pl_mtl_wrap(sw->gpu, pl_mtl_wrap_params(.tex = tex));
        [tex release]; // pl_mtl_wrap holds its own reference
        if (!wrapped) {
            CFRelease(surface);
            goto fail;
        }

        p->crop_surfaces[i] = surface;
        p->crop_textures[i] = wrapped;
    }

    p->crop_w = w;
    p->crop_h = h;
    p->crop_idx = 0;
    pl_info(sw->log, "metal: created %dx%d cropped mirror pool", w, h);
    return true;

fail:
    pl_err(sw->log, "metal: failed creating the %dx%d cropped mirror pool", w, h);
    mtl_sw_release_crop_pool(sw);
    return false;
}

// Fallback target when the layer cannot vend drawables: renders into the offscreen mirror pool so
// the frame callback keeps firing (SDR BGRA8; the mirror consumer is a PiP-sized sample layer).
static bool mtl_sw_start_offscreen_frame(pl_swapchain sw,
                                         struct pl_swapchain_frame *out_frame)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    const CGSize size = p->layer.drawableSize;
    const int w = size.width, h = size.height;
    if (w <= 0 || h <= 0)
        return false;

    pl_fmt fmt = mtl_sw_find_fmt(sw->gpu, MTLPixelFormatBGRA8Unorm);
    if (!fmt)
        return false;

    if (!mtl_sw_ensure_mirror_pool(sw, w, h))
        return false;

    const int idx = p->mirror_idx;
    p->mirror_idx = (p->mirror_idx + 1) % (int) PL_ARRAY_SIZE(p->mirror_textures);

    struct pl_tex_t *fbo = pl_zalloc_obj(NULL, fbo, struct pl_tex_mtl);
    struct pl_tex_mtl *texp = PL_PRIV(fbo);
    texp->tex = [p->mirror_textures[idx] retain];

    fbo->sampler_type = PL_SAMPLER_NORMAL;
    fbo->params = (struct pl_tex_params) {
        .w          = w,
        .h          = h,
        .format     = fmt,
        .sampleable = true,
        .renderable = true,
        .blit_src   = true,
        .blit_dst   = true,
        .debug_tag  = PL_DEBUG_TAG,
    };

    p->drawable = nil;
    p->fbo = fbo;
    p->frame_surface = p->mirror_surfaces[idx];

    struct pl_color_repr repr = pl_color_repr_rgb;
    repr.bits.sample_depth = 8;
    repr.bits.color_depth = 8;

    *out_frame = (struct pl_swapchain_frame) {
        .fbo = fbo,
        .flipped = false,
        .color_repr = repr,
        .color_space = pl_color_space_monitor,
    };

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
            // Normal when the layer is off-screen / backgrounded or its drawable pool is exhausted.
            // With a frame mirror installed, fall back to the offscreen pool so the mirror keeps
            // receiving frames (Picture in Picture while backgrounded); otherwise skip the frame,
            // traced (not warned) so a legitimately paused surface does not spam the log.
            if (p->frame_cb && mtl_sw_start_offscreen_frame(sw, out_frame)) {
                pl_mutex_unlock(&p->lock);
                return true;
            }
            pl_trace(sw->log, "metal: nextDrawable returned nil (drawableSize %dx%d) - skipping frame",
                     (int) p->layer.drawableSize.width, (int) p->layer.drawableSize.height);
            pl_mutex_unlock(&p->lock);
            return false;
        }
        p->frame_surface = NULL;

        struct pl_tex_t *fbo = pl_zalloc_obj(NULL, fbo, struct pl_tex_mtl);
        struct pl_tex_mtl *texp = PL_PRIV(fbo);
        texp->tex = [drawable.texture retain];

        fbo->sampler_type = PL_SAMPLER_NORMAL;
        fbo->params = (struct pl_tex_params) {
            .w          = texp->tex.width,
            .h          = texp->tex.height,
            .format     = p->fbo_fmt,
            .sampleable = true,
            .renderable = true,
            .blit_src   = true,
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
        if (p->drawable)
            [cmdbuf presentDrawable:p->drawable];

        // Mirror the frame's IOSurface to the host callback (PiP / AirPlay). With a crop set, the
        // crop region is first blitted into the BGRA8 cropped pool (converting from HDR formats via
        // the raster path) so the consumer receives the video rect, not the letterboxed surface;
        // otherwise the offscreen pool surface or the drawable's own backing surface is handed over
        // directly. Fire once the GPU has finished so the surface holds the rendered frame,
        // retaining it across the async hand-off.
        if (p->frame_cb) {
            IOSurfaceRef surface = NULL;
            int w = p->fbo->params.w;
            int h = p->fbo->params.h;

            struct pl_rect2d crop = p->mirror_crop;
            crop.x0 = PL_CLAMP(crop.x0, 0, p->fbo->params.w);
            crop.x1 = PL_CLAMP(crop.x1, 0, p->fbo->params.w);
            crop.y0 = PL_CLAMP(crop.y0, 0, p->fbo->params.h);
            crop.y1 = PL_CLAMP(crop.y1, 0, p->fbo->params.h);
            const int cw = pl_rect_w(crop), ch = pl_rect_h(crop);
            const bool cropped = cw > 0 && ch > 0 &&
                !(cw == p->fbo->params.w && ch == p->fbo->params.h);

            if (cropped && mtl_sw_ensure_crop_pool(sw, cw, ch)) {
                const int idx = p->crop_idx;
                p->crop_idx = (p->crop_idx + 1) % (int) PL_ARRAY_SIZE(p->crop_textures);
                const struct pl_tex_blit_params blit = {
                    .src    = p->fbo,
                    .dst    = p->crop_textures[idx],
                    .src_rc = { crop.x0, crop.y0, 0, crop.x1, crop.y1, 1 },
                    .dst_rc = { 0, 0, 0, cw, ch, 1 },
                };
                if (p->fbo->params.format == p->crop_textures[idx]->params.format) {
                    pl_tex_blit(sw->gpu, &blit);
                } else {
                    // Format conversion (e.g. HDR RGB10A2 -> BGRA8): the plain blit would
                    // reinterpret bits, so force the sampling raster path.
                    pl_tex_blit_raster(sw->gpu, &blit);
                }
                surface = p->crop_surfaces[idx];
                w = cw;
                h = ch;
            } else {
                surface = p->frame_surface;
                if (!surface && p->drawable)
                    surface = p->drawable.texture.iosurface;
            }

            if (surface) {
                // Submit the blit before the handler's command buffer so the queue's FIFO order
                // guarantees the crop is complete when the callback fires.
                pl_gpu_flush(sw->gpu);
                CFRetain(surface);
                const pl_mtl_frame_cb cb = p->frame_cb;
                void *const cb_priv = p->frame_cb_priv;
                const int cb_w = w, cb_h = h;
                [cmdbuf addCompletedHandler:^(id<MTLCommandBuffer> buf) {
                    cb(cb_priv, (void *) surface, cb_w, cb_h);
                    CFRelease(surface);
                }];
            }
        }

        struct mtl_pending use = mtl_commit(ctx, cmdbuf);
        [p->last_present release];
        p->last_present = [use.cmdbuf retain];
        mtl_pending_release(&use);
    }

    pl_tex_destroy(sw->gpu, &p->fbo);
    [p->drawable release];
    p->drawable = nil;
    p->frame_surface = NULL;

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

void pl_mtl_swapchain_set_frame_mirror_crop(pl_swapchain sw, int x, int y, int w, int h)
{
    struct mtl_sw_priv *p = PL_PRIV(sw);
    if (p->impl.start_frame != mtl_sw_start_frame)
        return; // not a Metal swapchain

    pl_mutex_lock(&p->lock);
    if (w > 0 && h > 0) {
        p->mirror_crop = (struct pl_rect2d) { x, y, x + w, y + h };
    } else {
        p->mirror_crop = (struct pl_rect2d) {0};
    }
    pl_mutex_unlock(&p->lock);
}
