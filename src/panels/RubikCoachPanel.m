#import "RubikCoachPanel.h"
#import "../AppDelegate.h"
#import "../PythonBridge.h"
#import <WebKit/WebKit.h>

static NSString * const kRubikCoachSelectedProfileKey = @"RubikCoachSelectedProfile";

static NSColor *RubikCoachHostColor(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

static NSInteger ReachyRubikCoachPort(void) {
    NSString *raw = [[[NSProcessInfo processInfo] environment][@"REACHY_RUBIK_COACH_PORT"]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSInteger port = raw.integerValue;
    return port > 0 ? port : 7861;
}

@interface RubikCoachPanel () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSView *overlayView;
@property (nonatomic, strong) NSView *overlayCard;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSButton *retryButton;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) NSInteger pollAttemptCount;
@property (nonatomic, assign) BOOL probeInFlight;
@property (nonatomic, assign) BOOL hasIssuedLoadRequest;
@property (nonatomic, assign) BOOL coachRunning;

@property (nonatomic, strong) NSView *controlBar;
@property (nonatomic, strong) NSTextField *headerTitleLabel;
@property (nonatomic, strong) NSTextField *headerDetailLabel;
@property (nonatomic, strong) NSTextField *statusChip;
@property (nonatomic, strong) NSTextField *profileLabel;
@property (nonatomic, strong) NSPopUpButton *profilePopupButton;
@property (nonatomic, strong) NSButton *startButton;
@property (nonatomic, strong) NSButton *stopButton;
@end

@implementation RubikCoachPanel

- (void)dealloc {
    [self.pollTimer invalidate];
    [[[AppDelegate shared] pythonBridge] callFunction:@"stop_rubik_coach" withArgs:nil];
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1160, 760)];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = RubikCoachHostColor(5, 10, 18, 1).CGColor;
    [self buildUI];
    [self populateProfiles];
    [self presentStoppedState];
    [self startCoachBootSequence];
}

- (void)buildUI {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    config.defaultWebpagePreferences.allowsContentJavaScript = YES;

    self.webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.hidden = YES;
    [self.view addSubview:self.webView];

    self.overlayView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.overlayView.wantsLayer = YES;
    self.overlayView.layer.backgroundColor = RubikCoachHostColor(5, 10, 18, 0.94).CGColor;
    [self.view addSubview:self.overlayView];

    self.overlayCard = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 244)];
    self.overlayCard.wantsLayer = YES;
    self.overlayCard.layer.cornerRadius = 24.0;
    self.overlayCard.layer.borderWidth = 1.0;
    self.overlayCard.layer.borderColor = RubikCoachHostColor(255, 255, 255, 0.08).CGColor;
    self.overlayCard.layer.backgroundColor = RubikCoachHostColor(15, 20, 32, 0.94).CGColor;
    [self.overlayView addSubview:self.overlayCard];

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(44, 44, 32, 32)];
    self.spinner.style = NSProgressIndicatorSpinningStyle;
    self.spinner.displayedWhenStopped = NO;
    [self.overlayCard addSubview:self.spinner];

    NSTextField *eyebrow = [NSTextField labelWithString:@"CONVERSATION APP"];
    eyebrow.frame = NSMakeRect(44, 36, 180, 18);
    eyebrow.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightSemibold];
    eyebrow.textColor = RubikCoachHostColor(98, 195, 255, 0.96);
    [self.overlayCard addSubview:eyebrow];

    self.titleLabel = [NSTextField labelWithString:@"Coach stopped"];
    self.titleLabel.frame = NSMakeRect(44, 70, 460, 32);
    self.titleLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];
    self.titleLabel.textColor = [NSColor whiteColor];
    [self.overlayCard addSubview:self.titleLabel];

    self.detailLabel = [NSTextField labelWithString:@"Use Start to launch the local OpenAI Live coach."];
    self.detailLabel.frame = NSMakeRect(44, 108, 470, 62);
    self.detailLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightRegular];
    self.detailLabel.textColor = RubikCoachHostColor(202, 211, 223, 0.82);
    self.detailLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.detailLabel.maximumNumberOfLines = 4;
    [self.overlayCard addSubview:self.detailLabel];

    self.retryButton = [NSButton buttonWithTitle:@"Retry"
                                          target:self
                                          action:@selector(startButtonClicked:)];
    self.retryButton.frame = NSMakeRect(44, 190, 110, 32);
    self.retryButton.bezelStyle = NSBezelStyleRounded;
    self.retryButton.hidden = YES;
    [self.overlayCard addSubview:self.retryButton];

    self.controlBar = [[NSView alloc] initWithFrame:NSZeroRect];
    self.controlBar.wantsLayer = YES;
    self.controlBar.layer.cornerRadius = 18.0;
    self.controlBar.layer.borderWidth = 1.0;
    self.controlBar.layer.borderColor = RubikCoachHostColor(255, 255, 255, 0.08).CGColor;
    self.controlBar.layer.backgroundColor = RubikCoachHostColor(12, 18, 28, 0.94).CGColor;
    [self.view addSubview:self.controlBar];

    self.headerTitleLabel = [NSTextField labelWithString:@"Conversation App"];
    self.headerTitleLabel.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    self.headerTitleLabel.textColor = [NSColor whiteColor];
    [self.controlBar addSubview:self.headerTitleLabel];

    self.headerDetailLabel = [NSTextField labelWithString:@"Embedded OpenAI Live session with built-in profile switching."];
    self.headerDetailLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    self.headerDetailLabel.textColor = RubikCoachHostColor(202, 211, 223, 0.76);
    [self.controlBar addSubview:self.headerDetailLabel];

    self.statusChip = [NSTextField labelWithString:@"Stopped"];
    self.statusChip.alignment = NSTextAlignmentCenter;
    self.statusChip.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    self.statusChip.textColor = RubikCoachHostColor(225, 232, 240, 0.96);
    self.statusChip.wantsLayer = YES;
    self.statusChip.layer.cornerRadius = 11.0;
    self.statusChip.layer.masksToBounds = YES;
    [self.controlBar addSubview:self.statusChip];

    self.profileLabel = [NSTextField labelWithString:@"Personality"];
    self.profileLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    self.profileLabel.textColor = RubikCoachHostColor(202, 211, 223, 0.82);
    [self.controlBar addSubview:self.profileLabel];

    self.profilePopupButton = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.profilePopupButton.target = self;
    self.profilePopupButton.action = @selector(profileChanged:);
    [self.controlBar addSubview:self.profilePopupButton];

    self.startButton = [NSButton buttonWithTitle:@"Start"
                                          target:self
                                          action:@selector(startButtonClicked:)];
    self.startButton.bezelStyle = NSBezelStyleRounded;
    [self.controlBar addSubview:self.startButton];

    self.stopButton = [NSButton buttonWithTitle:@"Stop"
                                         target:self
                                         action:@selector(stopButtonClicked:)];
    self.stopButton.bezelStyle = NSBezelStyleRounded;
    [self.controlBar addSubview:self.stopButton];
}

