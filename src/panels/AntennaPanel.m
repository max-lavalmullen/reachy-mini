#import "AntennaPanel.h"
#import "../AppDelegate.h"
#import "../HTTPClient.h"
#import "../widgets/JoystickView.h"

// ── Palette ───────────────────────────────────────────────────────────────────

static inline NSColor *cRGB(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}
static inline NSColor *cRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}

// ── AntennaKnobView ───────────────────────────────────────────────────────────
// Circular arc dial: drag the green thumb along the arc to set antenna angle.
// Internally stores value in degrees (-60…+60). Caller converts to radians.

static const CGFloat kKW = 165, kKH = 190;  // card size
static const CGFloat kKCY = 112;             // arc-circle center, Y from bottom
static const CGFloat kKR  = 60;              // arc radius
// Arc spans from drawAngle 30° (value=+60°) to 150° (value=-60°), neutral at 90° (up)
// drawAngle = 90 - value    ↔    value = 90 - drawAngle
static const CGFloat kKMin = 30.0, kKMax = 150.0, kKNeu = 90.0;

@interface AntennaKnobView : NSView
@property (nonatomic, assign) CGFloat   value;       // degrees −60…+60
@property (nonatomic, copy)   NSString *knobLabel;   // "Left" / "Right"
@property (nonatomic, copy)   void (^onChanged)(CGFloat deg);
@end

@implementation AntennaKnobView

- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 16;
        self.layer.backgroundColor = cRGB(14,25,42).CGColor;
        self.layer.borderColor     = cRGBA(255,255,255,0.08).CGColor;
        self.layer.borderWidth     = 0.5;
    }
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (void)drawRect:(NSRect)dirty {
    CGFloat cx = NSWidth(self.bounds) / 2.0;
    CGFloat cy = kKCY;
    CGFloat r  = kKR;

    // ── Full-range background arc ──────────────────────────────────────────────
    NSBezierPath *bg = [NSBezierPath bezierPath];
    [bg appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy)
                                   radius:r
                               startAngle:kKMin endAngle:kKMax clockwise:NO];
    bg.lineWidth = 9; bg.lineCapStyle = NSLineCapStyleRound;
    [cRGBA(255,255,255,0.11) setStroke]; [bg stroke];

    // ── Current-value arc (green, neutral → thumb) ────────────────────────────
    CGFloat thumbAngle = kKNeu - self.value;
    thumbAngle = MAX(kKMin, MIN(kKMax, thumbAngle));
    if (fabs(self.value) > 0.3) {
        NSBezierPath *va = [NSBezierPath bezierPath];
        [va appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy)
                                       radius:r
                                   startAngle:MIN(thumbAngle, kKNeu)
                                     endAngle:MAX(thumbAngle, kKNeu)
                                    clockwise:NO];
        va.lineWidth = 9; va.lineCapStyle = NSLineCapStyleRound;
        [cRGB(61,222,153) setStroke]; [va stroke];
    }

    // ── Neutral tick ──────────────────────────────────────────────────────────
    CGFloat nRad = kKNeu * M_PI / 180.0;
    NSBezierPath *tick = [NSBezierPath bezierPath];
    [tick moveToPoint:NSMakePoint(cx + (r-7)*cos(nRad), cy + (r-7)*sin(nRad))];
    [tick lineToPoint:NSMakePoint(cx + (r+6)*cos(nRad), cy + (r+6)*sin(nRad))];
    tick.lineWidth = 2; [cRGBA(255,255,255,0.35) setStroke]; [tick stroke];

    // ── Arm from center to thumb ───────────────────────────────────────────────
    CGFloat tRad = thumbAngle * M_PI / 180.0;
    CGFloat tx = cx + r * cos(tRad), ty = cy + r * sin(tRad);
    NSBezierPath *arm = [NSBezierPath bezierPath];
    [arm moveToPoint:NSMakePoint(cx, cy)];
    [arm lineToPoint:NSMakePoint(tx, ty)];
    arm.lineWidth = 1.5; [cRGBA(255,255,255,0.18) setStroke]; [arm stroke];

    // ── Center dot ────────────────────────────────────────────────────────────
    [cRGBA(255,255,255,0.28) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx-4,cy-4,8,8)] fill];

    // ── Thumb ─────────────────────────────────────────────────────────────────
    [cRGB(61,222,153) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(tx-10,ty-10,20,20)] fill];
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(tx-3.5,ty-3.5,7,7)] fill];

    // ── Value label ───────────────────────────────────────────────────────────
    NSString *valStr = [NSString stringWithFormat:@"%+.1f°", self.value];
    NSDictionary *vA = @{
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:16 weight:NSFontWeightSemibold],
    };
    NSSize vSz = [valStr sizeWithAttributes:vA];
    [valStr drawAtPoint:NSMakePoint(cx - vSz.width/2, 45) withAttributes:vA];

    // ── Name label ────────────────────────────────────────────────────────────
    NSString *nameStr = self.knobLabel ?: @"";
    NSDictionary *nA = @{
        NSForegroundColorAttributeName: cRGBA(255,255,255,0.40),
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
    };
    NSSize nSz = [nameStr sizeWithAttributes:nA];
    [nameStr drawAtPoint:NSMakePoint(cx - nSz.width/2, 22) withAttributes:nA];
}

