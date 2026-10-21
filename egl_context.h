#pragma once

#include <gbm.h>
#include <EGL/egl.h>

struct EGLState {
    int         drm_fd  = -1;               // headless (GBM) path only
    gbm_device *gbm_dev = nullptr;           // headless (GBM) path only
    EGLDisplay  dpy     = EGL_NO_DISPLAY;
    EGLContext  ctx     = EGL_NO_CONTEXT;
    EGLSurface  surface = EGL_NO_SURFACE;    // windowed (Wayland) path only
};

// Headless, surfaceless GBM context — default pipeline-testing path.
// `render_node` defaults to the Pi's only GPU; the platform view (ihs/) passes
// the node that matches the shell's device on a multi-GPU host.
bool setup_egl(EGLState &egl, const char *render_node = "/dev/dri/renderD128");

bool check_extensions(const EGLState &egl);
void teardown_egl(EGLState &egl);
