// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
// Auxiliary app extension principal supporting StikJIT activation and xpc_shmem RAM donation.
#import <Foundation/Foundation.h>
#import <sys/mman.h>

#if !TARGET_OS_SIMULATOR
#include <xpc/xpc.h>
#endif

@protocol DeskFleetJitHandlerProtocol <NSObject>
+ (void)handleRequestWithContext:(NSExtensionContext *)context
                     pairingPath:(NSString *)pairingPath
                       targetPid:(int32_t)targetPid
                     needsScript:(BOOL)needsScript;
@end

@interface DeskFleetHelperPrincipal : NSObject <NSExtensionRequestHandling>
@end

@implementation DeskFleetHelperPrincipal

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    NSExtensionItem *item = context.inputItems.firstObject;
    NSDictionary *info = item.userInfo;
    NSString *action = [info[@"action"] isKindOfClass:[NSString class]] ? info[@"action"] : nil;

    if ([action isEqualToString:@"donate_ram"]) {
        [self handleDonateRamWithContext:context info:info];
        return;
    }

    if ([action isEqualToString:@"enable_jit"]) {
        NSString *pairingPath = [info[@"pairingPath"] isKindOfClass:[NSString class]] ? info[@"pairingPath"] : @"";
        int32_t targetPid = [info[@"pid"] intValue];
        BOOL needsScript = [info[@"needsScript"] boolValue];
        Class<DeskFleetJitHandlerProtocol> handlerClass =
            (Class<DeskFleetJitHandlerProtocol>)NSClassFromString(@"DeskFleetJitHelper");
        if (!handlerClass) {
            [self completeContext:context success:NO error:@"DeskFleetJitHelper class unavailable"];
            return;
        }
        [handlerClass handleRequestWithContext:context
                                   pairingPath:pairingPath
                                     targetPid:targetPid
                                   needsScript:needsScript];
        return;
    }

    [self completeContext:context success:NO error:@"Unsupported DeskFleetJITHelper action"];
}

- (void)handleDonateRamWithContext:(NSExtensionContext *)context info:(NSDictionary *)info {
#if TARGET_OS_SIMULATOR
    [self completeContext:context success:NO error:@"RAM donation is not used on Simulator"];
#else
    unsigned long long requestedSize = [info[@"size"] unsignedLongLongValue];
    NSXPCListenerEndpoint *nsEndpoint = info[@"endpoint"];
    if (requestedSize == 0 || ![nsEndpoint isKindOfClass:[NSXPCListenerEndpoint class]]) {
        [self completeContext:context success:NO error:@"Invalid donate_ram parameters"];
        return;
    }

    xpc_endpoint_t endpoint = nil;
    @try {
        endpoint = [nsEndpoint valueForKey:@"_endpoint"];
    } @catch (NSException *ex) {
        (void)ex;
        [self completeContext:context success:NO error:@"Unable to extract XPC endpoint"];
        return;
    }
    if (!endpoint) {
        [self completeContext:context success:NO error:@"Missing XPC endpoint"];
        return;
    }

    size_t allocSize = (size_t)requestedSize;
    void *buffer = mmap(NULL, allocSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (buffer == MAP_FAILED) {
        [self completeContext:context success:NO error:@"Failed to allocate shared RAM buffer"];
        return;
    }

    xpc_object_t shmem = xpc_shmem_create(buffer, allocSize);
    if (!shmem) {
        munmap(buffer, allocSize);
        [self completeContext:context success:NO error:@"xpc_shmem_create() failed"];
        return;
    }

    dispatch_queue_t queue = dispatch_queue_create("moe.remon.deskfleet.plus.ram-donor.helper", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t conn = xpc_connection_create_from_endpoint(endpoint);
    xpc_connection_set_target_queue(conn, queue);

    __block void *heldBuffer = buffer;
    __block size_t heldSize = allocSize;
    __block xpc_object_t heldShmem = shmem;
    __block xpc_connection_t heldConn = conn;

    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            if (heldBuffer) {
                munmap(heldBuffer, heldSize);
                heldBuffer = NULL;
                heldSize = 0;
            }
            heldShmem = nil;
            if (heldConn) {
                xpc_connection_cancel(heldConn);
                heldConn = nil;
            }
            [context completeRequestReturningItems:@[] completionHandler:nil];
        }
    });
    xpc_connection_resume(conn);

    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(msg, "shmem", shmem);
    xpc_connection_send_message(conn, msg);
#endif
}

- (void)completeContext:(NSExtensionContext *)context success:(BOOL)success error:(NSString *)error {
    NSExtensionItem *result = [[NSExtensionItem alloc] init];
    if (error) {
        result.userInfo = @{@"success": @(success), @"error": error};
    } else {
        result.userInfo = @{@"success": @(success)};
    }
    [context completeRequestReturningItems:@[result] completionHandler:nil];
}

@end
