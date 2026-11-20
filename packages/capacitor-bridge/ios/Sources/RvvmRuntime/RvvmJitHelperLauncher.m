// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
#import "RvvmJitHelperLauncher.h"
#import <objc/message.h>

static NSString *const kDeskFleetJitHelperSuffix = @".jit-helper";

@implementation RvvmJitHelperLauncher

+ (void)activateJitWithPairingPath:(NSString *)pairingPath
                         targetPid:(pid_t)pid
                       needsScript:(BOOL)needsScript
                        completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion {
#if TARGET_OS_SIMULATOR
    if (completion) {
        completion(YES, nil);
    }
    return;
#else
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleId.length == 0) {
        if (completion) {
            completion(NO, @"Unable to resolve main app bundle identifier");
        }
        return;
    }
    NSString *extId = [bundleId stringByAppendingString:kDeskFleetJitHelperSuffix];

    Class nsExtensionClass = NSClassFromString(@"NSExtension");
    if (!nsExtensionClass) {
        if (completion) {
            completion(NO, @"NSExtension runtime class is unavailable");
        }
        return;
    }

    SEL extSel = NSSelectorFromString(@"extensionWithIdentifier:error:");
    if (![nsExtensionClass respondsToSelector:extSel]) {
        if (completion) {
            completion(NO, @"NSExtension extensionWithIdentifier:error: is unavailable");
        }
        return;
    }

    NSError *lookupError = nil;
    id (*lookupFn)(id, SEL, NSString *, NSError *__autoreleasing *) =
        (id (*)(id, SEL, NSString *, NSError *__autoreleasing *))objc_msgSend;
    id extension = lookupFn(nsExtensionClass, extSel, extId, &lookupError);
    if (!extension) {
        NSString *msg = lookupError.localizedDescription ?: [NSString stringWithFormat:@"JIT helper extension '%@' not found", extId];
        if (completion) {
            completion(NO, msg);
        }
        return;
    }

    __block BOOL finished = NO;
    dispatch_queue_t guardQueue = dispatch_queue_create("moe.remon.deskfleet.plus.jit-helper.guard", DISPATCH_QUEUE_SERIAL);
    void (^finishOnce)(BOOL, NSString *) = ^(BOOL ok, NSString *err) {
        __block BOOL shouldCall = NO;
        dispatch_sync(guardQueue, ^{
            if (!finished) {
                finished = YES;
                shouldCall = YES;
            }
        });
        if (shouldCall && completion) {
            completion(ok, err);
        }
    };

    void (^onComplete)(id<NSCopying>, NSArray *) = ^(id<NSCopying> reqId, NSArray *items) {
        (void)reqId;
        NSExtensionItem *item = items.firstObject;
        NSDictionary *info = item.userInfo;
        BOOL ok = [info[@"success"] boolValue];
        NSString *err = [info[@"error"] isKindOfClass:[NSString class]] ? info[@"error"] : nil;
        finishOnce(ok, ok ? nil : (err ?: @"JIT helper returned without success"));
    };

    void (^onCancel)(id<NSCopying>, NSError *) = ^(id<NSCopying> reqId, NSError *err) {
        (void)reqId;
        finishOnce(NO, err.localizedDescription ?: @"JIT helper extension cancelled");
    };

    void (^onInterrupt)(id<NSCopying>) = ^(id<NSCopying> reqId) {
        (void)reqId;
        finishOnce(NO, @"JIT helper extension process interrupted");
    };

    SEL setCompleteSel = NSSelectorFromString(@"setRequestCompletionBlock:");
    SEL setCancelSel = NSSelectorFromString(@"setRequestCancellationBlock:");
    SEL setInterruptSel = NSSelectorFromString(@"setRequestInterruptionBlock:");
    if ([extension respondsToSelector:setCompleteSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(extension, setCompleteSel, onComplete);
    }
    if ([extension respondsToSelector:setCancelSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(extension, setCancelSel, onCancel);
    }
    if ([extension respondsToSelector:setInterruptSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(extension, setInterruptSel, onInterrupt);
    }

    NSExtensionItem *requestItem = [[NSExtensionItem alloc] init];
    requestItem.userInfo = @{
        @"action": @"enable_jit",
        @"pairingPath": pairingPath,
        @"pid": @(pid),
        @"needsScript": @(needsScript),
    };

    SEL beginSel = NSSelectorFromString(@"beginExtensionRequestWithInputItems:completion:");
    if (![extension respondsToSelector:beginSel]) {
        finishOnce(NO, @"NSExtension beginExtensionRequestWithInputItems:completion: is unavailable");
        return;
    }

    void (^onBegin)(id<NSCopying>, NSError *) = ^(id<NSCopying> reqId, NSError *err) {
        (void)reqId;
        if (err) {
            finishOnce(NO, err.localizedDescription ?: @"Failed to start JIT helper request");
        }
    };
    ((void (*)(id, SEL, NSArray *, id))objc_msgSend)(extension, beginSel, @[requestItem], onBegin);
#endif
}

@end
