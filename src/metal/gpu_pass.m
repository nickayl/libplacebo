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

#include <spirv_cross_c.h>

#include "common.h"

static SpvExecutionModel stage_to_spv(enum glsl_shader_stage stage)
{
    static const SpvExecutionModel spv_execution_model[] = {
        [GLSL_SHADER_VERTEX]   = SpvExecutionModelVertex,
        [GLSL_SHADER_FRAGMENT] = SpvExecutionModelFragment,
        [GLSL_SHADER_COMPUTE]  = SpvExecutionModelGLCompute,
    };
    return spv_execution_model[stage];
}

#define SC(cmd)                                                             \
    do {                                                                    \
        spvc_result res = (cmd);                                            \
        if (res != SPVC_SUCCESS) {                                          \
            PL_ERR(gpu, "%s: %s (%d) (%s:%d)",                              \
                   #cmd, sc ? spvc_context_get_last_error_string(sc) : "",  \
                   res, __FILE__, __LINE__);                                \
            goto error;                                                     \
        }                                                                   \
    } while (0)

struct mtl_shader {
    char *msl;        // MSL source (allocated on `alloc`)
    char *entrypoint; // entry point name (allocated on `alloc`)
    MTLSize group_size;
};

// GLSL -> SPIR-V -> MSL, with all pass descriptors remapped 1:1 onto the
// matching Metal argument-table indices
static bool mtl_compile_shader(pl_gpu gpu, void *alloc,
                               const struct pl_pass_params *params,
                               enum glsl_shader_stage stage, const char *glsl,
                               struct mtl_shader *out)
{
    struct pl_gpu_mtl *p = PL_PRIV(gpu);
    spvc_context sc = NULL;
    void *tmp = pl_tmp(NULL);

    pl_str spirv = pl_spirv_compile_glsl(p->spirv, tmp, gpu->glsl, stage, glsl);
    if (!spirv.len)
        goto error;

    SC(spvc_context_create(&sc));

    spvc_parsed_ir ir;
    SC(spvc_context_parse_spirv(sc, (const SpvId *) spirv.buf,
                                spirv.len / sizeof(SpvId), &ir));

    spvc_compiler comp;
    SC(spvc_context_create_compiler(sc, SPVC_BACKEND_MSL, ir,
                                    SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &comp));

    spvc_compiler_options opts;
    SC(spvc_compiler_create_compiler_options(comp, &opts));
    SC(spvc_compiler_options_set_uint(opts, SPVC_COMPILER_OPTION_MSL_VERSION,
                                      SPVC_MAKE_MSL_VERSION(2, 2, 0)));
    // Like D3D, Metal's clip space is y-flipped relative to Vulkan's
    SC(spvc_compiler_options_set_bool(opts, SPVC_COMPILER_OPTION_FLIP_VERTEX_Y,
                                      SPVC_TRUE));
#if TARGET_OS_IPHONE
    SC(spvc_compiler_options_set_uint(opts, SPVC_COMPILER_OPTION_MSL_PLATFORM,
                                      SPVC_MSL_PLATFORM_IOS));
#endif
    SC(spvc_compiler_install_compiler_options(comp, opts));

    const SpvExecutionModel model = stage_to_spv(stage);

    for (int i = 0; i < params->num_descriptors; i++) {
        const struct pl_desc *desc = &params->descriptors[i];
        spvc_msl_resource_binding binding;
        spvc_msl_resource_binding_init(&binding);
        binding.stage = model;
        binding.desc_set = 0;
        binding.binding = desc->binding;
        binding.msl_buffer = desc->binding;
        binding.msl_texture = desc->binding;
        binding.msl_sampler = desc->binding;
        SC(spvc_compiler_msl_add_resource_binding(comp, &binding));
    }

    if (params->push_constants_size) {
        spvc_msl_resource_binding binding;
        spvc_msl_resource_binding_init(&binding);
        binding.stage = model;
        binding.desc_set = SPVC_MSL_PUSH_CONSTANT_DESC_SET;
        binding.binding = SPVC_MSL_PUSH_CONSTANT_BINDING;
        binding.msl_buffer = MTL_PUSHC_INDEX;
        SC(spvc_compiler_msl_add_resource_binding(comp, &binding));
    }

    const char *msl;
    SC(spvc_compiler_compile(comp, &msl));

