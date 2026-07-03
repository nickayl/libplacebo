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

static MTLRegion mtl_tex_region(const struct pl_tex_transfer_params *params)
{
    const pl_rect3d *rc = &params->rc;
    return MTLRegionMake3D(rc->x0, rc->y0, rc->z0,
                           pl_rect_w(*rc),
                           PL_MAX(pl_rect_h(*rc), 1),
                           PL_MAX(pl_rect_d(*rc), 1));
}

// Metal expects 0 for the pitches of the missing texture dimensions
static void mtl_tex_pitches(pl_tex tex, const struct pl_tex_transfer_params *params,
                            size_t *row_pitch, size_t *depth_pitch)
{
    *row_pitch = tex->params.h ? params->row_pitch : 0;
    *depth_pitch = tex->params.d ? params->depth_pitch : 0;
}

pl_tex mtl_tex_create(pl_gpu gpu, const struct pl_tex_params *params)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    const struct pl_fmt_mtl *fmtp = PL_PRIV(params->format);

    if (fmtp->mtl_fmt == MTLPixelFormatInvalid) {
        PL_ERR(gpu, "Format %s is vertex-only, not usable for textures!",
               params->format->name);
        return NULL;
    }

    if (params->import_handle) {
        pl_assert(params->import_handle == PL_HANDLE_MTL_TEX);
        id<MTLTexture> mtex = (id<MTLTexture>) params->shared_mem.handle.handle;
        if (!mtex) {
            PL_ERR(gpu, "No texture handle given to import!");
            return NULL;
        }

        if (mtex.pixelFormat != fmtp->mtl_fmt) {
            PL_ERR(gpu, "Imported texture pixel format %lu does not match "
                   "format %s!", (unsigned long) mtex.pixelFormat,
                   params->format->name);
            return NULL;
        }

        struct pl_tex_t *tex = pl_zalloc_obj(NULL, tex, struct pl_tex_mtl);
        struct pl_tex_mtl *texp = PL_PRIV(tex);
        texp->tex = [mtex retain];
        tex->params = *params;
        tex->params.initial_data = NULL;
        tex->sampler_type = PL_SAMPLER_NORMAL;
        return tex;
    }

    struct pl_tex_t *tex = pl_zalloc_obj(NULL, tex, struct pl_tex_mtl);
    tex->params = *params;
    tex->params.initial_data = NULL;
    tex->sampler_type = PL_SAMPLER_NORMAL;

    struct pl_tex_mtl *p = PL_PRIV(tex);

    @autoreleasepool {
        MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
        desc.pixelFormat = fmtp->mtl_fmt;
        desc.textureType = params->d ? MTLTextureType3D :
                           params->h ? MTLTextureType2D : MTLTextureType1D;
        desc.width  = params->w;
        desc.height = PL_MAX(params->h, 1);
        desc.depth  = PL_MAX(params->d, 1);
        desc.mipmapLevelCount = 1;
        desc.sampleCount = 1;
        desc.arrayLength = 1;

        MTLStorageMode storage = MTLStorageModeShared;
#if TARGET_OS_OSX
        // Discrete-GPU Macs cannot allocate shared-storage textures
        if (!ctx->dev.hasUnifiedMemory)
            storage = MTLStorageModeManaged;
#endif
        desc.storageMode = storage;

        MTLTextureUsage usage = 0;
        if (params->sampleable)
            usage |= MTLTextureUsageShaderRead;
        if (params->renderable)
            usage |= MTLTextureUsageRenderTarget;
        if (params->storable)
            usage |= MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        // Clears and scaling blits run as render passes; scaling blits also
        // sample the source
        if (params->blit_dst)
            usage |= MTLTextureUsageRenderTarget;
        if (params->blit_src)
            usage |= MTLTextureUsageShaderRead;
        desc.usage = usage ? usage : MTLTextureUsageShaderRead;

        p->tex = [ctx->dev newTextureWithDescriptor:desc];
        [desc release];
    }

    if (!p->tex) {
        PL_ERR(gpu, "Failed creating %dx%dx%d texture with format %s!",
               params->w, params->h, params->d, params->format->name);
        pl_free(tex);
        return NULL;
    }

    if (params->initial_data) {
        pl_fmt fmt = params->format;
        size_t row_pitch = (size_t) params->w * fmt->texel_size;
        bool ok = mtl_tex_upload(gpu, &(struct pl_tex_transfer_params) {
            .tex = tex,
            .rc = {
                .x1 = params->w,
                .y1 = PL_MAX(params->h, 1),
                .z1 = PL_MAX(params->d, 1),
            },
            .row_pitch = row_pitch,
            .depth_pitch = row_pitch * PL_MAX(params->h, 1),
            .ptr = (void *) params->initial_data,
        });

        if (!ok) {
            mtl_tex_destroy(gpu, tex);
            return NULL;
        }
    }

    return tex;
}

void mtl_tex_destroy(pl_gpu gpu, pl_tex tex)
{
    struct pl_tex_mtl *p = PL_PRIV(tex);
    // In-flight command buffers keep the MTLTexture itself alive
    mtl_pending_release(&p->pending);
    [p->tex release];
    pl_free((void *) tex);
}

