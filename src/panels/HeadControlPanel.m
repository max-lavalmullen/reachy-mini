#import "HeadControlPanel.h"
#import "../AppDelegate.h"
#import "../HTTPClient.h"
#import "../widgets/JoystickView.h"

@interface HeadControlPanel () <JoystickViewDelegate>
@property (nonatomic, strong) JoystickView *joystick;
@property (nonatomic, strong) NSSlider *rollSlider;
@property (nonatomic, strong) NSTextField *panLabel;
@property (nonatomic, strong) NSTextField *tiltLabel;
@property (nonatomic, strong) NSTextField *rollLabel;
@property (nonatomic, assign) CGFloat currentPan;
@property (nonatomic, assign) CGFloat currentTilt;
@property (nonatomic, assign) CGFloat currentRoll;
@property (nonatomic, strong) NSTimer *sendTimer;
@property (nonatomic, assign) BOOL dirty;
@end

@implementation HeadControlPanel

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,700,500)];
    [self buildUI];
}

- (void)buildUI {
    NSView *v = self.view;

    NSTextField *title = [NSTextField labelWithString:@"Head Control"];
    title.font = [NSFont boldSystemFontOfSize:18];
    title.frame = NSMakeRect(30, 450, 400, 28);
    [v addSubview:title];

    NSTextField *hint = [NSTextField labelWithString:@"Drag the joystick to pan/tilt. Slider = roll."];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.frame = NSMakeRect(30, 424, 500, 18);
    [v addSubview:hint];

    // Joystick
    CGFloat joySize = 220;
    self.joystick = [[JoystickView alloc] initWithFrame:
                     NSMakeRect(30, 160, joySize, joySize)];
    self.joystick.delegate = self;
    [v addSubview:self.joystick];

    // Readouts
    self.panLabel  = [self readoutLabel:@"Pan:   0.00°"  x:270 y:330];
    self.tiltLabel = [self readoutLabel:@"Tilt:  0.00°"  x:270 y:305];
    self.rollLabel = [self readoutLabel:@"Roll:  0.00°"  x:270 y:280];
    [v addSubview:self.panLabel];
    [v addSubview:self.tiltLabel];
    [v addSubview:self.rollLabel];

    // Roll slider
    NSTextField *rollTitle = [NSTextField labelWithString:@"Roll"];
    rollTitle.frame = NSMakeRect(30, 130, 60, 18);
    [v addSubview:rollTitle];

    self.rollSlider = [NSSlider sliderWithValue:0 minValue:-30 maxValue:30
                                         target:self action:@selector(rollChanged:)];
    self.rollSlider.frame = NSMakeRect(90, 130, 300, 22);
    self.rollSlider.sliderType = NSSliderTypeLinear;
    [v addSubview:self.rollSlider];

    // Center button
    NSButton *center = [NSButton buttonWithTitle:@"Center Head"
                                          target:self
                                          action:@selector(centerHead:)];
    center.frame = NSMakeRect(30, 80, 140, 28);
    center.bezelStyle = NSBezelStyleRounded;
    [v addSubview:center];

    // Info box
    NSBox *infoBox = [[NSBox alloc] initWithFrame:NSMakeRect(270, 60, 370, 200)];
    infoBox.title = @"API";
    [v addSubview:infoBox];
    NSTextField *info = [NSTextField labelWithString:
        @"POST /api/move/goto\n{\n  \"head_pose\": {\"pan\": p, \"tilt\": t, \"roll\": r},\n  \"duration\": 0.1\n}"];
    info.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    info.frame = NSMakeRect(8, 8, 350, 170);
    info.maximumNumberOfLines = 0;
    [infoBox addSubview:info];

    // Throttled send timer (10 Hz)
    self.sendTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                     target:self
                                                   selector:@selector(maybeSendMove)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (NSTextField *)readoutLabel:(NSString *)text x:(CGFloat)x y:(CGFloat)y {
    NSTextField *f = [NSTextField labelWithString:text];
    f.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    f.frame = NSMakeRect(x, y, 250, 20);
    return f;
}

// ── Joystick delegate ─────────────────────────────────────────────────────────

- (void)joystickDidMoveToX:(CGFloat)x y:(CGFloat)y {
    // x → pan, y → tilt (joystick Y is up = positive tilt forward)
    self.currentPan  = x * 35.0;    // ±35°
    self.currentTilt = -y * 25.0;   // ±25°, invert Y
    self.panLabel.stringValue  = [NSString stringWithFormat:@"Pan:  %+.1f°", self.currentPan];
    self.tiltLabel.stringValue = [NSString stringWithFormat:@"Tilt: %+.1f°", self.currentTilt];
    self.dirty = YES;
}

- (void)joystickDidRelease {
    self.currentPan  = 0;
    self.currentTilt = 0;
    self.dirty = YES;
}

// ── Slider ────────────────────────────────────────────────────────────────────

- (void)rollChanged:(NSSlider *)slider {
    self.currentRoll = slider.doubleValue;
    self.rollLabel.stringValue = [NSString stringWithFormat:@"Roll: %+.1f°", self.currentRoll];
    self.dirty = YES;
}

// ── Send ──────────────────────────────────────────────────────────────────────

- (void)maybeSendMove {
    if (!self.dirty) return;
    self.dirty = NO;
    [self sendHeadMove];
}

- (void)sendHeadMove {
    HTTPClient *http = [AppDelegate shared].httpClient;
    NSDictionary *body = @{
        @"head_pose": @{
            @"pan":  @(self.currentPan),
            @"tilt": @(self.currentTilt),
            @"roll": @(self.currentRoll),
        },
        @"duration": @0.1
    };
    [http postJSON:@"/api/move/goto" body:body completion:^(id json, NSError *error) {
        if (error) NSLog(@"HeadControl: %@", error.localizedDescription);
    }];
}

- (void)centerHead:(id)sender {
    self.currentPan  = 0;
    self.currentTilt = 0;
    self.currentRoll = 0;
    self.rollSlider.doubleValue = 0;
    self.panLabel.stringValue  = @"Pan:   0.00°";
    self.tiltLabel.stringValue = @"Tilt:  0.00°";
    self.rollLabel.stringValue = @"Roll:  0.00°";
    [self sendHeadMove];
}

@end
