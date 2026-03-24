#import "ConnectionGatePanel.h"
#import "../AppDelegate.h"
#import "../HTTPClient.h"
#import <WebKit/WebKit.h>

@interface ConnectionGatePanel () <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL isConnecting;
@property (nonatomic, assign) BOOL isWaking;
@property (nonatomic, assign) BOOL hasEntered;
@property (nonatomic, copy)   NSString *lastRobotState;
@end

@implementation ConnectionGatePanel

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1200, 760)];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor =
        [NSColor colorWithRed:5/255.0 green:10/255.0 blue:18/255.0 alpha:1.0].CGColor;
    [self buildWebView];
}

- (void)buildWebView {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    [config.userContentController addScriptMessageHandler:self name:@"reachy"];

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.webView.navigationDelegate = self;
    if (@available(macOS 12.0, *)) {
        self.webView.underPageBackgroundColor =
            [NSColor colorWithRed:5/255.0 green:10/255.0 blue:18/255.0 alpha:1.0];
    }
    [self.view addSubview:self.webView];

    // Load HTML with SVGs embedded as data URIs — no file URL security issues
    NSString *html = [self buildGateHTML];
    if (html.length) {
        [self.webView loadHTMLString:html baseURL:nil];
    } else {
        // Fallback: start polling immediately without the HTML UI
        [self startPolling];
    }
}

- (NSString *)buildGateHTML {
    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    NSString *htmlPath = [resourcePath stringByAppendingPathComponent:@"connection-gate.html"];
    NSString *html = [NSString stringWithContentsOfFile:htmlPath
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!html.length) return nil;

    // Embed SVGs as data URIs so WKWebView needs no external file access
    NSArray *svgFiles = @[@"reachy-mini-sleeping", @"reachy-mini-awake", @"reachy-mini-ko"];
    NSArray *tokens   = @[@"{{SVG_SLEEPING}}", @"{{SVG_AWAKE}}", @"{{SVG_KO}}"];

    for (NSUInteger i = 0; i < svgFiles.count; i++) {
        NSString *svgPath = [resourcePath
                             stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"%@.svg", svgFiles[i]]];
        NSData *svgData = [NSData dataWithContentsOfFile:svgPath];
        if (!svgData) continue;
        NSString *b64  = [svgData base64EncodedStringWithOptions:0];
        NSString *dataURI = [NSString stringWithFormat:@"data:image/svg+xml;base64,%@", b64];
        html = [html stringByReplacingOccurrencesOfString:tokens[i] withString:dataURI];
    }
    return html;
}

// ─── WKNavigationDelegate ────────────────────────────────────────────────────

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self startPolling];
}

// ─── Polling ─────────────────────────────────────────────────────────────────

- (void)startPolling {
    [self.pollTimer invalidate];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.8
                                                      target:self
                                                    selector:@selector(pollStatus)
                                                    userInfo:nil
                                                     repeats:YES];
    [self pollStatus];
}

- (void)pollStatus {
    if (self.hasEntered) return;
    HTTPClient *client = [AppDelegate shared].httpClient;
    [client getJSON:@"/api/daemon/status" completion:^(id json, NSError *error) {
        if (self.hasEntered) return;
        [self handleStatusJSON:json error:error];
    }];
}

