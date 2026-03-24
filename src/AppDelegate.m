#import "AppDelegate.h"
#import "PythonBridge.h"
#import "HTTPClient.h"
#import "panels/ConnectionPanel.h"
#import "panels/CameraPanel.h"
#import "panels/HeadControlPanel.h"
#import "panels/AntennaPanel.h"
#import "panels/MotorPanel.h"
#import "panels/BehaviorsPanel.h"
#import "panels/TerminalPanel.h"
#import "panels/ChatPanel.h"
#import "panels/DashboardPanel.h"
#import "panels/RubikCoachPanel.h"
#include <stdlib.h>

static AppDelegate *_sharedDelegate = nil;

static NSString *ReachyTrimmedString(NSString *s) {
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ReachyUnquotedEnvValue(NSString *value) {
    NSString *trimmed = ReachyTrimmedString(value);
    if (trimmed.length >= 2) {
        unichar first = [trimmed characterAtIndex:0];
        unichar last = [trimmed characterAtIndex:trimmed.length - 1];
        if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
            trimmed = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
        }
    }
    return [[trimmed stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\\t" withString:@"\t"];
}

static NSDictionary<NSString *, NSString *> *ReachyParseEnvFile(NSString *path) {
    NSString *raw = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if (!raw.length) return @{};

    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    [raw enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = ReachyTrimmedString(line);
        if (!trimmed.length || [trimmed hasPrefix:@"#"]) return;
        if ([trimmed hasPrefix:@"export "]) trimmed = ReachyTrimmedString([trimmed substringFromIndex:7]);

        NSRange eq = [trimmed rangeOfString:@"="];
        if (eq.location == NSNotFound || eq.location == 0) return;

        NSString *key = ReachyTrimmedString([trimmed substringToIndex:eq.location]);
        NSString *value = ReachyUnquotedEnvValue([trimmed substringFromIndex:eq.location + 1]);
        if (key.length) values[key] = value ?: @"";
    }];
    return values;
}

// Sidebar item descriptor
@interface SidebarItem : NSObject
@property (copy) NSString *title;
@property (copy) NSString *icon;    // SF Symbol name
@property (strong) NSViewController *panel;
@end
@implementation SidebarItem
@end

// ─────────────────────────────────────────────────────────────────────────────
// Sidebar row view — custom green-accent selection
// ─────────────────────────────────────────────────────────────────────────────
@interface SidebarRowView : NSTableRowView
@end
@implementation SidebarRowView
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    NSRect r = NSInsetRect(self.bounds, 8, 3);
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8];
    [[NSColor colorWithRed:61/255.0 green:222/255.0 blue:153/255.0 alpha:0.13] setFill];
    [bg fill];
    // Left accent pill
    NSRect pill = NSMakeRect(4, r.origin.y + 7, 3, r.size.height - 14);
    NSBezierPath *pillPath = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:1.5 yRadius:1.5];
    [[NSColor colorWithRed:61/255.0 green:222/255.0 blue:153/255.0 alpha:1.0] setFill];
    [pillPath fill];
}
@end

// ─────────────────────────────────────────────────────────────────────────────
// Sidebar table view controller
// ─────────────────────────────────────────────────────────────────────────────
@interface SidebarController : NSViewController <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSArray<SidebarItem *> *items;
@property (nonatomic, copy) void (^selectionHandler)(NSInteger index);
@end

@implementation SidebarController

static inline NSColor *sbRGB(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}
static inline NSColor *sbRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}

