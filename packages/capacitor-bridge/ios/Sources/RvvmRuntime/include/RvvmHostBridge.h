// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
#ifndef DESKFLEET_RVVM_HOST_BRIDGE_H
#define DESKFLEET_RVVM_HOST_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rvvm_host_vm rvvm_host_vm_t;

typedef struct {
    size_t      memory_bytes;
    size_t      vcpu_count;
    size_t      jit_cache_bytes;
    bool        enable_jit;
    bool        enable_network;
    const char* firmware_path;
    const char* kernel_path;      // Optional (NULL when using fw_payload.bin with U-Boot)
    const char* cmdline;          // Optional kernel cmdline
    const char* root_disk_path;   // NVMe disk 0 (/dev/nvme0n1)
    const char* seed_disk_path;   // Optional NVMe disk 1 (/dev/nvme1n1)
    const char* console_log_path; // Optional log path for UART 0 (/dev/ttyS0)
} rvvm_host_config_t;

/// Returns true if the current process is allowed to map and execute JIT code
/// (CS_DEBUGGED or dynamic-codesigning on device, or always true on simulator).
bool rvvm_host_check_jit_enabled(void);

/// Returns true if a debugger is currently attached (P_TRACED, e.g. iOS 26+ StikJIT).
bool rvvm_host_is_traced(void);

/// Starts an embedded librvvm RISC-V 64-bit virtual machine with UART 0 (console log),
/// UART 1 (host<->guest exec channel), RTL8169 userland NAT networking, and NVMe storage.
rvvm_host_vm_t* rvvm_host_start(const rvvm_host_config_t* config, char* error_buf, size_t error_buf_len);

/// Returns true while the VM is powered and running.
bool rvvm_host_is_running(rvvm_host_vm_t* vm);

/// Writes bytes into UART 1 RX (host -> guest /dev/ttyS1).
size_t rvvm_host_channel_write(rvvm_host_vm_t* vm, const uint8_t* data, size_t len);

/// Reads bytes from UART 1 TX (guest /dev/ttyS1 -> host), blocking up to timeout_ms.
/// Returns 0 on timeout, or -1 if the VM has stopped.
int64_t rvvm_host_channel_read(rvvm_host_vm_t* vm, uint8_t* buf, size_t max_len, uint32_t timeout_ms);

/// Stops and frees the virtual machine and its attached devices.
void rvvm_host_stop(rvvm_host_vm_t* vm);

typedef void (*rvvm_host_progress_cb_t)(uint64_t done_bytes, uint64_t total_bytes, void* ctx);

/// Streams a gzip-compressed disk image into a sparse raw file on disk using zlib,
/// invoking optional progress_cb as compressed input bytes are consumed.
bool rvvm_host_gunzip_file_with_progress(
    const char*             src_gz_path,
    const char*             dst_raw_path,
    rvvm_host_progress_cb_t progress_cb,
    void*                   progress_ctx,
    char*                   error_buf,
    size_t                  error_buf_len
);

/// Streams a gzip-compressed disk image into a sparse raw file on disk using zlib.
bool rvvm_host_gunzip_file(const char* src_gz_path, const char* dst_raw_path, char* error_buf, size_t error_buf_len);

/// Writes newline-separated unique non-loopback IPv4 DNS server strings from the iOS
/// system resolver into out_buf and returns the byte count written.
size_t rvvm_host_copy_ipv4_dns_servers(char* out_buf, size_t out_buf_len);

#ifdef __cplusplus
}
#endif

#endif
