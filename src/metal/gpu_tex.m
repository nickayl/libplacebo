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
    [p->tex release];
    pl_free((void *) tex);
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
            mtl_blit_sync(ctx, ^(id<MTLBlitCommandEncoder> enc) {
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
            return true;
        }

        const uint8_t *src = (const uint8_t *) bufp->buf.contents + params->buf_offset;
        [p->tex replaceRegion:region
                  mipmapLevel:0
                        slice:0
                    withBytes:src
                  bytesPerRow:row_pitch
                bytesPerImage:depth_pitch];
        return true;
    }

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
            mtl_blit_sync(ctx, ^(id<MTLBlitCommandEncoder> enc) {
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
            return true;
        }

        uint8_t *dst = (uint8_t *) bufp->buf.contents + params->buf_offset;
        [p->tex getBytes:dst
             bytesPerRow:row_pitch
           bytesPerImage:depth_pitch
              fromRegion:region
             mipmapLevel:0
                   slice:0];
        return true;
    }

    [p->tex getBytes:params->ptr
         bytesPerRow:row_pitch
       bytesPerImage:depth_pitch
          fromRegion:region
         mipmapLevel:0
               slice:0];
    return true;
}
