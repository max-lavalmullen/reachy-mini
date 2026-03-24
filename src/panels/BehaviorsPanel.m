#import "BehaviorsPanel.h"
#import "../AppDelegate.h"
#import "../HTTPClient.h"

// ── Palette ───────────────────────────────────────────────────────────────────

static inline NSColor *bRGB(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}
static inline NSColor *bRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}

// ── Dark table view ───────────────────────────────────────────────────────────

@interface BehDarkTable : NSTableView
@end
@implementation BehDarkTable
- (NSColor *)backgroundColor { return bRGB(10,18,32); }
- (void)drawBackgroundInClipRect:(NSRect)r { [self.backgroundColor setFill]; NSRectFill(r); }
@end

// ── BehaviorsPanel ────────────────────────────────────────────────────────────

@interface BehaviorsPanel () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) BehDarkTable  *movesTable;
@property (nonatomic, strong) NSArray<NSString *> *moves;
@property (nonatomic, strong) NSTextField   *statusLabel;
@property (nonatomic, strong) NSTextField   *datasetField;
@property (nonatomic, strong) NSButton      *playBtn;
@property (nonatomic, strong) NSButton      *wakeUpBtn;
@property (nonatomic, strong) NSButton      *sleepBtn;
@property (nonatomic, assign) BOOL           playing;
@end

@implementation BehaviorsPanel

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0,0,900,720)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = bRGB(5,10,18).CGColor;
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = root;
    self.moves = @[];
    [self buildUI];
    [self loadMoves];
}

