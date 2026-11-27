// Pairs iSH+ with the device it runs on (iOS 27+) and exposes CoreDevice
// screen streaming + HID remote control + pasteboard sync over LocalDevVPN.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*ishplus_pairing_ready_cb)(void *ctx, const char *service_name, uint16_t port,
                                         const char *const *txt_keys, const char *const *txt_values, size_t txt_count);
typedef void (*ishplus_pairing_pin_cb)(void *ctx, const char *pin);

int32_t ishplus_pairing_run(const char *name, const char *model,
                            ishplus_pairing_ready_cb ready, ishplus_pairing_pin_cb pin, void *ctx,
                            uint8_t **out_file, size_t *out_len, char **out_device, char **out_error);
void ishplus_pairing_cancel(void);
void ishplus_pairing_free(uint8_t *data, size_t len);
void ishplus_pairing_free_string(char *s);

typedef void (*deskfleet_coredevice_frame_cb)(void *ctx, const uint8_t *data, size_t len,
                                              uint64_t pts_ns, bool is_keyframe);
typedef void (*deskfleet_coredevice_clipboard_cb)(void *ctx, const char *utf8_text);
typedef void (*deskfleet_coredevice_closed_cb)(void *ctx, const char *error_or_null);

/// Probes CoreDevice RSD services on host_ip (typically "10.7.0.1") using pairing_path.
/// On success returns 0 and allocates a JSON string in out_json (free with ishplus_pairing_free_string).
/// On error returns -1 and allocates a message in out_error.
int32_t deskfleet_coredevice_probe(const char *host_ip, const char *pairing_path,
                                   char **out_json, char **out_error);

/// Starts a CoreDevice displayservice HEVC stream + HID/Pasteboard remote control session.
/// Returns an opaque non-NULL handle on success, or NULL with out_error populated on failure.
void *deskfleet_coredevice_session_start(const char *host_ip, const char *pairing_path,
                                         int64_t display_id,
                                         deskfleet_coredevice_frame_cb on_frame,
                                         deskfleet_coredevice_clipboard_cb on_clipboard,
                                         deskfleet_coredevice_closed_cb on_closed,
                                         void *ctx, char **out_error);

/// Requests an immediate HEVC keyframe (RTCP PLI + FIR) on an active session.
void deskfleet_coredevice_session_request_keyframe(void *handle);

/// Sends one JSON-encoded input command (`move`, `btn`, `wheel`, `key`, `clip`, `release`).
/// Returns 0 on enqueue, -1 if handle/json is invalid or the session is closed.
int32_t deskfleet_coredevice_session_send_input(void *handle, const char *command_json);

/// Stops and frees a session handle returned by deskfleet_coredevice_session_start.
void deskfleet_coredevice_session_stop(void *handle);

#ifdef __cplusplus
}
#endif