- (void)viewDidLayout {
    [super viewDidLayout];

    NSRect bounds = self.view.bounds;
    CGFloat outerPadding = 24.0;
    CGFloat topPadding = 18.0;
    CGFloat controlHeight = 78.0;
    self.controlBar.frame = NSMakeRect(outerPadding,
                                       NSHeight(bounds) - controlHeight - topPadding,
                                       NSWidth(bounds) - outerPadding * 2.0,
                                       controlHeight);

    NSRect contentFrame = NSMakeRect(0,
                                     0,
                                     NSWidth(bounds),
                                     NSMinY(self.controlBar.frame) - outerPadding);
    self.webView.frame = contentFrame;
    self.overlayView.frame = contentFrame;

    CGFloat cardWidth = 560.0;
    CGFloat cardHeight = 244.0;
    self.overlayCard.frame = NSMakeRect((NSWidth(contentFrame) - cardWidth) / 2.0,
                                        (NSHeight(contentFrame) - cardHeight) / 2.0,
                                        cardWidth,
                                        cardHeight);

    NSRect bar = self.controlBar.bounds;
    self.headerTitleLabel.frame = NSMakeRect(20, 42, 220, 22);
    self.headerDetailLabel.frame = NSMakeRect(20, 18, 320, 16);
    self.statusChip.frame = NSMakeRect(248, 40, 82, 24);

    CGFloat rightX = NSWidth(bar) - 20.0;
    self.stopButton.frame = NSMakeRect(rightX - 82.0, 24, 82, 30);
    rightX -= 92.0;
    self.startButton.frame = NSMakeRect(rightX - 96.0, 24, 96, 30);
    rightX -= 116.0;
    self.profilePopupButton.frame = NSMakeRect(rightX - 230.0, 22, 230, 32);
    self.profileLabel.frame = NSMakeRect(NSMinX(self.profilePopupButton.frame), 52, 90, 16);
}

