#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <UIKit/UIKit.h>
#import "providers/CLCameraProvider.h"
#import "providers/CLDiagnostics.h"
#import "providers/CLSnapshotBridge.h"
#import "providers/CLEntityProvider.h"
#import "providers/CLEntityTypeRegistry.h"
#import <CommonCrypto/CommonDigest.h>
#import <dispatch/dispatch.h>
#import "providers/CLESPOverlay.h"
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>

// Live rendering consumes validated snapshots and camera state; the target engine adapter is not yet verified.

@class ClientMenuPanel;

@protocol ClientMenuAPI <JSExport>
JSExportAs(registerAction,
- (void)registerAction:(NSString *)title callback:(JSValue *)callback
);
JSExportAs(registerFeature,
- (void)registerFeature:(NSString *)title enabled:(BOOL)enabled callback:(JSValue *)callback
);
JSExportAs(isFeatureEnabled,
- (BOOL)isFeatureEnabled:(NSString *)title
);
- (void)notify:(NSString *)message;
JSExportAs(exportJSON,
- (NSString *)exportJSON:(NSString *)json fileName:(NSString *)fileName
);
JSExportAs(setSyntheticESPEnabled,
- (void)setSyntheticESPEnabled:(BOOL)enabled
);
JSExportAs(setLiveESPEnabled,
- (void)setLiveESPEnabled:(BOOL)enabled
);
JSExportAs(exportDiagnostics,
- (NSString *)exportDiagnostics:(NSString *)fileName
);
- (NSDictionary *)snapshotContractStatus;
@end

@interface ClientMenuBridge : NSObject <ClientMenuAPI>
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *actions;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *features;
@property(nonatomic, weak) JSContext *context;
@property(nonatomic, weak) UIWindow *window;
- (void)setFeature:(NSString *)title enabled:(BOOL)enabled;
@end

@interface ClientLoaderTarget : NSObject
- (void)runCustomAction:(UIButton *)sender;
- (void)updateLiveESP:(CADisplayLink *)displayLink;
@end

static void ClientLoaderPresentNotification(ClientMenuBridge *bridge,
                                            NSString *message,
                                            NSUInteger attempt);

@interface ClientDraggableButton : UIButton
@property(nonatomic) CGPoint touchStart;
@property(nonatomic) CGPoint initialCenter;
@property(nonatomic) BOOL didMove;
@end

@interface ClientMenuPanel : UIView
- (instancetype)initWithWindow:(UIWindow *)window bridge:(ClientMenuBridge *)bridge;
- (void)reloadContent;
@end

@interface ClientESPSyntheticOverlay : UIView
@end

static NSString *const kClientLoaderHapticsKey = @"ClientLoader.haptics";
static NSString *const kClientLoaderButtonsVisibleKey = @"ClientLoader.customButtonsVisible";
static NSString *const kClientLoaderButtonTitlesKey = @"ClientLoader.customButtonTitles";
static NSString *const kClientLoaderButtonXKey = @"ClientLoader.buttonCenterX";
static NSString *const kClientLoaderButtonYKey = @"ClientLoader.buttonCenterY";
static NSString *const kClientLoaderFeaturePrefix = @"ClientLoader.feature.";
static NSString *const kClientLoaderAccent = @"#A879FF";

static ClientMenuBridge *sBridge;
static JSContext *sContext;
static UIButton *sMenuButton;
static UIStackView *sCustomButtonStack;
static ClientLoaderTarget *sTarget;
static ClientMenuPanel *sMenuPanel;
static ClientESPSyntheticOverlay *sESPSyntheticOverlay;
static BOOL sESPSyntheticOverlayEnabled;
static CLESPOverlay *sLiveESPLayer;
static CADisplayLink *sLiveESPDisplayLink;
static BOOL sLiveESPEnabled;
static BOOL sScriptsLoaded;
static NSUInteger sWindowLookupAttempts;
static dispatch_queue_t sLogQueue;
static NSObject *sLogSequenceLock;
static NSString *sStartupCorrelationID;
static NSUInteger sLogSequence;
static NSString *sEvaluatingScriptName;
static NSUncaughtExceptionHandler *sPreviousUncaughtExceptionHandler;
static const unsigned long long kClientLoaderMaximumLogBytes = 1024 * 1024;
static const unsigned long long kClientLoaderMaximumScriptBytes = 1024 * 1024;

static void ClientMenuOpen(void);
static void ClientMenuRefresh(void);
static void ClientLoaderRenderCustomButtons(void);
static void ClientLoaderSaveMenuButtonPosition(void);
static void ClientLoaderClampButton(UIButton *button, UIWindow *window);
static void ClientLoaderSetESPSyntheticOverlayEnabled(BOOL enabled);
static void ClientLoaderSetLiveESPEnabled(BOOL enabled);

static NSString *ClientLoaderTimestamp(void) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    return [formatter stringFromDate:[NSDate date]];
}

static NSString *ClientLoaderArchitectureName(void) {
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

static void ClientLoaderWriteLogRecord(NSDictionary *record) {
    dispatch_async(sLogQueue, ^{
        NSURL *documentsURL = [[[NSFileManager defaultManager]
            URLsForDirectory:NSDocumentDirectory
                   inDomains:NSUserDomainMask] firstObject];
        if (!documentsURL) {
            NSLog(@"[ClientLoader] ERROR: could not locate Documents directory for log file");
            return;
        }

        NSURL *directoryURL = [documentsURL URLByAppendingPathComponent:@"ClientLoader"
                                                            isDirectory:YES];
        NSError *directoryError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&directoryError]) {
            NSLog(@"[ClientLoader] ERROR: could not create log directory: %@", directoryError);
            return;
        }

        NSURL *logURL = [directoryURL URLByAppendingPathComponent:@"ClientLoader.log"];
        NSURL *rotatedURL = [directoryURL URLByAppendingPathComponent:@"ClientLoader.log.1"];
        NSError *attributesError = nil;
        NSDictionary *attributes = [[NSFileManager defaultManager]
            attributesOfItemAtPath:logURL.path error:&attributesError];
        if (attributesError &&
            [[NSFileManager defaultManager] fileExistsAtPath:logURL.path]) {
            NSLog(@"[ClientLoader] ERROR: could not inspect log file: %@", attributesError);
            return;
        }
        unsigned long long existingSize = [attributes[NSFileSize] unsignedLongLongValue];

        NSError *serializationError = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:record
                                                            options:0
                                                              error:&serializationError];
        if (!json) {
            NSLog(@"[ClientLoader] ERROR: could not serialize log record: %@", serializationError);
            return;
        }
        NSMutableData *line = [json mutableCopy];
        const uint8_t newline = '\n';
        [line appendBytes:&newline length:sizeof(newline)];
        if (line.length > kClientLoaderMaximumLogBytes) {
            NSLog(@"[ClientLoader] ERROR: log record exceeds the maximum size");
            return;
        }

        if (existingSize > 0 && existingSize + line.length > kClientLoaderMaximumLogBytes) {
            NSError *removeError = nil;
            if ([[NSFileManager defaultManager] fileExistsAtPath:rotatedURL.path] &&
                ![[NSFileManager defaultManager] removeItemAtURL:rotatedURL error:&removeError]) {
                NSLog(@"[ClientLoader] ERROR: could not remove rotated log: %@", removeError);
                return;
            }
            NSError *moveError = nil;
            if (![[NSFileManager defaultManager] moveItemAtURL:logURL
                                                             toURL:rotatedURL
                                                             error:&moveError]) {
                NSLog(@"[ClientLoader] ERROR: could not rotate log file: %@", moveError);
                return;
            }
        }

        int descriptor = open(logURL.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (descriptor < 0) {
            NSLog(@"[ClientLoader] ERROR: could not open log file: %s", strerror(errno));
            return;
        }
        const uint8_t *bytes = line.bytes;
        size_t remaining = line.length;
        while (remaining > 0) {
            ssize_t written = write(descriptor, bytes, remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                int writeError = errno;
                close(descriptor);
                NSLog(@"[ClientLoader] ERROR: could not write log file: %s", strerror(writeError));
                return;
            }
            bytes += written;
            remaining -= (size_t)written;
        }
        close(descriptor);
    });
}