    const char *entry = spvc_compiler_get_cleansed_entry_point_name(comp,
                            "main", model);

    out->msl = pl_str0dup0(alloc, msl);
    out->entrypoint = pl_str0dup0(alloc, entry ? entry : "main0");

    if (stage == GLSL_SHADER_COMPUTE) {
        out->group_size = MTLSizeMake(
            spvc_compiler_get_execution_mode_argument_by_index(comp,
                SpvExecutionModeLocalSize, 0),
            spvc_compiler_get_execution_mode_argument_by_index(comp,
                SpvExecutionModeLocalSize, 1),
            spvc_compiler_get_execution_mode_argument_by_index(comp,
                SpvExecutionModeLocalSize, 2));
    }

    spvc_context_destroy(sc);
    pl_free(tmp);
    return true;

error:
    if (sc)
        spvc_context_destroy(sc);
    pl_free(tmp);
    return false;
}

// Owned (+1) MTLFunction compiled from MSL source, or nil on failure
static id<MTLFunction> mtl_compile_function(pl_gpu gpu, const struct mtl_shader *sh)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    id<MTLFunction> fn = nil;

    @autoreleasepool {
        MTLCompileOptions *copts = [[MTLCompileOptions alloc] init];
        copts.languageVersion = MTLLanguageVersion2_2;

        NSError *err = nil;
        id<MTLLibrary> lib = [ctx->dev newLibraryWithSource:@(sh->msl)
                                                    options:copts
                                                      error:&err];
        [copts release];
        if (!lib) {
            PL_ERR(gpu, "Failed compiling MSL: %s",
                   err.localizedDescription.UTF8String);
            PL_DEBUG(gpu, "MSL source:\n%s", sh->msl);
            return nil;
        }

        fn = [lib newFunctionWithName:@(sh->entrypoint)];
        [lib release];
        if (!fn)
            PL_ERR(gpu, "Entry point '%s' not found in MSL library!", sh->entrypoint);
    }

    return fn;
}

static const MTLBlendFactor blend_factors[PL_BLEND_MODE_COUNT] = {
    [PL_BLEND_ZERO]                = MTLBlendFactorZero,
    [PL_BLEND_ONE]                 = MTLBlendFactorOne,
    [PL_BLEND_SRC_ALPHA]           = MTLBlendFactorSourceAlpha,
    [PL_BLEND_ONE_MINUS_SRC_ALPHA] = MTLBlendFactorOneMinusSourceAlpha,
};

