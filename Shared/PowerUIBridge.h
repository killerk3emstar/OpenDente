#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface ODNativeChargeClient : NSObject
+ (nullable instancetype)client NS_SWIFT_NAME(makeClient());
- (nullable NSArray<NSNumber *> *)limitsWithError:(NSError **)error;
- (nullable NSDictionary<NSString *, NSNumber *> *)stateWithError:(NSError **)error;
- (BOOL)setLimit:(NSInteger)limit error:(NSError **)error;
- (BOOL)restoreLimit:(NSInteger)limit enabled:(BOOL)enabled error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
