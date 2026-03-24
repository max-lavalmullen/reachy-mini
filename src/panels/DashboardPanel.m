#import "DashboardPanel.h"
#import "../AppDelegate.h"
#import "../PythonBridge.h"
#import <WebKit/WebKit.h>

static NSColor *DashboardHostColor(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

@interface DashboardPanel () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSView *overlayView;
@property (nonatomic, strong) NSView *overlayCard;
@property (nonatomic, strong) NSTextField *eyebrowLabel;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSButton *retryButton;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) NSInteger pollAttemptCount;
@property (nonatomic, assign) BOOL probeInFlight;
@property (nonatomic, assign) BOOL hasIssuedLoadRequest;
@end

@implementation DashboardPanel

- (void)dealloc {
    [self.pollTimer invalidate];
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1200, 760)];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = DashboardHostColor(5, 10, 18, 1).CGColor;
    [self buildUI];
    [self startDashboardBootSequence];
}

- (void)buildUI {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    config.defaultWebpagePreferences.allowsContentJavaScript = YES;

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.webView.navigationDelegate = self;
    self.webView.hidden = YES;
    if (@available(macOS 12.0, *)) {
        self.webView.underPageBackgroundColor = DashboardHostColor(5, 10, 18, 1);
    }
    [self.view addSubview:self.webView];

    self.overlayView = [[NSView alloc] initWithFrame:self.view.bounds];
    self.overlayView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.overlayView.wantsLayer = YES;
    self.overlayView.layer.backgroundColor = DashboardHostColor(5, 10, 18, 0.94).CGColor;
    [self.view addSubview:self.overlayView];

    self.overlayCard = [[NSView alloc] init];
    self.overlayCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.overlayCard.wantsLayer = YES;
    self.overlayCard.layer.cornerRadius = 20.0;
    self.overlayCard.layer.borderWidth = 1.0;
    self.overlayCard.layer.borderColor = DashboardHostColor(255, 255, 255, 0.08).CGColor;
    self.overlayCard.layer.backgroundColor = DashboardHostColor(14, 25, 42, 0.98).CGColor;
    [self.overlayView addSubview:self.overlayCard];

    NSView *spinnerRing = [[NSView alloc] init];
    spinnerRing.translatesAutoresizingMaskIntoConstraints = NO;
    spinnerRing.wantsLayer = YES;
    spinnerRing.layer.cornerRadius = 22.0;
    spinnerRing.layer.borderWidth = 1.0;
    spinnerRing.layer.borderColor = DashboardHostColor(61, 222, 153, 0.28).CGColor;
    spinnerRing.layer.backgroundColor = DashboardHostColor(61, 222, 153, 0.10).CGColor;
    [self.overlayCard addSubview:spinnerRing];

    self.spinner = [[NSProgressIndicator alloc] init];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.style = NSProgressIndicatorSpinningStyle;
    self.spinner.displayedWhenStopped = NO;
    [self.spinner startAnimation:nil];
    [spinnerRing addSubview:self.spinner];

    self.eyebrowLabel = [NSTextField labelWithString:@"LOCAL DASHBOARD"];
    self.eyebrowLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.eyebrowLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightSemibold];
    self.eyebrowLabel.textColor = DashboardHostColor(61, 222, 153, 0.96);
    [self.overlayCard addSubview:self.eyebrowLabel];

    self.titleLabel = [NSTextField labelWithString:@"Starting Reachy dashboard"];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];
    self.titleLabel.textColor = [NSColor whiteColor];
    [self.overlayCard addSubview:self.titleLabel];

    self.detailLabel = [NSTextField labelWithString:@"Launching the local daemon and loading the official Pollen interface."];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightRegular];
    self.detailLabel.textColor = DashboardHostColor(202, 211, 223, 0.55);
    self.detailLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.detailLabel.maximumNumberOfLines = 3;
    [self.overlayCard addSubview:self.detailLabel];

    self.retryButton = [NSButton buttonWithTitle:@"Retry"
                                          target:self
                                          action:@selector(retryClicked:)];
    self.retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.retryButton.bezelStyle = NSBezelStyleRounded;
    self.retryButton.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.retryButton.contentTintColor = DashboardHostColor(61, 222, 153, 1.0);
    self.retryButton.wantsLayer = YES;
    self.retryButton.layer.cornerRadius = 10.0;
    self.retryButton.layer.borderWidth = 1.0;
    self.retryButton.layer.borderColor = DashboardHostColor(61, 222, 153, 0.55).CGColor;
    self.retryButton.layer.backgroundColor = DashboardHostColor(61, 222, 153, 0.14).CGColor;
    self.retryButton.hidden = YES;
    [self.overlayCard addSubview:self.retryButton];

    NSLayoutConstraint *preferredCardWidth = [self.overlayCard.widthAnchor constraintEqualToConstant:560.0];
    preferredCardWidth.priority = NSLayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [self.overlayCard.centerXAnchor constraintEqualToAnchor:self.overlayView.centerXAnchor],
        [self.overlayCard.centerYAnchor constraintEqualToAnchor:self.overlayView.centerYAnchor],
        preferredCardWidth,
        [self.overlayCard.widthAnchor constraintLessThanOrEqualToAnchor:self.overlayView.widthAnchor constant:-40.0],
        [self.overlayCard.heightAnchor constraintEqualToConstant:232.0],
        [self.overlayCard.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.overlayView.leadingAnchor constant:20.0],
        [self.overlayCard.trailingAnchor constraintLessThanOrEqualToAnchor:self.overlayView.trailingAnchor constant:-20.0],

        [spinnerRing.leadingAnchor constraintEqualToAnchor:self.overlayCard.leadingAnchor constant:28.0],
        [spinnerRing.topAnchor constraintEqualToAnchor:self.overlayCard.topAnchor constant:28.0],
        [spinnerRing.widthAnchor constraintEqualToConstant:44.0],
        [spinnerRing.heightAnchor constraintEqualToConstant:44.0],

        [self.spinner.centerXAnchor constraintEqualToAnchor:spinnerRing.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:spinnerRing.centerYAnchor],

        [self.eyebrowLabel.leadingAnchor constraintEqualToAnchor:spinnerRing.trailingAnchor constant:16.0],
        [self.eyebrowLabel.topAnchor constraintEqualToAnchor:self.overlayCard.topAnchor constant:30.0],
        [self.eyebrowLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.overlayCard.trailingAnchor constant:-28.0],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.eyebrowLabel.leadingAnchor],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.eyebrowLabel.bottomAnchor constant:8.0],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.overlayCard.trailingAnchor constant:-28.0],

        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.detailLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:10.0],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

        [self.retryButton.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.retryButton.topAnchor constraintEqualToAnchor:self.detailLabel.bottomAnchor constant:18.0],
        [self.retryButton.widthAnchor constraintEqualToConstant:112.0],
        [self.retryButton.heightAnchor constraintEqualToConstant:36.0],
    ]];
}

