#import "ConnectionPanel.h"
#import "../AppDelegate.h"
#import "../HTTPClient.h"
#import <WebKit/WebKit.h>

// ── Palette ───────────────────────────────────────────────────────────────────

static inline NSColor *pRGB(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}
static inline NSColor *pRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}

// ── Emoji / display-name helpers ──────────────────────────────────────────────

static NSString *emojiForMove(NSString *move) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"happy":@"😊", @"joyful":@"😄", @"sad":@"😢", @"melancholy":@"😔",
            @"excited":@"🥳", @"enthusiastic":@"🙌", @"curious":@"🤔",
            @"surprise":@"😲", @"surprised":@"😲", @"angry":@"😠",
            @"annoyed":@"😤", @"scared":@"😨", @"afraid":@"😨",
            @"shy":@"😊", @"proud":@"😎", @"confused":@"😕", @"bored":@"😒",
            @"love":@"🥰", @"disgust":@"🤢", @"embarrassed":@"😳",
            @"sleepy":@"😴", @"neutral":@"😐", @"calm":@"😌",
            @"playful":@"😄", @"yes":@"👍", @"no":@"👎",
            @"hello":@"👋", @"bye":@"👋", @"dance":@"💃",
            @"wave":@"👋", @"nod":@"👍", @"shake":@"🙅",
        };
    });
    NSString *lower = move.lowercaseString;
    NSString *emoji = map[lower];
    if (!emoji) {
        NSArray *parts = [lower componentsSeparatedByCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"_- "]];
        emoji = map[parts.firstObject ?: lower];
    }
    return emoji ?: @"🤖";
}

static NSString *displayNameForMove(NSString *move) {
    NSArray<NSString *> *parts = [move componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet characterSetWithCharactersInString:@"_- "]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in parts) {
        if (!p.length) continue;
        [out addObject:[p stringByReplacingCharactersInRange:NSMakeRange(0,1)
                        withString:[p substringToIndex:1].uppercaseString]];
    }
    return out.count ? [out componentsJoinedByString:@" "] : move;
}

// ── CPButton ──────────────────────────────────────────────────────────────────

@interface CPButton : NSButton
@property (nonatomic, strong) NSColor *fillColor;
@property (nonatomic, strong) NSColor *borderColor;
- (void)styleTitle:(NSString *)t color:(NSColor *)tc size:(CGFloat)sz;
@end
@implementation CPButton
- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.wantsLayer = YES; self.bordered = NO;
        self.bezelStyle = NSBezelStyleRegularSquare;
        self.layer.cornerRadius = 10; self.layer.masksToBounds = YES;
    }
    return self;
}
- (void)setFillColor:(NSColor *)c   { _fillColor = c; self.layer.backgroundColor = c.CGColor; }
- (void)setBorderColor:(NSColor *)c {
    _borderColor = c;
    self.layer.borderColor = c ? c.CGColor : nil;
    self.layer.borderWidth = c ? 1.5 : 0;
}
- (void)setEnabled:(BOOL)e { [super setEnabled:e]; self.layer.opacity = e ? 1.0 : 0.38; }
- (void)drawRect:(NSRect)r {}
- (void)styleTitle:(NSString *)t color:(NSColor *)tc size:(CGFloat)sz {
    self.attributedTitle = [[NSAttributedString alloc] initWithString:t attributes:@{
        NSForegroundColorAttributeName: tc,
        NSFontAttributeName: [NSFont systemFontOfSize:sz weight:NSFontWeightSemibold],
    }];
}
@end

// ── CPBadge ───────────────────────────────────────────────────────────────────

@interface CPBadge : NSView
@property (nonatomic, strong) NSTextField *lbl;
- (void)setTitle:(NSString *)t fill:(NSColor *)fill text:(NSColor *)tc;
@end
@implementation CPBadge
- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.wantsLayer = YES; self.layer.cornerRadius = 10; self.layer.masksToBounds = YES;
        _lbl = [NSTextField labelWithString:@""];
        _lbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        _lbl.alignment = NSTextAlignmentCenter;
        [self addSubview:_lbl];
    }
    return self;
}
- (void)setTitle:(NSString *)t fill:(NSColor *)fill text:(NSColor *)tc {
    self.lbl.stringValue = t; self.lbl.textColor = tc;
    self.layer.backgroundColor = fill.CGColor;
}
- (NSSize)intrinsicContentSize {
    [self.lbl sizeToFit];
    return NSMakeSize(MAX(84, self.lbl.frame.size.width + 24), 22);
}
- (void)layout {
    [super layout];
    self.lbl.frame = self.bounds;
}
@end

// ── EmotionTile ───────────────────────────────────────────────────────────────

