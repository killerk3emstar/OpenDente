#import "PowerUIBridge.h"
#import <objc/message.h>
#import <dlfcn.h>

@implementation ODNativeChargeClient {
    id _client;
}

static BOOL fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.opendente.PowerUI" code:1
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"Native charge control failed"}];
    return NO;
}

+ (instancetype)client {
    @try {
        if (!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW)) return nil;
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        for (NSString *name in @[@"initWithClientName:", @"isMCLSupported", @"availableChargeLimitsWithError:",
                 @"getMCLLimitWithError:", @"isMCLCurrentlyEnabled:", @"setMCLLimit:error:", @"disableMCL:"]) {
            if (!class_getInstanceMethod(cls, NSSelectorFromString(name))) return nil;
        }
        id client = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc],
            sel_registerName("initWithClientName:"), @"OpenDente");
        if (!((BOOL (*)(id, SEL))objc_msgSend)(client, sel_registerName("isMCLSupported"))) return nil;
        ODNativeChargeClient *bridge = [self new];
        bridge->_client = client;
        return bridge;
    } @catch (NSException *exception) { return nil; }
}

- (NSArray<NSNumber *> *)limitsWithError:(NSError **)error {
    @try {
        id result = ((id (*)(id, SEL, NSError **))objc_msgSend)(_client,
            sel_registerName("availableChargeLimitsWithError:"), error);
        if (![result isKindOfClass:NSArray.class]) { fail(error, @"Native charge limits unavailable"); return nil; }
        for (id n in result) {
            if (![n isKindOfClass:NSNumber.class] || [n doubleValue] != [n integerValue] ||
                [n integerValue] < 1 || [n integerValue] > 100) {
                fail(error, @"Unrecognized native charge limits"); return nil;
            }
        }
        return result;
    } @catch (NSException *exception) { fail(error, exception.reason); return nil; }
}

- (NSDictionary<NSString *, NSNumber *> *)stateWithError:(NSError **)error {
    @try {
        NSError *failure = nil;
        unsigned char limit = ((unsigned char (*)(id, SEL, NSError **))objc_msgSend)(_client,
            sel_registerName("getMCLLimitWithError:"), &failure);
        if (failure) { if (error) *error = failure; return nil; }
        unsigned long long enabled = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(_client,
            sel_registerName("isMCLCurrentlyEnabled:"), &failure);
        if (failure) { if (error) *error = failure; return nil; }
        if (limit < 1 || limit > 100) { fail(error, @"Invalid native charge state"); return nil; }
        return @{@"limit": @(limit), @"enabled": @(enabled != 0)};
    } @catch (NSException *exception) { fail(error, exception.reason); return nil; }
}

- (BOOL)setLimit:(NSInteger)limit error:(NSError **)error {
    @try {
        NSArray *limits = [self limitsWithError:error];
        if (!limits) return NO;
        if (![limits containsObject:@(limit)]) return fail(error, @"This Mac does not support that native charge limit");
        if (limit == 100) return ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(_client, sel_registerName("disableMCL:"), error);
        return ((BOOL (*)(id, SEL, unsigned char, NSError **))objc_msgSend)(_client,
            sel_registerName("setMCLLimit:error:"), (unsigned char)limit, error);
    } @catch (NSException *exception) { return fail(error, exception.reason); }
}

- (BOOL)restoreLimit:(NSInteger)limit enabled:(BOOL)enabled error:(NSError **)error {
    // Restore the stored target even when the feature was originally disabled.
    if (![self setLimit:limit error:error]) return NO;
    if (!enabled) {
        @try { return ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(_client, sel_registerName("disableMCL:"), error); }
        @catch (NSException *exception) { return fail(error, exception.reason); }
    }
    return YES;
}
@end