- (NSString *)dashboardURLString {
    // Use v2 dashboard (React SPA) when available, fall back to legacy template UI.
    // REACHY_DASHBOARD_V2 is set by AppDelegate if the bundled assets exist.
    NSString *v2 = [[[NSProcessInfo processInfo] environment][@"REACHY_DASHBOARD_V2"] copy];
    if (v2.length) {
        return @"http://127.0.0.1:8000/v2/";
    }
    return @"http://127.0.0.1:8000/";
}

- (NSString *)daemonStatusURLString {
    return @"http://127.0.0.1:8000/api/daemon/status";
}

- (void)retryClicked:(id)sender {
    [self.webView stopLoading];
    [self startDashboardBootSequence];
}

- (void)startDashboardBootSequence {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.pollAttemptCount = 0;
    self.probeInFlight = NO;
    self.hasIssuedLoadRequest = NO;
    self.retryButton.hidden = YES;
    self.webView.hidden = YES;
    self.eyebrowLabel.stringValue = @"LOCAL DASHBOARD";
    self.eyebrowLabel.textColor = DashboardHostColor(61, 222, 153, 0.96);
    [self.spinner startAnimation:nil];
    [self setOverlayTitle:@"Starting Reachy dashboard"
                   detail:@"Launching the local daemon and loading the official Pollen interface."];
    self.overlayView.hidden = NO;

    PythonBridge *bridge = [AppDelegate shared].pythonBridge;
    if (!bridge) {
        [self presentFailureWithTitle:@"Python bridge unavailable"
                               detail:@"The embedded Python runtime did not initialize, so the dashboard daemon cannot start."];
        return;
    }

    NSString *result = [bridge callFunction:@"start_daemon" withArgs:nil];
    if ([result hasPrefix:@"error:"]) {
        [self presentFailureWithTitle:@"Daemon failed to start" detail:result];
        return;
    }

    [self beginPollingDashboard];
}

