// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
#ifndef DESKFLEET_RVVM_RAM_DONOR_H
#define DESKFLEET_RVVM_RAM_DONOR_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Attempts to allocate guest RAM backed by a shared-memory region donated by
/// DeskFleetJITHelper.appex so Jetsam accounts the dirty pages to the extension.
/// Returns NULL if unavailable (e.g. simulator or extension launch failure),
/// allowing librvvm to fall back to standard anonymous mmap.
void* rvvm_ram_donor_alloc(size_t size);

/// Releases a region previously returned by rvvm_ram_donor_alloc().
/// Returns true if ptr belonged to the RAM donor, false otherwise.
bool rvvm_ram_donor_free(void* ptr, size_t size);

/// Releases all active donated RAM regions and terminates donor helper sessions.
void rvvm_ram_donor_release_all(void);

#ifdef __cplusplus
}
#endif

#endif
