/* SPDX-License-Identifier: GPL-2.0-or-later */
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WinIOSStateCallback)(void);

@interface WinIOSBridge : NSObject

@property (class, nonatomic, readonly) WinIOSBridge *shared;

@property (nonatomic, readonly) BOOL isJITLive;
@property (nonatomic, readonly) BOOL isDebuggerAttached;
@property (nonatomic, readonly) BOOL isVMRunning;
@property (nonatomic, readonly) BOOL isUnpacking;
@property (nonatomic, readonly) double unpackProgress;
@property (nonatomic, readonly) NSString *jitStatusText;
@property (nonatomic, readonly) NSString *vmStatusText;
@property (nonatomic, readonly) uint32_t framebufferWidth;
@property (nonatomic, readonly) uint32_t framebufferHeight;
@property (nonatomic, readonly) uint64_t presentedFrames;
@property (nonatomic, readonly) uint64_t availableMemoryMB;
@property (nonatomic, readonly) BOOL usbKeyboardReady;
@property (nonatomic, readonly) BOOL usbTabletReady;
@property (nonatomic, readonly) uint64_t usbEventsDelivered;
@property (nonatomic, assign) BOOL useSafariForGuestLinks;

/* User configuration (applied on next VM start) */
@property (nonatomic, assign) int configuredCPUCount;          /* 1..8, default 4 */
@property (nonatomic, assign) uint64_t requestedRamMB;         /* 0 = automatic */
@property (nonatomic, copy, nullable) NSString *installerImagePath; /* optional read-only 2nd NVMe disk (ISO) */
@property (nonatomic, copy, nullable) NSString *firmwarePath;
@property (nonatomic, copy, nullable) NSString *driverImagePath;  /* optional read-only 3rd NVMe disk (driver ISO) */  /* UEFI code.fd (bundle fallback) */
@property (nonatomic, assign) BOOL networkEnabled;
@property (nonatomic, assign) BOOL soundEnabled;
@property (nonatomic, readonly) NSString *machineDirectoryPath;
@property (nonatomic, readonly) uint64_t runningRamMB;
@property (nonatomic, readonly) int runningCPUCount;
@property (nonatomic, readonly) double uptimeSeconds;
@property (nonatomic, copy, nullable) WinIOSStateCallback onStateChanged;

- (nullable NSString *)takeGuestOpenURL;

/* Clipboard bridge (needs the helper script running in Windows + network) */
- (void)setHostClipboardForGuest:(NSString *)text;
- (nullable NSString *)takeGuestClipboard;
/* Seconds since the Windows clipboard helper was last heard from, or -1. */
- (long)clipboardAgentSeenSeconds;
- (BOOL)takeGuestOAuthDone;

- (void)installTrapGuard;
- (BOOL)tryAcquireJIT:(BOOL)detachAfter;

- (BOOL)hasProvisionedMachine;
- (BOOL)needsSparseUnpack;
- (void)prepareAndStartWithLayer:(nullable CAMetalLayer *)layer;
- (void)bindMetalLayer:(nullable CAMetalLayer *)layer;

- (void)updateScreenSize:(CGSize)size scale:(CGFloat)scale;
- (void)updateHingeStatus:(NSInteger)status angleDegrees:(double)angleDegrees;

- (void)sendTabletNormalizedX:(double)x y:(double)y buttons:(uint8_t)buttons wheel:(int8_t)wheel;
- (void)sendKeyHid:(uint8_t)usage down:(BOOL)down;
- (void)tapKeyHid:(uint8_t)usage;
- (void)sendKeyComboWithModifiers:(NSArray<NSNumber *> *)modifiers key:(uint8_t)usage;
- (void)sendWindowsKey;
- (void)sendCtrlAltDel;
- (void)sendAltTab;
- (void)sendEscape;
- (void)pressPowerButton;
- (void)flushDisks;
- (void)stopVM;

@end

NS_ASSUME_NONNULL_END
