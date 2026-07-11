#include "utils.h"

#include <stdatomic.h>
#include <unistd.h>

#include <libplacebo/metal.h>

#import <QuartzCore/CAMetalLayer.h>
#include <IOSurface/IOSurfaceRef.h>

struct mirror_state {
    _Atomic int frames;
    _Atomic int bad;
    int expect_w, expect_h;
    uint32_t expect_fourcc;
    enum pl_color_transfer expect_trc;
};

static void frame_cb(void *priv, void *iosurface, int width, int height,
                     const struct pl_color_space *csp)
{
    struct mirror_state *st = priv;
    IOSurfaceRef surface = (IOSurfaceRef) iosurface;
    if (!surface || !csp || width != st->expect_w || height != st->expect_h ||
        (int) IOSurfaceGetWidth(surface) != width ||
        (int) IOSurfaceGetHeight(surface) != height ||
        IOSurfaceGetPixelFormat(surface) != st->expect_fourcc ||
        csp->transfer != st->expect_trc)
    {
        atomic_fetch_add(&st->bad, 1);
    }
    atomic_fetch_add(&st->frames, 1);
}

static void render_frames(pl_gpu gpu, pl_swapchain sw, int count)
{
    for (int i = 0; i < count; i++) {
        struct pl_swapchain_frame frame;
        REQUIRE(pl_swapchain_start_frame(sw, &frame));
        REQUIRE(frame.fbo);
        pl_tex_clear(gpu, frame.fbo, (float[4]) { 1.0f, 0.0f, 0.0f, 1.0f });
        REQUIRE(pl_swapchain_submit_frame(sw));
        pl_swapchain_swap_buffers(sw);
    }
}

// The mirror fires from GPU completion handlers; give the queue a bounded
// window to drain instead of asserting on a race.
static int await_frames(struct mirror_state *st, int want)
{
    for (int i = 0; i < 500; i++) {
        if (atomic_load(&st->frames) >= want)
            break;
        usleep(10000);
    }
    return atomic_load(&st->frames);
}

int main()
{
    pl_log log = pl_test_logger();
    pl_mtl mtl = pl_mtl_create(log, NULL);
    if (!mtl)
        return SKIP;

    const int width = 320, height = 240;
    int w, h;

    @autoreleasepool {
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.drawableSize = CGSizeMake(width, height);

        struct mirror_state st = {
            .expect_w = width,
            .expect_h = height,
            .expect_fourcc = 0x42475241, // 'BGRA'
            .expect_trc = PL_COLOR_TRC_UNKNOWN,
        };

        // Without a mirror the swapchain must behave exactly as before
        pl_swapchain plain = pl_mtl_create_swapchain(mtl, pl_mtl_swapchain_params(
            .layer = layer,
        ));
        REQUIRE(plain);
        w = width; h = height;
        REQUIRE(pl_swapchain_resize(plain, &w, &h));
        REQUIRE_CMP(w, ==, width, "d");
        REQUIRE_CMP(h, ==, height, "d");
        render_frames(mtl->gpu, plain, 2);
        pl_swapchain_destroy(&plain);
        REQUIRE_CMP(atomic_load(&st.frames), ==, 0, "d");

        // With a mirror the callback must fire once per submitted frame, with
        // the frame's real IOSurface and pixel dimensions
        pl_swapchain sw = pl_mtl_create_swapchain(mtl, pl_mtl_swapchain_params(
            .layer = layer,
            .frame_callback = frame_cb,
            .frame_callback_priv = &st,
        ));
        REQUIRE(sw);
        w = width; h = height;
        REQUIRE(pl_swapchain_resize(sw, &w, &h));

        const int num_frames = 4;
        render_frames(mtl->gpu, sw, num_frames);
        REQUIRE_CMP(await_frames(&st, num_frames), ==, num_frames, "d");
        REQUIRE_CMP(atomic_load(&st.bad), ==, 0, "d");

        // With a mirror crop the callback must receive the crop region's dimensions
        const int crop_w = 160, crop_h = 120;
        pl_mtl_swapchain_set_frame_mirror_crop(sw, 80, 60, crop_w, crop_h);
        st.expect_w = crop_w;
        st.expect_h = crop_h;
        render_frames(mtl->gpu, sw, 2);
        REQUIRE_CMP(await_frames(&st, num_frames + 2), ==, num_frames + 2, "d");
        REQUIRE_CMP(atomic_load(&st.bad), ==, 0, "d");

        // Clearing the crop restores the full-frame mirror
        pl_mtl_swapchain_set_frame_mirror_crop(sw, 0, 0, 0, 0);
        st.expect_w = width;
        st.expect_h = height;
        render_frames(mtl->gpu, sw, 1);
        REQUIRE_CMP(await_frames(&st, num_frames + 3), ==, num_frames + 3, "d");
        REQUIRE_CMP(atomic_load(&st.bad), ==, 0, "d");

        // An HDR colorspace hint must move the mirror to the 10-bit swapchain
        // format and report the hinted color space
        pl_swapchain_colorspace_hint(sw, &(struct pl_color_space) {
            .primaries = PL_COLOR_PRIM_BT_2020,
            .transfer  = PL_COLOR_TRC_PQ,
            .hdr = { .max_luma = 1000 },
        });
        st.expect_fourcc = 0x6C313072; // 'l10r'
        st.expect_trc = PL_COLOR_TRC_PQ;
        render_frames(mtl->gpu, sw, 2);
        REQUIRE_CMP(await_frames(&st, num_frames + 5), ==, num_frames + 5, "d");
        REQUIRE_CMP(atomic_load(&st.bad), ==, 0, "d");

        // Destroy with the mirror installed must drain cleanly
        pl_swapchain_destroy(&sw);
        REQUIRE_CMP(atomic_load(&st.frames), ==, num_frames + 5, "d");
    }

    pl_mtl_destroy(&mtl);
    pl_log_destroy(&log);
    return 0;
}