static void ClientLoaderLogEvent(NSString *level, NSString *event, NSString *message) {
    NSString *safeMessage = message.length > 2048
        ? [message substringToIndex:2048] : (message ?: @"");
    NSLog(@"[ClientLoader] %@", safeMessage);
    if ([level isEqualToString:@"ERROR"] || [level isEqualToString:@"FATAL"]) {
        [CLDiagnostics recordError:safeMessage];
    }
    if (!sLogQueue) {
        NSLog(@"[ClientLoader] ERROR: structured logger is not initialized");
        return;
    }

    @synchronized (sLogSequenceLock) {
        NSUInteger sequence = ++sLogSequence;
        ClientLoaderWriteLogRecord(@{
            @"timestamp": ClientLoaderTimestamp(),
            @"correlation_id": sStartupCorrelationID ?: @"uninitialized",
            @"event_id": @(sequence),
            @"level": level ?: @"INFO",
            @"event": event ?: @"native_log",
            @"message": safeMessage
        });
    }
}

static void ClientLoaderLog(NSString *message) {
    NSString *level = ([message hasPrefix:@"ERROR:"] || [message hasPrefix:@"FATAL:"])
        ? ([message hasPrefix:@"FATAL:"] ? @"FATAL" : @"ERROR")
        : @"INFO";
    ClientLoaderLogEvent(level, @"native_log", message);
}

static NSString *ClientLoaderSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static BOOL ClientLoaderCallJavaScript(JSValue *callback,
                                       NSArray *arguments,
                                       NSString *event,
                                       NSString *name) {
    if (!callback || callback.isUndefined || callback.isNull || !callback.isObject) {
        ClientLoaderLogEvent(@"ERROR", @"bridge_callback_rejected",
                             [NSString stringWithFormat:@"%@ callback is unavailable", name]);
        return NO;
    }
    sContext.exception = nil;
    [callback callWithArguments:arguments];
    JSValue *exception = sContext.exception;
    if (exception && !exception.isUndefined && !exception.isNull) {
        ClientLoaderLogEvent(@"ERROR", @"bridge_callback_failed",
                             [NSString stringWithFormat:@"%@ callback failed: %@",
                              name, exception.toString]);
        sContext.exception = nil;
        return NO;
    }
    ClientLoaderLogEvent(@"INFO", event,
                         [NSString stringWithFormat:@"%@ callback completed", name]);
    return YES;
}

static void ClientLoaderHandleUncaughtException(NSException *exception) {
    NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
    NSString *message = [NSString stringWithFormat:
        @"FATAL: uncaught Objective-C exception %@: %@\nCall stack:\n%@",
        exception.name, exception.reason ?: @"(no reason)", stack];
    ClientLoaderLog(message);
    if (sPreviousUncaughtExceptionHandler &&
        sPreviousUncaughtExceptionHandler != ClientLoaderHandleUncaughtException) {
        sPreviousUncaughtExceptionHandler(exception);
    }
}

static BOOL ClientLoaderHapticsEnabled(void) {
    id savedValue = [NSUserDefaults.standardUserDefaults objectForKey:kClientLoaderHapticsKey];
    return savedValue ? [savedValue boolValue] : YES;
}

static UIColor *ClientColor(NSString *hex, CGFloat alpha) {
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:
        [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString]];
    [scanner scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:alpha];
}

@implementation ClientMenuBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        _actions = [NSMutableArray array];
        _features = [NSMutableArray array];
    }
    return self;
}

- (void)registerAction:(NSString *)title callback:(JSValue *)callback {
    if (title.length == 0 || !callback || !callback.isObject) {
        ClientLoaderLog(@"ERROR: ignored invalid action registration");
        return;
    }
    NSIndexSet *existing = [self.actions indexesOfObjectsPassingTest:^BOOL(
        NSDictionary *item, __unused NSUInteger idx, __unused BOOL *stop) {
        return [item[@"title"] isEqualToString:title];
    }];
    if (existing.count) [self.actions removeObjectsAtIndexes:existing];
    [self.actions addObject:@{@"title": title, @"callback": callback}];
    ClientLoaderLogEvent(@"INFO", @"bridge_action_registered", title);
    ClientMenuRefresh();
}

- (void)registerFeature:(NSString *)title enabled:(BOOL)enabled callback:(JSValue *)callback {
    if (title.length == 0 || !callback || !callback.isObject) {
        ClientLoaderLog(@"ERROR: ignored invalid feature registration");
        return;
    }
    NSIndexSet *existing = [self.features indexesOfObjectsPassingTest:^BOOL(
        NSDictionary *item, __unused NSUInteger idx, __unused BOOL *stop) {
        return [item[@"title"] isEqualToString:title];
    }];
    if (existing.count) [self.features removeObjectsAtIndexes:existing];

    NSString *key = [kClientLoaderFeaturePrefix stringByAppendingString:title];
    id savedValue = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    BOOL currentValue = savedValue ? [savedValue boolValue] : enabled;
    NSMutableDictionary *record = [@{
        @"title": title,
        @"enabled": @(currentValue),
        @"callback": callback
    } mutableCopy];
    [self.features addObject:record];
    ClientLoaderLogEvent(@"INFO", @"bridge_feature_registered", title);
    ClientLoaderCallJavaScript(callback, @[@(currentValue)],
                               @"bridge_feature_initialized", title);
    ClientMenuRefresh();
}

