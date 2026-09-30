/*
 * miniaudio implementation TU + thin C shim for the Zig client (Phase B).
 *
 * miniaudio.h is ~4 MB of macros/GCC extensions and does not survive
 * translate-c, so the Zig side never @cImport()s it: audio.zig declares the
 * handful of entry points below and hands us one C function pointer for the
 * real-time data path. That keeps the Zig build fast and the shim auditable.
 *
 * fart-app (#20): the same shim also serves kujamba's local playback path
 * (kujamba play / kujamba trigger) via zc_playback_device_open, a
 * playback-only device with the same callback contract.
 */
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdlib.h>
#include <string.h>

/* mono-in / mono-out data path, called from the miniaudio audio thread */
typedef void (*zc_fill_fn)(void *user, float *out, float *in, unsigned int frames);

typedef struct
{
    ma_device device;
    ma_device_id id; /* resolved from --device; must outlive ma_device_init */
    zc_fill_fn fill;
    void *user;
    ma_uint64 frames_seen;
} zc_device;

static void zc_data_cb(ma_device *pDevice, void *pOutput, const void *pInput, ma_uint32 frameCount)
{
    zc_device *self = (zc_device*)pDevice->pUserData;
    if (self == NULL || self->fill == NULL) {
        return;
    }
    if (frameCount == 0) {
        return;
    }
    self->frames_seen += frameCount;
    self->fill(self->user, (float*)pOutput, (float*)pInput, (unsigned int)frameCount);
}

/* Resolve a `--device` id the way the demo scripts name devices: all digits
 * means "the Nth device in the backend's playback enumeration", anything else
 * is a case-insensitive substring match on playback device names. Writes the
 * ma_device_id into *out_id (which must outlive ma_device_init) and returns 0,
 * or a negative ma_result-derived code when nothing matches. */
static int zc_resolve_device_id(const char *device_id, ma_device_id *out_id)
{
    ma_context ctx;
    ma_device_info *infos = NULL;
    ma_uint32 count = 0;
    ma_result result;
    int all_digits = 1;
    const char *p;

    if (device_id == NULL || device_id[0] == 0 || out_id == NULL) {
        return -(int)MA_INVALID_ARGS;
    }
    for (p = device_id; *p != 0; ++p) {
        if (*p < '0' || *p > '9') {
            all_digits = 0;
            break;
        }
    }
    result = ma_context_init(NULL, 0, NULL, &ctx);
    if (result != MA_SUCCESS) {
        return -(int)result;
    }
    result = ma_context_get_devices(&ctx, &infos, &count, NULL, NULL);
    if (result != MA_SUCCESS) {
        ma_context_uninit(&ctx);
        return -(int)result;
    }
    result = MA_DOES_NOT_EXIST; /* a clean "no such device" for the caller */
    if (all_digits) {
        unsigned long idx = (unsigned long)strtoul(device_id, NULL, 10);
        if (idx < count) {
            *out_id = infos[idx].id;
            result = MA_SUCCESS;
        }
    } else {
        ma_uint32 i;
        for (i = 0; i < count; ++i) {
            if (infos[i].name[0] != 0 && strstr(infos[i].name, device_id) != NULL) {
                *out_id = infos[i].id;
                result = MA_SUCCESS;
                break;
            }
        }
    }
    ma_context_uninit(&ctx);
    /* plain negative ma_result codes: the callers negate when they need to */
    return (result == MA_SUCCESS) ? 0 : (int)result;
}

/* Open a device at `srate` (duplex for zc_device_open, playback-only for
 * zc_playback_device_open). Returns 0 on success, a negative zc error code
 * otherwise; `out` receives an opaque handle for the calls below.
 * `period_frames` of 0 lets the backend pick. `device_id` (duplex only)
 * selects a specific playback+capture pair via zc_resolve_device_id; NULL or
 * empty means the system default. */
static int zc_device_open_common(void **out, unsigned int srate, unsigned int period_frames,
                                 zc_fill_fn fill, void *user, const char *device_id,
                                 ma_device_type type)
{
    zc_device *self;
    ma_device_config config;
    ma_result result;

    if (out == NULL || fill == NULL) {
        return -1;
    }
    *out = NULL;

    self = (zc_device*)calloc(1, sizeof(zc_device));
    if (self == NULL) {
        return -2;
    }
    self->fill = fill;
    self->user = user;

    config = ma_device_config_init(type);
    config.playback.format = ma_format_f32;
    config.playback.channels = 1;
    if (type == ma_device_type_duplex) {
        config.capture.format = ma_format_f32;
        config.capture.channels = 1;
    }
    config.sampleRate = srate;
    if (period_frames != 0) {
        config.periodSizeInFrames = period_frames;
    }
    config.dataCallback = zc_data_cb;
    config.pUserData = self;

    if (device_id != NULL && device_id[0] != 0) {
        /* the id's storage must outlive ma_device_init, so it lives in the
         * device struct (the old custom.s trick never worked: it passed the
         * ma_device_id as ma_device_init's pContext argument) */
        int rc = zc_resolve_device_id(device_id, &self->id);
        if (rc != 0) {
            free(self);
            return rc; /* already a negative ma_result code */
        }
        config.playback.pDeviceID = &self->id;
        if (type == ma_device_type_duplex) {
            config.capture.pDeviceID = &self->id;
        }
    }
    result = ma_device_init(NULL, &config, &self->device);
    if (result != MA_SUCCESS) {
        free(self);
        return -(int)result;
    }
    if (ma_device_start(&self->device) != MA_SUCCESS) {
        ma_device_uninit(&self->device);
        free(self);
        return -3;
    }
    *out = (void*)self;
    return 0;
}

