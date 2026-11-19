// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
#ifndef DESKFLEET_RVVM_JIT_HELPER_LAUNCHER_H
#define DESKFLEET_RVVM_JIT_HELPER_LAUNCHER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Launches the embedded DeskFleetJITHelper app extension to activate JIT for the host process.
/// On iOS 26+, the extension remains attached while serving brk #0xf00d JIT allocations and
/// completes once rvvm_ios_jit_detach() is invoked.
@interface RvvmJitHelperLauncher : NSObject

+ (void)activateJitWithPairingPath:(NSString *)pairingPath
                         targetPid:(pid_t)pid
                       needsScript:(BOOL)needsScript
                        completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion;

@end

NS_ASSUME_NONNULL_END

#endif