pl_pass mtl_pass_create(pl_gpu gpu, const struct pl_pass_params *params)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);

    pl_assert(params->num_variables == 0); // max_variable_comps == 0
    pl_assert(params->num_constants == 0); // max_constants == 0

    struct pl_pass_t *pass = pl_zalloc_obj(NULL, pass, struct pl_pass_mtl);
    pass->params = pl_pass_params_copy(pass, params);
    struct pl_pass_mtl *p = PL_PRIV(pass);

    if (params->push_constants_size) {
        p->pushc_size = PL_ALIGN2(params->push_constants_size, 16);
        p->pushc = pl_zalloc(pass, p->pushc_size);
    }

    void *tmp = pl_tmp(NULL);
    id<MTLFunction> vert_fn = nil, frag_fn = nil, comp_fn = nil;

    @autoreleasepool {
        NSError *err = nil;

        switch (params->type) {
        case PL_PASS_RASTER: {
            struct mtl_shader vert = {0}, frag = {0};
            if (!mtl_compile_shader(gpu, tmp, params, GLSL_SHADER_VERTEX,
                                    params->vertex_shader, &vert))
                goto error;
            if (!mtl_compile_shader(gpu, tmp, params, GLSL_SHADER_FRAGMENT,
                                    params->glsl_shader, &frag))
                goto error;

            vert_fn = mtl_compile_function(gpu, &vert);
            frag_fn = mtl_compile_function(gpu, &frag);
            if (!vert_fn || !frag_fn)
                goto error;

            MTLRenderPipelineDescriptor *rpd = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
            rpd.vertexFunction = vert_fn;
            rpd.fragmentFunction = frag_fn;

            const struct pl_fmt_mtl *fmtp = PL_PRIV(params->target_format);
            MTLRenderPipelineColorAttachmentDescriptor *col = rpd.colorAttachments[0];
            col.pixelFormat = fmtp->mtl_fmt;

            const struct pl_blend_params *blend = params->blend_params;
            if (blend) {
                col.blendingEnabled = YES;
                col.rgbBlendOperation = MTLBlendOperationAdd;
                col.alphaBlendOperation = MTLBlendOperationAdd;
                col.sourceRGBBlendFactor = blend_factors[blend->src_rgb];
                col.destinationRGBBlendFactor = blend_factors[blend->dst_rgb];
                col.sourceAlphaBlendFactor = blend_factors[blend->src_alpha];
                col.destinationAlphaBlendFactor = blend_factors[blend->dst_alpha];
            }

            if (params->num_vertex_attribs) {
                MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
                for (int i = 0; i < params->num_vertex_attribs; i++) {
                    const struct pl_vertex_attrib *va = &params->vertex_attribs[i];
                    const struct pl_fmt_mtl *vap = PL_PRIV(va->fmt);
                    pl_assert(vap->mtl_vfmt != MTLVertexFormatInvalid);
                    vd.attributes[va->location].format = vap->mtl_vfmt;
                    vd.attributes[va->location].offset = va->offset;
                    vd.attributes[va->location].bufferIndex = MTL_VBUF_INDEX;
                }
                vd.layouts[MTL_VBUF_INDEX].stride = params->vertex_stride;
                vd.layouts[MTL_VBUF_INDEX].stepFunction = MTLVertexStepFunctionPerVertex;
                rpd.vertexDescriptor = vd;
            }

            p->rps = [ctx->dev newRenderPipelineStateWithDescriptor:rpd error:&err];
            if (!p->rps) {
                PL_ERR(gpu, "Failed creating render pipeline state: %s",
                       err.localizedDescription.UTF8String);
                goto error;
            }

            static const MTLPrimitiveType prim_map[PL_PRIM_TYPE_COUNT] = {
                [PL_PRIM_TRIANGLE_LIST]  = MTLPrimitiveTypeTriangle,
                [PL_PRIM_TRIANGLE_STRIP] = MTLPrimitiveTypeTriangleStrip,
            };
            p->prim = prim_map[params->vertex_type];
            break;
        }

        case PL_PASS_COMPUTE: {
            struct mtl_shader comp = {0};
            if (!mtl_compile_shader(gpu, tmp, params, GLSL_SHADER_COMPUTE,
                                    params->glsl_shader, &comp))
                goto error;

            comp_fn = mtl_compile_function(gpu, &comp);
            if (!comp_fn)
                goto error;

            p->cps = [ctx->dev newComputePipelineStateWithFunction:comp_fn error:&err];
            if (!p->cps) {
                PL_ERR(gpu, "Failed creating compute pipeline state: %s",
                       err.localizedDescription.UTF8String);
                goto error;
            }

            p->group_size = comp.group_size;
            break;
        }

        case PL_PASS_INVALID:
        case PL_PASS_TYPE_COUNT:
            pl_unreachable();
        }
    }

    [vert_fn release];
    [frag_fn release];
    [comp_fn release];
    pl_free(tmp);
    return pass;

error:
    [vert_fn release];
    [frag_fn release];
    [comp_fn release];
    pl_free(tmp);
    mtl_pass_destroy(gpu, pass);
    return NULL;
}

void mtl_pass_destroy(pl_gpu gpu, pl_pass pass)
{
    struct pl_pass_mtl *p = PL_PRIV(pass);
    [p->rps release];
    [p->cps release];
    pl_free((void *) pass);
}