- (BOOL)isFeatureEnabled:(NSString *)title {
    for (NSDictionary *feature in self.features) {
        if ([feature[@"title"] isEqualToString:title]) {
            return [feature[@"enabled"] boolValue];
        }
    }
    return NO;
}

- (void)setFeature:(NSString *)title enabled:(BOOL)enabled {
    for (NSMutableDictionary *feature in self.features) {
        if (![feature[@"title"] isEqualToString:title]) continue;
        feature[@"enabled"] = @(enabled);
        NSString *key = [kClientLoaderFeaturePrefix stringByAppendingString:title];
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:key];
        JSValue *callback = feature[@"callback"];
        if (callback && !callback.isUndefined) {
            ClientLoaderCallJavaScript(callback, @[@(enabled)],
                                       @"bridge_feature_callback_completed", title);
        }
        return;
    }
}

- (void)notify:(NSString *)message {
    if (![message isKindOfClass:NSString.class] || message.length == 0 ||
        message.length > 2048) {
        ClientLoaderLogEvent(@"ERROR", @"notification_rejected",
                             @"Notification text must contain 1 to 2048 characters");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        ClientLoaderPresentNotification(self, [message copy], 0);
    });
}

- (NSString *)exportJSON:(NSString *)json fileName:(NSString *)fileName {
    if (![json isKindOfClass:NSString.class] ||
        ![fileName isKindOfClass:NSString.class] ||
        json.length == 0 || fileName.length == 0) {
        ClientLoaderLog(@"ERROR: rejected diagnostic export with missing input");
        return nil;
    }
    NSRegularExpression *fileNamePattern = [NSRegularExpression
        regularExpressionWithPattern:@"^[A-Za-z0-9_-]{1,64}\\.json$"
                             options:0
                               error:nil];
    NSTextCheckingResult *match = [fileNamePattern firstMatchInString:fileName
                                                              options:0
                                                                range:NSMakeRange(0, fileName.length)];
    if (!match || match.range.length != fileName.length) {
        ClientLoaderLog(@"ERROR: rejected diagnostic export with an invalid file name");
        return nil;
    }

    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0 || data.length > 1024 * 1024) {
        ClientLoaderLog(@"ERROR: rejected diagnostic export with an invalid size");
        return nil;
    }
    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (!object || jsonError) {
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: rejected invalid diagnostic JSON: %@", jsonError]);
        return nil;
    }
    id schemaValue = [object isKindOfClass:NSDictionary.class] ? object[@"schemaVersion"] : nil;
    NSString *schemaVersion = [schemaValue isKindOfClass:NSNumber.class]
        ? [schemaValue stringValue] : @"unknown";

    NSURL *documentsURL = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory
               inDomains:NSUserDomainMask] firstObject];
    if (!documentsURL) {
        ClientLoaderLog(@"ERROR: could not locate Documents directory for diagnostic export");
        return nil;
    }
    NSURL *directoryURL = [[documentsURL URLByAppendingPathComponent:@"ClientLoader"
                                                        isDirectory:YES]
        URLByAppendingPathComponent:@"exports" isDirectory:YES];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]) {
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: could not create diagnostic export directory: %@", directoryError]);
        return nil;
    }

    NSURL *fileURL = [directoryURL URLByAppendingPathComponent:fileName];
    NSError *writeError = nil;
    if (![data writeToURL:fileURL options:NSDataWritingAtomic error:&writeError]) {
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: could not write diagnostic export: %@", writeError]);
        return nil;
    }
    NSError *verificationError = nil;
    NSData *writtenData = [NSData dataWithContentsOfURL:fileURL
                                                options:NSDataReadingMappedIfSafe
                                                  error:&verificationError];
    if (!writtenData || ![writtenData isEqualToData:data]) {
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: diagnostic export verification failed: %@",
            verificationError.localizedDescription ?: @"written bytes differ from source"]);
        return nil;
    }
    ClientLoaderLog([NSString stringWithFormat:
        @"Exported caller-supplied JSON via ClientMenu.exportJSON (schemaVersion=%@, %lu bytes) to %@",
        schemaVersion, (unsigned long)data.length, fileURL.path]);
    return fileURL.path;
}

- (void)setSyntheticESPEnabled:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        ClientLoaderSetESPSyntheticOverlayEnabled(enabled);
    });
}

- (void)setLiveESPEnabled:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        ClientLoaderSetLiveESPEnabled(enabled);
    });
}

- (NSString *)exportDiagnostics:(NSString *)fileName {
    NSError *error = nil;
    NSString *path = [CLDiagnostics writeRuntimeReportToDocumentsFile:fileName error:&error];
    if (!path) {
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: live ESP diagnostic export failed: %@", error]);
        return nil;
    }
    ClientLoaderLog([NSString stringWithFormat:
        @"Exported native CLDiagnostics runtime report (schemaVersion=2) to %@", path]);
    return path;
}

- (NSDictionary *)snapshotContractStatus {
    NSDictionary *status = [CLSnapshotBridge statusReport];
    ClientLoaderLog([NSString stringWithFormat:
        @"Snapshot contract bridge called (schemaVersion=%@, validationStatus=%@, providerStatus=%@)",
        status[@"schemaVersion"], status[@"validationStatus"], status[@"providerStatus"]]);
    return status;
}

@end

@implementation ClientMenuPanel {
    __weak UIWindow *_hostWindow;
    __weak ClientMenuBridge *_bridge;
    UIView *_card;
    UISegmentedControl *_tabs;
    UIStackView *_rows;
}

