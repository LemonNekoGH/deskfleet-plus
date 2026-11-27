// Stand-ins for the simulator, which has no device to pair with (and no
// JIT / CoreDevice tunnel): build-ios-viewer.ts builds these instead of the Rust library
// for simulator builds. Same interface as include/ishplus_rppairing.h.
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "include/ishplus_rppairing.h"

static char *dup_str(const char *s) {
    if (!s) return NULL;
    size_t len = strlen(s);
    char *copy = (char *)malloc(len + 1);
    if (copy) {
        memcpy(copy, s, len + 1);
    }
    return copy;
}

int32_t ishplus_pairing_run(const char *name, const char *model,
                            ishplus_pairing_ready_cb ready, ishplus_pairing_pin_cb pin, void *ctx,
                            uint8_t **out_file, size_t *out_len, char **out_device, char **out_error) {
    (void)name; (void)model; (void)ready; (void)pin; (void)ctx; (void)out_file; (void)out_len; (void)out_device;
    if (out_error) *out_error = dup_str("On-device pairing is unavailable in iOS Simulator.");
    return -1;
}
void ishplus_pairing_cancel(void) {}
void ishplus_pairing_free(uint8_t *data, size_t len) { (void)len; free(data); }
void ishplus_pairing_free_string(char *s) { free(s); }

int32_t deskfleet_coredevice_probe(const char *host_ip, const char *pairing_path,
                                   char **out_json, char **out_error) {
    (void)host_ip; (void)pairing_path; (void)out_json;
    if (out_error) *out_error = dup_str("CoreDevice screen control is unavailable in iOS Simulator.");
    return -1;
}

void *deskfleet_coredevice_session_start(const char *host_ip, const char *pairing_path,
                                         int64_t display_id,
                                         deskfleet_coredevice_frame_cb on_frame,
                                         deskfleet_coredevice_clipboard_cb on_clipboard,
                                         deskfleet_coredevice_closed_cb on_closed,
                                         void *ctx, char **out_error) {
    (void)host_ip; (void)pairing_path; (void)display_id;
    (void)on_frame; (void)on_clipboard; (void)on_closed; (void)ctx;
    if (out_error) *out_error = dup_str("CoreDevice screen control is unavailable in iOS Simulator.");
    return NULL;
}

void deskfleet_coredevice_session_request_keyframe(void *handle) { (void)handle; }

int32_t deskfleet_coredevice_session_send_input(void *handle, const char *command_json) {
    (void)handle; (void)command_json;
    return -1;
}

void deskfleet_coredevice_session_stop(void *handle) { (void)handle; }
