#import "CLDiagnostics.h"
#import "CLEntityProvider.h"
#import "CLCameraProvider.h"
#import "CLSnapshotBridge.h"
#import "CLEntityTypeRegistry.h"

static NSMutableArray<NSDictionary *> *sRecentErrors;

static NSString *CLArchitectureName(void) {
#if defined(__arm64__)
    return @"arm64";
#elif defined(__x86_64__)
    return @"x86_64";
#elif defined(__arm__)
    return @"arm";
#else
    return @"unknown";
#endif
}

static NSString *CLDiagnosticTimestamp(void) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    return [formatter stringFromDate:[NSDate date]];
}

@implementation CLDiagnostics

+ (void)initialize {
    if (self != CLDiagnostics.class) return;
    sRecentErrors = [NSMutableArray array];
}

+ (void)recordError:(NSString *)message {
    if (message.length == 0) return;
    @synchronized (self) {
        [sRecentErrors addObject:@{
            @"timestamp": CLDiagnosticTimestamp(),
            @"message": [message copy]
        }];
        if (sRecentErrors.count > 32) {
            [sRecentErrors removeObjectsInRange:NSMakeRange(0, sRecentErrors.count - 32)];
        }
    }
}

+ (NSDictionary *)runtimeReport {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    NSArray *errors;
    @synchronized (self) { errors = [sRecentErrors copy]; }
    return @{
        @"schemaVersion": @2,
        @"producer": @"native ClientLoader.CLDiagnostics.runtimeReport",
        @"exportRoute": @"ClientMenu.exportDiagnostics",
        @"captureTimestamp": CLDiagnosticTimestamp(),
        @"minecraft": @{
            @"bundleIdentifier": info[@"CFBundleIdentifier"] ?: @"unknown",
            @"version": info[@"CFBundleShortVersionString"] ?: @"unknown",
            @"build": info[@"CFBundleVersion"] ?: @"unknown",
            @"processArchitecture": CLArchitectureName()
        },
        @"entityProvider": [CLEntityProvider diagnostics],
        @"entityTypeRegistry": [CLEntityTypeRegistry diagnostics],
        @"cameraProvider": [CLCameraProvider diagnostics],
        @"snapshotContract": [CLSnapshotBridge statusReport],
        @"recentErrors": errors ?: @[],
        @"captureStatus": ([CLEntityProvider status] == CLEntityProviderStatusReady &&
                           [CLCameraProvider status] == CLCameraProviderStatusReady)
            ? @"ready" : @"unavailable",
        @"limitations": @[
            @"No live entity data is included unless a verified native adapter publishes snapshots.",
            @"No camera data is included unless a verified camera adapter publishes a matrix.",
            @"Block/chunk data is not captured."
        ]
    };
}

+ (nullable NSString *)writeRuntimeReportToDocumentsFile:(NSString *)fileName
                                                   error:(NSError **)error {
    if (![fileName isKindOfClass:NSString.class] || fileName.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ClientLoader.Diagnostics"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"A JSON filename is required."}];
        }
        return nil;
    }
    NSRegularExpression *pattern = [NSRegularExpression
        regularExpressionWithPattern:@"^[A-Za-z0-9_-]{1,64}\\.json$"
                             options:0
                               error:error];
    if (!pattern) return nil;
    NSTextCheckingResult *match = [pattern firstMatchInString:fileName
                                                      options:0
                                                        range:NSMakeRange(0, fileName.length)];
    if (!match || match.range.length != fileName.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"ClientLoader.Diagnostics"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Invalid JSON export filename."}];
        }
        return nil;
    }

    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    if (!documents) {
        if (error) {
            *error = [NSError errorWithDomain:@"ClientLoader.Diagnostics"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Documents directory is unavailable."}];
        }
        return nil;
    }
    NSURL *directory = [[documents URLByAppendingPathComponent:@"ClientLoader"
                                                   isDirectory:YES]
        URLByAppendingPathComponent:@"exports" isDirectory:YES];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directory
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:error]) {
        if (error && *error) [self recordError:[*error localizedDescription]];
        return nil;
    }
    NSURL *url = [directory URLByAppendingPathComponent:fileName];
    NSMutableDictionary *report = [[self runtimeReport] mutableCopy];
    report[@"export"] = @{@"status": @"success", @"path": url.path};
    NSData *data = [NSJSONSerialization dataWithJSONObject:report
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:error];
    if (!data) {
        if (error && *error) [self recordError:[*error localizedDescription]];
        return nil;
    }
    if (![data writeToURL:url options:NSDataWritingAtomic error:error]) {
        if (error && *error) [self recordError:[*error localizedDescription]];
        return nil;
    }
    NSError *verificationError = nil;
    NSData *writtenData = [NSData dataWithContentsOfURL:url
                                                options:NSDataReadingMappedIfSafe
                                                  error:&verificationError];
    if (!writtenData || ![writtenData isEqualToData:data]) {
        NSError *failure = verificationError ?: [NSError errorWithDomain:@"ClientLoader.Diagnostics"
                                                                      code:4
                                                                  userInfo:@{NSLocalizedDescriptionKey:
                                                                      @"Diagnostic export verification failed."}];
        if (error) *error = failure;
        [self recordError:[failure localizedDescription]];
        return nil;
    }
    return url.path;
}

@end