- (NSArray<NSString *> *)availableProfiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appRoot = [[[NSProcessInfo processInfo] environment][@"REACHY_RUBIK_COACH_APP"]
        stringByStandardizingPath];
    if (!appRoot.length) return @[@"rubiks_cube_coach"];

    NSString *profilesDir = [appRoot stringByAppendingPathComponent:@"src/reachy_mini_rubik_coach_app/profiles"];
    NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:profilesDir error:nil] ?: @[];
    NSMutableArray<NSString *> *profiles = [NSMutableArray array];
    for (NSString *name in contents) {
        if ([name hasPrefix:@"."] || [name isEqualToString:@"__pycache__"] || [name isEqualToString:@"example"]) continue;
        BOOL isDir = NO;
        NSString *path = [profilesDir stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
            [profiles addObject:name];
        }
    }
    [profiles sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    if (![profiles containsObject:@"rubiks_cube_coach"]) {
        [profiles insertObject:@"rubiks_cube_coach" atIndex:0];
    }
    return profiles;
}

- (void)populateProfiles {
    NSArray<NSString *> *profiles = [self availableProfiles];
    [self.profilePopupButton removeAllItems];
    [self.profilePopupButton addItemsWithTitles:profiles];

    NSString *savedProfile = [[NSUserDefaults standardUserDefaults] stringForKey:kRubikCoachSelectedProfileKey];
    NSString *fallback = [profiles containsObject:@"rubiks_cube_coach"] ? @"rubiks_cube_coach" : profiles.firstObject;
    NSString *selected = ([profiles containsObject:savedProfile] ? savedProfile : fallback);
    if (selected.length) {
        [self.profilePopupButton selectItemWithTitle:selected];
    }
}

- (NSString *)selectedProfileName {
    return self.profilePopupButton.selectedItem.title ?: @"rubiks_cube_coach";
}

- (NSDictionary *)coachConfig {
    NSString *profile = [self selectedProfileName];
    return @{
        @"profile": profile ?: @"rubiks_cube_coach",
        @"unlocked": @YES,
    };
}

- (void)persistSelectedProfile {
    NSString *profile = [self selectedProfileName];
    if (profile.length) {
        [[NSUserDefaults standardUserDefaults] setObject:profile forKey:kRubikCoachSelectedProfileKey];
    }
}

- (NSString *)coachURLString {
    return [NSString stringWithFormat:@"http://127.0.0.1:%ld/", (long)ReachyRubikCoachPort()];
}

- (void)updateStatusText:(NSString *)text color:(NSColor *)color {
    self.statusChip.stringValue = text ?: @"";
    self.statusChip.layer.backgroundColor = color.CGColor;
}

- (void)syncButtonState {
    self.startButton.title = self.coachRunning ? @"Restart" : @"Start";
    self.stopButton.enabled = self.coachRunning || self.probeInFlight || self.hasIssuedLoadRequest;
}

- (void)startButtonClicked:(id)sender {
    if (self.coachRunning || self.probeInFlight || self.hasIssuedLoadRequest) {
        [self stopCoachClicked:nil];
    }
    [self startCoachBootSequence];
}

- (void)stopCoachClicked:(id)sender {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.probeInFlight = NO;
    self.hasIssuedLoadRequest = NO;
    self.coachRunning = NO;
    [self.webView stopLoading];
    self.webView.hidden = YES;
    [[[AppDelegate shared] pythonBridge] callFunction:@"stop_rubik_coach" withArgs:nil];
    [self presentStoppedState];
}

- (void)profileChanged:(id)sender {
    [self persistSelectedProfile];
    if (self.coachRunning || self.probeInFlight || self.hasIssuedLoadRequest) {
        [self startButtonClicked:nil];
    }
}

- (void)startCoachBootSequence {
    [self persistSelectedProfile];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.pollAttemptCount = 0;
    self.probeInFlight = NO;
    self.hasIssuedLoadRequest = NO;
    self.coachRunning = NO;
    self.retryButton.hidden = YES;
    self.webView.hidden = YES;
    [self.spinner startAnimation:nil];
    [self setOverlayTitle:@"Starting conversation app"
                   detail:[NSString stringWithFormat:@"Launching the %@ personality with OpenAI Live and built-in profile controls.",
                       [self selectedProfileName]]];
    self.overlayView.hidden = NO;
    [self updateStatusText:@"Starting" color:RubikCoachHostColor(217, 149, 61, 0.92)];
    [self syncButtonState];

    PythonBridge *bridge = [AppDelegate shared].pythonBridge;
    if (!bridge) {
        [self presentFailureWithTitle:@"Python bridge unavailable"
                               detail:@"The embedded Python runtime did not initialize, so the conversation app cannot start."];
        return;
    }

    NSString *result = [bridge callFunction:@"start_rubik_coach" withArgs:[self coachConfig]];
    if ([result hasPrefix:@"error:"]) {
        [self presentFailureWithTitle:@"Conversation app failed to start" detail:result];
        return;
    }

    [self beginPollingCoach];
}