bool mtl_tex_poll(pl_gpu gpu, pl_tex tex, uint64_t timeout)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    struct pl_tex_mtl *p = PL_PRIV(tex);
    return mtl_pending_wait_timeout(ctx, &p->pending, timeout);
}

pl_tex pl_mtl_wrap(pl_gpu gpu, const struct pl_mtl_wrap_params *params)
{
    id<MTLTexture> mtex = params->tex;

    pl_fmt fmt = NULL;
    for (int i = 0; i < gpu->num_formats; i++) {
        const struct pl_fmt_mtl *fmtp = PL_PRIV(gpu->formats[i]);
        if (fmtp->mtl_fmt != MTLPixelFormatInvalid &&
            fmtp->mtl_fmt == mtex.pixelFormat)
        {
            fmt = gpu->formats[i];
            break;
        }
    }

    if (!fmt) {
        PL_ERR(gpu, "Failed mapping MTLPixelFormat %lu to a pl_fmt!",
               (unsigned long) mtex.pixelFormat);
        return NULL;
    }

    if (mtex.mipmapLevelCount > 1 || mtex.sampleCount > 1) {
        PL_ERR(gpu, "Mipmapped or multisampled textures cannot be wrapped!");
        return NULL;
    }

    struct pl_tex_t *tex = pl_zalloc_obj(NULL, tex, struct pl_tex_mtl);
    struct pl_tex_mtl *p = PL_PRIV(tex);
    p->tex = [mtex retain];

    const MTLTextureUsage usage = mtex.usage;
    const bool host_access = mtex.storageMode != MTLStorageModePrivate;

    tex->sampler_type = PL_SAMPLER_NORMAL;
    tex->params = (struct pl_tex_params) {
        .w = mtex.width,
        .h = mtex.textureType != MTLTextureType1D ? mtex.height : 0,
        .d = mtex.textureType == MTLTextureType3D ? mtex.depth : 0,
        .format        = fmt,
        .sampleable    = (usage & MTLTextureUsageShaderRead) &&
                         (fmt->caps & PL_FMT_CAP_SAMPLEABLE),
        .renderable    = (usage & MTLTextureUsageRenderTarget) &&
                         (fmt->caps & PL_FMT_CAP_RENDERABLE),
        .storable      = (usage & MTLTextureUsageShaderWrite) &&
                         (fmt->caps & PL_FMT_CAP_STORABLE),
        .blit_src      = fmt->caps & PL_FMT_CAP_BLITTABLE,
        .blit_dst      = (usage & MTLTextureUsageRenderTarget) &&
                         (fmt->caps & PL_FMT_CAP_BLITTABLE),
        .host_writable = host_access,
        .host_readable = host_access,
        .debug_tag     = PL_DEBUG_TAG,
    };

    return tex;
}

void mtl_tex_clear_ex(pl_gpu gpu, pl_tex tex, const union pl_clear_color color)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    struct pl_tex_mtl *p = PL_PRIV(tex);

    MTLClearColor cc;
    switch (tex->params.format->type) {
    case PL_FMT_UINT:
        cc = MTLClearColorMake(color.u[0], color.u[1], color.u[2], color.u[3]);
        break;
    case PL_FMT_SINT:
        cc = MTLClearColorMake(color.i[0], color.i[1], color.i[2], color.i[3]);
        break;
    default:
        cc = MTLClearColorMake(color.f[0], color.f[1], color.f[2], color.f[3]);
        break;
    }

    @autoreleasepool {
        id<MTLCommandBuffer> cmdbuf = [ctx->queue commandBuffer];
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = p->tex;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].clearColor = cc;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> enc = [cmdbuf renderCommandEncoderWithDescriptor:rpd];
        [enc endEncoding];

#if TARGET_OS_OSX
        if (p->tex.storageMode == MTLStorageModeManaged) {
            id<MTLBlitCommandEncoder> blit = [cmdbuf blitCommandEncoder];
            [blit synchronizeResource:p->tex];
            [blit endEncoding];
        }
#endif

        struct mtl_pending use = mtl_commit(ctx, cmdbuf);
        mtl_mark_pending(&p->pending, &use);
        mtl_pending_release(&use);
    }
}

