#import "MotorPanel.h"
#import "../AppDelegate.h"
#import "../HTTPClient.h"

// ── Palette ───────────────────────────────────────────────────────────────────

static inline NSColor *mRGB(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}
static inline NSColor *mRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}

#define kMAccent  mRGB(61,222,153)
#define kMBgCard  mRGB(14,25,42)
#define kMBgRoot  mRGB(5,10,18)
#define kMTextPri [NSColor whiteColor]
#define kMTextSec mRGBA(202,211,223,0.55)
#define kMBorder  mRGBA(255,255,255,0.08)

// ── Dark NSTableView ──────────────────────────────────────────────────────────

@interface DarkTableView : NSTableView
@end
@implementation DarkTableView
- (NSColor *)backgroundColor { return mRGB(10,18,32); }
- (void)drawBackgroundInClipRect:(NSRect)r {
    [self.backgroundColor setFill]; NSRectFill(r);
}
@end

// ── MotorPanel ────────────────────────────────────────────────────────────────

@interface MotorPanel () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSSegmentedControl *modeControl;
@property (nonatomic, strong) NSTextField        *statusLabel;
@property (nonatomic, strong) DarkTableView      *motorTable;
@property (nonatomic, strong) NSArray            *motorStatus;
@property (nonatomic, strong) NSTimer            *pollTimer;
@end

@implementation MotorPanel

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0,0,900,720)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = kMBgRoot.CGColor;
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = root;
    [self buildUI];
    [self refreshStatus:nil];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
        target:self selector:@selector(refreshStatus:) userInfo:nil repeats:YES];
}