- (void)beginPollingDashboard {
    [self pollDashboardAvailability];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                      target:self
                                                    selector:@selector(pollDashboardAvailability)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)pollDashboardAvailability {
    if (self.probeInFlight || self.hasIssuedLoadRequest) return;
    self.probeInFlight = YES;

    // Poll /api/daemon/status — it responds as soon as the daemon server is up,
    // regardless of robot connection state.
    NSURL *statusURL = [NSURL URLWithString:[self daemonStatusURLString]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:statusURL
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:2.5];
    request.HTTPMethod = @"GET";

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.probeInFlight = NO;
            if (self.hasIssuedLoadRequest) return;

            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            BOOL daemonReady = (!error && http.statusCode == 200 && data.length > 0);
            if (daemonReady) {
                self.hasIssuedLoadRequest = YES;
                [self.pollTimer invalidate];
                self.pollTimer = nil;
                self.eyebrowLabel.stringValue = @"DAEMON READY";
                [self setOverlayTitle:@"Loading interface"
                               detail:@"The daemon is up. Rendering the official Reachy dashboard now."];
                NSURL *dashURL = [NSURL URLWithString:[self dashboardURLString]];
                [self.webView loadRequest:[NSURLRequest requestWithURL:dashURL
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:30.0]];
                return;
            }

            self.pollAttemptCount += 1;
            if (self.pollAttemptCount >= 60) {
                NSString *reason = error.localizedDescription ?: @"The local daemon never came up.";
                [self presentFailureWithTitle:@"Dashboard timed out" detail:reason];
                return;
            }

            if (self.pollAttemptCount == 6) {
                self.eyebrowLabel.stringValue = @"STARTING DAEMON";
                [self setOverlayTitle:@"Starting daemon"
                               detail:@"The local server is initializing on 127.0.0.1:8000. This takes a few seconds on first launch."];
            }
        });
    }] resume];
}

- (void)setOverlayTitle:(NSString *)title detail:(NSString *)detail {
    self.titleLabel.stringValue = title ?: @"";
    self.detailLabel.stringValue = detail ?: @"";
}

- (void)presentFailureWithTitle:(NSString *)title detail:(NSString *)detail {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.hasIssuedLoadRequest = NO;
    self.eyebrowLabel.stringValue = @"LOAD FAILED";
    self.eyebrowLabel.textColor = DashboardHostColor(255, 120, 120, 0.96);
    [self.spinner stopAnimation:nil];
    self.retryButton.hidden = NO;
    [self setOverlayTitle:title detail:detail];
    self.overlayView.hidden = NO;
}

- (void)hideOverlay {
    [self.spinner stopAnimation:nil];
    self.overlayView.hidden = YES;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.webView.hidden = NO;
    [self hideOverlay];
}

- (void)webView:(WKWebView *)webView
didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    [self presentFailureWithTitle:@"Dashboard load failed" detail:error.localizedDescription];
}

- (void)webView:(WKWebView *)webView
didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    [self presentFailureWithTitle:@"Dashboard load failed" detail:error.localizedDescription];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self presentFailureWithTitle:@"Dashboard process ended"
                           detail:@"The embedded web content process terminated. Retry to reload the interface."];
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
