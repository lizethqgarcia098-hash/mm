#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLDiagnostics : NSObject
+ (NSDictionary *)runtimeReport;
+ (void)recordError:(NSString *)message;
+ (nullable NSString *)writeRuntimeReportToDocumentsFile:(NSString *)fileName
                                                   error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