- (void)handleStatusJSON:(id)json error:(NSError *)error {
    if (self.hasEntered) return;

    if (error || ![json isKindOfClass:[NSDictionary class]]) {
        // Daemon server not up yet
        if (![self.lastRobotState isEqualToString:@"starting"]) {
            [self callJS:@"updateState" arg:@"'starting'"];
            self.lastRobotState = @"starting";
        }
        return;
    }

    NSDictionary *dict = (NSDictionary *)json;
    // Daemon state values: not_initialized, starting, running, stopping, stopped, error
    NSString *daemonState = [[dict[@"state"] description] lowercaseString] ?: @"not_initialized";
    NSString *robotName   = dict[@"robot_name"] ?: @"";

    if ([daemonState isEqualToString:@"running"]) {
        // Robot is fully connected — map to gate's "connected" state
        self.isConnecting = NO;
        if (!self.isWaking &&
            ![self.lastRobotState isEqualToString:@"connected"] &&
            ![self.lastRobotState isEqualToString:@"awake"]) {
            NSString *jsArg = robotName.length
                ? [NSString stringWithFormat:@"'connected', '%@'", robotName]
                : @"'connected'";
            [self callJS:@"updateState" arg:jsArg];
            self.lastRobotState = @"connected";
        }
    } else if ([daemonState isEqualToString:@"starting"]) {
        // Robot is in the process of connecting
        self.isConnecting = YES;
        if (![self.lastRobotState isEqualToString:@"connecting"]) {
            [self callJS:@"updateState" arg:@"'connecting'"];
            self.lastRobotState = @"connecting";
        }
    } else if ([daemonState isEqualToString:@"error"]) {
        self.isConnecting = NO;
        self.isWaking = NO;
        if (![self.lastRobotState isEqualToString:@"error"]) {
            // Pass the daemon error message to JS for display
            NSString *errMsg = [dict[@"error"] description] ?: @"";
            // Escape single quotes in the error message
            errMsg = [errMsg stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
            errMsg = [errMsg stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            NSString *jsArg = errMsg.length
                ? [NSString stringWithFormat:@"'error', '', '%@'", errMsg]
                : @"'error'";
            [self callJS:@"updateState" arg:jsArg];
            self.lastRobotState = @"error";
        }
    } else {
        // not_initialized / stopped / stopping — show Connect button
        if (!self.isConnecting && !self.isWaking) {
            if (![self.lastRobotState isEqualToString:@"idle"]) {
                [self callJS:@"updateState" arg:@"'idle'"];
                self.lastRobotState = @"idle";
            }
        }
    }
}

// ─── JS → ObjC messages ──────────────────────────────────────────────────────

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"reachy"]) return;
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;

    NSString *action = body[@"action"];
    if      ([action isEqualToString:@"connect"])  [self doConnect];
    else if ([action isEqualToString:@"wakeUp"])   [self doWakeUp];
    else if ([action isEqualToString:@"enter"])    [self doEnter];
    else if ([action isEqualToString:@"retry"])    [self doRetry];
}

- (void)doConnect {
    self.isConnecting = YES;
    self.lastRobotState = @"connecting";
    [self callJS:@"updateState" arg:@"'connecting'"];

    HTTPClient *client = [AppDelegate shared].httpClient;
    [client postJSON:@"/api/daemon/start?wake_up=false" body:nil completion:^(id json, NSError *error) {
        if (self.hasEntered) return;
        if (error) {
            self.isConnecting = NO;
            self.lastRobotState = @"error";
            [self callJS:@"updateState" arg:@"'error'"];
        }
        // On success, polling will detect state=running and update to connected
    }];
}

- (void)doWakeUp {
    self.isWaking = YES;
    self.lastRobotState = @"waking";
    [self callJS:@"updateState" arg:@"'waking'"];

    HTTPClient *client = [AppDelegate shared].httpClient;
    [client postJSON:@"/api/move/play/wake_up" body:nil completion:^(id json, NSError *error) {
        if (self.hasEntered) return;
        self.isWaking = NO;
        if (error) {
            self.lastRobotState = @"error";
            [self callJS:@"updateState" arg:@"'error'"];
        } else {
            self.lastRobotState = @"awake";
            [self callJS:@"updateState" arg:@"'awake'"];
        }
    }];
}

- (void)doEnter {
    if (self.hasEntered) return;
    self.hasEntered = YES;
    [self.pollTimer invalidate];
    self.pollTimer = nil;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.45;
        self.view.animator.alphaValue = 0.0;
    } completionHandler:^{
        [self.delegate connectionGateDidComplete:self];
    }];
}

- (void)doRetry {
    self.isConnecting = NO;
    self.isWaking = NO;
    self.lastRobotState = @"starting";
    [self callJS:@"updateState" arg:@"'starting'"];
    // Polling continues — will detect actual daemon/robot state and update accordingly
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

- (void)callJS:(NSString *)fn arg:(NSString *)arg {
    NSString *js = [NSString stringWithFormat:@"%@(%@)", fn, arg];
    [self.webView evaluateJavaScript:js completionHandler:nil];
}

- (void)dealloc {
    [self.pollTimer invalidate];
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"reachy"];
}

@end
