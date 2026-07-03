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

struct mtl_fmt_map {
    const char *name;
    enum pl_fmt_type type;
    int comps;
    int depth;
    MTLPixelFormat mtl_fmt;
    MTLVertexFormat mtl_vfmt;
};

// Regular (unpacked, host-representable, RGBA-ordered) formats
static const struct mtl_fmt_map mtl_regular_formats[] = {
    {"r8",       PL_FMT_UNORM, 1,  8, MTLPixelFormatR8Unorm,      MTLVertexFormatUCharNormalized},
    {"rg8",      PL_FMT_UNORM, 2,  8, MTLPixelFormatRG8Unorm,     MTLVertexFormatUChar2Normalized},
    {"rgba8",    PL_FMT_UNORM, 4,  8, MTLPixelFormatRGBA8Unorm,   MTLVertexFormatUChar4Normalized},
    {"r16",      PL_FMT_UNORM, 1, 16, MTLPixelFormatR16Unorm,     MTLVertexFormatUShortNormalized},
    {"rg16",     PL_FMT_UNORM, 2, 16, MTLPixelFormatRG16Unorm,    MTLVertexFormatUShort2Normalized},
    {"rgba16",   PL_FMT_UNORM, 4, 16, MTLPixelFormatRGBA16Unorm,  MTLVertexFormatUShort4Normalized},

    {"r8s",      PL_FMT_SNORM, 1,  8, MTLPixelFormatR8Snorm,      MTLVertexFormatCharNormalized},
    {"rg8s",     PL_FMT_SNORM, 2,  8, MTLPixelFormatRG8Snorm,     MTLVertexFormatChar2Normalized},
    {"rgba8s",   PL_FMT_SNORM, 4,  8, MTLPixelFormatRGBA8Snorm,   MTLVertexFormatChar4Normalized},
    {"r16s",     PL_FMT_SNORM, 1, 16, MTLPixelFormatR16Snorm,     MTLVertexFormatShortNormalized},
    {"rg16s",    PL_FMT_SNORM, 2, 16, MTLPixelFormatRG16Snorm,    MTLVertexFormatShort2Normalized},
    {"rgba16s",  PL_FMT_SNORM, 4, 16, MTLPixelFormatRGBA16Snorm,  MTLVertexFormatShort4Normalized},

    {"r8u",      PL_FMT_UINT,  1,  8, MTLPixelFormatR8Uint,       MTLVertexFormatUChar},
    {"rg8u",     PL_FMT_UINT,  2,  8, MTLPixelFormatRG8Uint,      MTLVertexFormatUChar2},
    {"rgba8u",   PL_FMT_UINT,  4,  8, MTLPixelFormatRGBA8Uint,    MTLVertexFormatUChar4},
    {"r16u",     PL_FMT_UINT,  1, 16, MTLPixelFormatR16Uint,      MTLVertexFormatUShort},
    {"rg16u",    PL_FMT_UINT,  2, 16, MTLPixelFormatRG16Uint,     MTLVertexFormatUShort2},
    {"rgba16u",  PL_FMT_UINT,  4, 16, MTLPixelFormatRGBA16Uint,   MTLVertexFormatUShort4},
    {"r32u",     PL_FMT_UINT,  1, 32, MTLPixelFormatR32Uint,      MTLVertexFormatUInt},
    {"rg32u",    PL_FMT_UINT,  2, 32, MTLPixelFormatRG32Uint,     MTLVertexFormatUInt2},
    {"rgba32u",  PL_FMT_UINT,  4, 32, MTLPixelFormatRGBA32Uint,   MTLVertexFormatUInt4},

    {"r8i",      PL_FMT_SINT,  1,  8, MTLPixelFormatR8Sint,       MTLVertexFormatChar},
    {"rg8i",     PL_FMT_SINT,  2,  8, MTLPixelFormatRG8Sint,      MTLVertexFormatChar2},
    {"rgba8i",   PL_FMT_SINT,  4,  8, MTLPixelFormatRGBA8Sint,    MTLVertexFormatChar4},
    {"r16i",     PL_FMT_SINT,  1, 16, MTLPixelFormatR16Sint,      MTLVertexFormatShort},
    {"rg16i",    PL_FMT_SINT,  2, 16, MTLPixelFormatRG16Sint,     MTLVertexFormatShort2},
    {"rgba16i",  PL_FMT_SINT,  4, 16, MTLPixelFormatRGBA16Sint,   MTLVertexFormatShort4},
    {"r32i",     PL_FMT_SINT,  1, 32, MTLPixelFormatR32Sint,      MTLVertexFormatInt},
    {"rg32i",    PL_FMT_SINT,  2, 32, MTLPixelFormatRG32Sint,     MTLVertexFormatInt2},
    {"rgba32i",  PL_FMT_SINT,  4, 32, MTLPixelFormatRGBA32Sint,   MTLVertexFormatInt4},

    {"r16hf",    PL_FMT_FLOAT, 1, 16, MTLPixelFormatR16Float,     MTLVertexFormatHalf},
    {"rg16hf",   PL_FMT_FLOAT, 2, 16, MTLPixelFormatRG16Float,    MTLVertexFormatHalf2},
    {"rgba16hf", PL_FMT_FLOAT, 4, 16, MTLPixelFormatRGBA16Float,  MTLVertexFormatHalf4},
    {"r32f",     PL_FMT_FLOAT, 1, 32, MTLPixelFormatR32Float,     MTLVertexFormatFloat},
    {"rg32f",    PL_FMT_FLOAT, 2, 32, MTLPixelFormatRG32Float,    MTLVertexFormatFloat2},
    {"rgba32f",  PL_FMT_FLOAT, 4, 32, MTLPixelFormatRGBA32Float,  MTLVertexFormatFloat4},
};

