#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CLCameraProviderStatus) {
    CLCameraProviderStatusUnavailable = 0,
    CLCameraProviderStatusReady
};

@interface CLCameraProvider : NSObject
+ (CLCameraProviderStatus)status;
+ (NSString *)statusDescription;
+ (BOOL)projectBoundsAtPosition:(NSDictionary<NSString *, NSNumber *> *)position
                         bounds:(NSDictionary<NSString *, NSNumber *> *)bounds
                        viewport:(CGRect)viewport
                       resultRect:(CGRect *)resultRect;
+ (void)publishColumnMajorViewProjectionMatrix:(NSArray<NSNumber *> *)matrix
                               cameraPosition:(NSDictionary<NSString *, NSNumber *> *)cameraPosition
                            clipDepthMinimum:(double)clipDepthMinimum
                            clipDepthMaximum:(double)clipDepthMaximum
                                       source:(NSString *)source;
+ (NSDictionary *)diagnostics;
+ (void)clearCachedState;
@end

NS_ASSUME_NONNULL_END
