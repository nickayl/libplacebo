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

pl_buf mtl_buf_create(pl_gpu gpu, const struct pl_buf_params *params)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);

    struct pl_buf_t *buf = pl_zalloc_obj(NULL, buf, struct pl_buf_mtl);
    buf->params = *params;
    buf->params.initial_data = NULL;

    struct pl_buf_mtl *p = PL_PRIV(buf);

    // All buffers use shared storage: every supported device either has
    // unified memory or supports host-visible buffer mappings
    const MTLResourceOptions opts = MTLResourceStorageModeShared;
    const size_t size = PL_MAX(params->size, 1);

    if (params->initial_data) {
        p->buf = [ctx->dev newBufferWithBytes:params->initial_data
                                       length:size
                                      options:opts];
    } else {
        p->buf = [ctx->dev newBufferWithLength:size options:opts];
    }

    if (!p->buf) {
        PL_ERR(gpu, "Failed creating buffer of size %zu!", params->size);
        pl_free(buf);
        return NULL;
    }

    if (params->host_mapped)
        buf->data = p->buf.contents;

    return buf;
}

void mtl_buf_destroy(pl_gpu gpu, pl_buf buf)
{
    struct pl_buf_mtl *p = PL_PRIV(buf);
    // In-flight command buffers keep the MTLBuffer itself alive
    [p->pending release];
    [p->buf release];
    pl_free((void *) buf);
}

void mtl_buf_write(pl_gpu gpu, pl_buf buf, size_t buf_offset,
                   const void *data, size_t size)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    struct pl_buf_mtl *p = PL_PRIV(buf);
    mtl_pending_wait(ctx, &p->pending);
    memcpy((uint8_t *) p->buf.contents + buf_offset, data, size);
}

bool mtl_buf_read(pl_gpu gpu, pl_buf buf, size_t buf_offset,
                  void *dest, size_t size)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    struct pl_buf_mtl *p = PL_PRIV(buf);
    mtl_pending_wait(ctx, &p->pending);
    memcpy(dest, (const uint8_t *) p->buf.contents + buf_offset, size);
    return true;
}

void mtl_buf_copy(pl_gpu gpu, pl_buf dst, size_t dst_offset,
                  pl_buf src, size_t src_offset, size_t size)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    struct pl_buf_mtl *dstp = PL_PRIV(dst);
    struct pl_buf_mtl *srcp = PL_PRIV(src);

    id<MTLCommandBuffer> cmdbuf = mtl_blit_submit(ctx, ^(id<MTLBlitCommandEncoder> enc) {
        [enc copyFromBuffer:srcp->buf
               sourceOffset:src_offset
                   toBuffer:dstp->buf
          destinationOffset:dst_offset
                       size:size];
    });

    mtl_mark_pending(&srcp->pending, cmdbuf);
    mtl_mark_pending(&dstp->pending, cmdbuf);
    [cmdbuf release];
}

bool mtl_buf_poll(pl_gpu gpu, pl_buf buf, uint64_t timeout)
{
    struct mtl_ctx *ctx = mtl_ctx_of(gpu);
    struct pl_buf_mtl *p = PL_PRIV(buf);

    // Metal has no bounded wait on command buffers; only honor the
    // wait-forever case and otherwise just report the current status
    if (timeout == UINT64_MAX)
        mtl_pending_wait(ctx, &p->pending);

    return mtl_pending_busy(p->pending);
}
