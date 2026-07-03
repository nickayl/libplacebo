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

const struct pl_mtl_params pl_mtl_default_params = { PL_MTL_DEFAULTS };

pl_mtl pl_mtl_create(pl_log log, const struct pl_mtl_params *params)
{
    params = PL_DEF(params, &pl_mtl_default_params);

    struct pl_mtl_t *mtl = pl_zalloc_obj(NULL, mtl, struct mtl_ctx);
    struct mtl_ctx *ctx = PL_PRIV(mtl);
    ctx->log = log;
    ctx->mtl = mtl;

    id<MTLDevice> dev = params->device;
    if (dev) {
        [dev retain];
    } else {
        dev = MTLCreateSystemDefaultDevice();
    }

    if (!dev) {
        pl_fatal(log, "Failed to create a Metal device!");
        goto error;
    }

    ctx->dev = dev;
    mtl->device = dev;
    @autoreleasepool {
        pl_info(log, "Created Metal device: %s", dev.name.UTF8String);
    }

    ctx->queue = [dev newCommandQueue];
    if (!ctx->queue) {
        pl_fatal(log, "Failed to create a Metal command queue!");
        goto error;
    }

    // Optional: enables bounded-timeout waits on individual submissions
    ctx->event = [dev newSharedEvent];

    mtl->gpu = mtl_gpu_create(ctx);
    if (!mtl->gpu)
        goto error;

    return mtl;

error:
    pl_mtl_destroy((pl_mtl *) &mtl);
    return NULL;
}

void pl_mtl_destroy(pl_mtl *pmtl)
{
    struct pl_mtl_t *mtl = (struct pl_mtl_t *) *pmtl;
    if (!mtl)
        return;

    pl_gpu_destroy(mtl->gpu);

    struct mtl_ctx *ctx = PL_PRIV(mtl);
    [ctx->event release];
    [ctx->queue release];
    [ctx->dev release];

    pl_free(mtl);
    *pmtl = NULL;
}
