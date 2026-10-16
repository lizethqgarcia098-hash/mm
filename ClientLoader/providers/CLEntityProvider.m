#import "CLEntityProvider.h"
#import <math.h>

static NSArray<CLWorldEntitySnapshot *> *sSnapshots;
static CLEntityProviderStatus sStatus = CLEntityProviderStatusUnavailable;
static NSUInteger sQueryCount;
static NSUInteger sRejectedCount;
static NSString *sFailureReason;
static NSString *sCaptureTimestamp;
static const NSUInteger kMaximumRetainedSnapshots = 256;

static BOOL CLFiniteNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]);
}

static BOOL CLHasVector(NSDictionary *vector, NSArray<NSString *> *keys, BOOL positive) {
    for (NSString *key in keys) {
        id value = vector[key];
        if (!CLFiniteNumber(value) || (positive && [value doubleValue] <= 0)) return NO;
    }
    return YES;
}

static NSString *CLTimestamp(void) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    return [formatter stringFromDate:[NSDate date]];
}

@implementation CLWorldEntitySnapshot

- (nullable instancetype)initWithEntityId:(NSString *)entityId
                           typeIdentifier:(NSString *)typeIdentifier
                                 position:(NSDictionary<NSString *,NSNumber *> *)position
                                   bounds:(NSDictionary<NSString *,NSNumber *> *)bounds
                                   source:(NSString *)source
                          captureTimestamp:(NSString *)captureTimestamp
                                  isValid:(BOOL)isValid {
    if (entityId.length == 0 || typeIdentifier.length == 0 ||
        source.length == 0 || captureTimestamp.length == 0 ||
        !CLHasVector(position, @[@"x", @"y", @"z"], NO) ||
        !CLHasVector(bounds, @[@"width", @"height", @"depth"], YES)) {
        return nil;
    }
    self = [super init];
    if (!self) return nil;
    _entityId = [entityId copy];
    _typeIdentifier = [typeIdentifier copy];
    _position = [position copy];
    _bounds = [bounds copy];
    _source = [source copy];
    _captureTimestamp = [captureTimestamp copy];
    _isValid = isValid;
    return self;
}

@end

@implementation CLEntityProvider

+ (void)initialize {
    if (self != CLEntityProvider.class) return;
    sSnapshots = @[];
    sFailureReason = @"No verified native adapter connects this process to the live Minecraft entity registry.";
    sCaptureTimestamp = CLTimestamp();
}

+ (CLEntityProviderStatus)status {
    @synchronized (self) { return sStatus; }
}

+ (NSString *)statusDescription {
    @synchronized (self) { return sFailureReason ?: @"No live entity query has been published."; }
}

+ (NSArray<CLWorldEntitySnapshot *> *)latestSnapshots {
    @synchronized (self) { return [sSnapshots copy]; }
}

+ (NSDictionary *)diagnostics {
    @synchronized (self) {
        NSMutableArray *entities = [NSMutableArray arrayWithCapacity:MIN(sSnapshots.count, 32)];
        NSUInteger count = MIN(sSnapshots.count, 32);
        for (NSUInteger index = 0; index < count; index++) {
            CLWorldEntitySnapshot *snapshot = sSnapshots[index];
            [entities addObject:@{
                @"entityId": snapshot.entityId,
                @"typeIdentifier": snapshot.typeIdentifier,
                @"position": snapshot.position,
                @"bounds": snapshot.bounds,
                @"source": snapshot.source,
                @"captureTimestamp": snapshot.captureTimestamp,
                @"isValid": @(snapshot.isValid)
            }];
        }
        return @{
            @"status": sStatus == CLEntityProviderStatusReady ? @"ready" :
                (sStatus == CLEntityProviderStatusPartial ? @"partial" : @"unavailable"),
            @"failureReason": sFailureReason ?: @"",
            @"queryCount": @(sQueryCount),
            @"successfulCaptures": @(sSnapshots.count),
            @"rejectedRecords": @(sRejectedCount),
            @"captureTimestamp": sCaptureTimestamp ?: @"",
            @"sampleLimit": @32,
            @"entities": entities
        };
    }
}

+ (void)publishSnapshots:(NSArray<CLWorldEntitySnapshot *> *)snapshots
             queryCount:(NSUInteger)queryCount
          rejectedCount:(NSUInteger)rejectedCount
                 status:(CLEntityProviderStatus)status
         failureReason:(NSString *)failureReason {
    NSMutableArray *validSnapshots = [NSMutableArray array];
    NSUInteger rejected = rejectedCount;
    for (id snapshot in snapshots) {
        if (![snapshot isKindOfClass:CLWorldEntitySnapshot.class] || ![snapshot isValid]) {
            rejected++;
            continue;
        }
        if (validSnapshots.count >= kMaximumRetainedSnapshots) {
            rejected++;
            continue;
        }
        [validSnapshots addObject:snapshot];
    }
    @synchronized (self) {
        sSnapshots = [validSnapshots copy];
        sQueryCount = queryCount;
        sRejectedCount = rejected;
        sStatus = status;
        sFailureReason = [failureReason copy] ?: @"";
        sCaptureTimestamp = CLTimestamp();
    }
}

+ (void)clearCachedSnapshots {
    @synchronized (self) {
        sSnapshots = @[];
        sQueryCount = 0;
        sRejectedCount = 0;
        sStatus = CLEntityProviderStatusUnavailable;
        sFailureReason = @"Entity snapshot cache was cleared; no live query has been published.";
        sCaptureTimestamp = CLTimestamp();
    }
}

@end
