/*
 * vadrv_shim.c — Intel QSV fix for HandBrake/FFmpeg on Linux
 *
 * Problem 1: libmfx-gen (oneVPL GPU runtime) loads libva via dlopen(RTLD_DEEPBIND),
 * putting libva in a private symbol scope. This causes vaGetDriverName() to fail
 * (VA_STATUS_ERROR_UNIMPLEMENTED) on the MFX-internal VA display because the display
 * context's vaGetDriverName function pointer is NULL.
 *
 * Problem 2: iHD drivers built against VA-API < 1.15.0 export only
 * __vaDriverInit_1_14 and leave vtable_tpi NULL. This causes vaGetDeviceID() to
 * return VA_STATUS_ERROR_UNIMPLEMENTED, which FFmpeg's QSV hwdevice creation treats
 * as a fatal error ("Failed to get device id from the driver").
 *
 * Fix 1: Override dlopen() to strip RTLD_DEEPBIND for libva loads.
 *
 * Fix 2: Override vaGetDriverName() to return "iHD" unconditionally.
 *
 * Fix 3: Override vaGetDeviceID() to return the dev_t of the DRM render node
 * (from LIBVA_DRM_DEVICE env var, defaulting to /dev/dri/renderD128).
 *
 * Installed to /etc/ld.so.preload so it is effective for all processes.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>

typedef void         *VADisplay;
typedef int           VAStatus;
typedef unsigned int  VAGenericID;
#define VA_STATUS_SUCCESS 0

/* Strip RTLD_DEEPBIND when libmfx-gen (or anything else) dlopen's libva,
   so our versioned symbols stay reachable in the global scope. */
void *dlopen(const char *filename, int flags)
{
    typedef void *(*dlopen_fn)(const char *, int);
    dlopen_fn real = (dlopen_fn)dlsym(RTLD_NEXT, "dlopen");
    if (filename && strstr(filename, "libva"))
        flags &= ~RTLD_DEEPBIND;
    return real(filename, flags);
}

/* vaGetDriverName fails on MFX-internal VA displays that were not created via
   vaGetDisplayDRM(). Return the driver name from the environment ("iHD"). */
VAStatus vaGetDriverName(VADisplay dpy, char **driver_name)
{
    const char *name = getenv("LIBVA_DRIVER_NAME");
    if (!name) name = "iHD";
    if (driver_name) *driver_name = strdup(name);
    return VA_STATUS_SUCCESS;
}

/* vaGetDeviceID requires VA-API 1.15.0 (vtable_tpi) in the iHD driver.
   Drivers built against < 1.15.0 leave vtable_tpi NULL, so libva's own
   vaGetDeviceID() returns VA_STATUS_ERROR_UNIMPLEMENTED. We return the
   dev_t of the DRM render node directly, bypassing the vtable. */
VAStatus vaGetDeviceID(VADisplay dpy, VAGenericID *device_id)
{
    if (device_id) {
        struct stat s;
        const char *dev = getenv("LIBVA_DRM_DEVICE");
        if (!dev) dev = "/dev/dri/renderD128";
        *device_id = (stat(dev, &s) == 0) ? (VAGenericID)s.st_rdev : 0;
    }
    return VA_STATUS_SUCCESS;
}