// ── Mouse tracking ────────────────────────────────────────────────────────────

- (void)mouseDown:(NSEvent *)e    { [self trackEvent:e]; }
- (void)mouseDragged:(NSEvent *)e { [self trackEvent:e]; }

- (void)trackEvent:(NSEvent *)e {
    NSPoint p  = [self convertPoint:e.locationInWindow fromView:nil];
    CGFloat cx = NSWidth(self.bounds) / 2.0;
    CGFloat cy = kKCY;
    CGFloat dx = p.x - cx, dy = p.y - cy;
    if (dx*dx + dy*dy < 64) return;  // dead zone near center

    CGFloat angleDeg = atan2(dy, dx) * 180.0 / M_PI;
    CGFloat newVal   = MAX(-60.0, MIN(60.0, kKNeu - angleDeg));
    if (fabs(newVal - self.value) > 0.05) {
        self.value = newVal;
        [self setNeedsDisplay:YES];
        if (self.onChanged) self.onChanged(newVal);
    }
}

@end

// ── AntennaPanel (Combined Head & Antenna Controls) ───────────────────────────

@interface AntennaPanel () <JoystickViewDelegate>
// Head
@property (nonatomic, strong) JoystickView *joystick;
@property (nonatomic, strong) NSSlider     *rollSlider;
@property (nonatomic, strong) NSTextField  *panLabel, *tiltLabel, *rollLabel;
@property (nonatomic, assign) CGFloat       currentPan, currentTilt, currentRoll; // radians
@property (nonatomic, assign) BOOL          headDirty;
// Antennas
@property (nonatomic, strong) AntennaKnobView *leftKnob, *rightKnob;
@property (nonatomic, assign) CGFloat          leftDeg, rightDeg;  // degrees
@property (nonatomic, assign) BOOL             antennaDirty;
// Timer
@property (nonatomic, strong) NSTimer *sendTimer;
@end

@implementation AntennaPanel

// ── Lifecycle ─────────────────────────────────────────────────────────────────

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0,0,900,720)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = cRGB(5,10,18).CGColor;
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = root;
    [self buildUI];
    self.sendTimer = [NSTimer scheduledTimerWithTimeInterval:0.05  // 20 Hz
        target:self selector:@selector(sendTick) userInfo:nil repeats:YES];
}

- (void)dealloc { [self.sendTimer invalidate]; }

// ── Card / label helpers ──────────────────────────────────────────────────────

- (NSView *)card {
    NSView *c = [[NSView alloc] init];
    c.translatesAutoresizingMaskIntoConstraints = NO;
    c.wantsLayer = YES;
    c.layer.cornerRadius  = 16;
    c.layer.backgroundColor = cRGB(14,25,42).CGColor;
    c.layer.borderColor   = cRGBA(255,255,255,0.08).CGColor;
    c.layer.borderWidth   = 0.5;
    return c;
}

