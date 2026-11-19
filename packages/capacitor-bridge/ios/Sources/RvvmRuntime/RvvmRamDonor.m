// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
// Uses xpc_shmem shared-memory donation from an auxiliary app extension to reduce
// host-process Jetsam pressure on iOS (technique pioneered by MeloNX, MIT-licensed).
#import "RvvmRamDonor.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <objc/message.h>
#import <pthread.h>

#if !TARGET_OS_SIMULATOR
#include <xpc/xpc.h>

@interface DeskFleetDonatedRegion : NSObject
@property (nonatomic, assign) void *ptr;
@property (nonatomic, assign) size_t size;
@property (nonatomic, strong, nullable) xpc_object_t shmem;
@property (nonatomic, strong, nullable) xpc_connection_t connection;
@property (nonatomic, strong, nullable) id extension;
@property (nonatomic, strong, nullable) id<NSCopying> requestId;
- (void)releaseResources;
@end

@implementation DeskFleetDonatedRegion
- (void)releaseResources {
    if (self.ptr && self.size > 0) {
        vm_deallocate(mach_task_self(), (vm_address_t)self.ptr, (vm_size_t)self.size);
        self.ptr = NULL;
        self.size = 0;
    }
    if (self.connection) {
        xpc_connection_cancel(self.connection);
        self.connection = nil;
    }
    self.shmem = nil;
    if (self.extension && self.requestId) {
        SEL cancelSel = NSSelectorFromString(@"cancelExtensionRequestWithIdentifier:");
        if ([self.extension respondsToSelector:cancelSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self.extension, cancelSel, self.requestId);
        }
    }
    self.requestId = nil;
    self.extension = nil;
}

- (void)dealloc {
    [self releaseResources];
}
@end

static pthread_mutex_t g_donor_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableArray<DeskFleetDonatedRegion *> *g_regions = nil;

void *rvvm_ram_donor_alloc(size_t size) {
    if (size == 0) {
        return NULL;
    }

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleId.length == 0) {
        return NULL;
    }
    NSString *extId = [bundleId stringByAppendingString:@".jit-helper"];
    Class nsExtensionClass = NSClassFromString(@"NSExtension");
    SEL extSel = NSSelectorFromString(@"extensionWithIdentifier:error:");
    if (!nsExtensionClass || ![nsExtensionClass respondsToSelector:extSel]) {
        return NULL;
    }

    NSError *lookupError = nil;
    id (*lookupFn)(id, SEL, NSString *, NSError *__autoreleasing *) =
        (id (*)(id, SEL, NSString *, NSError *__autoreleasing *))objc_msgSend;
    id extension = lookupFn(nsExtensionClass, extSel, extId, &lookupError);
    if (!extension) {
        return NULL;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block id<NSCopying> capturedRequestId = nil;
    __block xpc_object_t receivedShmem = nil;
    __block xpc_connection_t clientConn = nil;

    dispatch_queue_t xpcQueue = dispatch_queue_create("ai.yetanother.deskfleet.ram-donor", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener = xpc_connection_create(NULL, xpcQueue);
    xpc_endpoint_t endpoint = xpc_endpoint_create(listener);

    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) {
            return;
        }
        clientConn = (xpc_connection_t)peer;
        xpc_connection_set_target_queue(clientConn, xpcQueue);
        xpc_connection_set_event_handler(clientConn, ^(xpc_object_t msg) {
            if (xpc_get_type(msg) == XPC_TYPE_DICTIONARY) {
                xpc_object_t shmem = xpc_dictionary_get_value(msg, "shmem");
                if (shmem && xpc_get_type(shmem) == XPC_TYPE_SHMEM) {
                    receivedShmem = shmem;
                }
                dispatch_semaphore_signal(sem);
            } else if (xpc_get_type(msg) == XPC_TYPE_ERROR) {
                dispatch_semaphore_signal(sem);
            }
        });
        xpc_connection_resume(clientConn);
    });
    xpc_connection_resume(listener);

    NSXPCListenerEndpoint *nsEndpoint = [[NSXPCListenerEndpoint alloc] init];
    @try {
        [nsEndpoint setValue:endpoint forKey:@"_endpoint"];
    } @catch (NSException *ex) {
        (void)ex;
        xpc_connection_cancel(listener);
        return NULL;
    }

    NSExtensionItem *item = [[NSExtensionItem alloc] init];
    item.userInfo = @{
        @"action": @"donate_ram",
        @"size": @((unsigned long long)size),
        @"endpoint": nsEndpoint,
    };

    SEL beginSel = NSSelectorFromString(@"beginExtensionRequestWithInputItems:completion:");
    if (![extension respondsToSelector:beginSel]) {
        xpc_connection_cancel(listener);
        return NULL;
    }

    void (^onBegin)(id<NSCopying>, NSError *) = ^(id<NSCopying> reqId, NSError *err) {
        if (err) {
            dispatch_semaphore_signal(sem);
        } else {
            capturedRequestId = reqId;
        }
    };
    ((void (*)(id, SEL, NSArray *, id))objc_msgSend)(extension, beginSel, @[item], onBegin);

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC));
    xpc_connection_cancel(listener);

    if (!receivedShmem) {
        if (clientConn) {
            xpc_connection_cancel(clientConn);
        }
        return NULL;
    }

    void *mapped = NULL;
    size_t mappedSize = xpc_shmem_map(receivedShmem, &mapped);
    if (!mapped || mappedSize < size) {
        if (mapped && mappedSize > 0) {
            vm_deallocate(mach_task_self(), (vm_address_t)mapped, (vm_size_t)mappedSize);
        }
        if (clientConn) {
            xpc_connection_cancel(clientConn);
        }
        return NULL;
    }

    DeskFleetDonatedRegion *region = [[DeskFleetDonatedRegion alloc] init];
    region.ptr = mapped;
    region.size = mappedSize;
    region.shmem = receivedShmem;
    region.connection = clientConn;
    region.extension = extension;
    region.requestId = capturedRequestId;

    pthread_mutex_lock(&g_donor_lock);
    if (!g_regions) {
        g_regions = [[NSMutableArray alloc] init];
    }
    [g_regions addObject:region];
    pthread_mutex_unlock(&g_donor_lock);

    return mapped;
}

bool rvvm_ram_donor_free(void *ptr, size_t size) {
    (void)size;
    if (!ptr) {
        return false;
    }
    DeskFleetDonatedRegion *found = nil;
    pthread_mutex_lock(&g_donor_lock);
    for (NSUInteger i = 0; i < g_regions.count; ++i) {
        if (g_regions[i].ptr == ptr) {
            found = g_regions[i];
            [g_regions removeObjectAtIndex:i];
            break;
        }
    }
    pthread_mutex_unlock(&g_donor_lock);
    if (found) {
        [found releaseResources];
        return true;
    }
    return false;
}

void rvvm_ram_donor_release_all(void) {
    NSArray<DeskFleetDonatedRegion *> *snapshot = nil;
    pthread_mutex_lock(&g_donor_lock);
    if (g_regions.count > 0) {
        snapshot = [g_regions copy];
        [g_regions removeAllObjects];
    }
    pthread_mutex_unlock(&g_donor_lock);
    for (DeskFleetDonatedRegion *region in snapshot) {
        [region releaseResources];
    }
}
#else
void *rvvm_ram_donor_alloc(size_t size) {
    (void)size;
    return NULL;
}

bool rvvm_ram_donor_free(void *ptr, size_t size) {
    (void)ptr;
    (void)size;
    return false;
}

void rvvm_ram_donor_release_all(void) {}
#endif