- (instancetype)initWithWindow:(UIWindow *)window bridge:(ClientMenuBridge *)bridge {
    self = [super initWithFrame:window.bounds];
    if (!self) return nil;
    _hostWindow = window;
    _bridge = bridge;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.58];

    UIControl *dismissBackdrop = [[UIControl alloc] initWithFrame:self.bounds];
    dismissBackdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dismissBackdrop addTarget:self action:@selector(closePanel)
              forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:dismissBackdrop];

    _card = [UIView new];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.backgroundColor = ClientColor(@"#17151F", 0.98);
    _card.layer.cornerRadius = 22;
    _card.layer.borderWidth = 1;
    _card.layer.borderColor = ClientColor(kClientLoaderAccent, 0.52).CGColor;
    _card.layer.shadowColor = UIColor.blackColor.CGColor;
    _card.layer.shadowOpacity = 0.38;
    _card.layer.shadowRadius = 22;
    _card.layer.shadowOffset = CGSizeMake(0, 10);
    [self addSubview:_card];

    UILabel *title = [UILabel new];
    title.text = @"CLIENT";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:21 weight:UIFontWeightHeavy];
    UILabel *subtitle = [UILabel new];
    subtitle.text = @"BEDROCK  •  LOCAL TOOLS";
    subtitle.textColor = ClientColor(@"#AAA5B8", 1);
    subtitle.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    subtitle.numberOfLines = 1;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"×" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightRegular];
    close.backgroundColor = ClientColor(@"#302B3B", 1);
    close.layer.cornerRadius = 17;
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [close.widthAnchor constraintEqualToConstant:34],
        [close.heightAnchor constraintEqualToConstant:34]
    ]];

    UIStackView *headingText = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    headingText.axis = UILayoutConstraintAxisVertical;
    headingText.spacing = 1;
    UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[headingText, close]];
    heading.axis = UILayoutConstraintAxisHorizontal;
    heading.alignment = UIStackViewAlignmentCenter;
    heading.distribution = UIStackViewDistributionEqualSpacing;
    heading.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:heading];

    _tabs = [[UISegmentedControl alloc] initWithItems:@[@"Features", @"Buttons"]];
    _tabs.selectedSegmentIndex = 0;
    _tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [_tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}
                         forState:UIControlStateSelected];
    [_tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: ClientColor(@"#C7C2D2", 1)}
                         forState:UIControlStateNormal];
    _tabs.selectedSegmentTintColor = ClientColor(kClientLoaderAccent, 1);
    _tabs.backgroundColor = ClientColor(@"#292532", 1);
    [_tabs addTarget:self action:@selector(tabChanged)
    forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_tabs];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [_card addSubview:scroll];
    _rows = [UIStackView new];
    _rows.axis = UILayoutConstraintAxisVertical;
    _rows.spacing = 10;
    _rows.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:_rows];

    UILabel *footer = [UILabel new];
    footer.text = @"PERSONAL UI  •  NO WORLD EXPERIMENTS";
    footer.textColor = ClientColor(@"#8E899A", 1);
    footer.font = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
    footer.textAlignment = NSTextAlignmentCenter;
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:footer];

    UILayoutGuide *safe = self.safeAreaLayoutGuide;
    NSLayoutConstraint *cardWidth =
        [_card.widthAnchor constraintEqualToAnchor:safe.widthAnchor multiplier:0.91];
    cardWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [_card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        cardWidth,
        [_card.widthAnchor constraintLessThanOrEqualToConstant:460],
        [_card.heightAnchor constraintEqualToAnchor:safe.heightAnchor multiplier:0.78],
        [heading.topAnchor constraintEqualToAnchor:_card.topAnchor constant:18],
        [heading.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:19],
        [heading.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-17],
        [_tabs.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:14],
        [_tabs.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:18],
        [_tabs.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-18],
        [_tabs.heightAnchor constraintEqualToConstant:36],
        [scroll.topAnchor constraintEqualToAnchor:_tabs.bottomAnchor constant:13],
        [scroll.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:17],
        [scroll.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-17],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-9],
        [footer.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:12],
        [footer.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-12],
        [footer.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-12],
        [_rows.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [_rows.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [_rows.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [_rows.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [_rows.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];
    [self reloadContent];
    return self;
}

- (void)closePanel {
    [UIView animateWithDuration:0.16 animations:^{ self.alpha = 0; }
                     completion:^(__unused BOOL finished) { [self removeFromSuperview]; }];
}

- (void)tabChanged {
    [self reloadContent];
}

- (UIView *)sectionLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text.uppercaseString;
    label.textColor = ClientColor(kClientLoaderAccent, 1);
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    return label;
}

- (UIView *)noteLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = ClientColor(@"#B8B3C2", 1);
    label.font = [UIFont systemFontOfSize:12];
    label.numberOfLines = 0;
    return label;
}

- (UIView *)rowWithTitle:(NSString *)title detail:(NSString *)detail accessory:(UIView *)accessory {
    UIView *container = [UIView new];
    container.backgroundColor = ClientColor(@"#24212E", 1);
    container.layer.cornerRadius = 13;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *name = [UILabel new];
    name.text = title;
    name.textColor = UIColor.whiteColor;
    name.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    UILabel *description = [UILabel new];
    description.text = detail;
    description.textColor = ClientColor(@"#AAA5B8", 1);
    description.font = [UIFont systemFontOfSize:11];
    description.numberOfLines = 0;
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[name, description]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 3;
    UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:@[labels, accessory]];
    line.axis = UILayoutConstraintAxisHorizontal;
    line.alignment = UIStackViewAlignmentCenter;
    line.spacing = 8;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:line];
    [accessory setContentHuggingPriority:UILayoutPriorityRequired
                                forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [line.topAnchor constraintEqualToAnchor:container.topAnchor constant:11],
        [line.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-11],
        [line.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12],
        [line.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12],
        [container.heightAnchor constraintGreaterThanOrEqualToConstant:56]
    ]];
    return container;
}

