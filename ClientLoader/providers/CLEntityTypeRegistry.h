#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLEntityTypeRegistry : NSObject
+ (BOOL)loadRegistryAtURL:(NSURL *)url error:(NSError **)error;
+ (BOOL)loadRegistryFromDocumentsWithError:(NSError **)error;
+ (nullable NSDictionary *)definitionForIdentifier:(NSString *)identifier;
+ (NSArray<NSString *> *)sourceFilesForIdentifier:(NSString *)identifier;
+ (NSString *)classificationForIdentifier:(NSString *)identifier;
+ (NSDictionary *)diagnostics;
@end

NS_ASSUME_NONNULL_END