- (void)loadView {
    // Fully custom dark view — no NSVisualEffectView
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0,0,220,760)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = sbRGB(10,18,32).CGColor;

    // ── Header (clears titlebar area) ─────────────────────────────────────────
    NSView *header = [[NSView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.wantsLayer = YES;
    [root addSubview:header];

    NSTextField *appName = [NSTextField labelWithString:@"Reachy Mini"];
    appName.translatesAutoresizingMaskIntoConstraints = NO;
    appName.font = [NSFont systemFontOfSize:14 weight:NSFontWeightBold];
    appName.textColor = [NSColor whiteColor];
    [header addSubview:appName];

    NSTextField *appSub = [NSTextField labelWithString:@"Control Panel"];
    appSub.translatesAutoresizingMaskIntoConstraints = NO;
    appSub.font = [NSFont systemFontOfSize:10];
    appSub.textColor = sbRGBA(202,211,223,0.45);
    [header addSubview:appSub];

    // Separator under header
    NSView *sep = [[NSView alloc] init];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.wantsLayer = YES;
    sep.layer.backgroundColor = sbRGBA(255,255,255,0.07).CGColor;
    [root addSubview:sep];

    // ── Nav table ─────────────────────────────────────────────────────────────
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = NO;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;

    self.tableView = [[NSTableView alloc] init];
    self.tableView.headerView = nil;
    self.tableView.rowHeight = 44;
    self.tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    self.tableView.backgroundColor = [NSColor clearColor];
    self.tableView.intercellSpacing = NSMakeSize(0, 1);

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:col];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.target = self;
    self.tableView.action = @selector(tableViewClicked:);
    scroll.documentView = self.tableView;
    [root addSubview:scroll];

    // ── Constraints ───────────────────────────────────────────────────────────
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:root.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:72],  // 28pt titlebar + label space

        [appName.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [appName.topAnchor constraintEqualToAnchor:header.topAnchor constant:34],

        [appSub.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [appSub.topAnchor constraintEqualToAnchor:appName.bottomAnchor constant:2],

        [sep.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [sep.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [sep.heightAnchor constraintEqualToConstant:1],

        [scroll.topAnchor constraintEqualToAnchor:sep.bottomAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    self.view = root;
}

- (void)tableViewClicked:(id)sender {
    NSInteger row = self.tableView.clickedRow;
    if (row < 0) return;
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [self.tableView reloadData];
    if (self.selectionHandler) self.selectionHandler(row);
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    [self.tableView reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return self.items.count; }

- (NSTableRowView *)tableView:(NSTableView *)tv rowViewForRow:(NSInteger)row {
    return [[SidebarRowView alloc] init];
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    SidebarItem *item = self.items[row];
    BOOL selected = [tv.selectedRowIndexes containsIndex:row];

    NSTableCellView *cell = [tv makeViewWithIdentifier:@"SC" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0,0,220,44)];
        cell.identifier = @"SC";

        NSImageView *imgView = [[NSImageView alloc] init];
        imgView.translatesAutoresizingMaskIntoConstraints = NO;
        imgView.imageScaling = NSImageScaleProportionallyDown;
        imgView.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:15
                                            weight:NSFontWeightMedium scale:NSImageSymbolScaleMedium];
        imgView.identifier = @"icon";
        [cell addSubview:imgView];
        cell.imageView = imgView;

        NSTextField *label = [NSTextField labelWithString:@""];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.bordered = NO;
        label.backgroundColor = [NSColor clearColor];
        label.editable = NO;
        label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        label.identifier = @"label";
        [cell addSubview:label];
        cell.textField = label;

        [NSLayoutConstraint activateConstraints:@[
            [imgView.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:20],
            [imgView.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [imgView.widthAnchor constraintEqualToConstant:20],
            [imgView.heightAnchor constraintEqualToConstant:20],

            [label.leadingAnchor constraintEqualToAnchor:imgView.trailingAnchor constant:12],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        ]];
    }

    NSColor *accent = sbRGB(61,222,153);
    NSColor *textNormal = [NSColor colorWithWhite:0.85 alpha:1];
    NSColor *iconNormal = [NSColor colorWithWhite:0.60 alpha:1];

    cell.textField.stringValue = item.title;
    cell.textField.textColor = selected ? accent : textNormal;

    if (@available(macOS 11.0, *)) {
        NSImage *sym = [NSImage imageWithSystemSymbolName:item.icon
                                 accessibilityDescription:item.title];
        cell.imageView.image = sym;
        cell.imageView.contentTintColor = selected ? accent : iconNormal;
    }
    return cell;
}

- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row { return 44; }

@end

// ─────────────────────────────────────────────────────────────────────────────
// AppDelegate
// ─────────────────────────────────────────────────────────────────────────────
@interface AppDelegate ()
@property (nonatomic, strong) SidebarController *sidebarController;
@property (nonatomic, strong) NSViewController *currentPanel;
@property (nonatomic, strong) NSView *detailContainer;
@property (nonatomic, strong) NSArray<SidebarItem *> *sidebarItems;
@property (nonatomic, strong) NSWindow *rubikCoachWindow;
@property (nonatomic, strong) RubikCoachPanel *rubikCoachPanel;
@property (nonatomic, copy, readwrite) NSString *workspacePath;
@end

@implementation AppDelegate

+ (AppDelegate *)shared { return _sharedDelegate; }

- (void)applicationWillFinishLaunching:(NSNotification *)n {
    _sharedDelegate = self;
    [self configureRuntimeEnvironment];
    [self buildMenuBar];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];

    // Init Python bridge first
    self.pythonBridge = [[PythonBridge alloc] init];
    if (![self.pythonBridge initialize]) {
        NSLog(@"WARNING: Python bridge failed to initialize — daemon features disabled");
    }

    // Start daemon — autostart=True connects robot in background, wake_up_on_start=False
    NSString *daemonResult = [self.pythonBridge callFunction:@"start_daemon" withArgs:nil];
    NSLog(@"start_daemon on launch: %@", daemonResult);

    // HTTP client
    self.httpClient = [[HTTPClient alloc] initWithBaseURL:@"http://127.0.0.1:8000"];

    [self buildMainWindow];
    [self.mainWindow makeKeyAndOrderFront:nil];

    NSString *savedFrame = [[NSUserDefaults standardUserDefaults] stringForKey:@"MainWindowFrame"];
    if (savedFrame) {
        [self.mainWindow setFrameFromString:savedFrame];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    // Save window frame
    [[NSUserDefaults standardUserDefaults] setObject:self.mainWindow.stringWithSavedFrame
                                              forKey:@"MainWindowFrame"];
    // Stop camera & daemon
    [self.pythonBridge callFunction:@"stop_camera" withArgs:nil];
    [self.pythonBridge callFunction:@"stop_rubik_coach" withArgs:nil];
    [self.pythonBridge callFunction:@"stop_daemon" withArgs:nil];
    [self.pythonBridge teardown];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

- (void)configureRuntimeEnvironment {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *envCandidates = [NSMutableArray array];

    NSString *bundleEnv = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@".env"];
    if (bundleEnv) [envCandidates addObject:bundleEnv];

    NSString *devRoot = [self developmentWorkspacePath];
    if (devRoot.length) {
        [envCandidates addObject:[devRoot stringByAppendingPathComponent:@".env"]];
    }

    [envCandidates addObject:[NSHomeDirectory() stringByAppendingPathComponent:@".reachy-control.env"]];

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *candidate in envCandidates) {
        NSString *standard = [candidate stringByStandardizingPath];
        if (!standard.length || [seen containsObject:standard] || ![fm fileExistsAtPath:standard]) continue;
        [seen addObject:standard];

        NSDictionary<NSString *, NSString *> *values = ReachyParseEnvFile(standard);
        for (NSString *key in values) {
            setenv(key.UTF8String, values[key].UTF8String, 1);
        }
        NSLog(@"Loaded runtime env from %@", standard);
    }

    NSString *configuredDashboard = [[NSProcessInfo processInfo] environment][@"REACHY_DASHBOARD_V2"];
    BOOL dashboardIsDir = NO;
    if (!(configuredDashboard.length &&
          [fm fileExistsAtPath:[configuredDashboard stringByStandardizingPath] isDirectory:&dashboardIsDir] &&
          dashboardIsDir)) {
        NSArray<NSString *> *dashboardCandidates = @[
            [[[[NSBundle mainBundle] resourcePath] ?: @"" stringByAppendingPathComponent:@"dashboard-v2"] stringByStandardizingPath],
            [[devRoot ?: @"" stringByAppendingPathComponent:@"python/dashboard-v2"] stringByStandardizingPath],
        ];
        for (NSString *candidate in dashboardCandidates) {
            BOOL isDir = NO;
            if (!candidate.length || ![fm fileExistsAtPath:candidate isDirectory:&isDir] || !isDir) continue;
            setenv("REACHY_DASHBOARD_V2", candidate.UTF8String, 1);
            NSLog(@"Using dashboard-v2 assets from %@", candidate);
            break;
        }
    }

    NSString *configuredRubikApp = [[NSProcessInfo processInfo] environment][@"REACHY_RUBIK_COACH_APP"];
    BOOL rubikAppIsDir = NO;
    NSString *standardRubikApp = [configuredRubikApp stringByStandardizingPath];
    if (!(standardRubikApp.length &&
          [fm fileExistsAtPath:[standardRubikApp stringByAppendingPathComponent:@"src/reachy_mini_rubik_coach_app"]
                   isDirectory:&rubikAppIsDir] &&
          rubikAppIsDir)) {
        NSArray<NSString *> *rubikCandidates = @[
            [[[[NSBundle mainBundle] resourcePath] ?: @"" stringByAppendingPathComponent:@"apps/reachy_mini_rubik_coach_app"]
                stringByStandardizingPath],
            [[devRoot ?: @"" stringByAppendingPathComponent:@"apps/reachy_mini_rubik_coach_app"]
                stringByStandardizingPath],
        ];
        for (NSString *candidate in rubikCandidates) {
            BOOL isDir = NO;
            NSString *sourceDir = [candidate stringByAppendingPathComponent:@"src/reachy_mini_rubik_coach_app"];
            if (!candidate.length || ![fm fileExistsAtPath:sourceDir isDirectory:&isDir] || !isDir) continue;
            setenv("REACHY_RUBIK_COACH_APP", candidate.UTF8String, 1);
            NSLog(@"Using Rubik coach app from %@", candidate);
            break;
        }
    }

    NSString *configuredWorkspace = [[[NSProcessInfo processInfo] environment][@"REACHY_WORKSPACE"]
        stringByStandardizingPath];
    BOOL isDir = NO;
    if (configuredWorkspace.length && [fm fileExistsAtPath:configuredWorkspace isDirectory:&isDir] && isDir) {
        self.workspacePath = configuredWorkspace;
        return;
    }

    if (devRoot.length && [fm fileExistsAtPath:devRoot isDirectory:&isDir] && isDir) {
        self.workspacePath = devRoot;
        return;
    }

    self.workspacePath = NSHomeDirectory();
}

- (NSString *)developmentWorkspacePath {
    NSString *exeDir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
    NSString *candidate = [[[exeDir stringByAppendingPathComponent:@"../../../.."]
        stringByStandardizingPath] copy];
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:[candidate stringByAppendingPathComponent:@"src"]
                                             isDirectory:&isDir] && isDir &&
        [[NSFileManager defaultManager] fileExistsAtPath:[candidate stringByAppendingPathComponent:@"python"]]) {
        return candidate;
    }
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// Menu Bar
// ─────────────────────────────────────────────────────────────────────────────
- (void)buildMenuBar {
    NSMenu *menuBar = [[NSMenu alloc] init];
    [NSApp setMainMenu:menuBar];

    // App menu
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [menuBar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    appItem.submenu = appMenu;
    [appMenu addItemWithTitle:@"About Reachy Control"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Reachy Control"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];

    // Window menu
    NSMenuItem *winItem = [[NSMenuItem alloc] init];
    [menuBar addItem:winItem];
    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    winItem.submenu = winMenu;
    [NSApp setWindowsMenu:winMenu];
    [winMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [winMenu addItemWithTitle:@"Zoom"     action:@selector(performZoom:)        keyEquivalent:@""];
    [winMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *rubikCoachItem = [winMenu addItemWithTitle:@"Open Rubik Coach App"
                                                    action:@selector(showRubikCoach:)
                                             keyEquivalent:@"r"];
    rubikCoachItem.target = self;
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Window
// ─────────────────────────────────────────────────────────────────────────────
- (void)buildMainWindow {
    NSRect frame = NSMakeRect(80, 80, 1200, 760);
    NSWindowStyleMask style = NSWindowStyleMaskTitled
                            | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable
                            | NSWindowStyleMaskResizable
                            | NSWindowStyleMaskFullSizeContentView;
    self.mainWindow = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:style
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    self.mainWindow.title = @"Reachy Control";
    self.mainWindow.subtitle = @"Mini Lite Desktop";
    self.mainWindow.titlebarAppearsTransparent = YES;
    self.mainWindow.minSize = NSMakeSize(1120, 680);
    self.mainWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.mainWindow.backgroundColor = [NSColor colorWithRed:5/255.0 green:10/255.0 blue:18/255.0 alpha:1];
    if (@available(macOS 11.0, *)) {
        self.mainWindow.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
    }

    NSView *contentView = self.mainWindow.contentView;
    contentView.wantsLayer = YES;

    // Build sidebar items (Dashboard first, then Conversation for Live API)
    [self buildSidebarItems];

    // Sidebar (220pt wide, full height)
    self.sidebarController = [[SidebarController alloc] init];
    self.sidebarController.items = self.sidebarItems;
    [self.sidebarController loadView];
    NSView *sidebarView = self.sidebarController.view;
    sidebarView.frame = NSMakeRect(0, 0, 220, contentView.bounds.size.height);
    sidebarView.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    [contentView addSubview:sidebarView];

    // Detail container fills the rest of the window
    NSRect detailFrame = NSMakeRect(220, 0,
                                    contentView.bounds.size.width - 220,
                                    contentView.bounds.size.height);
    self.detailContainer = [[NSView alloc] initWithFrame:detailFrame];
    self.detailContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.detailContainer.wantsLayer = YES;
    self.detailContainer.layer.backgroundColor =
        [NSColor colorWithRed:5/255.0 green:10/255.0 blue:18/255.0 alpha:1].CGColor;
    [contentView addSubview:self.detailContainer];

    // Thin separator line between sidebar and detail
    NSView *divider = [[NSView alloc] initWithFrame:NSMakeRect(220, 0, 1, contentView.bounds.size.height)];
    divider.wantsLayer = YES;
    divider.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.07].CGColor;
    divider.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    [contentView addSubview:divider];

    // Wire sidebar selection
    __weak typeof(self) ws = self;
    self.sidebarController.selectionHandler = ^(NSInteger idx) {
        [ws showPanelAtIndex:idx];
    };

    // Start on Connection panel (index 0) — robot status + Wake Up is the entry point
    [self.sidebarController.tableView
        selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
        byExtendingSelection:NO];
    [self.sidebarController.tableView reloadData];
    [self showPanelAtIndex:0];
}

- (void)showRubikCoach:(id)sender {
    if (self.rubikCoachWindow) {
        [self.rubikCoachWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }

    NSRect frame = NSMakeRect(120, 120, 1160, 760);
    NSWindowStyleMask style = NSWindowStyleMaskTitled
                            | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable
                            | NSWindowStyleMaskResizable
                            | NSWindowStyleMaskFullSizeContentView;
    self.rubikCoachWindow = [[NSWindow alloc] initWithContentRect:frame
                                                        styleMask:style
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
    self.rubikCoachWindow.title = @"Conversation App";
    self.rubikCoachWindow.subtitle = @"OpenAI Live + Personality Control";
    self.rubikCoachWindow.titlebarAppearsTransparent = YES;
    self.rubikCoachWindow.minSize = NSMakeSize(980, 640);
    self.rubikCoachWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.rubikCoachWindow.backgroundColor = [NSColor colorWithRed:5/255.0 green:10/255.0 blue:18/255.0 alpha:1];
    if (@available(macOS 11.0, *)) {
        self.rubikCoachWindow.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
    }

    self.rubikCoachWindow.contentView.wantsLayer = YES;
    self.rubikCoachPanel = [[RubikCoachPanel alloc] init];
    [self.rubikCoachPanel loadView];
    self.rubikCoachPanel.view.frame = self.rubikCoachWindow.contentView.bounds;
    self.rubikCoachPanel.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.rubikCoachWindow.contentView addSubview:self.rubikCoachPanel.view];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(rubikCoachWindowWillClose:)
                                                 name:NSWindowWillCloseNotification
                                               object:self.rubikCoachWindow];

    [self.rubikCoachWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)rubikCoachWindowWillClose:(NSNotification *)notification {
    if (notification.object != self.rubikCoachWindow) return;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowWillCloseNotification
                                                  object:self.rubikCoachWindow];
    [self.pythonBridge callFunction:@"stop_rubik_coach" withArgs:nil];
    self.rubikCoachPanel = nil;
    self.rubikCoachWindow = nil;
}

- (void)buildSidebarItems {
    NSArray *defs = @[
        @[@"Connection",   @"cable.connector",         [ConnectionPanel class]],
        @[@"Conversation", @"waveform.and.mic",        [ChatPanel class]],
        @[@"Camera",       @"camera",                  [CameraPanel class]],
        @[@"Controls",     @"dot.arrowtriangles.up.right.down.left.circle", [AntennaPanel class]],
        @[@"Motors",       @"bolt.circle",             [MotorPanel class]],
        @[@"Behaviors",    @"play.circle",             [BehaviorsPanel class]],
        @[@"Terminal",     @"terminal",                [TerminalPanel class]],
    ];

    NSMutableArray *items = [NSMutableArray array];
    for (NSArray *def in defs) {
        SidebarItem *item = [[SidebarItem alloc] init];
        item.title = def[0];
        item.icon  = def[1];
        Class cls  = def[2];
        item.panel = [[cls alloc] init];
        [items addObject:item];
    }
    self.sidebarItems = items;
}

- (void)showPanelAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.sidebarItems.count) return;
    SidebarItem *item = self.sidebarItems[idx];
    NSViewController *vc = item.panel;

    if (self.currentPanel == vc) return;
    self.currentPanel = vc;

    // Ensure view is loaded
    if (!vc.viewLoaded) {
        [vc loadView];
    }

    // Swap into detail container (plain NSView — no contentView indirection)
    NSView *container = self.detailContainer;
    for (NSView *sub in [container.subviews copy]) {
        [sub removeFromSuperview];
    }
    vc.view.frame = container.bounds;
    vc.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:vc.view];
}

@end