- (void)buildUI {
    NSView *v = self.view;

    // ── Top card: controls ────────────────────────────────────────────────────
    NSView *topCard = [[NSView alloc] init];
    topCard.translatesAutoresizingMaskIntoConstraints = NO;
    topCard.wantsLayer = YES;
    topCard.layer.cornerRadius = 16;
    topCard.layer.backgroundColor = bRGB(14,25,42).CGColor;
    topCard.layer.borderColor = bRGBA(255,255,255,0.08).CGColor;
    topCard.layer.borderWidth = 0.5;
    [v addSubview:topCard];

    NSTextField *titleLbl = [NSTextField labelWithString:@"Behaviors"];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    titleLbl.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    titleLbl.textColor = [NSColor whiteColor];
    [topCard addSubview:titleLbl];

    // Dataset row
    NSTextField *dsLbl = [NSTextField labelWithString:@"Dataset"];
    dsLbl.translatesAutoresizingMaskIntoConstraints = NO;
    dsLbl.font = [NSFont systemFontOfSize:12];
    dsLbl.textColor = bRGBA(202,211,223,0.55);
    [topCard addSubview:dsLbl];

    self.datasetField = [[NSTextField alloc] init];
    self.datasetField.translatesAutoresizingMaskIntoConstraints = NO;
    self.datasetField.stringValue = @"emotions";
    self.datasetField.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    self.datasetField.textColor = [NSColor whiteColor];
    self.datasetField.backgroundColor = bRGB(8,14,26);
    self.datasetField.bezeled = NO;
    self.datasetField.drawsBackground = YES;
    self.datasetField.focusRingType = NSFocusRingTypeNone;
    self.datasetField.wantsLayer = YES;
    self.datasetField.layer.cornerRadius = 8;
    self.datasetField.layer.borderWidth = 1;
    self.datasetField.layer.borderColor = bRGBA(255,255,255,0.12).CGColor;
    [topCard addSubview:self.datasetField];

    NSButton *loadBtn = [self pillButton:@"Load" action:@selector(loadMoves)];
    [topCard addSubview:loadBtn];

    // Action buttons row
    self.wakeUpBtn = [self greenButton:@"▶  Wake Up" action:@selector(wakeUp:)];
    self.sleepBtn  = [self ghostButton:@"Goto Sleep" action:@selector(gotoSleep:)];
    [topCard addSubview:self.wakeUpBtn];
    [topCard addSubview:self.sleepBtn];

    // Status label
    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.textColor = bRGBA(202,211,223,0.55);
    [topCard addSubview:self.statusLabel];

    // ── Moves list ────────────────────────────────────────────────────────────
    NSView *listCard = [[NSView alloc] init];
    listCard.translatesAutoresizingMaskIntoConstraints = NO;
    listCard.wantsLayer = YES;
    listCard.layer.cornerRadius = 12;
    listCard.layer.backgroundColor = bRGB(10,18,32).CGColor;
    listCard.layer.borderColor = bRGBA(255,255,255,0.08).CGColor;
    listCard.layer.borderWidth = 0.5;
    listCard.layer.masksToBounds = YES;
    [v addSubview:listCard];

    self.movesTable = [[BehDarkTable alloc] init];
    self.movesTable.dataSource = self;
    self.movesTable.delegate   = self;
    self.movesTable.doubleAction = @selector(playSelected:);
    self.movesTable.target = self;
    self.movesTable.rowHeight = 34;
    self.movesTable.backgroundColor = bRGB(10,18,32);
    self.movesTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.movesTable.headerView = nil;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"move"];
    col.title = @"Move";
    col.width = 400;
    [self.movesTable addTableColumn:col];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    scroll.documentView = self.movesTable;
    [listCard addSubview:scroll];

    // Play button (below list)
    self.playBtn = [self greenButton:@"▶  Play Selected" action:@selector(playSelected:)];
    [v addSubview:self.playBtn];

    // ── Constraints ───────────────────────────────────────────────────────────
    [NSLayoutConstraint activateConstraints:@[
        // Top card
        [topCard.topAnchor constraintEqualToAnchor:v.topAnchor constant:20],
        [topCard.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [topCard.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
        [topCard.heightAnchor constraintEqualToConstant:160],

        [titleLbl.topAnchor constraintEqualToAnchor:topCard.topAnchor constant:18],
        [titleLbl.leadingAnchor constraintEqualToAnchor:topCard.leadingAnchor constant:22],

        // Dataset row
        [dsLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:14],
        [dsLbl.leadingAnchor constraintEqualToAnchor:topCard.leadingAnchor constant:22],
        [dsLbl.widthAnchor constraintEqualToConstant:60],

        [self.datasetField.centerYAnchor constraintEqualToAnchor:dsLbl.centerYAnchor],
        [self.datasetField.leadingAnchor constraintEqualToAnchor:dsLbl.trailingAnchor constant:10],
        [self.datasetField.widthAnchor constraintEqualToConstant:160],
        [self.datasetField.heightAnchor constraintEqualToConstant:30],

        [loadBtn.centerYAnchor constraintEqualToAnchor:dsLbl.centerYAnchor],
        [loadBtn.leadingAnchor constraintEqualToAnchor:self.datasetField.trailingAnchor constant:10],
        [loadBtn.widthAnchor constraintEqualToConstant:72],
        [loadBtn.heightAnchor constraintEqualToConstant:30],

        // Wake up / sleep buttons
        [self.wakeUpBtn.topAnchor constraintEqualToAnchor:dsLbl.bottomAnchor constant:14],
        [self.wakeUpBtn.leadingAnchor constraintEqualToAnchor:topCard.leadingAnchor constant:22],
        [self.wakeUpBtn.widthAnchor constraintEqualToConstant:130],
        [self.wakeUpBtn.heightAnchor constraintEqualToConstant:34],

        [self.sleepBtn.topAnchor constraintEqualToAnchor:self.wakeUpBtn.topAnchor],
        [self.sleepBtn.leadingAnchor constraintEqualToAnchor:self.wakeUpBtn.trailingAnchor constant:10],
        [self.sleepBtn.widthAnchor constraintEqualToConstant:120],
        [self.sleepBtn.heightAnchor constraintEqualToConstant:34],

        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.wakeUpBtn.centerYAnchor],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.sleepBtn.trailingAnchor constant:20],

        // List card
        [listCard.topAnchor constraintEqualToAnchor:topCard.bottomAnchor constant:16],
        [listCard.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [listCard.widthAnchor constraintEqualToConstant:420],
        [listCard.bottomAnchor constraintEqualToAnchor:self.playBtn.topAnchor constant:-12],

        [scroll.topAnchor constraintEqualToAnchor:listCard.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:listCard.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:listCard.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:listCard.bottomAnchor],

        // Play button
        [self.playBtn.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-20],
        [self.playBtn.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [self.playBtn.widthAnchor constraintEqualToConstant:160],
        [self.playBtn.heightAnchor constraintEqualToConstant:38],
    ]];
}

// ── Button helpers ────────────────────────────────────────────────────────────

- (NSButton *)greenButton:(NSString *)title action:(SEL)action {
    NSButton *b = [[NSButton alloc] init];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.title = title;
    b.bezelStyle = NSBezelStyleRounded;
    b.target = self; b.action = action;
    b.wantsLayer = YES;
    b.layer.cornerRadius = 10;
    b.layer.backgroundColor = bRGBA(61,222,153,0.18).CGColor;
    b.layer.borderWidth = 1;
    b.layer.borderColor = bRGBA(61,222,153,0.55).CGColor;
    b.contentTintColor = bRGB(61,222,153);
    b.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    return b;
}

- (NSButton *)ghostButton:(NSString *)title action:(SEL)action {
    NSButton *b = [[NSButton alloc] init];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.title = title;
    b.bezelStyle = NSBezelStyleRounded;
    b.target = self; b.action = action;
    b.wantsLayer = YES;
    b.layer.cornerRadius = 10;
    b.layer.backgroundColor = bRGBA(255,255,255,0.04).CGColor;
    b.layer.borderWidth = 1;
    b.layer.borderColor = bRGBA(255,255,255,0.18).CGColor;
    b.contentTintColor = [NSColor whiteColor];
    b.font = [NSFont systemFontOfSize:13];
    return b;
}

- (NSButton *)pillButton:(NSString *)title action:(SEL)action {
    NSButton *b = [[NSButton alloc] init];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.title = title;
    b.bezelStyle = NSBezelStyleRounded;
    b.target = self; b.action = action;
    b.wantsLayer = YES;
    b.layer.cornerRadius = 8;
    b.layer.backgroundColor = bRGBA(255,255,255,0.06).CGColor;
    b.layer.borderWidth = 1;
    b.layer.borderColor = bRGBA(255,255,255,0.14).CGColor;
    b.contentTintColor = [NSColor whiteColor];
    return b;
}

// ── Data loading ──────────────────────────────────────────────────────────────

- (void)loadMoves {
    NSString *dataset = self.datasetField.stringValue.length ? self.datasetField.stringValue : @"emotions";
    NSString *path = [NSString stringWithFormat:@"/api/move/recorded-move-datasets/list/%@", dataset];
    self.statusLabel.stringValue = @"Loading…";

    [[AppDelegate shared].httpClient getJSON:path completion:^(id json, NSError *error) {
        if (error) {
            self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", error.localizedDescription];
            return;
        }
        NSArray *list = nil;
        if ([json isKindOfClass:[NSArray class]])           list = json;
        else if ([json isKindOfClass:[NSDictionary class]]) list = json[@"moves"] ?: json[@"list"];

        self.moves = list ?: @[];
        NSUInteger n = self.moves.count;
        self.statusLabel.stringValue = n
            ? [NSString stringWithFormat:@"%lu move%@", n, n == 1 ? @"" : @"s"]
            : @"No moves";
        [self.movesTable reloadData];
    }];
}

// ── Playback ──────────────────────────────────────────────────────────────────

- (void)playSelected:(id)sender {
    NSInteger row = self.movesTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.moves.count) {
        self.statusLabel.stringValue = @"Select a move first";
        return;
    }
    [self playMove:self.moves[row]
           dataset:self.datasetField.stringValue.length ? self.datasetField.stringValue : @"emotions"];
}

