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

#pragma once

#include "../common.h"
#include "../log.h"
#include "../gpu.h"

#import <Metal/Metal.h>

#include <libplacebo/metal.h>

// Note: this backend is built without ARC. Ownership of Objective-C objects
// is explicit: whatever is stored in these structs holds a retain reference,
// released by the matching destroy function.

struct mtl_ctx {
    pl_log log;
    struct pl_mtl_t *mtl;
    id<MTLDevice> dev;
};

struct pl_fmt_mtl {
    MTLPixelFormat mtl_fmt;
};

pl_gpu mtl_gpu_create(struct mtl_ctx *ctx);
void mtl_setup_formats(struct pl_gpu_t *gpu, id<MTLDevice> dev);