@interface EmotionTile : NSView
@property (copy) NSString *moveName;
@property (copy) NSString *dataset;
@property (copy) void (^onPlay)(NSString *, NSString *);
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) BOOL isHovered;
@property (nonatomic, strong) NSTrackingArea *trackArea;
@end
@implementation EmotionTile
- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 12; self.layer.masksToBounds = YES;
        _isEnabled = YES; [self refreshLayer];
    }
    return self;
}
- (void)refreshLayer {
    if (_isPlaying) {
        self.layer.backgroundColor = pRGBA(61,222,153,0.14).CGColor;
        self.layer.borderColor = pRGBA(61,222,153,0.75).CGColor;
        self.layer.borderWidth = 1.5;
    } else if (_isHovered && _isEnabled) {
        self.layer.backgroundColor = pRGBA(255,255,255,0.07).CGColor;
        self.layer.borderColor = pRGBA(255,255,255,0.18).CGColor;
        self.layer.borderWidth = 1.0;
    } else {
        self.layer.backgroundColor = pRGB(14,25,42).CGColor;
        self.layer.borderColor = pRGBA(255,255,255,0.08).CGColor;
        self.layer.borderWidth = 0.5;
    }
    self.layer.opacity = _isEnabled ? 1.0 : 0.38;
}
- (void)setIsPlaying:(BOOL)v { _isPlaying = v; [self refreshLayer]; }
- (void)setIsEnabled:(BOOL)v { _isEnabled = v; [self refreshLayer]; }
- (void)setIsHovered:(BOOL)v { _isHovered = v; [self refreshLayer]; }
- (void)refreshTrackingArea {
    if (self.trackArea) [self removeTrackingArea:self.trackArea];
    self.trackArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
               owner:self userInfo:nil];
    [self addTrackingArea:self.trackArea];
}
- (void)viewDidMoveToWindow { [self refreshTrackingArea]; }
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self refreshTrackingArea]; }
- (void)mouseEntered:(NSEvent *)e { self.isHovered = YES; }
- (void)mouseExited:(NSEvent *)e  { self.isHovered = NO; }
- (void)mouseDown:(NSEvent *)e {
    if (!self.isEnabled) return;
    self.layer.opacity = 0.7;
    if (self.onPlay) self.onPlay(self.moveName, self.dataset);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ self.layer.opacity = 1.0; });
}
@end

// ── BehaviorGridView ──────────────────────────────────────────────────────────

@interface BehaviorGridView : NSView
@property (nonatomic, copy) void (^onPlay)(NSString *, NSString *);
@property (nonatomic, copy) NSString *playingMove;
@property (nonatomic, assign) BOOL movesEnabled;
- (void)reloadMoves:(NSArray<NSString *> *)moves dataset:(NSString *)ds;
@end

static const CGFloat kTW = 136, kTH = 84, kTG = 10, kTP = 20;

@implementation BehaviorGridView
- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f]; if (self) _movesEnabled = YES; return self;
}
- (BOOL)isFlipped { return YES; }
- (void)reloadMoves:(NSArray<NSString *> *)moves dataset:(NSString *)ds {
    for (NSView *v in [self.subviews copy]) [v removeFromSuperview];
    if (!moves.count) {
        CGFloat scrollH = self.superview.frame.size.height ?: 300;
        self.frame = NSMakeRect(0, 0, self.frame.size.width ?: 700, scrollH);
        return;
    }
    CGFloat w = self.frame.size.width;
    if (w < 10) w = 700;
    NSInteger cols = MAX(1, (NSInteger)floor((w - 2*kTP + kTG) / (kTW + kTG)));
    NSInteger rows = ((NSInteger)moves.count + cols - 1) / cols;
    __weak typeof(self) ws = self;
    for (NSInteger i = 0; i < (NSInteger)moves.count; i++) {
        NSString *moveName = moves[i];
        CGFloat tx = kTP + (i % cols) * (kTW + kTG);
        CGFloat ty = kTP + (i / cols) * (kTH + kTG);
        EmotionTile *tile = [[EmotionTile alloc] initWithFrame:NSMakeRect(tx, ty, kTW, kTH)];
        tile.moveName = moveName; tile.dataset = ds;
        tile.isEnabled = self.movesEnabled;
        tile.isPlaying = [moveName isEqualToString:self.playingMove];
        tile.onPlay = ^(NSString *m, NSString *d) { if (ws.onPlay) ws.onPlay(m, d); };
        NSTextField *el = [NSTextField labelWithString:emojiForMove(moveName)];
        el.font = [NSFont systemFontOfSize:26]; el.alignment = NSTextAlignmentCenter;
        el.frame = NSMakeRect(0, 6, kTW, 38); [tile addSubview:el];
        NSTextField *nl = [NSTextField labelWithString:displayNameForMove(moveName)];
        nl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        nl.textColor = pRGBA(255,255,255,0.68); nl.alignment = NSTextAlignmentCenter;
        nl.lineBreakMode = NSLineBreakByTruncatingTail;
        nl.frame = NSMakeRect(4, kTH - 23, kTW - 8, 17); [tile addSubview:nl];
        [self addSubview:tile];
    }
    CGFloat totalH = kTP + rows * kTH + (rows - 1) * kTG + kTP;
    CGFloat scrollH = self.superview.frame.size.height ?: 300;
    self.frame = NSMakeRect(0, 0, w, MAX(totalH, scrollH));
}
- (void)setPlayingMove:(NSString *)m {
    _playingMove = m;
    for (NSView *v in self.subviews)
        if ([v isKindOfClass:[EmotionTile class]])
            ((EmotionTile *)v).isPlaying = [((EmotionTile *)v).moveName isEqualToString:m];
}
- (void)setMovesEnabled:(BOOL)e {
    _movesEnabled = e;
    for (NSView *v in self.subviews)
        if ([v isKindOfClass:[EmotionTile class]])
            ((EmotionTile *)v).isEnabled = e;
}
@end

