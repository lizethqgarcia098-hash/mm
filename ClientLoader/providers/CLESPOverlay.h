#import <UIKit/UIKit.h>
#import "CLEntityProvider.h"

NS_ASSUME_NONNULL_BEGIN

@interface CLESPOverlay : UIView
@property(nonatomic, assign, getter=isEnabled) BOOL enabled;
@property(nonatomic, copy, readonly) NSArray<CLWorldEntitySnapshot *> *snapshots;
- (void)updateWithSnapshots:(NSArray<CLWorldEntitySnapshot *> *)snapshots;
- (void)clearSnapshots;
@end

NS_ASSUME_NONNULL_END