void mtl_tex_blit(pl_gpu gpu, const struct pl_tex_blit_params *params)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    struct pl_tex_mtl *srcp = PL_PRIV(params->src);
    struct pl_tex_mtl *dstp = PL_PRIV(params->dst);

    const pl_rect3d src_rc = params->src_rc, dst_rc = params->dst_rc;
    const int sw = pl_rect_w(src_rc), sh = pl_rect_h(src_rc), sd = pl_rect_d(src_rc);
    const int dw = pl_rect_w(dst_rc), dh = pl_rect_h(dst_rc), dd = pl_rect_d(dst_rc);

    // Same size, no flips: a plain blit-encoder copy. Everything else
    // (scaling, mirroring) goes through the shared raster-pass helper.
    if (sw == dw && sh == dh && sd == dd && sw > 0 && sh >= 0 && sd >= 0) {
        struct mtl_pending use = mtl_blit_submit(ctx, ^(id<MTLBlitCommandEncoder> enc) {
            [enc copyFromTexture:srcp->tex
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(src_rc.x0, src_rc.y0, src_rc.z0)
                      sourceSize:MTLSizeMake(sw, PL_MAX(sh, 1), PL_MAX(sd, 1))
                       toTexture:dstp->tex
                destinationSlice:0
                destinationLevel:0
              destinationOrigin:MTLOriginMake(dst_rc.x0, dst_rc.y0, dst_rc.z0)];
#if TARGET_OS_OSX
            if (dstp->tex.storageMode == MTLStorageModeManaged)
                [enc synchronizeResource:dstp->tex];
#endif
        });
        mtl_mark_pending(&srcp->pending, &use);
        mtl_mark_pending(&dstp->pending, &use);
        mtl_pending_release(&use);
        return;
    }

    pl_tex_blit_raster(gpu, params);
}

bool mtl_tex_upload(pl_gpu gpu, const struct pl_tex_transfer_params *params)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    pl_tex tex = params->tex;
    struct pl_tex_mtl *p = PL_PRIV(tex);
    pl_fmt fmt = tex->params.format;

    const MTLRegion region = mtl_tex_region(params);
    size_t row_pitch, depth_pitch;
    mtl_tex_pitches(tex, params, &row_pitch, &depth_pitch);

    if (params->buf) {
        struct pl_buf_mtl *bufp = PL_PRIV(params->buf);

        // The blit encoder requires texel-aligned pitches; fall back to the
        // CPU path through the shared-storage contents pointer otherwise
        if (params->row_pitch % fmt->texel_size == 0) {
            struct mtl_pending use = mtl_blit_submit(ctx, ^(id<MTLBlitCommandEncoder> enc) {
                [enc copyFromBuffer:bufp->buf
                       sourceOffset:params->buf_offset
                  sourceBytesPerRow:params->row_pitch
                sourceBytesPerImage:params->depth_pitch
                         sourceSize:region.size
                          toTexture:p->tex
                   destinationSlice:0
                   destinationLevel:0
                  destinationOrigin:region.origin];
#if TARGET_OS_OSX
                // Keep the CPU view coherent after a GPU write on managed storage
                if (p->tex.storageMode == MTLStorageModeManaged)
                    [enc synchronizeResource:p->tex];
#endif
            });
            mtl_mark_pending(&bufp->pending, &use);
            mtl_mark_pending(&p->pending, &use);
            mtl_timer_record(params->timer, &use);
            mtl_pending_release(&use);
            return true;
        }

        mtl_pending_wait(ctx, &bufp->pending);
        mtl_pending_wait(ctx, &p->pending);
        const uint8_t *src = (const uint8_t *) bufp->buf.contents + params->buf_offset;
        [p->tex replaceRegion:region
                  mipmapLevel:0
                        slice:0
                    withBytes:src
                  bytesPerRow:row_pitch
                bytesPerImage:depth_pitch];
        return true;
    }

    mtl_pending_wait(ctx, &p->pending);
    [p->tex replaceRegion:region
              mipmapLevel:0
                    slice:0
                withBytes:params->ptr
              bytesPerRow:row_pitch
            bytesPerImage:depth_pitch];
    return true;
}

bool mtl_tex_download(pl_gpu gpu, const struct pl_tex_transfer_params *params)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    pl_tex tex = params->tex;
    struct pl_tex_mtl *p = PL_PRIV(tex);
    pl_fmt fmt = tex->params.format;

    const MTLRegion region = mtl_tex_region(params);
    size_t row_pitch, depth_pitch;
    mtl_tex_pitches(tex, params, &row_pitch, &depth_pitch);

    if (params->buf) {
        struct pl_buf_mtl *bufp = PL_PRIV(params->buf);

        if (params->row_pitch % fmt->texel_size == 0) {
            struct mtl_pending use = mtl_blit_submit(ctx, ^(id<MTLBlitCommandEncoder> enc) {
                [enc copyFromTexture:p->tex
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:region.origin
                          sourceSize:region.size
                            toBuffer:bufp->buf
                   destinationOffset:params->buf_offset
              destinationBytesPerRow:params->row_pitch
            destinationBytesPerImage:params->depth_pitch];
            });
            mtl_mark_pending(&p->pending, &use);
            mtl_mark_pending(&bufp->pending, &use);
            mtl_timer_record(params->timer, &use);
            mtl_pending_release(&use);
            return true;
        }

        mtl_pending_wait(ctx, &p->pending);
        mtl_pending_wait(ctx, &bufp->pending);
        uint8_t *dst = (uint8_t *) bufp->buf.contents + params->buf_offset;
        [p->tex getBytes:dst
             bytesPerRow:row_pitch
           bytesPerImage:depth_pitch
              fromRegion:region
             mipmapLevel:0
                   slice:0];
        return true;
    }

    mtl_pending_wait(ctx, &p->pending);
    [p->tex getBytes:params->ptr
         bytesPerRow:row_pitch
       bytesPerImage:depth_pitch
          fromRegion:region
         mipmapLevel:0
               slice:0];
    return true;
}