// ── States ────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, CPState) {
    CPStateUnknown = 0, CPStateNotInitialized,
    CPStateStarting, CPStateRunning,
    CPStateStopping, CPStateStopped, CPStateError,
};

// ── ConnectionPanel ───────────────────────────────────────────────────────────

@interface ConnectionPanel () <WKNavigationDelegate>
// Robot zone
@property (nonatomic, strong) NSView              *robotZone;
@property (nonatomic, strong) WKWebView           *robotView;
@property (nonatomic, strong) NSTextField         *robotNameLabel;
@property (nonatomic, strong) CPBadge             *stateBadge;
@property (nonatomic, strong) NSTextField         *statusDetailLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) CPButton            *primaryBtn;
@property (nonatomic, strong) CPButton            *sleepBtn;
// Behavior zone
@property (nonatomic, strong) NSView              *behaviorZone;
@property (nonatomic, strong) NSArray<CPButton *> *tabBtns;
@property (nonatomic, strong) NSTextField         *behaviorStatusLabel;
@property (nonatomic, strong) NSTextField         *serialPortLabel;
@property (nonatomic, strong) NSScrollView        *behaviorScroll;
@property (nonatomic, strong) BehaviorGridView    *behaviorGrid;
// Live constraint for primary button centering
@property (nonatomic, strong) NSLayoutConstraint  *primaryCenterX;
@property (nonatomic, strong) NSLayoutConstraint  *primaryLeading;
// State
@property (nonatomic, strong) NSTimer             *pollTimer;
@property (nonatomic, assign) CPState              currentState;
@property (nonatomic, assign) BOOL                 robotIsAwake;
@property (nonatomic, copy)   NSString            *currentRobotName;
// Behaviors
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSString *> *> *movesCache;
@property (nonatomic, assign) NSInteger            selectedTab;
@property (nonatomic, assign) BOOL                 behaviorPlaying;
@property (nonatomic, copy)   NSString            *playingMoveName;
@end

@implementation ConnectionPanel

static const CGFloat kSvgW = 300.0, kSvgH = 193.0;
static NSArray<NSString *> *kDatasets;

+ (void)initialize {
    if (self == [ConnectionPanel class])
        kDatasets = @[@"emotions", @"animations", @"dances"];
}

// ─── Lifecycle ────────────────────────────────────────────────────────────────

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0,0,980,760)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = pRGB(5,10,18).CGColor;
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = root;
    self.movesCache = [NSMutableDictionary dictionary];
    self.selectedTab = 0;
    [self buildUI];
    [self startPolling];
}