- (void)beginPollingCoach {
    [self pollCoachAvailability];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                      target:self
                                                    selector:@selector(pollCoachAvailability)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (NSString *)rubikCoachFailureDetail {
    NSString *statusJSON = [[[AppDelegate shared] pythonBridge] callFunction:@"rubik_coach_status" withArgs:nil];
    if (!statusJSON.length) return @"The local coach endpoint never responded.";

    NSData *data = [statusJSON dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *status = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *lastError = [status[@"last_error"] isKindOfClass:[NSString class]] ? status[@"last_error"] : nil;
    NSString *state = [status[@"state"] isKindOfClass:[NSString class]] ? status[@"state"] : nil;
    if (lastError.length) return lastError;
    if (state.length) {
        return [NSString stringWithFormat:@"Conversation app status: %@.", state];
    }
    return @"The local coach endpoint never responded.";
}

- (void)pollCoachAvailability {
    if (self.probeInFlight || self.hasIssuedLoadRequest) return;
    self.probeInFlight = YES;

    NSURL *url = [NSURL URLWithString:[self coachURLString]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:2.5];
    request.HTTPMethod = @"GET";

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.probeInFlight = NO;
            if (self.hasIssuedLoadRequest) return;

            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            BOOL ok = (!error && http.statusCode >= 200 && http.statusCode < 400 && data.length > 0);
            if (ok) {
                self.hasIssuedLoadRequest = YES;
                [self.pollTimer invalidate];
                self.pollTimer = nil;
                [self setOverlayTitle:@"Loading conversation interface"
                               detail:@"The local OpenAI Live server is ready. Rendering the embedded app now."];
                [self.webView loadRequest:[NSURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:30.0]];
                return;
            }

            self.pollAttemptCount += 1;
            if (self.pollAttemptCount >= 40) {
                NSString *reason = error.localizedDescription ?: [self rubikCoachFailureDetail];
                [self presentFailureWithTitle:@"Conversation app timed out" detail:reason];
                return;
            }

            if (self.pollAttemptCount == 8) {
                [self setOverlayTitle:@"Connecting to conversation app"
                               detail:@"The embedded app is still starting. This can take a few seconds while the robot session and camera worker initialize."];
            }
        });
    }] resume];
}

- (void)setOverlayTitle:(NSString *)title detail:(NSString *)detail {
    self.titleLabel.stringValue = title ?: @"";
    self.detailLabel.stringValue = detail ?: @"";
}

- (void)presentStoppedState {
    [self.spinner stopAnimation:nil];
    self.retryButton.hidden = YES;
    self.overlayView.hidden = NO;
    [self setOverlayTitle:@"Conversation app stopped"
                   detail:@"Use Start to relaunch it, or switch personalities above and start a different behavior."];
    [self updateStatusText:@"Stopped" color:RubikCoachHostColor(73, 84, 99, 0.92)];
    [self syncButtonState];
}

- (void)presentFailureWithTitle:(NSString *)title detail:(NSString *)detail {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.hasIssuedLoadRequest = NO;
    self.probeInFlight = NO;
    self.coachRunning = NO;
    [self.spinner stopAnimation:nil];
    self.retryButton.hidden = NO;
    [self setOverlayTitle:title detail:detail];
    self.overlayView.hidden = NO;
    [self updateStatusText:@"Error" color:RubikCoachHostColor(176, 74, 74, 0.95)];
    [self syncButtonState];
}

- (void)hideOverlay {
    [self.spinner stopAnimation:nil];
    self.overlayView.hidden = YES;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.coachRunning = YES;
    self.webView.hidden = NO;
    [self hideOverlay];
    [self updateStatusText:@"Running" color:RubikCoachHostColor(59, 138, 96, 0.95)];
    [self syncButtonState];
}

- (void)webView:(WKWebView *)webView
didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    [self presentFailureWithTitle:@"Conversation app load failed" detail:error.localizedDescription];
}

- (void)webView:(WKWebView *)webView
didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    [self presentFailureWithTitle:@"Conversation app load failed" detail:error.localizedDescription];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self presentFailureWithTitle:@"Conversation app process ended"
                           detail:@"The embedded web content process terminated. Use Restart to launch it again."];
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *host = url.host.lowercaseString;
    if (!host.length || [host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    [[NSWorkspace sharedWorkspace] openURL:url];
    decisionHandler(WKNavigationActionPolicyCancel);
}

@end
