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

#include "../common.h"
#include "log.h"

#include <libplacebo/metal.h>

const struct pl_mtl_params pl_mtl_default_params = { PL_MTL_DEFAULTS };

pl_mtl pl_mtl_create(pl_log log, const struct pl_mtl_params *params)
{
    pl_fatal(log, "libplacebo compiled without Metal support!");
    return NULL;
}

void pl_mtl_destroy(pl_mtl *pmtl)
{
    pl_mtl mtl = *pmtl;
    pl_assert(!mtl);
}

pl_swapchain pl_mtl_create_swapchain(pl_mtl mtl,
    const struct pl_mtl_swapchain_params *params)
{
    pl_unreachable();
}