int zc_device_open(void **out, unsigned int srate, unsigned int period_frames,
                   zc_fill_fn fill, void *user, const char* device_id)
{
    return zc_device_open_common(out, srate, period_frames, fill, user,
                                 device_id, ma_device_type_duplex);
}

/* Playback-only open for the local audition path (#20): no capture side, so
 * no mic permission is needed and the tx ring on the Zig side stays unused.
 * device_id resolves exactly like zc_device_open's (index or name substring);
 * NULL or empty means the system default output. */
int zc_playback_device_open(void **out, unsigned int srate, unsigned int period_frames,
                            zc_fill_fn fill, void *user, const char *device_id)
{
    return zc_device_open_common(out, srate, period_frames, fill, user,
                                 device_id, ma_device_type_playback);
}

void zc_device_close(void *handle)
{
    zc_device *self = (zc_device*)handle;
    if (self == NULL) {
        return;
    }
    ma_device_uninit(&self->device);
    free(self);
}

/* rate the device actually runs at (may differ from the requested rate when
 * the backend had to fall back to the hardware's native rate) */
unsigned int zc_device_sample_rate(void *handle)
{
    zc_device *self = (zc_device*)handle;
    return (self == NULL) ? 0 : self->device.sampleRate;
}

const char* zc_device_name(void *handle)
{
    zc_device *self = (zc_device*)handle;
    if (self == NULL) {
        return "";
    }
    return (self->device.playback.name[0] != 0) ? self->device.playback.name : self->device.capture.name;
}

const char* zc_backend_name(void *handle)
{
    zc_device *self = (zc_device*)handle;
    if (self == NULL || self->device.pContext == NULL) {
        return "";
    }
    return ma_get_backend_name(self->device.pContext->backend);
}

/* frames the data callback has actually pulled through (both directions) */
ma_uint64 zc_device_frames_seen(void *handle)
{
    zc_device *self = (zc_device*)handle;
    return (self == NULL) ? 0 : self->frames_seen;
}

/* human-readable text for a negative zc_device_open code */
const char* zc_error_string(int code)
{
    if (code == -1) return "bad arguments";
    if (code == -2) return "out of memory";
    if (code == -3) return "ma_device_start failed";
    if (code < 0) {
        /* ma_result codes ARE negative; pass the code through unchanged */
        return ma_result_description((ma_result)code);
    }
    return "unknown error";
}

/* Report the default playback device (name + native rate) for diagnostics:
 * the demo uses it to prove a real output device exists even when opening a
 * duplex device fails (e.g. microphone permission denied). */
int zc_probe(const char* backend, unsigned int* out_srate, char* name_buf, unsigned int name_cap)
{
    ma_context ctx;
    ma_device_info* infos = NULL;
    ma_uint32 count = 0;
    ma_result result;

    (void)backend;
    if (name_buf != NULL && name_cap > 0) {
        name_buf[0] = '\0';
    }
    if (out_srate != NULL) {
        *out_srate = 0;
    }
    result = ma_context_init(NULL, 0, NULL, &ctx);
    if (result != MA_SUCCESS) {
        return -(int)result;
    }
    result = ma_context_get_devices(&ctx, &infos, &count, NULL, NULL);
    if (result != MA_SUCCESS) {
        ma_context_uninit(&ctx);
        return -(int)result;
    }
    for (ma_uint32 i = 0; i < count; ++i) {
        if (!infos[i].isDefault) {
            continue;
        }
        if (name_buf != NULL && name_cap > 0) {
            strncpy(name_buf, infos[i].name, name_cap - 1);
            name_buf[name_cap - 1] = '\0';
        }
        if (out_srate != NULL) {
            for (ma_uint32 f = 0; f < infos[i].nativeDataFormatCount && f < 64; ++f) {
                if (infos[i].nativeDataFormats[f].sampleRate != 0) {
                    *out_srate = infos[i].nativeDataFormats[f].sampleRate;
                    break;
                }
            }
        }
        break;
    }
    ma_context_uninit(&ctx);
    return 0;
}