- (UISwitch *)switchWithIdentifier:(NSString *)identifier isOn:(BOOL)isOn {
    UISwitch *toggle = [UISwitch new];
    toggle.on = isOn;
    toggle.onTintColor = ClientColor(kClientLoaderAccent, 1);
    toggle.accessibilityIdentifier = identifier;
    [toggle addTarget:self action:@selector(toggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    return toggle;
}

- (void)toggleChanged:(UISwitch *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *identifier = sender.accessibilityIdentifier;
    if ([identifier isEqualToString:@"__haptics"]) {
        [defaults setBool:sender.isOn forKey:kClientLoaderHapticsKey];
    } else if ([identifier isEqualToString:@"__customButtons"]) {
        [defaults setBool:sender.isOn forKey:kClientLoaderButtonsVisibleKey];
        ClientLoaderRenderCustomButtons();
    } else {
        [_bridge setFeature:identifier enabled:sender.isOn];
    }
    if (ClientLoaderHapticsEnabled()) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
}

- (UIButton *)actionButton:(NSString *)title action:(SEL)selector identifier:(NSString *)identifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    button.backgroundColor = ClientColor(kClientLoaderAccent, 0.78);
    button.layer.cornerRadius = 9;
    button.contentEdgeInsets = UIEdgeInsetsMake(7, 11, 7, 11);
    button.accessibilityIdentifier = identifier;
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)addCustomButtonTapped:(UIButton *)sender {
    NSString *title = sender.accessibilityIdentifier;
    if (title.length == 0) return;
    NSMutableArray<NSString *> *titles = [[NSUserDefaults.standardUserDefaults
        arrayForKey:kClientLoaderButtonTitlesKey] mutableCopy] ?: [NSMutableArray array];
    if (![titles containsObject:title]) [titles addObject:title];
    [NSUserDefaults.standardUserDefaults setObject:titles forKey:kClientLoaderButtonTitlesKey];
    ClientLoaderRenderCustomButtons();
    [self reloadContent];
}

- (void)removeCustomButtonTapped:(UIButton *)sender {
    NSString *title = sender.accessibilityIdentifier;
    NSMutableArray<NSString *> *titles = [[NSUserDefaults.standardUserDefaults
        arrayForKey:kClientLoaderButtonTitlesKey] mutableCopy] ?: [NSMutableArray array];
    [titles removeObject:title];
    [NSUserDefaults.standardUserDefaults setObject:titles forKey:kClientLoaderButtonTitlesKey];
    ClientLoaderRenderCustomButtons();
    [self reloadContent];
}

- (void)reloadContent {
    for (UIView *view in _rows.arrangedSubviews) {
        [_rows removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    if (_tabs.selectedSegmentIndex == 0) {
        [_rows addArrangedSubview:[self sectionLabel:@"Overlay"]];
        BOOL buttonsVisible = [NSUserDefaults.standardUserDefaults
            objectForKey:kClientLoaderButtonsVisibleKey]
            ? [NSUserDefaults.standardUserDefaults boolForKey:kClientLoaderButtonsVisibleKey]
            : YES;
        [_rows addArrangedSubview:[self rowWithTitle:@"Custom action buttons"
                                              detail:@"Show your added script actions over the game."
                                           accessory:[self switchWithIdentifier:@"__customButtons"
                                                                          isOn:buttonsVisible]]];
        BOOL haptics = [NSUserDefaults.standardUserDefaults
            objectForKey:kClientLoaderHapticsKey]
            ? [NSUserDefaults.standardUserDefaults boolForKey:kClientLoaderHapticsKey]
            : YES;
        [_rows addArrangedSubview:[self rowWithTitle:@"Haptic feedback"
                                              detail:@"Light vibration when changing a setting."
                                           accessory:[self switchWithIdentifier:@"__haptics"
                                                                          isOn:haptics]]];

        [_rows addArrangedSubview:[self sectionLabel:@"Script features"]];
        if (_bridge.features.count == 0) {
            [_rows addArrangedSubview:[self noteLabel:
                @"No script features registered. Add a feature in a local .js file to expose its toggle here."]];
        }
        for (NSDictionary *feature in _bridge.features) {
            NSString *title = feature[@"title"];
            [_rows addArrangedSubview:[self rowWithTitle:title
                                                  detail:@"Runs the local script callback when changed."
                                               accessory:[self switchWithIdentifier:title
                                                                              isOn:[feature[@"enabled"] boolValue]]]];
        }
    } else {
        [_rows addArrangedSubview:[self sectionLabel:@"Available actions"]];
        [_rows addArrangedSubview:[self noteLabel:
            @"Add an action as a floating on-screen button. Actions come from trusted local scripts."]];
        NSArray<NSString *> *added = [NSUserDefaults.standardUserDefaults
            arrayForKey:kClientLoaderButtonTitlesKey] ?: @[];
        if (_bridge.actions.count == 0) {
            [_rows addArrangedSubview:[self noteLabel:
                @"No script actions registered. Put .js files in Documents/ClientLoader/scripts/."]];
        }
        for (NSDictionary *action in _bridge.actions) {
            NSString *title = action[@"title"];
            BOOL isAdded = [added containsObject:title];
            UIButton *add = [self actionButton:(isAdded ? @"Added" : @"Add")
                                         action:@selector(addCustomButtonTapped:)
                                     identifier:title];
            add.enabled = !isAdded;
            if (isAdded) add.backgroundColor = ClientColor(@"#514B5B", 1);
            [_rows addArrangedSubview:[self rowWithTitle:title
                                                  detail:@"Creates a quick button for this script action."
                                               accessory:add]];
        }

        [_rows addArrangedSubview:[self sectionLabel:@"Your buttons"]];
        if (added.count == 0) {
            [_rows addArrangedSubview:[self noteLabel:@"No custom buttons yet."]];
        }
        for (NSString *title in added) {
            UIButton *remove = [self actionButton:@"Remove"
                                           action:@selector(removeCustomButtonTapped:)
                                       identifier:title];
            remove.backgroundColor = ClientColor(@"#8A435E", 1);
            [_rows addArrangedSubview:[self rowWithTitle:title
                                                  detail:@"Pinned to the game overlay."
                                               accessory:remove]];
        }
    }
}

@end

@implementation ClientESPSyntheticOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.accessibilityLabel = @"Synthetic ESP test boxes, not live entities";
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (width < 160 || height < 240) return;

    NSArray<NSDictionary *> *samples = @[
        @{
            @"label": @"TEST COW  •  NOT LIVE",
            @"x": @(width * 0.16),
            @"y": @(height * 0.31),
            @"w": @(width * 0.25),
            @"h": @(height * 0.23),
            @"color": ClientColor(@"#64D98B", 0.96)
        },
        @{
            @"label": @"TEST PLAYER  •  NOT LIVE",
            @"x": @(width * 0.58),
            @"y": @(height * 0.39),
            @"w": @(width * 0.25),
            @"h": @(height * 0.34),
            @"color": ClientColor(@"#67B7FF", 0.96)
        }
    ];
    NSDictionary *attributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: UIColor.whiteColor
    };
    for (NSDictionary *sample in samples) {
        CGRect box = CGRectMake([sample[@"x"] doubleValue],
                                [sample[@"y"] doubleValue],
                                [sample[@"w"] doubleValue],
                                [sample[@"h"] doubleValue]);
        UIColor *color = sample[@"color"];
        UIBezierPath *path = [UIBezierPath bezierPathWithRect:box];
        path.lineWidth = 2.0;
        [color setStroke];
        [path stroke];

        CGRect labelRect = CGRectMake(box.origin.x,
                                      MAX(8, box.origin.y - 18),
                                      MIN(box.size.width + 100, width - box.origin.x),
                                      16);
        NSString *label = sample[@"label"];
        [label drawInRect:labelRect withAttributes:attributes];
    }
}

@end

static UIWindow *ClientLoaderFindWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static const NSUInteger kClientLoaderNotificationMaximumAttempts = 120;

static void ClientLoaderPresentNotification(ClientMenuBridge *bridge,
                                            NSString *message,
                                            NSUInteger attempt) {
    UIWindow *window = ClientLoaderFindWindow();
    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    if (window && presenter) {
        bridge.window = window;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Client Loader"
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [presenter presentViewController:alert animated:YES completion:^{
            ClientLoaderLogEvent(@"INFO", @"notification_presented", message);
        }];
        return;
    }

    if (attempt + 1 >= kClientLoaderNotificationMaximumAttempts) {
        ClientLoaderLogEvent(@"ERROR",
                             window ? @"notification_failed_no_presenter"
                                    : @"notification_failed_no_window",
                             message);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ClientLoaderPresentNotification(bridge, message, attempt + 1);
    });
}

