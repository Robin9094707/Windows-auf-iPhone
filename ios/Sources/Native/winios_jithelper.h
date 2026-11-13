/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Launches the built-in JIT helper extension (separate process, StikJIT). */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WinIOSJITHelperProgress)(NSInteger stage, double fraction);
typedef void (^WinIOSJITHelperCompletion)(BOOL ok, NSString *message, NSString *log);

@interface WinIOSJITHelper : NSObject
/* YES when the helper extension is part of this app bundle. */
@property (class, nonatomic, readonly) BOOL isAvailable;
/* Starts the helper: it attaches to this process over LocalDevVPN and runs the JIT script.
 * Callbacks arrive on the main queue. */
+ (void)enableJITWithPairing:(NSData *)pairing
                scriptBase64:(nullable NSString *)script
                    progress:(WinIOSJITHelperProgress)progress
                  completion:(WinIOSJITHelperCompletion)completion;
+ (void)cancel;
@end

NS_ASSUME_NONNULL_END
