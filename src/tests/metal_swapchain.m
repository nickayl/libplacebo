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
};

static void frame_cb(void *priv, void *iosurface, int width, int height)
{
    struct mirror_state *st = priv;
    IOSurfaceRef surface = (IOSurfaceRef) iosurface;
    if (!surface || width != st->expect_w || height != st->expect_h ||
        (int) IOSurfaceGetWidth(surface) != width ||
        (int) IOSurfaceGetHeight(surface) != height)
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

        struct mirror_state st = { .expect_w = width, .expect_h = height };

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

        // Destroy with the mirror installed must drain cleanly
        pl_swapchain_destroy(&sw);
        REQUIRE_CMP(atomic_load(&st.frames), ==, num_frames, "d");
    }

    pl_mtl_destroy(&mtl);
    pl_log_destroy(&log);
    return 0;
}
