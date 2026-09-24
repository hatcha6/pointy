/*
 * The counter camera as a barcode wedge, run entirely in native code.
 *
 * A camera is opened, streamed, decoded (zxing-cpp) and confirmed (a scan is
 * only reported once enough independent looks agree, see
 * policy/confirmation_policy.h) on native threads. Dart never sees a pixel
 * unless it asks for a preview; it hands the library a native port and
 * receives finished scans on it, the same way it would receive keystrokes
 * from a hardware scanner.
 *
 * WHY A PORT AND NOT A CALLBACK. `NativeCallable.listener` would read more
 * naturally, but calling one after Dart has closed it — which is exactly what
 * happens when the app exits or hot-restarts while a camera thread is mid-
 * frame — is a FATAL in the Dart VM ("Callback invoked after it has been
 * deleted.") and takes the whole till down with it. Posting to a closed port
 * simply returns false, which this library reads as "nobody is listening any
 * more" and uses to release the camera on its own.
 *
 * Every message posted to a port is a Dart List whose first element is one of
 * the PCW_MSG_* kinds below; the layout of each is documented next to it and
 * mirrored by lib/src/native_wedge_events.dart. Change both together, and
 * bump PCW_ABI_VERSION when a change is not backwards compatible. A bare
 * integer message is a liveness probe (the library checking a port is still
 * open) and carries nothing: ignore it.
 */
#ifndef POINTY_CAMERA_WEDGE_H_
#define POINTY_CAMERA_WEDGE_H_

#include <stdint.h>

#if defined(_WIN32)
#if defined(PCW_BUILDING_LIBRARY)
#define PCW_API __declspec(dllexport)
#else
#define PCW_API __declspec(dllimport)
#endif
#else
#define PCW_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped on any change the Dart side cannot read. */
#define PCW_ABI_VERSION 1

/* Message kinds: element 0 of every posted List. */
enum {
  /* [1, state, error, message, device_id, device_label, width, height,
   *  fps_milli, pixel_format, substituted (0/1), retry_in_ms] */
  PCW_MSG_STATUS = 1,
  /* [2, text, symbology, confirmations] */
  PCW_MSG_SCAN = 2,
  /* [3, frames_captured, frames_decoded, decode_hits, scans,
   *  rejected_disagreements, suppressed_rereads, capture_fps_milli,
   *  decode_us_average, active (0/1)] */
  PCW_MSG_STATS = 3,
  /* [4, width, height, Uint8List luma (width * height, row-major)] */
  PCW_MSG_PREVIEW = 4,
  /* [5, error, message, [id, label, id, label, ...]] */
  PCW_MSG_DEVICES = 5,
};

/* The wedge's lifecycle, as reported in PCW_MSG_STATUS. */
enum {
  PCW_STATE_STARTING = 1,   /* opening a camera */
  PCW_STATE_RUNNING = 2,    /* frames are arriving and being read */
  PCW_STATE_RECOVERING = 3, /* no camera right now; `error` says why, and it
                               will try again on its own after retry_in_ms */
  PCW_STATE_STOPPED = 4,    /* final: the camera is released, release the
                               handle */
};

/* Why a camera is not running. Stable numbers: Dart maps them to messages. */
enum {
  PCW_ERROR_NONE = 0,
  PCW_ERROR_NO_CAMERA = 1,        /* nothing connected at all */
  PCW_ERROR_DEVICE_NOT_FOUND = 2, /* the picked camera is absent and there is
                                     more than one other to choose from */
  PCW_ERROR_ACCESS_DENIED = 3,    /* the OS privacy setting blocks cameras */
  PCW_ERROR_IN_USE = 4,           /* another program holds the camera */
  PCW_ERROR_DEVICE_LOST = 5,      /* unplugged or reset while streaming */
  PCW_ERROR_NO_USABLE_FORMAT = 6, /* it offers nothing we can turn into grey */
  PCW_ERROR_STALLED = 7,          /* opened, then stopped sending frames */
  PCW_ERROR_PLATFORM = 8,         /* anything else; `message` has the code */
  PCW_ERROR_UNSUPPORTED = 9,      /* no camera backend on this platform */
};

typedef struct pcw_wedge pcw_wedge;

/*
 * Options for pcw_start. Zero means "use the default" for every number, so a
 * caller that zero-fills the struct and sets struct_size gets sane behaviour.
 */
typedef struct pcw_options {
  /* sizeof(pcw_options) as the caller knows it; lets fields be appended. */
  int32_t struct_size;
  /* UTF-8 id from pcw_list_devices, or NULL for "the first camera". */
  const char* device_id;
  /* The capture size to aim for. Default 1280x720. */
  int32_t preferred_width;
  int32_t preferred_height;
  /* How far apart two agreeing looks may be. Default 600. */
  int32_t agreement_window_ms;
  /* How long a value that was just scanned is ignored. Default 1500. */
  int32_t reread_holdoff_ms;
  /* How often PCW_MSG_STATS is posted. Default 1000. */
  int32_t stats_interval_ms;
} pcw_options;

/* PCW_ABI_VERSION of the library actually loaded. */
PCW_API int32_t pcw_abi_version(void);

/*
 * Connect the library to the Dart VM. Pass `NativeApi.initializeApiDLData`.
 * Call once per isolate before anything else; returns 0 on success.
 */
PCW_API int32_t pcw_initialize(void* dart_api_dl_data);

/* 1 when this build can open cameras on the platform it is running on. */
PCW_API int32_t pcw_is_supported(void);

/*
 * List cameras on a background thread and post one PCW_MSG_DEVICES message to
 * `reply_port`. Returns 0 when the request was accepted.
 */
PCW_API int32_t pcw_list_devices(int64_t reply_port);

/*
 * Start a wedge that posts events to `event_port`. Returns immediately; the
 * camera is opened on the wedge's own thread and its outcome arrives as a
 * PCW_MSG_STATUS. Returns NULL only when the library is not initialized.
 */
PCW_API pcw_wedge* pcw_start(const pcw_options* options, int64_t event_port);

/*
 * Ask for (max_edge > 0) or stop (max_edge <= 0) PCW_MSG_PREVIEW messages: the
 * latest frame, shrunk so its longer edge is at most max_edge, at most every
 * interval_ms. Off by default; nothing is copied for Dart while it is off.
 */
PCW_API void pcw_set_preview(pcw_wedge* wedge, int32_t max_edge,
                             int32_t interval_ms);

/*
 * Ask the wedge to stop. Returns at once; PCW_STATE_STOPPED is posted once the
 * camera has been released.
 */
PCW_API void pcw_stop(pcw_wedge* wedge);

/*
 * Stop (if needed), wait for the wedge's threads and free it. Call after
 * PCW_STATE_STOPPED has arrived and it returns immediately. The handle is
 * invalid afterwards.
 */
PCW_API void pcw_release(pcw_wedge* wedge);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* POINTY_CAMERA_WEDGE_H_ */
