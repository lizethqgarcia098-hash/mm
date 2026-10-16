#import "CLSnapshotBridge.h"
#import "CLSnapshot.h"

@implementation CLSnapshotBridge

+ (NSDictionary *)statusReport {
    CLSnapshot unavailableSnapshot = {
        .schema_version = CL_SNAPSHOT_SCHEMA_VERSION,
        .source = CL_SNAPSHOT_SOURCE_UNKNOWN,
        .data_kind = CL_SNAPSHOT_DATA_UNKNOWN,
        .provider_status = CL_PROVIDER_UNAVAILABLE,
        .status = CL_SNAPSHOT_STATUS_UNAVAILABLE
    };
    CLSnapshotValidation validation =
        CLValidateSnapshot(&unavailableSnapshot, 0, 0, false);

    NSString *validationStatus = @"invalid";
    if (validation.status == CL_SNAPSHOT_VALIDATION_UNAVAILABLE) {
        validationStatus = @"unavailable";
    } else if (validation.status == CL_SNAPSHOT_VALIDATION_PARTIAL) {
        validationStatus = @"partial";
    } else if (validation.status == CL_SNAPSHOT_VALIDATION_VALID) {
        validationStatus = @"valid";
    } else if (validation.status == CL_SNAPSHOT_VALIDATION_STALE) {
        validationStatus = @"stale";
    }

    return @{
        @"schemaVersion": @(CL_SNAPSHOT_SCHEMA_VERSION),
        @"validatorLinked": @YES,
        @"validationStatus": validationStatus,
        @"providerStatus": @"unavailable",
        @"liveDataAvailable": @NO,
        @"entityCount": @0,
        @"limitation": @"No verified Minecraft entity provider is connected."
    };
}

@end
