#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLWorldEntitySnapshot : NSObject
@property(nonatomic, copy, readonly) NSString *entityId;
@property(nonatomic, copy, readonly) NSString *typeIdentifier;
@property(nonatomic, assign, readonly) BOOL isValid;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *position;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *bounds;
@property(nonatomic, copy, readonly) NSString *source;
@property(nonatomic, copy, readonly) NSString *captureTimestamp;

// position is the entity base center (x/z) and feet height (y); bounds are full dimensions.
- (nullable instancetype)initWithEntityId:(NSString *)entityId
                           typeIdentifier:(NSString *)typeIdentifier
                                 position:(NSDictionary<NSString *, NSNumber *> *)position
                                   bounds:(NSDictionary<NSString *, NSNumber *> *)bounds
                                   source:(NSString *)source
                          captureTimestamp:(NSString *)captureTimestamp
                                  isValid:(BOOL)isValid NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

typedef NS_ENUM(NSInteger, CLEntityProviderStatus) {
    CLEntityProviderStatusUnavailable = 0,
    CLEntityProviderStatusPartial,
    CLEntityProviderStatusReady
};

@interface CLEntityProvider : NSObject
+ (CLEntityProviderStatus)status;
+ (NSString *)statusDescription;
+ (NSArray<CLWorldEntitySnapshot *> *)latestSnapshots;
+ (NSDictionary *)diagnostics;
+ (void)publishSnapshots:(NSArray<CLWorldEntitySnapshot *> *)snapshots
             queryCount:(NSUInteger)queryCount
          rejectedCount:(NSUInteger)rejectedCount
                 status:(CLEntityProviderStatus)status
         failureReason:(nullable NSString *)failureReason;
+ (void)clearCachedSnapshots;
@end

NS_ASSUME_NONNULL_END
