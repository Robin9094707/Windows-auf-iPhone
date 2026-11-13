/* SPDX-License-Identifier: GPL-2.0-or-later */
#import "winios_jithelper.h"
#import <notify.h>
#import <unistd.h>

/* Private Foundation API used to run an app extension on demand (same approach as LiveContainer). */
@interface NSExtension : NSObject
+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))callback;
- (void)cancelExtensionRequestWithIdentifier:(NSUUID *)identifier;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *uuid, NSError *error))callback;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *uuid))callback;
- (void)setRequestCompletionBlock:(void (^)(NSUUID *uuid, NSArray *items))callback;
@property (nonatomic, strong) NSArray *preferredLanguages;
@end

static NSExtension *gExtension;
static NSUUID *gRequest;
static int gNotifyToken = NOTIFY_TOKEN_INVALID;
static BOOL gFinished = YES;
static WinIOSJITHelperCompletion gCompletion;

static NSString *HelperBundleIdentifier(void) {
    /* Read the real identifier from the embedded appex – sideloading tools rewrite it. */
    NSURL *plugins = NSBundle.mainBundle.builtInPlugInsURL;
    if (!plugins) return nil;
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:plugins
                                                          includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL *url in items) {
        if (![url.lastPathComponent hasPrefix:@"JITHelper"]) continue;
        NSBundle *b = [NSBundle bundleWithURL:url];
        if (b.bundleIdentifier) return b.bundleIdentifier;
    }
    return nil;
}

static void Finish(BOOL ok, NSString *message, NSString *log) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFinished) return;
        gFinished = YES;
        if (gNotifyToken != NOTIFY_TOKEN_INVALID) { notify_cancel(gNotifyToken); gNotifyToken = NOTIFY_TOKEN_INVALID; }
        WinIOSJITHelperCompletion c = gCompletion;
        gCompletion = nil;
        gRequest = nil;
        if (c) c(ok, message ?: @"", log ?: @"");
    });
}

@implementation WinIOSJITHelper

+ (BOOL)isAvailable {
    return HelperBundleIdentifier() != nil && NSClassFromString(@"NSExtension") != nil;
}

+ (void)enableJITWithPairing:(NSData *)pairing
                scriptBase64:(NSString *)script
                    progress:(WinIOSJITHelperProgress)progress
                  completion:(WinIOSJITHelperCompletion)completion {
    if (!gFinished) { completion(NO, @"Der JIT-Helfer läuft bereits.", @""); return; }
    NSString *identifier = HelperBundleIdentifier();
    if (!identifier) { completion(NO, @"Der JIT-Helfer fehlt in dieser App-Installation.", @""); return; }

    NSError *error = nil;
    NSExtension *ext = [NSExtension extensionWithIdentifier:identifier error:&error];
    if (!ext || error) {
        completion(NO, [NSString stringWithFormat:@"JIT-Helfer konnte nicht geladen werden: %@",
                        error.localizedDescription ?: @"unbekannt"], @"");
        return;
    }
    gExtension = ext;
    gFinished = NO;
    gCompletion = [completion copy];
    ext.preferredLanguages = @[];

    NSString *notifyName = [NSString stringWithFormat:@"%@.jithelper.progress",
                            NSBundle.mainBundle.bundleIdentifier ?: @"com.windowsaufiphone.app"];
    WinIOSJITHelperProgress prog = [progress copy];
    notify_register_dispatch(notifyName.UTF8String, &gNotifyToken, dispatch_get_main_queue(), ^(int token) {
        uint64_t v = 0;
        notify_get_state(token, &v);
        if (prog) prog((NSInteger)(v / 1000), (double)(v % 1000) / 999.0);
    });

    [ext setRequestCompletionBlock:^(NSUUID *uuid, NSArray *items) {
        NSDictionary *info = [(NSExtensionItem *)items.firstObject userInfo];
        BOOL ok = [info[@"ok"] boolValue];
        Finish(ok, info[@"message"] ?: (ok ? @"JIT aktiviert" : @"Unbekannter Fehler"), info[@"log"]);
    }];
    [ext setRequestCancellationBlock:^(NSUUID *uuid, NSError *err) {
        Finish(NO, [NSString stringWithFormat:@"JIT-Helfer abgebrochen: %@", err.localizedDescription ?: @""], @"");
    }];
    [ext setRequestInterruptionBlock:^(NSUUID *uuid) {
        Finish(NO, @"Der JIT-Helfer wurde vom System beendet.", @"");
    }];

    NSExtensionItem *item = [NSExtensionItem new];
    NSMutableDictionary *info = [@{ @"pid": @(getpid()), @"pairing": pairing, @"force": @YES,
                                    @"notify": notifyName } mutableCopy];
    if (script.length) info[@"script"] = script;
    item.userInfo = info;
    [ext beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *uuid) {
        if (!uuid) { Finish(NO, @"Der JIT-Helfer ließ sich nicht starten.", @""); return; }
        dispatch_async(dispatch_get_main_queue(), ^{ gRequest = uuid; });
    }];
}

+ (void)cancel {
    if (gExtension && gRequest) [gExtension cancelExtensionRequestWithIdentifier:gRequest];
    Finish(NO, @"Abgebrochen", @"");
}

@end
