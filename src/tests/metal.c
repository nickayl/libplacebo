#include "gpu_tests.h"

#include <libplacebo/metal.h>

int main()
{
    pl_log log = pl_test_logger();
    pl_mtl mtl = pl_mtl_create(log, NULL);
    if (!mtl)
        return SKIP;

    pl_gpu gpu = mtl->gpu;
    REQUIRE(gpu);
    REQUIRE(gpu->num_formats > 0);
    REQUIRE_CMP(gpu->glsl.version, ==, 450, "d");
    REQUIRE(gpu->limits.max_tex_2d_dim >= 8192);

    // The p010/norm16 story: 16-bit unorm formats must exist and filter
    pl_fmt fmt = pl_find_fmt(gpu, PL_FMT_UNORM, 2, 16, 16,
                             PL_FMT_CAP_SAMPLEABLE | PL_FMT_CAP_LINEAR);
    REQUIRE(fmt);

    pl_buffer_tests(gpu);
    pl_texture_tests(gpu);
    gpu_shader_tests(gpu);

    pl_mtl_destroy(&mtl);
    pl_log_destroy(&log);
    return 0;
}
