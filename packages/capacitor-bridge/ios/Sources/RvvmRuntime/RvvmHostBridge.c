// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
#include "RvvmHostBridge.h"
#include "RvvmRamDonor.h"

#include <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>
#include <zlib.h>

#define RVVM_STATIC 1
#include <rvvm/rvvm.h>
#include <rvvm/rvvm_board.h>
#include <ns16550a.h>
#include <rtl8169.h>

// Darwin csops() status flags
#define DESKFLEET_CS_OPS_STATUS 0
#define DESKFLEET_CS_DYNAMIC_CODESIGNING 0x00000200U
#define DESKFLEET_CS_DEBUGGED 0x10000000U

extern int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

static void set_error(char* buf, size_t len, const char* msg) {
    if (!buf || len == 0) {
        return;
    }
    snprintf(buf, len, "%s", msg ? msg : "unknown error");
}

bool rvvm_host_check_jit_enabled(void) {
#if TARGET_OS_SIMULATOR
    return true;
#else
    uint32_t flags = 0;
    if (csops(getpid(), DESKFLEET_CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & (DESKFLEET_CS_DEBUGGED | DESKFLEET_CS_DYNAMIC_CODESIGNING)) != 0;
#endif
}

bool rvvm_host_is_traced(void) {
    struct kinfo_proc info;
    size_t            info_size = sizeof(info);
    int               mib[4]    = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &info_size, NULL, 0) != 0) {
        return false;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// ---------------------------------------------------------------------------
// UART 0 console log chardev (guest -> log file)
// ---------------------------------------------------------------------------

typedef struct {
    chardev_t       base;
    int             fd;
    pthread_mutex_t lock;
} console_log_chardev_t;

static uint32_t console_log_poll(chardev_t* dev) {
    (void)dev;
    return CHARDEV_TX;
}

static size_t console_log_read(chardev_t* dev, void* buf, size_t nbytes) {
    (void)dev;
    (void)buf;
    (void)nbytes;
    return 0;
}

static size_t console_log_write(chardev_t* dev, const void* buf, size_t nbytes) {
    console_log_chardev_t* ctx = (console_log_chardev_t*)dev->data;
    if (!ctx || ctx->fd < 0 || !buf || nbytes == 0) {
        return nbytes;
    }
    pthread_mutex_lock(&ctx->lock);
    const uint8_t* ptr = (const uint8_t*)buf;
    size_t         rem = nbytes;
    while (rem > 0) {
        ssize_t written = write(ctx->fd, ptr, rem);
        if (written <= 0) {
            break;
        }
        ptr += (size_t)written;
        rem -= (size_t)written;
    }
    pthread_mutex_unlock(&ctx->lock);
    return nbytes;
}

static void console_log_remove(chardev_t* dev) {
    console_log_chardev_t* ctx = (console_log_chardev_t*)dev->data;
    if (!ctx) {
        return;
    }
    pthread_mutex_lock(&ctx->lock);
    if (ctx->fd >= 0) {
        close(ctx->fd);
        ctx->fd = -1;
    }
    pthread_mutex_unlock(&ctx->lock);
    pthread_mutex_destroy(&ctx->lock);
    free(ctx);
}

static chardev_t* console_log_chardev_create(const char* path) {
    console_log_chardev_t* ctx = (console_log_chardev_t*)calloc(1, sizeof(console_log_chardev_t));
    if (!ctx) {
        return NULL;
    }
    ctx->fd = -1;
    if (path && path[0] != '\0') {
        ctx->fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    }
    pthread_mutex_init(&ctx->lock, NULL);
    ctx->base.data   = ctx;
    ctx->base.poll   = console_log_poll;
    ctx->base.read   = console_log_read;
    ctx->base.write  = console_log_write;
    ctx->base.remove = console_log_remove;
    return &ctx->base;
}

// ---------------------------------------------------------------------------
// UART 1 bidirectional in-memory ring-buffer chardev (host <-> guest exec)
// ---------------------------------------------------------------------------

#define EXEC_RING_CAPACITY (256U * 1024U)

typedef struct {
    uint8_t* data;
    size_t   cap;
    size_t   head;
    size_t   tail;
    size_t   count;
} byte_ring_t;

static bool byte_ring_init(byte_ring_t* ring, size_t cap) {
    ring->data = (uint8_t*)malloc(cap);
    if (!ring->data) {
        return false;
    }
    ring->cap   = cap;
    ring->head  = 0;
    ring->tail  = 0;
    ring->count = 0;
    return true;
}

static void byte_ring_free(byte_ring_t* ring) {
    free(ring->data);
    ring->data  = NULL;
    ring->cap   = 0;
    ring->head  = 0;
    ring->tail  = 0;
    ring->count = 0;
}

static size_t byte_ring_push(byte_ring_t* ring, const uint8_t* src, size_t len) {
    size_t space = ring->cap - ring->count;
    size_t n     = len < space ? len : space;
    for (size_t i = 0; i < n; ++i) {
        ring->data[ring->tail] = src[i];
        ring->tail             = (ring->tail + 1) % ring->cap;
    }
    ring->count += n;
    return n;
}

static size_t byte_ring_pop(byte_ring_t* ring, uint8_t* dst, size_t len) {
    size_t n = len < ring->count ? len : ring->count;
    for (size_t i = 0; i < n; ++i) {
        dst[i]     = ring->data[ring->head];
        ring->head = (ring->head + 1) % ring->cap;
    }
    ring->count -= n;
    return n;
}

typedef struct {
    chardev_t       base;
    pthread_mutex_t lock;
    pthread_cond_t  tx_cond; // Signaled when guest writes bytes for host to read
    byte_ring_t     rx;      // Host -> guest
    byte_ring_t     tx;      // Guest -> host
    bool            closed;
    int             refcount;
} exec_channel_t;

static void exec_channel_release(exec_channel_t* ch) {
    bool should_free = false;
    pthread_mutex_lock(&ch->lock);
    ch->refcount -= 1;
    if (ch->refcount <= 0) {
        should_free = true;
    }
    pthread_mutex_unlock(&ch->lock);
    if (should_free) {
        byte_ring_free(&ch->rx);
        byte_ring_free(&ch->tx);
        pthread_cond_destroy(&ch->tx_cond);
        pthread_mutex_destroy(&ch->lock);
        free(ch);
    }
}

static uint32_t exec_channel_poll(chardev_t* dev) {
    exec_channel_t* ch    = (exec_channel_t*)dev->data;
    uint32_t        flags = 0;
    pthread_mutex_lock(&ch->lock);
    if (ch->rx.count > 0) {
        flags |= CHARDEV_RX;
    }
    if (ch->tx.count < ch->tx.cap) {
        flags |= CHARDEV_TX;
    }
    pthread_mutex_unlock(&ch->lock);
    return flags;
}

static size_t exec_channel_read(chardev_t* dev, void* buf, size_t nbytes) {
    exec_channel_t* ch = (exec_channel_t*)dev->data;
    pthread_mutex_lock(&ch->lock);
    size_t n = byte_ring_pop(&ch->rx, (uint8_t*)buf, nbytes);
    pthread_mutex_unlock(&ch->lock);
    return n;
}

static size_t exec_channel_write(chardev_t* dev, const void* buf, size_t nbytes) {
    exec_channel_t* ch = (exec_channel_t*)dev->data;
    pthread_mutex_lock(&ch->lock);
    size_t n = byte_ring_push(&ch->tx, (const uint8_t*)buf, nbytes);
    if (n > 0) {
        pthread_cond_broadcast(&ch->tx_cond);
    }
    pthread_mutex_unlock(&ch->lock);
    return n;
}

static void exec_channel_remove(chardev_t* dev) {
    exec_channel_t* ch = (exec_channel_t*)dev->data;
    if (!ch) {
        return;
    }
    pthread_mutex_lock(&ch->lock);
    ch->closed       = true;
    ch->base.io_dev  = NULL;
    ch->base.notify  = NULL;
    pthread_cond_broadcast(&ch->tx_cond);
    pthread_mutex_unlock(&ch->lock);
    exec_channel_release(ch);
}

static exec_channel_t* exec_channel_create(void) {
    exec_channel_t* ch = (exec_channel_t*)calloc(1, sizeof(exec_channel_t));
    if (!ch) {
        return NULL;
    }
    if (!byte_ring_init(&ch->rx, EXEC_RING_CAPACITY) || !byte_ring_init(&ch->tx, EXEC_RING_CAPACITY)) {
        byte_ring_free(&ch->rx);
        byte_ring_free(&ch->tx);
        free(ch);
        return NULL;
    }
    pthread_mutex_init(&ch->lock, NULL);
    pthread_cond_init(&ch->tx_cond, NULL);
    ch->refcount    = 2; // One for UART device, one for rvvm_host_vm_t
    ch->base.data   = ch;
    ch->base.poll   = exec_channel_poll;
    ch->base.read   = exec_channel_read;
    ch->base.write  = exec_channel_write;
    ch->base.remove = exec_channel_remove;
    return ch;
}

// ---------------------------------------------------------------------------
// VM wrapper
// ---------------------------------------------------------------------------

struct rvvm_host_vm {
    rvvm_machine_t* machine;
    exec_channel_t* channel;
};

static void* rvvm_donor_alloc_hook(size_t size) {
    return rvvm_ram_donor_alloc(size);
}

static bool rvvm_donor_free_hook(void* ptr, size_t size) {
    return rvvm_ram_donor_free(ptr, size);
}

rvvm_host_vm_t* rvvm_host_start(const rvvm_host_config_t* config, char* error_buf, size_t error_buf_len) {
    if (!config) {
        set_error(error_buf, error_buf_len, "RVVM config is NULL");
        return NULL;
    }
    if (!config->firmware_path || config->firmware_path[0] == '\0') {
        set_error(error_buf, error_buf_len, "RVVM firmware path is required");
        return NULL;
    }
    if (config->enable_jit && !rvvm_host_check_jit_enabled()) {
        set_error(error_buf, error_buf_len, "JIT is not enabled for this process");
        return NULL;
    }

    rvvm_set_ram_allocator(rvvm_donor_alloc_hook, rvvm_donor_free_hook);

    size_t mem_bytes  = config->memory_bytes ? config->memory_bytes : (512ULL << 20);
    size_t vcpu_count = config->vcpu_count ? config->vcpu_count : 2U;
    size_t jit_cache  = config->jit_cache_bytes ? config->jit_cache_bytes : (32ULL << 20);

    rvvm_machine_t* machine = rvvm_create_machine(mem_bytes, vcpu_count, "rv64");
    if (!machine) {
        set_error(error_buf, error_buf_len, "rvvm_create_machine() failed");
        return NULL;
    }

    rvvm_set_opt(machine, RVVM_OPT_JIT, config->enable_jit ? 1 : 0);
    rvvm_set_opt(machine, RVVM_OPT_JIT_CACHE, jit_cache);

    if (!rvvm_board_riscv_virt_init(machine, false)) {
        rvvm_free_machine(machine);
        set_error(error_buf, error_buf_len, "rvvm_board_riscv_virt_init() failed");
        return NULL;
    }

    // UART 0 (/dev/ttyS0): boot console log
    chardev_t* console_dev = console_log_chardev_create(config->console_log_path);
    if (!rvvm_ns16550a_init(machine, console_dev, 0x10000000UL, 0, NULL, 0)) {
        rvvm_free_machine(machine);
        set_error(error_buf, error_buf_len, "Failed to attach UART 0 console");
        return NULL;
    }

    // UART 1 (/dev/ttyS1): DeskFleet host<->guest exec channel
    exec_channel_t* channel = exec_channel_create();
    if (!channel) {
        rvvm_free_machine(machine);
        set_error(error_buf, error_buf_len, "Failed to allocate exec channel");
        return NULL;
    }
    if (!rvvm_ns16550a_init(machine, &channel->base, 0x10001000UL, 0, NULL, 0)) {
        exec_channel_release(channel);
        rvvm_free_machine(machine);
        set_error(error_buf, error_buf_len, "Failed to attach UART 1 exec channel");
        return NULL;
    }

    // Networking: RTL8169 + pure userland NAT TAP
    if (config->enable_network) {
        tap_dev_t* tap = tap_open();
        if (!tap || !rvvm_rtl8169_init(machine, tap, RVVM_PCI_ADDR_ANY)) {
            if (tap) {
                tap_close(tap);
            }
            exec_channel_release(channel);
            rvvm_free_machine(machine);
            set_error(error_buf, error_buf_len, "Failed to initialize userland RTL8169 network");
            return NULL;
        }
    }

    // Root disk (/dev/nvme0n1)
    if (config->root_disk_path && config->root_disk_path[0] != '\0') {
        if (!rvvm_nvme_init_auto(machine, config->root_disk_path)) {
            exec_channel_release(channel);
            rvvm_free_machine(machine);
            set_error(error_buf, error_buf_len, "Failed to attach root NVMe disk image");
            return NULL;
        }
    }

    // Optional seed disk (/dev/nvme1n1)
    if (config->seed_disk_path && config->seed_disk_path[0] != '\0') {
        if (!rvvm_nvme_init_auto(machine, config->seed_disk_path)) {
            exec_channel_release(channel);
            rvvm_free_machine(machine);
            set_error(error_buf, error_buf_len, "Failed to attach seed NVMe disk image");
            return NULL;
        }
    }

    if (config->cmdline && config->cmdline[0] != '\0') {
        rvvm_set_cmdline(machine, config->cmdline);
    }

    if (!rvvm_load_firmware(machine, config->firmware_path)) {
        exec_channel_release(channel);
        rvvm_free_machine(machine);
        set_error(error_buf, error_buf_len, "Failed to load RISC-V firmware");
        return NULL;
    }

    if (config->kernel_path && config->kernel_path[0] != '\0') {
        if (!rvvm_load_kernel(machine, config->kernel_path)) {
            exec_channel_release(channel);
            rvvm_free_machine(machine);
            set_error(error_buf, error_buf_len, "Failed to load Linux kernel payload");
            return NULL;
        }
    }

    if (!rvvm_start_machine(machine)) {
        exec_channel_release(channel);
        rvvm_free_machine(machine);
        set_error(error_buf, error_buf_len, "rvvm_start_machine() failed");
        return NULL;
    }

    rvvm_host_vm_t* vm = (rvvm_host_vm_t*)calloc(1, sizeof(rvvm_host_vm_t));
    if (!vm) {
        rvvm_free_machine(machine);
        exec_channel_release(channel);
        set_error(error_buf, error_buf_len, "Out of memory");
        return NULL;
    }
    vm->machine = machine;
    vm->channel = channel;
    return vm;
}

bool rvvm_host_is_running(rvvm_host_vm_t* vm) {
    if (!vm || !vm->machine) {
        return false;
    }
    return rvvm_machine_running(vm->machine);
}

size_t rvvm_host_channel_write(rvvm_host_vm_t* vm, const uint8_t* data, size_t len) {
    if (!vm || !vm->channel || !data || len == 0) {
        return 0;
    }
    exec_channel_t* ch = vm->channel;
    pthread_mutex_lock(&ch->lock);
    if (ch->closed) {
        pthread_mutex_unlock(&ch->lock);
        return 0;
    }
    size_t written = byte_ring_push(&ch->rx, data, len);
    void (*notify)(void*, uint32_t) = ch->base.notify;
    void* io_dev = ch->base.io_dev;
    pthread_mutex_unlock(&ch->lock);
    if (written > 0 && notify && io_dev) {
        notify(io_dev, CHARDEV_RX);
    }
    return written;
}

int64_t rvvm_host_channel_read(rvvm_host_vm_t* vm, uint8_t* buf, size_t max_len, uint32_t timeout_ms) {
    if (!vm || !vm->channel || !buf || max_len == 0) {
        return -1;
    }
    exec_channel_t* ch = vm->channel;
    pthread_mutex_lock(&ch->lock);
    if (ch->tx.count == 0 && !ch->closed && timeout_ms > 0) {
        struct timeval  tv;
        struct timespec ts;
        gettimeofday(&tv, NULL);
        uint64_t ns = (uint64_t)tv.tv_usec * 1000ULL + (uint64_t)timeout_ms * 1000000ULL;
        ts.tv_sec   = tv.tv_sec + (time_t)(ns / 1000000000ULL);
        ts.tv_nsec  = (long)(ns % 1000000000ULL);
        pthread_cond_timedwait(&ch->tx_cond, &ch->lock, &ts);
    }
    if (ch->tx.count > 0) {
        size_t n = byte_ring_pop(&ch->tx, buf, max_len);
        void (*notify)(void*, uint32_t) = ch->base.notify;
        void* io_dev = ch->base.io_dev;
        pthread_mutex_unlock(&ch->lock);
        if (notify && io_dev) {
            notify(io_dev, CHARDEV_TX);
        }
        return (int64_t)n;
    }
    bool closed = ch->closed;
    pthread_mutex_unlock(&ch->lock);
    return closed ? -1 : 0;
}

void rvvm_host_stop(rvvm_host_vm_t* vm) {
    if (!vm) {
        return;
    }
    if (vm->channel) {
        pthread_mutex_lock(&vm->channel->lock);
        vm->channel->closed = true;
        pthread_cond_broadcast(&vm->channel->tx_cond);
        pthread_mutex_unlock(&vm->channel->lock);
    }
    if (vm->machine) {
        rvvm_free_machine(vm->machine);
        vm->machine = NULL;
    }
    if (vm->channel) {
        exec_channel_release(vm->channel);
        vm->channel = NULL;
    }
    free(vm);
}

static bool buffer_is_all_zero(const uint8_t* buf, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        if (buf[i] != 0) {
            return false;
        }
    }
    return true;
}