- (NSTextField *)titleLabel:(NSString *)t {
    NSTextField *l = [NSTextField labelWithString:t];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    l.textColor = [NSColor whiteColor];
    return l;
}

- (NSTextField *)hintLabel:(NSString *)t {
    NSTextField *l = [NSTextField labelWithString:t];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [NSFont systemFontOfSize:12];
    l.textColor = cRGBA(202,211,223,0.55);
    return l;
}

- (NSTextField *)readoutLabel:(NSString *)t {
    NSTextField *l = [NSTextField labelWithString:t];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    l.textColor = [NSColor whiteColor];
    return l;
}

- (NSButton *)styledButton:(NSString *)title action:(SEL)action {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.bezelStyle = NSBezelStyleRounded;
    b.wantsLayer = YES;
    b.layer.cornerRadius = 9;
    b.layer.backgroundColor = cRGBA(255,255,255,0.06).CGColor;
    b.layer.borderWidth = 1;
    b.layer.borderColor = cRGBA(255,255,255,0.14).CGColor;
    b.contentTintColor = [NSColor whiteColor];
    return b;
}

// ── Build UI ──────────────────────────────────────────────────────────────────

- (void)buildUI {
    NSView *v = self.view;

    // ─── HEAD CONTROL CARD ────────────────────────────────────────────────────

    NSView *hCard = [self card];
    [v addSubview:hCard];

    NSTextField *hTitle = [self titleLabel:@"Head Control"];
    NSTextField *hHint  = [self hintLabel:@"Drag joystick to pan/tilt · slider for roll"];
    [hCard addSubview:hTitle];
    [hCard addSubview:hHint];

    // Joystick
    JoystickView *joy = [[JoystickView alloc] initWithFrame:NSMakeRect(0,0,180,180)];
    joy.translatesAutoresizingMaskIntoConstraints = NO;
    joy.delegate = self;
    self.joystick = joy;
    [hCard addSubview:joy];

    // Readout labels (right of joystick)
    self.panLabel  = [self readoutLabel:@"Pan    0.0°"];
    self.tiltLabel = [self readoutLabel:@"Tilt   0.0°"];
    self.rollLabel = [self readoutLabel:@"Roll   0.0°"];
    [hCard addSubview:self.panLabel];
    [hCard addSubview:self.tiltLabel];
    [hCard addSubview:self.rollLabel];

    // Roll slider (below joystick, spans width)
    NSTextField *rollLbl = [self hintLabel:@"Roll"];
    rollLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [hCard addSubview:rollLbl];

    NSSlider *rollS = [NSSlider sliderWithValue:0 minValue:-0.4 maxValue:0.4
                                         target:self action:@selector(rollChanged:)];
    rollS.translatesAutoresizingMaskIntoConstraints = NO;
    rollS.sliderType = NSSliderTypeLinear;
    self.rollSlider = rollS;
    [hCard addSubview:rollS];

    NSButton *centerBtn = [self styledButton:@"Center Head" action:@selector(centerHead:)];
    [hCard addSubview:centerBtn];

    // Head card constraints
    [NSLayoutConstraint activateConstraints:@[
        [hCard.topAnchor constraintEqualToAnchor:v.topAnchor constant:20],
        [hCard.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [hCard.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
        [hCard.heightAnchor constraintEqualToConstant:320],

        [hTitle.topAnchor constraintEqualToAnchor:hCard.topAnchor constant:18],
        [hTitle.leadingAnchor constraintEqualToAnchor:hCard.leadingAnchor constant:22],

        [hHint.topAnchor constraintEqualToAnchor:hTitle.bottomAnchor constant:4],
        [hHint.leadingAnchor constraintEqualToAnchor:hCard.leadingAnchor constant:22],

        // Joystick: left side
        [joy.topAnchor constraintEqualToAnchor:hHint.bottomAnchor constant:16],
        [joy.leadingAnchor constraintEqualToAnchor:hCard.leadingAnchor constant:30],
        [joy.widthAnchor constraintEqualToConstant:180],
        [joy.heightAnchor constraintEqualToConstant:180],

        // Readouts: right of joystick
        [self.panLabel.topAnchor constraintEqualToAnchor:joy.topAnchor constant:24],
        [self.panLabel.leadingAnchor constraintEqualToAnchor:joy.trailingAnchor constant:36],

        [self.tiltLabel.topAnchor constraintEqualToAnchor:self.panLabel.bottomAnchor constant:14],
        [self.tiltLabel.leadingAnchor constraintEqualToAnchor:self.panLabel.leadingAnchor],

        [self.rollLabel.topAnchor constraintEqualToAnchor:self.tiltLabel.bottomAnchor constant:14],
        [self.rollLabel.leadingAnchor constraintEqualToAnchor:self.panLabel.leadingAnchor],

        // Roll row: below joystick
        [rollLbl.topAnchor constraintEqualToAnchor:joy.bottomAnchor constant:18],
        [rollLbl.leadingAnchor constraintEqualToAnchor:hCard.leadingAnchor constant:22],
        [rollLbl.widthAnchor constraintEqualToConstant:36],

        [rollS.centerYAnchor constraintEqualToAnchor:rollLbl.centerYAnchor],
        [rollS.leadingAnchor constraintEqualToAnchor:rollLbl.trailingAnchor constant:10],
        [rollS.trailingAnchor constraintEqualToAnchor:hCard.trailingAnchor constant:-22],

        // Center button
        [centerBtn.bottomAnchor constraintEqualToAnchor:hCard.bottomAnchor constant:-16],
        [centerBtn.leadingAnchor constraintEqualToAnchor:hCard.leadingAnchor constant:22],
        [centerBtn.widthAnchor constraintEqualToConstant:130],
        [centerBtn.heightAnchor constraintEqualToConstant:30],
    ]];

    // ─── ANTENNA CARD ─────────────────────────────────────────────────────────

    NSView *aCard = [self card];
    [v addSubview:aCard];

    NSTextField *aTitle = [self titleLabel:@"Antennas"];
    NSTextField *aHint  = [self hintLabel:@"Drag the arc handles to set antenna angles"];
    [aCard addSubview:aTitle];
    [aCard addSubview:aHint];

    // Left knob
    AntennaKnobView *lk = [[AntennaKnobView alloc] initWithFrame:NSMakeRect(0,0,kKW,kKH)];
    lk.translatesAutoresizingMaskIntoConstraints = NO;
    lk.knobLabel = @"Left";
    __weak typeof(self) ws = self;
    lk.onChanged = ^(CGFloat deg) { ws.leftDeg = deg; ws.antennaDirty = YES; };
    self.leftKnob = lk;
    [aCard addSubview:lk];

    // Right knob
    AntennaKnobView *rk = [[AntennaKnobView alloc] initWithFrame:NSMakeRect(0,0,kKW,kKH)];
    rk.translatesAutoresizingMaskIntoConstraints = NO;
    rk.knobLabel = @"Right";
    rk.onChanged = ^(CGFloat deg) { ws.rightDeg = deg; ws.antennaDirty = YES; };
    self.rightKnob = rk;
    [aCard addSubview:rk];

    NSButton *resetBtn = [self styledButton:@"Reset to 0°" action:@selector(resetAntennas:)];
    [aCard addSubview:resetBtn];

    // Antenna card constraints
    [NSLayoutConstraint activateConstraints:@[
        [aCard.topAnchor constraintEqualToAnchor:hCard.bottomAnchor constant:16],
        [aCard.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [aCard.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
        [aCard.heightAnchor constraintEqualToConstant:300],

        [aTitle.topAnchor constraintEqualToAnchor:aCard.topAnchor constant:18],
        [aTitle.leadingAnchor constraintEqualToAnchor:aCard.leadingAnchor constant:22],

        [aHint.topAnchor constraintEqualToAnchor:aTitle.bottomAnchor constant:4],
        [aHint.leadingAnchor constraintEqualToAnchor:aCard.leadingAnchor constant:22],

        // Two knobs centered side-by-side
        [lk.topAnchor constraintEqualToAnchor:aHint.bottomAnchor constant:16],
        [lk.centerXAnchor constraintEqualToAnchor:aCard.centerXAnchor constant:-100],
        [lk.widthAnchor constraintEqualToConstant:kKW],
        [lk.heightAnchor constraintEqualToConstant:kKH],

        [rk.topAnchor constraintEqualToAnchor:aHint.bottomAnchor constant:16],
        [rk.centerXAnchor constraintEqualToAnchor:aCard.centerXAnchor constant:100],
        [rk.widthAnchor constraintEqualToConstant:kKW],
        [rk.heightAnchor constraintEqualToConstant:kKH],

        // Reset button
        [resetBtn.bottomAnchor constraintEqualToAnchor:aCard.bottomAnchor constant:-16],
        [resetBtn.centerXAnchor constraintEqualToAnchor:aCard.centerXAnchor],
        [resetBtn.widthAnchor constraintEqualToConstant:130],
        [resetBtn.heightAnchor constraintEqualToConstant:30],
    ]];
}

// ── 20 Hz send tick — batches head + antenna into one goto call ───────────────

- (void)sendTick {
    if (!self.headDirty && !self.antennaDirty) return;

    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    if (self.headDirty) {
        body[@"head_pose"] = @{
            @"pan":  @(self.currentPan),    // radians
            @"tilt": @(self.currentTilt),   // radians
            @"roll": @(self.currentRoll),   // radians
        };
        self.headDirty = NO;
    }
    if (self.antennaDirty) {
        body[@"antennas"] = @[
            @(self.leftDeg  * M_PI / 180.0),  // convert degrees → radians
            @(self.rightDeg * M_PI / 180.0),
        ];
        self.antennaDirty = NO;
    }
    body[@"duration"] = @0.05;  // short: robot follows in real time

    [[AppDelegate shared].httpClient postJSON:@"/api/move/goto"
                                        body:body
                                  completion:^(id j, NSError *e){}];
}

// ── JoystickViewDelegate ──────────────────────────────────────────────────────

// Joystick sends normalized [-1,1] values. API expects radians.
// ±0.4 rad = ±22.9° (safe range for Reachy Mini head)
- (void)joystickDidMoveToX:(CGFloat)x y:(CGFloat)y {
    self.currentPan  =  x * 0.40;   // radians
    self.currentTilt = -y * 0.35;   // radians, invert Y (joystick is flipped)
    [self updateHeadLabels];
    self.headDirty = YES;
}

- (void)joystickDidRelease {
    self.currentPan  = 0;
    self.currentTilt = 0;
    [self updateHeadLabels];
    self.headDirty = YES;
}

- (void)updateHeadLabels {
    CGFloat pd = self.currentPan  * 180.0 / M_PI;
    CGFloat td = self.currentTilt * 180.0 / M_PI;
    CGFloat rd = self.currentRoll * 180.0 / M_PI;
    self.panLabel.stringValue  = [NSString stringWithFormat:@"Pan   %+.1f°", pd];
    self.tiltLabel.stringValue = [NSString stringWithFormat:@"Tilt  %+.1f°", td];
    self.rollLabel.stringValue = [NSString stringWithFormat:@"Roll  %+.1f°", rd];
}

// ── Roll slider ───────────────────────────────────────────────────────────────

- (void)rollChanged:(NSSlider *)s {
    self.currentRoll = s.doubleValue;  // slider range ±0.4 rad
    [self updateHeadLabels];
    self.headDirty = YES;
}

// ── Button actions ────────────────────────────────────────────────────────────

- (void)centerHead:(id)sender {
    self.currentPan = self.currentTilt = self.currentRoll = 0;
    self.rollSlider.doubleValue = 0;
    [self updateHeadLabels];
    self.headDirty = YES;
}

- (void)resetAntennas:(id)sender {
    self.leftDeg = self.rightDeg = 0;
    self.leftKnob.value  = 0; [self.leftKnob  setNeedsDisplay:YES];
    self.rightKnob.value = 0; [self.rightKnob setNeedsDisplay:YES];
    self.antennaDirty = YES;
}

@end