// Metal has no 3-component pixel formats, but it does have the vertex formats
static const struct mtl_fmt_map mtl_vertex_only_formats[] = {
    {"rgb8",    PL_FMT_UNORM, 3,  8, MTLPixelFormatInvalid, MTLVertexFormatUChar3Normalized},
    {"rgb16",   PL_FMT_UNORM, 3, 16, MTLPixelFormatInvalid, MTLVertexFormatUShort3Normalized},
    {"rgb8s",   PL_FMT_SNORM, 3,  8, MTLPixelFormatInvalid, MTLVertexFormatChar3Normalized},
    {"rgb16s",  PL_FMT_SNORM, 3, 16, MTLPixelFormatInvalid, MTLVertexFormatShort3Normalized},
    {"rgb8u",   PL_FMT_UINT,  3,  8, MTLPixelFormatInvalid, MTLVertexFormatUChar3},
    {"rgb16u",  PL_FMT_UINT,  3, 16, MTLPixelFormatInvalid, MTLVertexFormatUShort3},
    {"rgb32u",  PL_FMT_UINT,  3, 32, MTLPixelFormatInvalid, MTLVertexFormatUInt3},
    {"rgb8i",   PL_FMT_SINT,  3,  8, MTLPixelFormatInvalid, MTLVertexFormatChar3},
    {"rgb16i",  PL_FMT_SINT,  3, 16, MTLPixelFormatInvalid, MTLVertexFormatShort3},
    {"rgb32i",  PL_FMT_SINT,  3, 32, MTLPixelFormatInvalid, MTLVertexFormatInt3},
    {"rgb16hf", PL_FMT_FLOAT, 3, 16, MTLPixelFormatInvalid, MTLVertexFormatHalf3},
    {"rgb32f",  PL_FMT_FLOAT, 3, 32, MTLPixelFormatInvalid, MTLVertexFormatFloat3},
};