static void ClientMenuOpen(void) {
    if (!sBridge.window) {
        ClientLoaderLog(@"ERROR: menu open requested before an active window was available");
        return;
    }
    if (sMenuPanel.superview) {
        ClientLoaderLog(@"Closing client panel");
        [sMenuPanel removeFromSuperview];
        sMenuPanel = nil;
        return;
    }
    ClientLoaderLog(@"Opening client panel");
    @try {
        ClientMenuPanel *panel = [[ClientMenuPanel alloc]
            initWithWindow:sBridge.window bridge:sBridge];
        panel.alpha = 0;
        [sBridge.window addSubview:panel];
        [sBridge.window bringSubviewToFront:panel];
        sMenuPanel = panel;
        ClientLoaderLog(@"Opened client panel");
        [UIView animateWithDuration:0.18 animations:^{ panel.alpha = 1; }];
    } @catch (NSException *exception) {
        sMenuPanel = nil;
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: could not open client panel (%@): %@\nCall stack:\n%@",
            exception.name, exception.reason ?: @"(no reason)",
            [exception.callStackSymbols componentsJoinedByString:@"\n"]]);
    }
}

static void ClientMenuRefresh(void) {
    if (sMenuPanel.superview) [sMenuPanel reloadContent];
    ClientLoaderRenderCustomButtons();
}

static void ClientLoaderSetESPSyntheticOverlayEnabled(BOOL enabled) {
    sESPSyntheticOverlayEnabled = enabled;
    UIWindow *window = sBridge.window ?: ClientLoaderFindWindow();
    if (!window) {
        ClientLoaderLog(@"ERROR: cannot update synthetic ESP overlay without an active window");
        return;
    }
    if (!enabled) {
        [sESPSyntheticOverlay removeFromSuperview];
        sESPSyntheticOverlay = nil;
        ClientLoaderLog(@"Synthetic ESP test boxes disabled");
        return;
    }
    if (sESPSyntheticOverlay.superview != window) {
        [sESPSyntheticOverlay removeFromSuperview];
        sESPSyntheticOverlay = [[ClientESPSyntheticOverlay alloc] initWithFrame:window.bounds];
        sESPSyntheticOverlay.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [window addSubview:sESPSyntheticOverlay];
    }
    [window bringSubviewToFront:sESPSyntheticOverlay];
    if (sMenuButton.superview == window) [window bringSubviewToFront:sMenuButton];
    ClientLoaderLog(@"Synthetic ESP test boxes enabled; markers are not live entities");
}

static void ClientLoaderSetLiveESPEnabled(BOOL enabled) {
    sLiveESPEnabled = enabled;
    if (!enabled) {
        [sLiveESPDisplayLink invalidate];
        sLiveESPDisplayLink = nil;
        [sLiveESPLayer removeFromSuperview];
        sLiveESPLayer = nil;
        ClientLoaderLog(@"Live ESP disabled");
        return;
    }

    UIWindow *window = sBridge.window ?: ClientLoaderFindWindow();
    if (!window) {
        ClientLoaderLog(@"ERROR: cannot enable live ESP without an active window");
        return;
    }
    if (!sTarget) sTarget = [ClientLoaderTarget new];
    if (sLiveESPLayer.superview != window) {
        [sLiveESPLayer removeFromSuperview];
        sLiveESPLayer = [[CLESPOverlay alloc] initWithFrame:window.bounds];
        sLiveESPLayer.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [window addSubview:sLiveESPLayer];
    }
    sLiveESPLayer.enabled = YES;
    [window bringSubviewToFront:sLiveESPLayer];
    if (sMenuButton.superview == window) [window bringSubviewToFront:sMenuButton];
    if (!sLiveESPDisplayLink) {
        sLiveESPDisplayLink = [CADisplayLink displayLinkWithTarget:sTarget
                                                          selector:@selector(updateLiveESP:)];
        sLiveESPDisplayLink.preferredFramesPerSecond = 15;
        [sLiveESPDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                                  forMode:NSRunLoopCommonModes];
    }
    ClientLoaderLog([NSString stringWithFormat:
        @"Live ESP enabled; entity provider=%@, camera provider=%@",
        [CLEntityProvider statusDescription], [CLCameraProvider statusDescription]]);
}

static void ClientLoaderSaveMenuButtonPosition(void) {
    UIWindow *window = sBridge.window;
    if (!window || CGRectGetWidth(window.bounds) <= 0 || CGRectGetHeight(window.bounds) <= 0) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:sMenuButton.center.x / CGRectGetWidth(window.bounds)
                 forKey:kClientLoaderButtonXKey];
    [defaults setDouble:sMenuButton.center.y / CGRectGetHeight(window.bounds)
                 forKey:kClientLoaderButtonYKey];
}

static void ClientLoaderClampButton(UIButton *button, UIWindow *window) {
    CGFloat radius = CGRectGetWidth(button.bounds) / 2.0;
    CGFloat minX = radius + 4;
    CGFloat maxX = MAX(minX, CGRectGetWidth(window.bounds) - radius - 4);
    CGFloat minY = radius + window.safeAreaInsets.top + 4;
    CGFloat maxY = MAX(minY, CGRectGetHeight(window.bounds) - radius - window.safeAreaInsets.bottom - 4);
    button.center = CGPointMake(MIN(MAX(button.center.x, minX), maxX),
                                MIN(MAX(button.center.y, minY), maxY));
}