- (void)buildUI {
    NSView *v = self.view;

    // ── Control card ──────────────────────────────────────────────────────────
    NSView *card = [[NSView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 16;
    card.layer.backgroundColor = kMBgCard.CGColor;
    card.layer.borderColor = kMBorder.CGColor;
    card.layer.borderWidth = 0.5;
    [v addSubview:card];

    NSTextField *titleLbl = [NSTextField labelWithString:@"Motors"];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    titleLbl.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    titleLbl.textColor = kMTextPri;
    [card addSubview:titleLbl];

    // Mode label
    NSTextField *modeLbl = [NSTextField labelWithString:@"Mode"];
    modeLbl.translatesAutoresizingMaskIntoConstraints = NO;
    modeLbl.font = [NSFont systemFontOfSize:12];
    modeLbl.textColor = kMTextSec;
    [card addSubview:modeLbl];

    // Segmented control
    self.modeControl = [NSSegmentedControl
        segmentedControlWithLabels:@[@"Enabled", @"Gravity Comp.", @"Disabled"]
                      trackingMode:NSSegmentSwitchTrackingSelectOne
                            target:self action:@selector(modeChanged:)];
    self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.modeControl];

    // Status label
    self.statusLabel = [NSTextField labelWithString:@"Motor mode: —"];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.textColor = kMTextSec;
    [card addSubview:self.statusLabel];

    // Refresh button
    NSButton *refreshBtn = [[NSButton alloc] init];
    refreshBtn.translatesAutoresizingMaskIntoConstraints = NO;
    refreshBtn.title = @"Refresh";
    refreshBtn.bezelStyle = NSBezelStyleRounded;
    refreshBtn.target = self; refreshBtn.action = @selector(refreshStatus:);
    refreshBtn.wantsLayer = YES;
    refreshBtn.layer.cornerRadius = 8;
    refreshBtn.layer.backgroundColor = mRGBA(255,255,255,0.06).CGColor;
    refreshBtn.layer.borderWidth = 1;
    refreshBtn.layer.borderColor = mRGBA(255,255,255,0.14).CGColor;
    refreshBtn.contentTintColor = kMTextPri;
    [card addSubview:refreshBtn];

    // ── Motor table ───────────────────────────────────────────────────────────
    NSView *tableCard = [[NSView alloc] init];
    tableCard.translatesAutoresizingMaskIntoConstraints = NO;
    tableCard.wantsLayer = YES;
    tableCard.layer.cornerRadius = 12;
    tableCard.layer.backgroundColor = mRGB(10,18,32).CGColor;
    tableCard.layer.borderColor = kMBorder.CGColor;
    tableCard.layer.borderWidth = 0.5;
    tableCard.layer.masksToBounds = YES;
    [v addSubview:tableCard];

    self.motorTable = [[DarkTableView alloc] init];
    self.motorTable.dataSource = self;
    self.motorTable.delegate   = self;
    self.motorTable.rowHeight  = 32;
    self.motorTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.motorTable.backgroundColor = mRGB(10,18,32);
    self.motorTable.gridColor = mRGBA(255,255,255,0.05);
    self.motorTable.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;
    self.motorTable.headerView.wantsLayer = YES;
    self.motorTable.headerView.layer.backgroundColor = mRGB(14,22,38).CGColor;

    for (NSArray *col in @[
        @[@"Motor",       @"motor",    @160],
        @[@"Position",    @"position", @120],
        @[@"Temperature", @"temp",     @120],
        @[@"Mode",        @"mode",     @150],
    ]) {
        NSTableColumn *tc = [[NSTableColumn alloc] initWithIdentifier:col[1]];
        tc.title = col[0];
        tc.width = [col[2] floatValue];
        NSTableHeaderCell *hc = [[NSTableHeaderCell alloc] initTextCell:col[0]];
        hc.textColor = mRGBA(202,211,223,0.55);
        hc.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        tc.headerCell = hc;
        [self.motorTable addTableColumn:tc];
    }

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    scroll.documentView = self.motorTable;
    [tableCard addSubview:scroll];

    // ── Constraints ───────────────────────────────────────────────────────────
    [NSLayoutConstraint activateConstraints:@[
        // Control card: top
        [card.topAnchor constraintEqualToAnchor:v.topAnchor constant:20],
        [card.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
        [card.heightAnchor constraintEqualToConstant:120],

        [titleLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [titleLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],

        [modeLbl.centerYAnchor constraintEqualToAnchor:self.modeControl.centerYAnchor],
        [modeLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],
        [modeLbl.widthAnchor constraintEqualToConstant:44],

        [self.modeControl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:14],
        [self.modeControl.leadingAnchor constraintEqualToAnchor:modeLbl.trailingAnchor constant:10],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.modeControl.bottomAnchor constant:8],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],

        [refreshBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [refreshBtn.centerYAnchor constraintEqualToAnchor:self.modeControl.centerYAnchor],
        [refreshBtn.widthAnchor constraintEqualToConstant:80],
        [refreshBtn.heightAnchor constraintEqualToConstant:28],

        // Table card: fills rest
        [tableCard.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:16],
        [tableCard.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [tableCard.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
        [tableCard.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-20],

        [scroll.topAnchor constraintEqualToAnchor:tableCard.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:tableCard.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:tableCard.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:tableCard.bottomAnchor],
    ]];
}

// ── Polling ───────────────────────────────────────────────────────────────────

- (void)refreshStatus:(id)sender {
    [[AppDelegate shared].httpClient getJSON:@"/api/motors/status"
                                  completion:^(id json, NSError *error) {
        if (error || !json) return;
        if ([json isKindOfClass:[NSArray class]])          self.motorStatus = json;
        else if ([json isKindOfClass:[NSDictionary class]]) self.motorStatus = json[@"motors"] ?: @[json];

        NSString *mode = [json isKindOfClass:[NSDictionary class]] ? json[@"mode"] : nil;
        if (mode) {
            NSInteger seg = 0;
            if ([mode containsString:@"gravity"]) seg = 1;
            else if ([mode containsString:@"dis"]) seg = 2;
            self.modeControl.selectedSegment = seg;
            self.statusLabel.stringValue = [NSString stringWithFormat:@"Mode: %@", mode];
        }
        [self.motorTable reloadData];
    }];
}

// ── Mode change ───────────────────────────────────────────────────────────────

- (void)modeChanged:(NSSegmentedControl *)seg {
    NSArray *modes = @[@"enabled", @"gravity_compensation", @"disabled"];
    NSString *mode = modes[seg.selectedSegment];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Setting mode: %@…", mode];
    NSString *path = [NSString stringWithFormat:@"/api/motors/set_mode/%@", mode];
    [[AppDelegate shared].httpClient postJSON:path body:nil completion:^(id json, NSError *error) {
        self.statusLabel.stringValue = error
            ? [NSString stringWithFormat:@"Error: %@", error.localizedDescription]
            : [NSString stringWithFormat:@"Mode: %@", mode];
    }];
}

// ── NSTableViewDataSource ─────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return self.motorStatus.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSTableCellView *cell = [tv makeViewWithIdentifier:col.identifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
        tf.textColor = [NSColor whiteColor];
        [cell addSubview:tf];
        cell.textField = tf;
        cell.identifier = col.identifier;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    NSDictionary *motor = self.motorStatus[row];
    NSString *id_ = col.identifier;
    NSString *text = @"—";
    if ([id_ isEqual:@"motor"])    text = motor[@"name"] ?: [NSString stringWithFormat:@"Motor %ld", row];
    if ([id_ isEqual:@"position"]) text = [NSString stringWithFormat:@"%.2f°", [motor[@"position"] doubleValue]];
    if ([id_ isEqual:@"temp"])     text = [NSString stringWithFormat:@"%.1f°C", [motor[@"temperature"] doubleValue]];
    if ([id_ isEqual:@"mode"])     text = motor[@"mode"] ?: @"—";

    // Color-code temperatures
    if ([id_ isEqual:@"temp"]) {
        double t = [motor[@"temperature"] doubleValue];
        cell.textField.textColor = t > 50 ? mRGB(243,139,168) : t > 40 ? mRGB(249,226,175) : mRGB(61,222,153);
    } else {
        cell.textField.textColor = [NSColor whiteColor];
    }

    cell.textField.stringValue = text;
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tv rowViewForRow:(NSInteger)row {
    NSTableRowView *rv = [[NSTableRowView alloc] init];
    return rv;
}

- (void)tableView:(NSTableView *)tv didAddRowView:(NSTableRowView *)rv forRow:(NSInteger)row {
    rv.backgroundColor = (row % 2 == 0) ? mRGB(10,18,32) : mRGB(12,21,36);
}

- (void)viewWillDisappear { [self.pollTimer invalidate]; self.pollTimer = nil; }

@end