- (void)dealloc {
    [self stopPolling];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// ─── UI construction (Auto Layout throughout) ─────────────────────────────────

- (void)buildUI {
    NSView *v = self.view;

    // ── Two zones ─────────────────────────────────────────────────────────────

    NSView *robotZone = [[NSView alloc] init];
    robotZone.translatesAutoresizingMaskIntoConstraints = NO;
    self.robotZone = robotZone;
    [v addSubview:robotZone];

    NSView *behaviorZone = [[NSView alloc] init];
    behaviorZone.translatesAutoresizingMaskIntoConstraints = NO;
    behaviorZone.wantsLayer = YES;
    self.behaviorZone = behaviorZone;
    [v addSubview:behaviorZone];

    NSView *robotCard = [[NSView alloc] init];
    robotCard.translatesAutoresizingMaskIntoConstraints = NO;
    robotCard.wantsLayer = YES;
    robotCard.layer.cornerRadius = 18;
    robotCard.layer.borderWidth = 1;
    robotCard.layer.borderColor = pRGBA(255,255,255,0.08).CGColor;
    robotCard.layer.backgroundColor = pRGB(14,25,42).CGColor;
    [robotZone addSubview:robotCard];

    NSView *behaviorCard = [[NSView alloc] init];
    behaviorCard.translatesAutoresizingMaskIntoConstraints = NO;
    behaviorCard.wantsLayer = YES;
    behaviorCard.layer.cornerRadius = 18;
    behaviorCard.layer.borderWidth = 1;
    behaviorCard.layer.borderColor = pRGBA(255,255,255,0.08).CGColor;
    behaviorCard.layer.backgroundColor = pRGB(14,25,42).CGColor;
    [behaviorZone addSubview:behaviorCard];

    [NSLayoutConstraint activateConstraints:@[
        [robotZone.topAnchor constraintEqualToAnchor:v.topAnchor],
        [robotZone.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [robotZone.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [robotZone.heightAnchor constraintEqualToAnchor:v.heightAnchor multiplier:0.54],
        [behaviorZone.topAnchor constraintEqualToAnchor:robotZone.bottomAnchor],
        [behaviorZone.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [behaviorZone.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [behaviorZone.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],

        [robotCard.topAnchor constraintEqualToAnchor:robotZone.topAnchor constant:18],
        [robotCard.leadingAnchor constraintEqualToAnchor:robotZone.leadingAnchor constant:20],
        [robotCard.trailingAnchor constraintEqualToAnchor:robotZone.trailingAnchor constant:-20],
        [robotCard.bottomAnchor constraintEqualToAnchor:robotZone.bottomAnchor constant:-10],

        [behaviorCard.topAnchor constraintEqualToAnchor:behaviorZone.topAnchor constant:10],
        [behaviorCard.leadingAnchor constraintEqualToAnchor:behaviorZone.leadingAnchor constant:20],
        [behaviorCard.trailingAnchor constraintEqualToAnchor:behaviorZone.trailingAnchor constant:-20],
        [behaviorCard.bottomAnchor constraintEqualToAnchor:behaviorZone.bottomAnchor constant:-18],
    ]];

    // ── Robot SVG ─────────────────────────────────────────────────────────────

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    wv.translatesAutoresizingMaskIntoConstraints = NO;
    wv.navigationDelegate = self;
    wv.wantsLayer = YES;
    wv.layer.cornerRadius = 20; wv.layer.masksToBounds = YES;
    wv.layer.borderWidth = 1;
    wv.layer.borderColor = pRGBA(255,255,255,0.08).CGColor;
    wv.layer.backgroundColor = pRGB(5,10,18).CGColor;
    if (@available(macOS 12.0, *)) wv.underPageBackgroundColor = pRGB(5,10,18);
    self.robotView = wv;

    // ── Robot name ────────────────────────────────────────────────────────────

    NSTextField *nameLbl = [NSTextField labelWithString:@"Reachy Mini"];
    nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
    nameLbl.font = [NSFont systemFontOfSize:24 weight:NSFontWeightBold];
    nameLbl.textColor = [NSColor whiteColor];
    nameLbl.alignment = NSTextAlignmentCenter;
    self.robotNameLabel = nameLbl;

    // ── State badge ───────────────────────────────────────────────────────────

    CPBadge *badge = [[CPBadge alloc] initWithFrame:NSMakeRect(0,0,100,22)];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [badge setTitle:@"● Connecting" fill:pRGBA(255,255,255,0.08) text:pRGBA(202,211,223,0.78)];
    self.stateBadge = badge;

    // ── Name row (name + badge, horizontal) ───────────────────────────────────

    NSStackView *nameRow = [NSStackView stackViewWithViews:@[nameLbl, badge]];
    nameRow.translatesAutoresizingMaskIntoConstraints = NO;
    nameRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    nameRow.alignment = NSLayoutAttributeCenterY;
    nameRow.spacing = 10;
    nameRow.distribution = NSStackViewDistributionFill;

    // ── Status detail ─────────────────────────────────────────────────────────

    NSTextField *detail = [NSTextField labelWithString:@"Connecting to Reachy…"];
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    detail.font = [NSFont systemFontOfSize:12];
    detail.textColor = pRGBA(202,211,223,0.55);
    detail.alignment = NSTextAlignmentCenter;
    detail.lineBreakMode = NSLineBreakByWordWrapping;
    detail.maximumNumberOfLines = 2;
    self.statusDetailLabel = detail;

    // ── Spinner ───────────────────────────────────────────────────────────────

    NSProgressIndicator *spin = [[NSProgressIndicator alloc] init];
    spin.translatesAutoresizingMaskIntoConstraints = NO;
    spin.style = NSProgressIndicatorSpinningStyle;
    spin.controlSize = NSControlSizeSmall;
    spin.displayedWhenStopped = NO;
    [spin startAnimation:nil];
    self.spinner = spin;

    // ── Buttons ───────────────────────────────────────────────────────────────

    CPButton *primary = [[CPButton alloc] initWithFrame:NSMakeRect(0,0,168,44)];
    primary.translatesAutoresizingMaskIntoConstraints = NO;
    [primary styleTitle:@"▶  Wake Up" color:pRGB(4,14,8) size:14];
    primary.fillColor = pRGB(61,222,153);
    primary.target = self; primary.action = @selector(primaryBtnClicked:);
    self.primaryBtn = primary;

    CPButton *sleep = [[CPButton alloc] initWithFrame:NSMakeRect(0,0,148,44)];
    sleep.translatesAutoresizingMaskIntoConstraints = NO;
    [sleep styleTitle:@"Goto Sleep" color:pRGBA(255,255,255,0.80) size:14];
    sleep.fillColor = pRGBA(255,255,255,0);
    sleep.borderColor = pRGBA(255,255,255,0.12);
    sleep.target = self; sleep.action = @selector(sleepBtnClicked:);
    sleep.hidden = YES;
    self.sleepBtn = sleep;

    // Button row: spinner + primary + sleep (NSStackView collapses hidden views)
    NSStackView *actionRow = [[NSStackView alloc] init];
    actionRow.translatesAutoresizingMaskIntoConstraints = NO;
    actionRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actionRow.alignment = NSLayoutAttributeCenterY;
    actionRow.spacing = 12;
    actionRow.distribution = NSStackViewDistributionFill;
    [actionRow addArrangedSubview:spin];
    [actionRow addArrangedSubview:primary];
    [actionRow addArrangedSubview:sleep];

    // ── Content stack (vertical, centered in robot zone) ──────────────────────

    NSStackView *contentStack = [[NSStackView alloc] init];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    contentStack.alignment = NSLayoutAttributeCenterX;
    contentStack.distribution = NSStackViewDistributionFill;
    [contentStack addArrangedSubview:wv];
    [contentStack setCustomSpacing:16 afterView:wv];
    [contentStack addArrangedSubview:nameRow];
    [contentStack setCustomSpacing:8 afterView:nameRow];
    [contentStack addArrangedSubview:detail];
    [contentStack setCustomSpacing:16 afterView:detail];
    [contentStack addArrangedSubview:actionRow];

    [robotCard addSubview:contentStack];

    // Fixed sizes
    [NSLayoutConstraint activateConstraints:@[
        [wv.widthAnchor constraintEqualToConstant:kSvgW],
        [wv.heightAnchor constraintEqualToConstant:kSvgH],
        [primary.widthAnchor constraintEqualToConstant:168],
        [primary.heightAnchor constraintEqualToConstant:44],
        [sleep.widthAnchor constraintEqualToConstant:148],
        [sleep.heightAnchor constraintEqualToConstant:44],
        [spin.widthAnchor constraintEqualToConstant:18],
        [spin.heightAnchor constraintEqualToConstant:18],
        [detail.widthAnchor constraintLessThanOrEqualToConstant:420],
        // Content stack: center in robot zone
        [contentStack.centerXAnchor constraintEqualToAnchor:robotCard.centerXAnchor],
        [contentStack.centerYAnchor constraintEqualToAnchor:robotCard.centerYAnchor],
        // Keep content within bounds
        [contentStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:robotCard.leadingAnchor constant:20],
        [contentStack.trailingAnchor constraintLessThanOrEqualToAnchor:robotCard.trailingAnchor constant:-20],
    ]];

    [self loadRobotSVG:@"sleeping"];

    // ── Behavior zone ─────────────────────────────────────────────────────────

    // Divider
    NSView *div = [[NSView alloc] init];
    div.translatesAutoresizingMaskIntoConstraints = NO;
    div.wantsLayer = YES; div.layer.backgroundColor = pRGBA(255,255,255,0.07).CGColor;
    [behaviorCard addSubview:div];

    // Dataset tabs
    NSView *tabBar = [[NSView alloc] init];
    tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    [behaviorCard addSubview:tabBar];

    NSArray<NSString *> *tabTitles = @[@"Emotions", @"Animations", @"Dances"];
    NSMutableArray<CPButton *> *tabs = [NSMutableArray array];
    CGFloat tabX = 0;
    for (NSInteger i = 0; i < (NSInteger)tabTitles.count; i++) {
        BOOL active = (i == 0);
        CPButton *tab = [[CPButton alloc] initWithFrame:NSMakeRect(tabX, 1, 100, 30)];
        tab.layer.cornerRadius = 8;
        tab.tag = i; tab.target = self; tab.action = @selector(tabSelected:);
        [tab styleTitle:tabTitles[i]
                  color:active ? pRGB(4,14,8) : pRGBA(255,255,255,0.55) size:12];
        tab.fillColor   = active ? pRGB(61,222,153) : pRGBA(255,255,255,0);
        tab.borderColor = active ? nil : pRGBA(255,255,255,0.14);
        [tabBar addSubview:tab];
        [tabs addObject:tab];
        tabX += 108;
    }
    self.tabBtns = tabs;

    // Behavior status label
    NSTextField *bStatus = [NSTextField labelWithString:@""];
    bStatus.translatesAutoresizingMaskIntoConstraints = NO;
    bStatus.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    bStatus.textColor = pRGBA(202,211,223,0.55);
    bStatus.alignment = NSTextAlignmentRight;
    self.behaviorStatusLabel = bStatus;
    [behaviorCard addSubview:bStatus];

    // Serial port label
    NSTextField *portLbl = [NSTextField labelWithString:@""];
    portLbl.translatesAutoresizingMaskIntoConstraints = NO;
    portLbl.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    portLbl.textColor = pRGBA(202,211,223,0.40);
    portLbl.alignment = NSTextAlignmentRight;
    self.serialPortLabel = portLbl;
    [behaviorCard addSubview:portLbl];

    // Behavior grid + scroll view
    BehaviorGridView *grid = [[BehaviorGridView alloc] initWithFrame:NSMakeRect(0,0,960,300)];
    __weak typeof(self) ws = self;
    grid.onPlay = ^(NSString *m, NSString *d) { [ws playMove:m dataset:d]; };
    self.behaviorGrid = grid;

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    scroll.documentView = grid;
    self.behaviorScroll = scroll;
    [behaviorCard addSubview:scroll];

    // Behavior zone constraints
    [NSLayoutConstraint activateConstraints:@[
        // Divider at very top of behavior zone
        [div.topAnchor constraintEqualToAnchor:behaviorCard.topAnchor],
        [div.leadingAnchor constraintEqualToAnchor:behaviorCard.leadingAnchor],
        [div.trailingAnchor constraintEqualToAnchor:behaviorCard.trailingAnchor],
        [div.heightAnchor constraintEqualToConstant:1],
        // Tab bar: 20pt from left, 44pt tall, below divider
        [tabBar.topAnchor constraintEqualToAnchor:div.bottomAnchor],
        [tabBar.leadingAnchor constraintEqualToAnchor:behaviorCard.leadingAnchor constant:20],
        [tabBar.widthAnchor constraintEqualToConstant:tabX],
        [tabBar.heightAnchor constraintEqualToConstant:44],
        // Behavior status: right side of tab bar row
        [bStatus.centerYAnchor constraintEqualToAnchor:tabBar.centerYAnchor],
        [bStatus.trailingAnchor constraintEqualToAnchor:portLbl.leadingAnchor constant:-12],
        [bStatus.widthAnchor constraintEqualToConstant:110],
        // Serial port: trailing edge
        [portLbl.centerYAnchor constraintEqualToAnchor:tabBar.centerYAnchor],
        [portLbl.trailingAnchor constraintEqualToAnchor:behaviorCard.trailingAnchor constant:-16],
        [portLbl.widthAnchor constraintEqualToConstant:220],
        // Scroll view: fills everything below tab bar
        [scroll.topAnchor constraintEqualToAnchor:tabBar.bottomAnchor constant:4],
        [scroll.leadingAnchor constraintEqualToAnchor:behaviorCard.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:behaviorCard.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:behaviorCard.bottomAnchor],
    ]];

    // Load behaviors once layout is settled
    dispatch_async(dispatch_get_main_queue(), ^{
        [self loadBehaviorsForDataset:@"emotions"];
    });

    // Resize notification to relayout tiles when window resizes
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(scrollViewResized:)
        name:NSViewFrameDidChangeNotification
        object:scroll];
    scroll.postsFrameChangedNotifications = YES;
}

// ─── SVG ─────────────────────────────────────────────────────────────────────

- (void)loadRobotSVG:(NSString *)variant {
    NSString *path = [[[NSBundle mainBundle] resourcePath]
                      stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"reachy-mini-%@.svg", variant]];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSString *b64  = [data base64EncodedStringWithOptions:0];
    NSString *html = [NSString stringWithFormat:
        @"<html><head><style>"
         "*{margin:0;padding:0;box-sizing:border-box}"
         "html,body{width:100%%;height:100%%;overflow:hidden;background:transparent}"
         "img{width:100%%;height:100%%;object-fit:cover;display:block}"
         "</style></head><body>"
         "<img src=\"data:image/svg+xml;base64,%@\"/>"
         "</body></html>", b64];
    [self.robotView loadHTMLString:html baseURL:nil];
}

// ─── Scroll view resize → relayout tiles ─────────────────────────────────────

- (void)scrollViewResized:(NSNotification *)n {
    CGFloat w = self.behaviorScroll.frame.size.width;
    if (w < 10) return;
    NSString *ds = kDatasets[self.selectedTab];
    NSArray *moves = self.movesCache[ds];
    if (!moves.count) return;
    if (fabs(self.behaviorGrid.frame.size.width - w) > 2) {
        self.behaviorGrid.frame = NSMakeRect(0, 0, w, self.behaviorGrid.frame.size.height);
        [self.behaviorGrid reloadMoves:moves dataset:ds];
    }
}

// ─── Polling ─────────────────────────────────────────────────────────────────

- (void)startPolling {
    if (self.pollTimer) return;
    [self pollStatus];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
        target:self selector:@selector(pollStatus) userInfo:nil repeats:YES];
}
- (void)stopPolling { [self.pollTimer invalidate]; self.pollTimer = nil; }

- (void)pollStatus {
    [[AppDelegate shared].httpClient getJSON:@"/api/daemon/status"
                                  completion:^(id json, NSError *err) {
        if (![json isKindOfClass:[NSDictionary class]]) {
            [self applyState:CPStateUnknown name:nil error:nil port:nil]; return;
        }
        NSDictionary *d = json;
        NSString *name  = d[@"robot_name"];
        NSString *error = d[@"error"];
        NSString *port  = nil;
        id backend = d[@"backend_status"];
        if ([backend isKindOfClass:[NSDictionary class]]) port = backend[@"serial_port"];
        [self applyState:[self stateFor:d[@"state"]] name:name error:error port:port];
    }];
}

- (CPState)stateFor:(NSString *)s {
    if ([s isEqualToString:@"running"])         return CPStateRunning;
    if ([s isEqualToString:@"starting"])        return CPStateStarting;
    if ([s isEqualToString:@"stopping"])        return CPStateStopping;
    if ([s isEqualToString:@"stopped"])         return CPStateStopped;
    if ([s isEqualToString:@"error"])           return CPStateError;
    if ([s isEqualToString:@"not_initialized"]) return CPStateNotInitialized;
    return CPStateUnknown;
}

// ─── State → UI ───────────────────────────────────────────────────────────────

- (void)applyState:(CPState)s name:(NSString *)name error:(NSString *)err port:(NSString *)port {
    CPState prev = self.currentState;
    self.currentState = s;

    // Robot name
    NSString *dn = name.length ? name : @"Reachy Mini";
    if (![dn isEqualToString:self.currentRobotName]) {
        self.currentRobotName = dn;
        self.robotNameLabel.stringValue = dn;
    }

    // Auto-load behaviors on first connect
    if (s == CPStateRunning && prev != CPStateRunning)
        if (!self.movesCache[kDatasets[self.selectedTab]].count)
            [self loadBehaviorsForDataset:kDatasets[self.selectedTab]];

    BOOL connected  = (s == CPStateRunning);
    BOOL connecting = (s == CPStateStarting || s == CPStateStopping);
    BOOL canConnect = !connected && !connecting;

    // Badge + detail + SVG
    switch (s) {
        case CPStateRunning:
            [self.stateBadge setTitle:@"● Connected"
                                 fill:pRGBA(61,222,153,0.18) text:pRGB(61,222,153)];
            [self.stateBadge invalidateIntrinsicContentSize];
            self.statusDetailLabel.stringValue = self.robotIsAwake
                ? @"Reachy is awake and ready."
                : @"Connected — press Wake Up to start.";
            self.statusDetailLabel.textColor = pRGBA(202,211,223,0.55);
            if (prev != CPStateRunning && !self.robotIsAwake) [self loadRobotSVG:@"sleeping"];
            break;
        case CPStateStarting:
            [self.stateBadge setTitle:@"● Connecting"
                                 fill:pRGBA(255,255,255,0.08) text:pRGBA(202,211,223,0.78)];
            [self.stateBadge invalidateIntrinsicContentSize];
            self.statusDetailLabel.stringValue = @"Establishing connection to robot…";
            self.statusDetailLabel.textColor = pRGBA(202,211,223,0.55);
            if (prev != CPStateStarting) [self loadRobotSVG:@"sleeping"];
            break;
        case CPStateStopping:
            [self.stateBadge setTitle:@"● Sleeping"
                                 fill:pRGBA(255,255,255,0.08) text:pRGBA(202,211,223,0.78)];
            [self.stateBadge invalidateIntrinsicContentSize];
            self.statusDetailLabel.stringValue = @"Going to sleep…";
            self.statusDetailLabel.textColor = pRGBA(202,211,223,0.55);
            break;
        case CPStateError:
            [self.stateBadge setTitle:@"● Error"
                                 fill:pRGBA(255,120,120,0.16) text:pRGB(255,120,120)];
            [self.stateBadge invalidateIntrinsicContentSize];
            self.statusDetailLabel.stringValue = err.length ? err : @"Connection failed.";
            self.statusDetailLabel.textColor = pRGBA(255,100,100,0.90);
            if (prev != CPStateError) { self.robotIsAwake = NO; [self loadRobotSVG:@"ko"]; }
            break;
        default:
            [self.stateBadge setTitle:@"● Disconnected"
                                 fill:pRGBA(255,120,120,0.12) text:pRGBA(255,120,120,0.90)];
            [self.stateBadge invalidateIntrinsicContentSize];
            self.statusDetailLabel.stringValue = (s == CPStateUnknown)
                ? @"Waiting for daemon…" : @"Not connected.";
            self.statusDetailLabel.textColor = pRGBA(202,211,223,0.55);
            if (prev != s) { self.robotIsAwake = NO; [self loadRobotSVG:@"sleeping"]; }
            break;
    }

    // Spinner
    self.spinner.hidden = !connecting;

    // Buttons
    if (connected) {
        [self.primaryBtn styleTitle:@"▶  Wake Up" color:pRGB(4,14,8) size:14];
        self.primaryBtn.fillColor = pRGB(61,222,153);
        self.primaryBtn.enabled = YES;
        self.primaryBtn.hidden = NO;
        self.sleepBtn.hidden = NO;
    } else if (canConnect) {
        [self.primaryBtn styleTitle:@"Connect" color:pRGB(4,14,8) size:14];
        self.primaryBtn.fillColor = pRGB(61,222,153);
        self.primaryBtn.enabled = YES;
        self.primaryBtn.hidden = NO;
        self.sleepBtn.hidden = YES;
    } else {
        self.primaryBtn.enabled = NO;
        self.primaryBtn.hidden = YES;
        self.sleepBtn.hidden = YES;
    }

    // Tiles: only interactive when connected
    self.behaviorGrid.movesEnabled = connected;

    // Serial port
    self.serialPortLabel.stringValue = port ?: @"";
}

// ─── Button actions ───────────────────────────────────────────────────────────

- (void)primaryBtnClicked:(id)sender {
    if (self.currentState == CPStateRunning) {
        // Wake Up
        self.primaryBtn.enabled = NO;
        [[AppDelegate shared].httpClient postAction:@"/api/move/play/wake_up"
                                               body:nil completion:^(id j, NSError *e) {
            if (!e) {
                self.robotIsAwake = YES;
                self.statusDetailLabel.stringValue = @"Reachy is awake and ready.";
                [self loadRobotSVG:@"awake"];
            }
            self.primaryBtn.enabled = YES;
        }];
    } else {
        // Connect
        self.primaryBtn.enabled = NO;
        [[AppDelegate shared].httpClient postJSON:@"/api/daemon/start?wake_up=false"
                                            body:nil completion:^(id j, NSError *e) {
            // state will update via poll
        }];
        [self.stateBadge setTitle:@"● Connecting"
                             fill:pRGBA(255,255,255,0.08) text:pRGBA(202,211,223,0.78)];
        [self.stateBadge invalidateIntrinsicContentSize];
        self.statusDetailLabel.stringValue = @"Establishing connection to robot…";
    }
}

- (void)sleepBtnClicked:(id)sender {
    self.sleepBtn.enabled = NO;
    [[AppDelegate shared].httpClient postAction:@"/api/move/play/goto_sleep"
                                           body:nil completion:^(id j, NSError *e) {
        self.robotIsAwake = NO;
        [self loadRobotSVG:@"sleeping"];
        self.statusDetailLabel.stringValue = @"Connected — press Wake Up to start.";
        self.sleepBtn.enabled = YES;
    }];
}

// ─── Dataset tabs ─────────────────────────────────────────────────────────────

- (void)tabSelected:(CPButton *)tab {
    NSInteger idx = tab.tag;
    if (idx == self.selectedTab) return;
    self.selectedTab = idx;

    NSArray<NSString *> *titles = @[@"Emotions", @"Animations", @"Dances"];
    for (NSInteger i = 0; i < (NSInteger)self.tabBtns.count; i++) {
        BOOL active = (i == idx);
        CPButton *t = self.tabBtns[i];
        [t styleTitle:titles[i]
                color:active ? pRGB(4,14,8) : pRGBA(255,255,255,0.55) size:12];
        t.fillColor   = active ? pRGB(61,222,153) : pRGBA(255,255,255,0);
        t.borderColor = active ? nil : pRGBA(255,255,255,0.14);
    }

    NSString *ds = kDatasets[idx];
    NSArray *cached = self.movesCache[ds];
    if (cached.count) {
        [self showMoves:cached dataset:ds];
    } else {
        self.behaviorStatusLabel.stringValue = @"Loading…";
        [self loadBehaviorsForDataset:ds];
    }
}

// ─── Behaviors ────────────────────────────────────────────────────────────────

- (void)loadBehaviorsForDataset:(NSString *)dataset {
    NSString *path = [NSString stringWithFormat:
                      @"/api/move/recorded-move-datasets/list/%@", dataset];
    [[AppDelegate shared].httpClient getJSON:path completion:^(id json, NSError *err) {
        NSArray<NSString *> *moves = nil;
        if ([json isKindOfClass:[NSArray class]])          moves = json;
        else if ([json isKindOfClass:[NSDictionary class]]) moves = json[@"moves"] ?: json[@"list"];

        if (moves.count) {
            // Cache and display only on success
            self.movesCache[dataset] = moves;
            if ([kDatasets[self.selectedTab] isEqualToString:dataset])
                [self showMoves:moves dataset:dataset];
        } else if (!err) {
            // Empty dataset (not an error)
            self.movesCache[dataset] = @[];
            if ([kDatasets[self.selectedTab] isEqualToString:dataset]) {
                self.behaviorStatusLabel.stringValue = @"No moves";
            }
        }
        // On error (401, network fail): don't cache, silently retry on next connect
    }];
}

- (void)showMoves:(NSArray<NSString *> *)moves dataset:(NSString *)ds {
    CGFloat w = MAX(self.behaviorScroll.frame.size.width, 100);
    self.behaviorGrid.frame = NSMakeRect(0, 0, w, self.behaviorGrid.frame.size.height);
    self.behaviorGrid.playingMove = self.playingMoveName;
    self.behaviorGrid.movesEnabled = (self.currentState == CPStateRunning);
    [self.behaviorGrid reloadMoves:moves dataset:ds];
    NSUInteger n = moves.count;
    self.behaviorStatusLabel.stringValue = n
        ? [NSString stringWithFormat:@"%lu move%@", n, n == 1 ? @"" : @"s"]
        : @"No moves";
}

- (void)playMove:(NSString *)move dataset:(NSString *)dataset {
    if (self.behaviorPlaying) return;
    self.behaviorPlaying = YES;
    self.playingMoveName = move;
    self.behaviorGrid.playingMove = move;
    self.behaviorStatusLabel.stringValue = [NSString stringWithFormat:@"▶ %@…",
                                            displayNameForMove(move)];
    NSString *path = [NSString stringWithFormat:
                      @"/api/move/play/recorded-move-dataset/%@/%@", dataset, move];
    [[AppDelegate shared].httpClient postAction:path body:nil completion:^(id j, NSError *e) {
        self.behaviorPlaying = NO;
        self.playingMoveName = nil;
        self.behaviorGrid.playingMove = nil;
        NSArray *moves = self.movesCache[kDatasets[self.selectedTab]];
        self.behaviorStatusLabel.stringValue = moves.count
            ? [NSString stringWithFormat:@"%lu moves", (unsigned long)moves.count] : @"";
    }];
}

@end