- (void)playMove:(NSString *)move dataset:(NSString *)dataset {
    if (self.playing) return;
    self.playing = YES;
    self.statusLabel.stringValue = [NSString stringWithFormat:@"▶ %@…", move];
    self.playBtn.enabled = NO;

    NSString *path = [NSString stringWithFormat:@"/api/move/play/recorded-move-dataset/%@/%@", dataset, move];
    [[AppDelegate shared].httpClient postAction:path body:nil completion:^(id json, NSError *error) {
        self.playing = NO;
        self.playBtn.enabled = YES;
        self.statusLabel.stringValue = error
            ? [NSString stringWithFormat:@"Error: %@", error.localizedDescription]
            : [NSString stringWithFormat:@"✓ %@", move];
    }];
}

- (void)wakeUp:(id)sender {
    self.wakeUpBtn.enabled = NO;
    self.statusLabel.stringValue = @"Waking up…";
    [[AppDelegate shared].httpClient postAction:@"/api/move/play/wake_up"
                                           body:nil completion:^(id json, NSError *error) {
        self.wakeUpBtn.enabled = YES;
        self.statusLabel.stringValue = error ? error.localizedDescription : @"Awake!";
    }];
}

- (void)gotoSleep:(id)sender {
    self.sleepBtn.enabled = NO;
    self.statusLabel.stringValue = @"Going to sleep…";
    [[AppDelegate shared].httpClient postAction:@"/api/move/play/goto_sleep"
                                           body:nil completion:^(id json, NSError *error) {
        self.sleepBtn.enabled = YES;
        self.statusLabel.stringValue = error ? error.localizedDescription : @"Sleeping.";
    }];
}

// ── NSTableViewDataSource ─────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return self.moves.count; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSTableCellView *cell = [tv makeViewWithIdentifier:@"moveCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
        tf.textColor = [NSColor whiteColor];
        [cell addSubview:tf];
        cell.textField = tf;
        cell.identifier = @"moveCell";
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:14],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    cell.textField.stringValue = self.moves[row];
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tv rowViewForRow:(NSInteger)row {
    return [[NSTableRowView alloc] init];
}

- (void)tableView:(NSTableView *)tv didAddRowView:(NSTableRowView *)rv forRow:(NSInteger)row {
    rv.backgroundColor = (row % 2 == 0) ? bRGB(10,18,32) : bRGB(12,21,36);
}

@end
