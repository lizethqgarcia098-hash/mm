#import "CLEntityTypeRegistry.h"

static NSDictionary<NSString *, NSDictionary *> *sDefinitionsByIdentifier;
static NSDictionary *sRegistryDiagnostics;
static NSString *sRegistryStatus = @"not_loaded";
static NSString *sRegistryFailureReason = @"Registry has not been loaded.";

static BOOL CLValidDefinition(NSDictionary *definition) {
    return [definition isKindOfClass:NSDictionary.class] &&
        [definition[@"identifier"] isKindOfClass:NSString.class] &&
        [definition[@"sourceFile"] isKindOfClass:NSString.class];
}

@implementation CLEntityTypeRegistry

+ (void)initialize {
    if (self != CLEntityTypeRegistry.class) return;
    sDefinitionsByIdentifier = @{};
    sRegistryDiagnostics = @{};
}

+ (BOOL)loadRegistryAtURL:(NSURL *)url error:(NSError **)error {
    if (error) *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) {
        @synchronized (self) {
            sDefinitionsByIdentifier = @{};
            sRegistryDiagnostics = @{};
            sRegistryStatus = @"unavailable";
            sRegistryFailureReason = error && *error
                ? [*error localizedDescription] : @"Could not read entity registry file.";
        }
        return NO;
    }
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![root isKindOfClass:NSDictionary.class] ||
        ![root[@"schemaVersion"] isEqual:@1] ||
        ![root[@"definitions"] isKindOfClass:NSArray.class]) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"ClientLoader.EntityRegistry"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Registry JSON schema version or definitions array is invalid."}];
        }
        @synchronized (self) {
            sDefinitionsByIdentifier = @{};
            sRegistryDiagnostics = @{};
            sRegistryStatus = @"invalid";
            sRegistryFailureReason = error && *error
                ? [*error localizedDescription] : @"Registry JSON schema is invalid.";
        }
        return NO;
    }

    NSMutableDictionary<NSString *, NSDictionary *> *definitions = [NSMutableDictionary dictionary];
    NSUInteger malformed = 0;
    for (id candidate in root[@"definitions"]) {
        if (!CLValidDefinition(candidate)) {
            malformed++;
            continue;
        }
        NSString *identifier = candidate[@"identifier"];
        if (!definitions[identifier]) definitions[identifier] = candidate;
    }
    if (definitions.count == 0) {
        @synchronized (self) {
            sDefinitionsByIdentifier = @{};
            sRegistryDiagnostics = root;
            sRegistryStatus = @"invalid";
            sRegistryFailureReason = @"Registry contains no valid entity definitions.";
        }
        return NO;
    }

    @synchronized (self) {
        sDefinitionsByIdentifier = [definitions copy];
        sRegistryDiagnostics = root;
        sRegistryStatus = @"ready";
        sRegistryFailureReason = @"";
        if (malformed) {
            sRegistryFailureReason = [NSString stringWithFormat:
                @"Loaded registry with %lu malformed definition record(s).",
                (unsigned long)malformed];
        }
    }
    return YES;
}

+ (BOOL)loadRegistryFromDocumentsWithError:(NSError **)error {
    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    if (!documents) {
        if (error) {
            *error = [NSError errorWithDomain:@"ClientLoader.EntityRegistry"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Documents directory is unavailable."}];
        }
        @synchronized (self) {
            sDefinitionsByIdentifier = @{};
            sRegistryDiagnostics = @{};
            sRegistryStatus = @"unavailable";
            sRegistryFailureReason = @"Documents directory is unavailable.";
        }
        return NO;
    }
    NSURL *url = [[documents URLByAppendingPathComponent:@"ClientLoader"
                                            isDirectory:YES]
        URLByAppendingPathComponent:@"entity_registry.json"];
    return [self loadRegistryAtURL:url error:error];
}

+ (NSDictionary *)definitionForIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) return nil;
    @synchronized (self) { return sDefinitionsByIdentifier[identifier]; }
}

+ (NSArray<NSString *> *)sourceFilesForIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) return @[];
    @synchronized (self) {
        id sources = sRegistryDiagnostics[@"identifierSources"][identifier];
        return [sources isKindOfClass:NSArray.class] ? [sources copy] : @[];
    }
}

+ (NSString *)classificationForIdentifier:(NSString *)identifier {
    NSDictionary *definition = [self definitionForIdentifier:identifier];
    if (!definition) return @"unknown";
    NSArray *families = definition[@"typeFamilies"];
    if (![families isKindOfClass:NSArray.class]) return @"unknown";
    if ([families containsObject:@"player"]) return @"player";
    if ([families containsObject:@"mob"]) return @"mob";
    return @"other";
}

+ (NSDictionary *)diagnostics {
    @synchronized (self) {
        return @{
            @"status": sRegistryStatus ?: @"unavailable",
            @"failureReason": sRegistryFailureReason ?: @"",
            @"definitionsFound": sRegistryDiagnostics[@"definitionsFound"] ?: @0,
            @"parsedSuccessfully": sRegistryDiagnostics[@"parsedSuccessfully"] ?: @0,
            @"definitionsWithIdentifiers": sRegistryDiagnostics[@"definitionsWithIdentifiers"] ?: @0,
            @"definitionsMissingIdentifier": sRegistryDiagnostics[@"definitionsMissingIdentifier"] ?: @0,
            @"malformedFileCount": sRegistryDiagnostics[@"malformedFileCount"] ?: @0,
            @"duplicateIdentifierCount": sRegistryDiagnostics[@"duplicateIdentifierCount"] ?: @0,
            @"duplicateIdentifiers": sRegistryDiagnostics[@"duplicateIdentifiers"] ?: @[],
            @"malformedFiles": sRegistryDiagnostics[@"malformedFiles"] ?: @[],
            @"missingIdentifierFiles": sRegistryDiagnostics[@"missingIdentifierFiles"] ?: @[],
            @"loadedIdentifierCount": @(sDefinitionsByIdentifier.count),
            @"sourceDirectory": sRegistryDiagnostics[@"sourceDirectory"] ?: @""
        };
    }
}

@end