// Binds a descriptor to `slot` for every relevant stage. `enc` is either a
// render or a compute command encoder.
static void mtl_bind_desc(pl_gpu gpu, id enc, bool compute,
                          const struct pl_desc *desc,
                          const struct pl_desc_binding *db)
{
    struct pl_gpu_mtl *p = PL_PRIV(gpu);
    const int slot = desc->binding;

    switch (desc->type) {
    case PL_DESC_SAMPLED_TEX: {
        pl_tex tex = db->object;
        struct pl_tex_mtl *texp = PL_PRIV(tex);
        id<MTLSamplerState> sampler = p->samplers[db->sample_mode][db->address_mode];
        if (compute) {
            [(id<MTLComputeCommandEncoder>) enc setTexture:texp->tex atIndex:slot];
            [(id<MTLComputeCommandEncoder>) enc setSamplerState:sampler atIndex:slot];
        } else {
            [(id<MTLRenderCommandEncoder>) enc setVertexTexture:texp->tex atIndex:slot];
            [(id<MTLRenderCommandEncoder>) enc setVertexSamplerState:sampler atIndex:slot];
            [(id<MTLRenderCommandEncoder>) enc setFragmentTexture:texp->tex atIndex:slot];
            [(id<MTLRenderCommandEncoder>) enc setFragmentSamplerState:sampler atIndex:slot];
        }
        return;
    }
    case PL_DESC_STORAGE_IMG: {
        pl_tex tex = db->object;
        struct pl_tex_mtl *texp = PL_PRIV(tex);
        if (compute) {
            [(id<MTLComputeCommandEncoder>) enc setTexture:texp->tex atIndex:slot];
        } else {
            [(id<MTLRenderCommandEncoder>) enc setVertexTexture:texp->tex atIndex:slot];
            [(id<MTLRenderCommandEncoder>) enc setFragmentTexture:texp->tex atIndex:slot];
        }
        return;
    }
    case PL_DESC_BUF_UNIFORM:
    case PL_DESC_BUF_STORAGE: {
        pl_buf buf = db->object;
        struct pl_buf_mtl *bufp = PL_PRIV(buf);
        if (compute) {
            [(id<MTLComputeCommandEncoder>) enc setBuffer:bufp->buf offset:0 atIndex:slot];
        } else {
            [(id<MTLRenderCommandEncoder>) enc setVertexBuffer:bufp->buf offset:0 atIndex:slot];
            [(id<MTLRenderCommandEncoder>) enc setFragmentBuffer:bufp->buf offset:0 atIndex:slot];
        }
        return;
    }
    case PL_DESC_BUF_TEXEL_UNIFORM:
    case PL_DESC_BUF_TEXEL_STORAGE:
        PL_ERR(gpu, "Texel buffers are not supported by the Metal backend!");
        return;
    case PL_DESC_INVALID:
    case PL_DESC_TYPE_COUNT:
        break;
    }

    pl_unreachable();
}

