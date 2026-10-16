#import "CLCameraProvider.h"
#import "CLProjection.h"
#import <math.h>

static NSArray<NSNumber *> *sViewProjectionMatrix;
static NSDictionary<NSString *, NSNumber *> *sCameraPosition;
static NSString *sCameraSource;
static double sClipDepthMinimum;
static double sClipDepthMaximum;
static NSString *sCameraFailureReason =
    @"No verified active Minecraft camera matrix is available to the loader.";

static BOOL CLFiniteCameraNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]);
}

@implementation CLCameraProvider

+ (CLCameraProviderStatus)status {
    @synchronized (self) {
        return sViewProjectionMatrix.count == 16 && sClipDepthMaximum > sClipDepthMinimum
            ? CLCameraProviderStatusReady : CLCameraProviderStatusUnavailable;
    }
}

+ (NSString *)statusDescription {
    @synchronized (self) {
        return sViewProjectionMatrix.count == 16 && sClipDepthMaximum > sClipDepthMinimum
            ? (sCameraSource ?: @"Camera matrix supplied without a source label.")
            : sCameraFailureReason;
    }
}

+ (void)publishColumnMajorViewProjectionMatrix:(NSArray<NSNumber *> *)matrix
                               cameraPosition:(NSDictionary<NSString *,NSNumber *> *)cameraPosition
                            clipDepthMinimum:(double)clipDepthMinimum
                            clipDepthMaximum:(double)clipDepthMaximum
                                       source:(NSString *)source {
    BOOL valid = matrix.count == 16 && source.length > 0 &&
        isfinite(clipDepthMinimum) && isfinite(clipDepthMaximum) &&
        clipDepthMaximum > clipDepthMinimum;
    for (id value in matrix) {
        if (!CLFiniteCameraNumber(value)) {
            valid = NO;
            break;
        }
    }
    for (NSString *key in @[@"x", @"y", @"z"]) {
        id value = cameraPosition[key];
        if (!CLFiniteCameraNumber(value)) valid = NO;
    }
    @synchronized (self) {
        if (!valid) {
            sViewProjectionMatrix = nil;
            sCameraPosition = nil;
            sCameraSource = nil;
            sClipDepthMinimum = 0;
            sClipDepthMaximum = 0;
            sCameraFailureReason = @"Rejected invalid camera matrix/position or missing source.";
            return;
        }
        sViewProjectionMatrix = [matrix copy];
        sCameraPosition = [cameraPosition copy];
        sCameraSource = [source copy];
        sClipDepthMinimum = clipDepthMinimum;
        sClipDepthMaximum = clipDepthMaximum;
        sCameraFailureReason = @"";
    }
}

+ (BOOL)projectBoundsAtPosition:(NSDictionary<NSString *,NSNumber *> *)position
                         bounds:(NSDictionary<NSString *,NSNumber *> *)bounds
                        viewport:(CGRect)viewport
                       resultRect:(CGRect *)resultRect {
    NSArray<NSNumber *> *matrix;
    double clipDepthMinimum;
    double clipDepthMaximum;
    @synchronized (self) {
        matrix = [sViewProjectionMatrix copy];
        clipDepthMinimum = sClipDepthMinimum;
        clipDepthMaximum = sClipDepthMaximum;
    }
    if (!resultRect || matrix.count != 16 ||
        clipDepthMaximum <= clipDepthMinimum || CGRectIsEmpty(viewport)) return NO;

    for (NSString *key in @[@"x", @"y", @"z"]) {
        if (!CLFiniteCameraNumber(position[key])) return NO;
    }
    for (NSString *key in @[@"width", @"height", @"depth"]) {
        if (!CLFiniteCameraNumber(bounds[key])) return NO;
    }
    double values[16];
    double worldPosition[3] = {
        [position[@"x"] doubleValue], [position[@"y"] doubleValue],
        [position[@"z"] doubleValue]
    };
    double dimensions[3] = {
        [bounds[@"width"] doubleValue], [bounds[@"height"] doubleValue],
        [bounds[@"depth"] doubleValue]
    };
    for (NSUInteger i = 0; i < 16; i++) values[i] = [matrix[i] doubleValue];
    CLProjectedRect projected;
    if (!CLProjectAABB(values, worldPosition, dimensions,
                       clipDepthMinimum, clipDepthMaximum,
                       CGRectGetMinX(viewport), CGRectGetMinY(viewport),
                       CGRectGetWidth(viewport), CGRectGetHeight(viewport),
                       &projected)) return NO;
    *resultRect = CGRectMake(projected.x, projected.y, projected.width, projected.height);
    return YES;
}

+ (NSDictionary *)diagnostics {
    @synchronized (self) {
        return @{
            @"status": (sViewProjectionMatrix.count == 16 &&
                        sClipDepthMaximum > sClipDepthMinimum) ? @"ready" : @"unavailable",
            @"failureReason": sCameraFailureReason ?: @"",
            @"source": sCameraSource ?: @"",
            @"projectionConvention": @"column-major matrix; clip w > 0; NDC x/y [-1, 1]",
            @"clipDepthRange": @[@(sClipDepthMinimum), @(sClipDepthMaximum)],
            @"cameraPosition": sCameraPosition ?: @{},
            @"matrix": sViewProjectionMatrix ?: @[]
        };
    }
}

+ (void)clearCachedState {
    @synchronized (self) {
        sViewProjectionMatrix = nil;
        sCameraPosition = nil;
        sCameraSource = nil;
        sClipDepthMinimum = 0;
        sClipDepthMaximum = 0;
        sCameraFailureReason = @"No verified active Minecraft camera matrix is available to the loader.";
    }
}

@end