bool rvvm_host_gunzip_file(const char* src_gz_path, const char* dst_raw_path, char* error_buf, size_t error_buf_len) {
    if (!src_gz_path || !dst_raw_path) {
        set_error(error_buf, error_buf_len, "Invalid gunzip file paths");
        return false;
    }

    gzFile gz = gzopen(src_gz_path, "rb");
    if (!gz) {
        set_error(error_buf, error_buf_len, "Failed to open gzip guest image");
        return false;
    }
    gzbuffer(gz, 256 * 1024);

    int out_fd = open(dst_raw_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (out_fd < 0) {
        gzclose(gz);
        set_error(error_buf, error_buf_len, "Failed to create destination guest disk image");
        return false;
    }

    const size_t chunk_size = 256 * 1024;
    uint8_t*     buf        = (uint8_t*)malloc(chunk_size);
    if (!buf) {
        close(out_fd);
        gzclose(gz);
        set_error(error_buf, error_buf_len, "Out of memory allocating gunzip buffer");
        return false;
    }

    off_t total_written = 0;
    bool  ok            = true;
    while (true) {
        int n = gzread(gz, buf, (unsigned int)chunk_size);
        if (n < 0) {
            int         zerr = 0;
            const char* zmsg = gzerror(gz, &zerr);
            set_error(error_buf, error_buf_len, zmsg ? zmsg : "zlib read error");
            ok = false;
            break;
        }
        if (n == 0) {
            break;
        }
        // Preserve APFS sparse holes for all-zero blocks to keep guest image footprint small.
        if (buffer_is_all_zero(buf, (size_t)n)) {
            if (lseek(out_fd, (off_t)n, SEEK_CUR) < 0) {
                set_error(error_buf, error_buf_len, "Failed to seek sparse hole in guest disk image");
                ok = false;
                break;
            }
        } else {
            size_t offset = 0;
            while (offset < (size_t)n) {
                ssize_t w = write(out_fd, buf + offset, (size_t)n - offset);
                if (w <= 0) {
                    set_error(error_buf, error_buf_len, "Failed writing guest disk image");
                    ok = false;
                    break;
                }
                offset += (size_t)w;
            }
            if (!ok) {
                break;
            }
        }
        total_written += (off_t)n;
    }

    if (ok && ftruncate(out_fd, total_written) != 0) {
        set_error(error_buf, error_buf_len, "Failed finalizing guest disk image size");
        ok = false;
    }

    free(buf);
    close(out_fd);
    int close_rc = gzclose(gz);
    if (ok && close_rc != Z_OK) {
        set_error(error_buf, error_buf_len, "gzip stream integrity check failed");
        ok = false;
    }
    return ok;
}
