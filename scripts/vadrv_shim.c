/*
 * vadrv_shim.c — Intel QSV fix for HandBrake/FFmpeg on Linux
 *
 * Problem: libmfx-gen (oneVPL GPU runtime) loads libva via dlopen(RTLD_DEEPBIND),
 * putting libva in a private symbol scope. This causes vaGetDriverName() to fail
 * (VA_STATUS_ERROR_UNIMPLEMENTED) on the MFX-internal VA display because the display
 * context's vaGetDriverName function pointer is NULL — it was never set via
 * vaGetDisplayDRM(). FFmpeg aborts hwdevice creation on that failure.
 *
 * Fix 1: Override dlopen() to strip RTLD_DEEPBIND for libva loads. Without DEEPBIND,
 * libva is loaded into the global symbol scope and our vaGetDriverName override is visible.
 *
 * Fix 2: Override vaGetDriverName() to always return "iHD" successfully. This lets
 * FFmpeg proceed past the verification check. The MFX session is already valid
 * (HandBrake's QSV detection succeeds), so the actual encode works.
 *
 * Installed to /etc/ld.so.preload so it is effective for all processes without
 * any wrapper scripts or runtime environment configuration.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

typedef void *VADisplay;
typedef int   VAStatus;
#define VA_STATUS_SUCCESS 0

/* Strip RTLD_DEEPBIND when libmfx-gen (or anything else) dlopen's libva,
   so our versioned vaGetDriverName symbol stays reachable in the global scope. */
void *dlopen(const char *filename, int flags)
{
    typedef void *(*dlopen_fn)(const char *, int);
    dlopen_fn real = (dlopen_fn)dlsym(RTLD_NEXT, "dlopen");
    if (filename && strstr(filename, "libva"))
        flags &= ~RTLD_DEEPBIND;
    return real(filename, flags);
}

/* vaGetDriverName fails on MFX-internal VA displays. Return "iHD" so FFmpeg's
   QSV hwdevice creation proceeds. The iHD string must match LIBVA_DRIVER_NAME. */
VAStatus vaGetDriverName(VADisplay dpy, char **driver_name)
{
    const char *name = getenv("LIBVA_DRIVER_NAME");
    if (!name) name = "iHD";
    if (driver_name) *driver_name = strdup(name);
    return VA_STATUS_SUCCESS;
}