static enum pl_fmt_caps mtl_fmt_caps(const struct mtl_fmt_map *map, bool fl32_filter)
{
    enum pl_fmt_caps caps = PL_FMT_CAP_SAMPLEABLE | PL_FMT_CAP_HOST_READABLE |
                            PL_FMT_CAP_VERTEX;

    switch (map->type) {
    case PL_FMT_UNORM:
    case PL_FMT_SNORM:
        caps |= PL_FMT_CAP_LINEAR | PL_FMT_CAP_RENDERABLE | PL_FMT_CAP_BLENDABLE;
        break;
    case PL_FMT_FLOAT:
        caps |= PL_FMT_CAP_RENDERABLE | PL_FMT_CAP_BLENDABLE;
        if (map->depth == 16 || fl32_filter)
            caps |= PL_FMT_CAP_LINEAR;
        break;
    case PL_FMT_UINT:
    case PL_FMT_SINT:
        caps |= PL_FMT_CAP_RENDERABLE; // integer formats aren't filterable/blendable
        break;
    case PL_FMT_UNKNOWN:
    case PL_FMT_TYPE_COUNT:
        pl_unreachable();
    }

    // Blits are a blit-encoder copy, or a raster pass when scaling; clears
    // are a render pass — all renderable formats qualify
    if (caps & PL_FMT_CAP_RENDERABLE)
        caps |= PL_FMT_CAP_BLITTABLE;

    return caps;
}

// Note: PL_FMT_CAP_READWRITE is deliberately not advertised. Metal's
// read-write texture tiers cover R and RGBA variants but not RG, and
// heterogeneous caps between component-count siblings of the same format
// family break `pl_renderer`'s FBO format probing (which matches the full
// cap set of the 4-component format). Revisit if read-write storage images
// become load-bearing.