static void ClientLoaderRenderCustomButtons(void) {
    UIWindow *window = sBridge.window;
    if (!window) return;
    [sCustomButtonStack removeFromSuperview];
    sCustomButtonStack = nil;
    BOOL visible = [NSUserDefaults.standardUserDefaults
        objectForKey:kClientLoaderButtonsVisibleKey]
        ? [NSUserDefaults.standardUserDefaults boolForKey:kClientLoaderButtonsVisibleKey]
        : YES;
    if (!visible) return;

    NSArray<NSString *> *titles = [NSUserDefaults.standardUserDefaults
        arrayForKey:kClientLoaderButtonTitlesKey] ?: @[];
    if (titles.count == 0) return;

    sCustomButtonStack = [UIStackView new];
    sCustomButtonStack.axis = UILayoutConstraintAxisVertical;
    sCustomButtonStack.alignment = UIStackViewAlignmentLeading;
    sCustomButtonStack.spacing = 8;
    sCustomButtonStack.translatesAutoresizingMaskIntoConstraints = NO;
    [window addSubview:sCustomButtonStack];
    [NSLayoutConstraint activateConstraints:@[
        [sCustomButtonStack.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:12],
        [sCustomButtonStack.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-92],
        [sCustomButtonStack.widthAnchor constraintLessThanOrEqualToAnchor:window.widthAnchor multiplier:0.58]
    ]];

    for (NSString *title in titles) {
        NSDictionary *action = nil;
        for (NSDictionary *candidate in sBridge.actions) {
            if ([candidate[@"title"] isEqualToString:title]) {
                action = candidate;
                break;
            }
        }
        if (!action) continue;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:title forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        button.backgroundColor = ClientColor(@"#24212E", 0.94);
        button.layer.cornerRadius = 15;
        button.layer.borderWidth = 1;
        button.layer.borderColor = ClientColor(kClientLoaderAccent, 0.84).CGColor;
        button.contentEdgeInsets = UIEdgeInsetsMake(9, 13, 9, 13);
        button.accessibilityIdentifier = title;
        [button addTarget:sTarget action:@selector(runCustomAction:)
         forControlEvents:UIControlEventTouchUpInside];
        [sCustomButtonStack addArrangedSubview:button];
    }
}

@implementation ClientDraggableButton

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *touch = touches.anyObject;
    UIWindow *window = self.window;
    if (!touch || !window) return;
    self.touchStart = [touch locationInView:window];
    self.initialCenter = self.center;
    self.didMove = NO;
    self.alpha = 0.82;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *touch = touches.anyObject;
    UIWindow *window = self.window;
    if (!touch || !window) return;
    CGPoint location = [touch locationInView:window];
    CGFloat dx = location.x - self.touchStart.x;
    CGFloat dy = location.y - self.touchStart.y;
    if (!self.didMove && hypot(dx, dy) < 8.0) return;
    self.didMove = YES;
    self.center = CGPointMake(self.initialCenter.x + dx, self.initialCenter.y + dy);
    ClientLoaderClampButton(self, window);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    self.alpha = 1.0;
    if (self.didMove) {
        ClientLoaderSaveMenuButtonPosition();
    } else {
        ClientMenuOpen();
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    self.alpha = 1.0;
    if (self.didMove) ClientLoaderSaveMenuButtonPosition();
}

@end

static void ClientLoaderInstallButton(UIWindow *window) {
    sBridge.window = window;
    if (sMenuButton && sMenuButton.superview == window) {
        ClientLoaderClampButton(sMenuButton, window);
        ClientLoaderRenderCustomButtons();
        if (sESPSyntheticOverlayEnabled) ClientLoaderSetESPSyntheticOverlayEnabled(YES);
        if (sLiveESPEnabled) ClientLoaderSetLiveESPEnabled(YES);
        return;
    }
    [sMenuButton removeFromSuperview];
    CGFloat side = 54.0;
    sMenuButton = [ClientDraggableButton buttonWithType:UIButtonTypeSystem];
    sMenuButton.bounds = CGRectMake(0, 0, side, side);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    double savedX = [defaults doubleForKey:kClientLoaderButtonXKey];
    double savedY = [defaults doubleForKey:kClientLoaderButtonYKey];
    CGFloat x = savedX > 0 ? savedX * CGRectGetWidth(window.bounds) : CGRectGetWidth(window.bounds) - side / 2.0 - 16.0;
    CGFloat y = savedY > 0 ? savedY * CGRectGetHeight(window.bounds) : CGRectGetHeight(window.bounds) * 0.70;
    sMenuButton.center = CGPointMake(x, y);
    sMenuButton.backgroundColor = ClientColor(kClientLoaderAccent, 0.96);
    sMenuButton.layer.cornerRadius = side / 2.0;
    sMenuButton.layer.borderWidth = 1.5;
    sMenuButton.layer.borderColor = UIColor.whiteColor.CGColor;
    sMenuButton.layer.shadowColor = UIColor.blackColor.CGColor;
    sMenuButton.layer.shadowOpacity = 0.35;
    sMenuButton.layer.shadowRadius = 7;
    sMenuButton.layer.shadowOffset = CGSizeMake(0, 3);
    [sMenuButton setTitle:@"C" forState:UIControlStateNormal];
    [sMenuButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    sMenuButton.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightHeavy];
    sMenuButton.userInteractionEnabled = YES;
    sMenuButton.multipleTouchEnabled = NO;
    sMenuButton.exclusiveTouch = YES;
    sMenuButton.accessibilityLabel = @"Drag or open Client Menu";
    sMenuButton.accessibilityHint = @"Drag to move; tap to open the client panel";
    if (!sTarget) sTarget = [ClientLoaderTarget new];
    [window addSubview:sMenuButton];
    ClientLoaderClampButton(sMenuButton, window);
    ClientLoaderRenderCustomButtons();
    if (sESPSyntheticOverlayEnabled) ClientLoaderSetESPSyntheticOverlayEnabled(YES);
    if (sLiveESPEnabled) ClientLoaderSetLiveESPEnabled(YES);
    ClientLoaderLog([NSString stringWithFormat:
        @"Installed draggable menu button at %@",
        NSStringFromCGPoint(sMenuButton.center)]);
}

@implementation ClientLoaderTarget

- (void)updateLiveESP:(CADisplayLink *)displayLink {
    (void)displayLink;
    if (!sLiveESPEnabled || !sLiveESPLayer) return;
    [sLiveESPLayer updateWithSnapshots:[CLEntityProvider latestSnapshots]];
}