void mtl_pass_run(pl_gpu gpu, const struct pl_pass_run_params *params)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    pl_pass pass = params->pass;
    struct pl_pass_mtl *p = PL_PRIV(pass);

    @autoreleasepool {
        id<MTLCommandBuffer> cmdbuf = [ctx->queue commandBuffer];
        id<MTLBuffer> vbuf_tmp = nil, ibuf_tmp = nil;

        if (pass->params.type == PL_PASS_COMPUTE) {
            id<MTLComputeCommandEncoder> enc = [cmdbuf computeCommandEncoder];
            [enc setComputePipelineState:p->cps];

            for (int i = 0; i < pass->params.num_descriptors; i++) {
                mtl_bind_desc(gpu, enc, true, &pass->params.descriptors[i],
                              &params->desc_bindings[i]);
            }

            if (pass->params.push_constants_size) {
                memcpy(p->pushc, params->push_constants,
                       pass->params.push_constants_size);
                [enc setBytes:p->pushc length:p->pushc_size atIndex:MTL_PUSHC_INDEX];
            }

            [enc dispatchThreadgroups:MTLSizeMake(params->compute_groups[0],
                                                  params->compute_groups[1],
                                                  params->compute_groups[2])
                threadsPerThreadgroup:p->group_size];
            [enc endEncoding];
        } else {
            pl_tex target = params->target;
            struct pl_tex_mtl *targetp = PL_PRIV(target);

            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = targetp->tex;
            rpd.colorAttachments[0].loadAction = pass->params.load_target
                ? MTLLoadActionLoad : MTLLoadActionDontCare;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

            id<MTLRenderCommandEncoder> enc = [cmdbuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:p->rps];

            [enc setViewport:(MTLViewport) {
                .originX = params->viewport.x0,
                .originY = params->viewport.y0,
                .width   = pl_rect_w(params->viewport),
                .height  = pl_rect_h(params->viewport),
                .znear   = 0.0,
                .zfar    = 1.0,
            }];

            [enc setScissorRect:(MTLScissorRect) {
                .x      = params->scissors.x0,
                .y      = params->scissors.y0,
                .width  = pl_rect_w(params->scissors),
                .height = pl_rect_h(params->scissors),
            }];

            for (int i = 0; i < pass->params.num_descriptors; i++) {
                mtl_bind_desc(gpu, enc, false, &pass->params.descriptors[i],
                              &params->desc_bindings[i]);
            }

            if (pass->params.push_constants_size) {
                memcpy(p->pushc, params->push_constants,
                       pass->params.push_constants_size);
                [enc setVertexBytes:p->pushc length:p->pushc_size
                            atIndex:MTL_PUSHC_INDEX];
                [enc setFragmentBytes:p->pushc length:p->pushc_size
                              atIndex:MTL_PUSHC_INDEX];
            }

            if (params->vertex_data) {
                const size_t size = pl_vertex_buf_size(params);
                if (size <= 4096) {
                    [enc setVertexBytes:params->vertex_data
                                 length:size
                                atIndex:MTL_VBUF_INDEX];
                } else {
                    vbuf_tmp = [ctx->dev newBufferWithBytes:params->vertex_data
                                                     length:size
                                                    options:MTLResourceStorageModeShared];
                    [enc setVertexBuffer:vbuf_tmp offset:0 atIndex:MTL_VBUF_INDEX];
                }
            } else {
                struct pl_buf_mtl *bufp = PL_PRIV(params->vertex_buf);
                [enc setVertexBuffer:bufp->buf
                              offset:params->buf_offset
                             atIndex:MTL_VBUF_INDEX];
            }

            const MTLIndexType index_type = params->index_fmt == PL_INDEX_UINT32
                ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;

            if (params->index_data) {
                ibuf_tmp = [ctx->dev newBufferWithBytes:params->index_data
                                                 length:pl_index_buf_size(params)
                                                options:MTLResourceStorageModeShared];
                [enc drawIndexedPrimitives:p->prim
                                indexCount:params->vertex_count
                                 indexType:index_type
                               indexBuffer:ibuf_tmp
                         indexBufferOffset:0];
            } else if (params->index_buf) {
                struct pl_buf_mtl *bufp = PL_PRIV(params->index_buf);
                [enc drawIndexedPrimitives:p->prim
                                indexCount:params->vertex_count
                                 indexType:index_type
                               indexBuffer:bufp->buf
                         indexBufferOffset:params->index_offset];
            } else {
                [enc drawPrimitives:p->prim
                         vertexStart:0
                         vertexCount:params->vertex_count];
            }

            [enc endEncoding];
        }

        // Release the one-shot upload buffers once the GPU is done with them
        if (vbuf_tmp || ibuf_tmp) {
            [cmdbuf addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                [vbuf_tmp release];
                [ibuf_tmp release];
            }];
        }

        struct mtl_pending use = mtl_commit(ctx, cmdbuf);
        mtl_timer_record(params->timer, &use);

        // Track the last GPU use of everything this pass touches, so CPU
        // accesses and polls can synchronize against it
        for (int i = 0; i < pass->params.num_descriptors; i++) {
            const struct pl_desc *desc = &pass->params.descriptors[i];
            const struct pl_desc_binding *db = &params->desc_bindings[i];
            switch (desc->type) {
            case PL_DESC_SAMPLED_TEX:
            case PL_DESC_STORAGE_IMG: {
                struct pl_tex_mtl *texp = PL_PRIV((pl_tex) db->object);
                mtl_mark_pending(&texp->pending, &use);
                break;
            }
            case PL_DESC_BUF_UNIFORM:
            case PL_DESC_BUF_STORAGE: {
                struct pl_buf_mtl *bufp = PL_PRIV((pl_buf) db->object);
                mtl_mark_pending(&bufp->pending, &use);
                break;
            }
            default:
                break;
            }
        }

        if (pass->params.type == PL_PASS_RASTER) {
            struct pl_tex_mtl *targetp = PL_PRIV(params->target);
            mtl_mark_pending(&targetp->pending, &use);

            if (params->vertex_buf) {
                struct pl_buf_mtl *bufp = PL_PRIV(params->vertex_buf);
                mtl_mark_pending(&bufp->pending, &use);
            }
            if (params->index_buf) {
                struct pl_buf_mtl *bufp = PL_PRIV(params->index_buf);
                mtl_mark_pending(&bufp->pending, &use);
            }
        }

        mtl_pending_release(&use);
    }
}