void mtl_setup_formats(struct pl_gpu_t *gpu, id<MTLDevice> dev)
{
    bool fl32_filter = false;
    if (@available(macOS 11.0, iOS 14.0, *))
        fl32_filter = dev.supports32BitFloatFiltering;

    PL_ARRAY(pl_fmt) formats = {0};

    for (int n = 0; n < PL_ARRAY_SIZE(mtl_regular_formats); n++) {
        const struct mtl_fmt_map *map = &mtl_regular_formats[n];

        struct pl_fmt_t *fmt = pl_alloc_obj(gpu, fmt, struct pl_fmt_mtl);
        struct pl_fmt_mtl *fmtp = PL_PRIV(fmt);
        fmtp->mtl_fmt = map->mtl_fmt;
        fmtp->mtl_vfmt = map->mtl_vfmt;

        *fmt = (struct pl_fmt_t) {
            .name           = map->name,
            .type           = map->type,
            .num_components = map->comps,
            .opaque         = false,
            .gatherable     = true,
            .internal_size  = map->comps * map->depth / 8,
            .texel_size     = map->comps * map->depth / 8,
            .texel_align    = 1,
            .caps           = mtl_fmt_caps(map, fl32_filter),
        };

        for (int i = 0; i < map->comps; i++) {
            fmt->component_depth[i] = map->depth;
            fmt->host_bits[i] = map->depth;
            fmt->sample_order[i] = i;
        }

        fmt->glsl_type = pl_var_glsl_type_name(pl_var_from_fmt(fmt, ""));
        fmt->glsl_format = pl_fmt_glsl_format(fmt, map->comps);
        fmt->fourcc = pl_fmt_fourcc(fmt);
        if (gpu->glsl.compute && fmt->glsl_format)
            fmt->caps |= PL_FMT_CAP_STORABLE;
        PL_ARRAY_APPEND(gpu, formats, fmt);
    }

    for (int n = 0; n < PL_ARRAY_SIZE(mtl_vertex_only_formats); n++) {
        const struct mtl_fmt_map *map = &mtl_vertex_only_formats[n];

        struct pl_fmt_t *fmt = pl_alloc_obj(gpu, fmt, struct pl_fmt_mtl);
        struct pl_fmt_mtl *fmtp = PL_PRIV(fmt);
        fmtp->mtl_fmt = MTLPixelFormatInvalid;
        fmtp->mtl_vfmt = map->mtl_vfmt;

        *fmt = (struct pl_fmt_t) {
            .name           = map->name,
            .type           = map->type,
            .num_components = map->comps,
            .opaque         = false,
            .internal_size  = map->comps * map->depth / 8,
            .texel_size     = map->comps * map->depth / 8,
            .texel_align    = 1,
            .caps           = PL_FMT_CAP_VERTEX,
        };

        for (int i = 0; i < map->comps; i++) {
            fmt->component_depth[i] = map->depth;
            fmt->host_bits[i] = map->depth;
            fmt->sample_order[i] = i;
        }

        fmt->glsl_type = pl_var_glsl_type_name(pl_var_from_fmt(fmt, ""));
        fmt->fourcc = pl_fmt_fourcc(fmt);
        PL_ARRAY_APPEND(gpu, formats, fmt);
    }

    // bgra8: like rgba8, but with swapped sampling order (no vertex usage)
    {
        struct pl_fmt_t *fmt = pl_alloc_obj(gpu, fmt, struct pl_fmt_mtl);
        struct pl_fmt_mtl *fmtp = PL_PRIV(fmt);
        fmtp->mtl_fmt = MTLPixelFormatBGRA8Unorm;
        fmtp->mtl_vfmt = MTLVertexFormatInvalid;

        *fmt = (struct pl_fmt_t) {
            .name           = "bgra8",
            .type           = PL_FMT_UNORM,
            .num_components = 4,
            .opaque         = false,
            .gatherable     = true,
            .internal_size  = 4,
            .texel_size     = 4,
            .texel_align    = 1,
            .caps           = PL_FMT_CAP_SAMPLEABLE | PL_FMT_CAP_LINEAR |
                              PL_FMT_CAP_RENDERABLE | PL_FMT_CAP_BLENDABLE |
                              PL_FMT_CAP_HOST_READABLE,
            .sample_order   = {2, 1, 0, 3},
        };

        for (int i = 0; i < 4; i++) {
            fmt->component_depth[i] = 8;
            fmt->host_bits[i] = 8;
        }

        fmt->glsl_type = pl_var_glsl_type_name(pl_var_from_fmt(fmt, ""));
        fmt->glsl_format = pl_fmt_glsl_format(fmt, 4);
        fmt->fourcc = pl_fmt_fourcc(fmt);
        PL_ARRAY_APPEND(gpu, formats, fmt);
    }

    // rgb10a2: packed 32-bit, not usable as a vertex or variable type
    {
        struct pl_fmt_t *fmt = pl_alloc_obj(gpu, fmt, struct pl_fmt_mtl);
        struct pl_fmt_mtl *fmtp = PL_PRIV(fmt);
        fmtp->mtl_fmt = MTLPixelFormatRGB10A2Unorm;
        fmtp->mtl_vfmt = MTLVertexFormatInvalid;

        *fmt = (struct pl_fmt_t) {
            .name            = "rgb10a2",
            .type            = PL_FMT_UNORM,
            .num_components  = 4,
            .opaque          = false,
            .gatherable      = true,
            .internal_size   = 4,
            .texel_size      = 4,
            .texel_align     = 4,
            .caps            = PL_FMT_CAP_SAMPLEABLE | PL_FMT_CAP_LINEAR |
                               PL_FMT_CAP_RENDERABLE | PL_FMT_CAP_BLENDABLE |
                               PL_FMT_CAP_HOST_READABLE,
            .component_depth = {10, 10, 10, 2},
            .host_bits       = {10, 10, 10, 2},
            .sample_order    = {0, 1, 2, 3},
        };

        fmt->fourcc = pl_fmt_fourcc(fmt);
        PL_ARRAY_APPEND(gpu, formats, fmt);
    }

    gpu->formats = formats.elem;
    gpu->num_formats = formats.num;
}