- (void)runCustomAction:(UIButton *)sender {
    NSString *title = sender.accessibilityIdentifier;
    for (NSDictionary *action in sBridge.actions) {
        if (![action[@"title"] isEqualToString:title]) continue;
        JSValue *callback = action[@"callback"];
        ClientLoaderLogEvent(@"INFO", @"menu_action_invoked", title);
        ClientLoaderCallJavaScript(callback, @[], @"menu_action_completed", title);
        if (ClientLoaderHapticsEnabled()) {
            UIImpactFeedbackGenerator *feedback =
                [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [feedback impactOccurred];
        }
        return;
    }
}

@end

static void ClientLoaderLoadScripts(void) {
    if (sScriptsLoaded) return;
    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory
               inDomains:NSUserDomainMask] firstObject];
    if (!documents) {
        ClientLoaderLog(@"ERROR: could not locate Documents directory for scripts");
        return;
    }
    NSURL *scriptDirectory = [[documents URLByAppendingPathComponent:@"ClientLoader"
                                                          isDirectory:YES]
        URLByAppendingPathComponent:@"scripts" isDirectory:YES];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:scriptDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]) {
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: could not create script directory: %@", directoryError]);
        return;
    }

    NSError *listingError = nil;
    NSArray<NSURL *> *items = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:scriptDirectory
       includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                          options:NSDirectoryEnumerationSkipsHiddenFiles
                            error:&listingError];
    if (!items) {
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: could not list scripts: %@", listingError]);
        return;
    }

    sBridge = [ClientMenuBridge new];
    sContext = [JSContext new];
    sBridge.context = sContext;
    sContext[@"ClientMenu"] = sBridge;
    sContext.exceptionHandler = ^(JSContext *context, JSValue *exception) {
        (void)context;
        NSString *scriptName = sEvaluatingScriptName ?: @"(startup)";
        ClientLoaderLogEvent(@"ERROR", @"javascript_exception",
                             [NSString stringWithFormat:@"%@: %@",
                              scriptName, exception.toString]);
    };

    NSArray<NSURL *> *scripts = [[items filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSURL *url, __unused NSDictionary *bindings) {
            NSNumber *isRegularFile = nil;
            [url getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:nil];
            return isRegularFile.boolValue && [url.pathExtension.lowercaseString isEqualToString:@"js"];
        }]] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
        }];
    NSUInteger evaluatedCount = 0;
    NSUInteger failedCount = 0;
    for (NSURL *scriptURL in scripts) {
        NSError *readError = nil;
        NSData *sourceData = [NSData dataWithContentsOfURL:scriptURL
                                                   options:NSDataReadingMappedIfSafe
                                                     error:&readError];
        if (!sourceData) {
            failedCount++;
            ClientLoaderLogEvent(@"ERROR", @"script_read_failed",
                                 [NSString stringWithFormat:@"%@: %@",
                                  scriptURL.lastPathComponent, readError]);
            continue;
        }
        if (sourceData.length > kClientLoaderMaximumScriptBytes) {
            failedCount++;
            ClientLoaderLogEvent(@"ERROR", @"script_rejected_size",
                                 [NSString stringWithFormat:@"%@ is %lu bytes; maximum is %llu",
                                  scriptURL.lastPathComponent,
                                  (unsigned long)sourceData.length,
                                  kClientLoaderMaximumScriptBytes]);
            continue;
        }
        NSString *source = [[NSString alloc] initWithData:sourceData
                                                 encoding:NSUTF8StringEncoding];
        if (!source) {
            failedCount++;
            ClientLoaderLogEvent(@"ERROR", @"script_rejected_encoding",
                                 [NSString stringWithFormat:@"%@ is not valid UTF-8",
                                  scriptURL.lastPathComponent]);
            continue;
        }
        NSString *scriptName = scriptURL.lastPathComponent;
        NSString *scriptHash = ClientLoaderSHA256(sourceData);
        ClientLoaderLogEvent(@"INFO", @"script_discovered",
                             [NSString stringWithFormat:@"%@ sha256=%@ bytes=%lu",
                              scriptName, scriptHash, (unsigned long)sourceData.length]);
        sEvaluatingScriptName = scriptName;
        sContext.exception = nil;
        [sContext evaluateScript:source withSourceURL:scriptURL];
        JSValue *exception = sContext.exception;
        if (exception && !exception.isUndefined && !exception.isNull) {
            failedCount++;
            ClientLoaderLogEvent(@"ERROR", @"script_evaluation_failed",
                                 [NSString stringWithFormat:@"%@: %@",
                                  scriptName, exception.toString]);
        } else {
            evaluatedCount++;
            ClientLoaderLogEvent(@"INFO", @"script_evaluation_succeeded", scriptName);
        }
        sContext.exception = nil;
        sEvaluatingScriptName = nil;
    }
    sScriptsLoaded = YES;
    ClientLoaderLogEvent(@"INFO", @"script_loading_finished",
                         [NSString stringWithFormat:
                          @"discovered=%lu evaluated=%lu failed=%lu directory=%@",
                          (unsigned long)scripts.count,
                          (unsigned long)evaluatedCount,
                          (unsigned long)failedCount,
                          scriptDirectory.path]);
}

static void ClientLoaderStart(void) {
    static dispatch_once_t registryLoadOnce;
    dispatch_once(&registryLoadOnce, ^{
        NSError *error = nil;
        if ([CLEntityTypeRegistry loadRegistryFromDocumentsWithError:&error]) {
            NSDictionary *report = [CLEntityTypeRegistry diagnostics];
            ClientLoaderLog([NSString stringWithFormat:
                @"Loaded %lu entity type definition(s) from registry (%@).",
                (unsigned long)[report[@"loadedIdentifierCount"] unsignedIntegerValue],
                report[@"sourceDirectory"]]);
        } else {
            ClientLoaderLog([NSString stringWithFormat:
                @"ERROR: entity type registry unavailable: %@",
                error.localizedDescription ?: @"unknown registry error"]);
        }
    });
    ClientLoaderLoadScripts();
    UIWindow *window = ClientLoaderFindWindow();
    if (window) {
        sWindowLookupAttempts = 0;
        ClientLoaderInstallButton(window);
        return;
    }
    if (++sWindowLookupAttempts > 120) {
        ClientLoaderLog(@"ERROR: gave up waiting for an active app window");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{ ClientLoaderStart(); });
}

__attribute__((constructor))
static void ClientLoaderInitialize(void) {
    @autoreleasepool {
        sLogQueue = dispatch_queue_create("com.clientloader.diagnostics", DISPATCH_QUEUE_SERIAL);
        sLogSequenceLock = [NSObject new];
        sStartupCorrelationID = NSUUID.UUID.UUIDString;
        sPreviousUncaughtExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&ClientLoaderHandleUncaughtException);
        NSDictionary *bundleInfo = NSBundle.mainBundle.infoDictionary ?: @{};
        ClientLoaderLogEvent(@"INFO", @"loader_initialized",
                             [NSString stringWithFormat:
                              @"Native loader initialized; app=%@ version=%@ build=%@ architecture=%@",
                              bundleInfo[@"CFBundleIdentifier"] ?: @"unknown",
                              bundleInfo[@"CFBundleShortVersionString"] ?: @"unknown",
                              bundleInfo[@"CFBundleVersion"] ?: @"unknown",
                              ClientLoaderArchitectureName()]);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *notification) {
                sWindowLookupAttempts = 0;
                ClientLoaderStart();
            }];
            ClientLoaderStart();
        });
    }
}
