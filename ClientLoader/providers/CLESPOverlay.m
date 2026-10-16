#import "CLESPOverlay.h"
#import "CLCameraProvider.h"
#import "CLEntityTypeRegistry.h"

@implementation CLESPOverlay {
    NSArray<CLWorldEntitySnapshot *> *_snapshots;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _enabled = NO;
    _snapshots = @[];
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = NO;
    self.opaque = NO;
    self.contentMode = UIViewContentModeRedraw;
    self.accessibilityLabel = @"Live entity overlay";
    return self;
}

- (NSArray<CLWorldEntitySnapshot *> *)snapshots {
    return _snapshots;
}

- (void)setEnabled:(BOOL)enabled {
    if (_enabled == enabled) return;
    _enabled = enabled;
    [self setNeedsDisplay];
}

- (void)updateWithSnapshots:(NSArray<CLWorldEntitySnapshot *> *)snapshots {
    NSMutableArray *valid = [NSMutableArray array];
    for (id snapshot in snapshots) {
        if ([snapshot isKindOfClass:CLWorldEntitySnapshot.class] && [snapshot isValid]) {
            [valid addObject:snapshot];
        }
    }
    _snapshots = [valid copy];
    [self setNeedsDisplay];
}

- (void)clearSnapshots {
    _snapshots = @[];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    if (!self.isEnabled || _snapshots.count == 0) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;
    CGRect viewport = self.bounds;
    NSDictionary *attributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: UIColor.whiteColor
    };

    for (CLWorldEntitySnapshot *snapshot in _snapshots) {
        CGRect box;
        if (![CLCameraProvider projectBoundsAtPosition:snapshot.position
                                               bounds:snapshot.bounds
                                              viewport:viewport
                                             resultRect:&box]) continue;
        NSString *classification =
            [CLEntityTypeRegistry classificationForIdentifier:snapshot.typeIdentifier];
        UIColor *color = [classification isEqualToString:@"player"]
            ? [UIColor colorWithRed:0.35 green:0.69 blue:1 alpha:0.96]
            : ([classification isEqualToString:@"mob"]
                ? [UIColor colorWithRed:0.39 green:0.85 blue:0.55 alpha:0.96]
                : [UIColor colorWithWhite:0.9 alpha:0.96]);
        CGContextSetStrokeColorWithColor(context, color.CGColor);
        CGContextSetLineWidth(context, 2);
        CGContextStrokeRect(context, box);
        NSString *label = [NSString stringWithFormat:@"%@  %@", snapshot.typeIdentifier,
            snapshot.entityId];
        CGRect labelRect = CGRectMake(box.origin.x, MAX(0, box.origin.y - 16),
                                      MIN(CGRectGetWidth(box) + 160,
                                          CGRectGetMaxX(viewport) - box.origin.x), 14);
        [label drawInRect:labelRect withAttributes:attributes];
    }
}

@end
