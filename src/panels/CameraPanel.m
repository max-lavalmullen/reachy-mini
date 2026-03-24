#import "CameraPanel.h"
#import "../AppDelegate.h"
#import "../PythonBridge.h"

static __weak CameraPanel *gCameraPanel = nil;

void camera_frame_callback(const char *data, int length) {
    CameraPanel *panel = gCameraPanel;
    if (panel && data && length > 0)
        [panel receivedJPEGFrame:data length:length];
}

@interface CameraPanel ()
@property (nonatomic, strong) NSImageView *imageView;
@property (nonatomic, strong) NSView      *overlay;       // bottom HUD
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *fpsLabel;
@property (nonatomic, strong) NSButton    *startBtn;
@property (nonatomic, strong) NSButton    *stopBtn;
@property (nonatomic, assign) NSInteger    frameCount;
@property (nonatomic, strong) NSTimer     *fpsTimer;
@property (nonatomic, assign) BOOL         cameraRunning;
@end

@implementation CameraPanel

static inline NSColor *camRGB(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}
static inline NSColor *camRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0,0,900,720)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = camRGB(5,10,18).CGColor;
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = root;
    gCameraPanel = self;
    [self buildUI];
}

- (void)buildUI {
    NSView *v = self.view;

    // ── Camera frame ──────────────────────────────────────────────────────────
    NSView *frame = [[NSView alloc] init];
    frame.translatesAutoresizingMaskIntoConstraints = NO;
    frame.wantsLayer = YES;
    frame.layer.cornerRadius = 14;
    frame.layer.masksToBounds = YES;
    frame.layer.backgroundColor = [NSColor blackColor].CGColor;
    frame.layer.borderColor = camRGBA(255,255,255,0.08).CGColor;
    frame.layer.borderWidth = 0.5;
    [v addSubview:frame];

    // Image view fills the frame
    self.imageView = [[NSImageView alloc] init];
    self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.imageView.imageAlignment = NSImageAlignCenter;
    self.imageView.wantsLayer = YES;
    [frame addSubview:self.imageView];

    // ── Placeholder when no feed ──────────────────────────────────────────────
    NSTextField *placeholder = [NSTextField labelWithString:@"No camera feed"];
    placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    placeholder.font = [NSFont systemFontOfSize:15];
    placeholder.textColor = camRGBA(255,255,255,0.20);
    placeholder.alignment = NSTextAlignmentCenter;
    [frame addSubview:placeholder];

    // ── Bottom HUD overlay ────────────────────────────────────────────────────
    NSView *hud = [[NSView alloc] init];
    hud.translatesAutoresizingMaskIntoConstraints = NO;
    hud.wantsLayer = YES;
    hud.layer.backgroundColor = camRGBA(5,10,18,0.82).CGColor;
    [v addSubview:hud];
    self.overlay = hud;

    // Status label
    self.statusLabel = [NSTextField labelWithString:@"Camera not started"];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.textColor = camRGBA(202,211,223,0.60);
    [hud addSubview:self.statusLabel];

    // FPS label (right side)
    self.fpsLabel = [NSTextField labelWithString:@""];
    self.fpsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.fpsLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.fpsLabel.textColor = camRGB(61,222,153);
    self.fpsLabel.alignment = NSTextAlignmentRight;
    [hud addSubview:self.fpsLabel];

    // Start button
    self.startBtn = [[NSButton alloc] init];
    self.startBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.startBtn.title = @"▶  Start";
    self.startBtn.bezelStyle = NSBezelStyleRounded;
    self.startBtn.target = self; self.startBtn.action = @selector(startCamera:);
    self.startBtn.wantsLayer = YES;
    self.startBtn.layer.cornerRadius = 9;
    self.startBtn.layer.backgroundColor = camRGBA(61,222,153,0.18).CGColor;
    self.startBtn.layer.borderWidth = 1;
    self.startBtn.layer.borderColor = camRGBA(61,222,153,0.6).CGColor;
    self.startBtn.contentTintColor = camRGB(61,222,153);
    [hud addSubview:self.startBtn];

    // Stop button
    self.stopBtn = [[NSButton alloc] init];
    self.stopBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.stopBtn.title = @"■  Stop";
    self.stopBtn.bezelStyle = NSBezelStyleRounded;
    self.stopBtn.target = self; self.stopBtn.action = @selector(stopCamera:);
    self.stopBtn.wantsLayer = YES;
    self.stopBtn.layer.cornerRadius = 9;
    self.stopBtn.layer.backgroundColor = camRGBA(255,255,255,0.06).CGColor;
    self.stopBtn.layer.borderWidth = 1;
    self.stopBtn.layer.borderColor = camRGBA(255,255,255,0.14).CGColor;
    self.stopBtn.contentTintColor = [NSColor whiteColor];
    [hud addSubview:self.stopBtn];

    // ── Constraints ───────────────────────────────────────────────────────────
    [NSLayoutConstraint activateConstraints:@[
        // HUD: pinned to bottom
        [hud.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [hud.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [hud.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
        [hud.heightAnchor constraintEqualToConstant:56],

        // Camera frame: fills above HUD
        [frame.topAnchor constraintEqualToAnchor:v.topAnchor constant:16],
        [frame.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:16],
        [frame.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16],
        [frame.bottomAnchor constraintEqualToAnchor:hud.topAnchor constant:-16],

        // Image view fills frame
        [self.imageView.topAnchor constraintEqualToAnchor:frame.topAnchor],
        [self.imageView.leadingAnchor constraintEqualToAnchor:frame.leadingAnchor],
        [self.imageView.trailingAnchor constraintEqualToAnchor:frame.trailingAnchor],
        [self.imageView.bottomAnchor constraintEqualToAnchor:frame.bottomAnchor],

        // Placeholder centered in frame
        [placeholder.centerXAnchor constraintEqualToAnchor:frame.centerXAnchor],
        [placeholder.centerYAnchor constraintEqualToAnchor:frame.centerYAnchor],

        // HUD contents
        [self.startBtn.leadingAnchor constraintEqualToAnchor:hud.leadingAnchor constant:16],
        [self.startBtn.centerYAnchor constraintEqualToAnchor:hud.centerYAnchor],
        [self.startBtn.widthAnchor constraintEqualToConstant:96],
        [self.startBtn.heightAnchor constraintEqualToConstant:32],

        [self.stopBtn.leadingAnchor constraintEqualToAnchor:self.startBtn.trailingAnchor constant:10],
        [self.stopBtn.centerYAnchor constraintEqualToAnchor:hud.centerYAnchor],
        [self.stopBtn.widthAnchor constraintEqualToConstant:80],
        [self.stopBtn.heightAnchor constraintEqualToConstant:32],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.stopBtn.trailingAnchor constant:20],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:hud.centerYAnchor],

        [self.fpsLabel.trailingAnchor constraintEqualToAnchor:hud.trailingAnchor constant:-16],
        [self.fpsLabel.centerYAnchor constraintEqualToAnchor:hud.centerYAnchor],
        [self.fpsLabel.widthAnchor constraintEqualToConstant:80],
    ]];
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)startCamera:(id)sender {
    if (self.cameraRunning) return;
    self.statusLabel.stringValue = @"Starting camera…";
    self.statusLabel.textColor = camRGBA(202,211,223,0.60);
    gCameraPanel = self;

    BOOL ok = [[AppDelegate shared].pythonBridge startCameraWithCallback:(void *)camera_frame_callback];
    if (ok) {
        self.cameraRunning = YES;
        self.statusLabel.stringValue = @"● Live";
        self.statusLabel.textColor = camRGB(61,222,153);
        [self startFPSTimer];
    } else {
        self.statusLabel.stringValue = @"Failed to start camera";
        self.statusLabel.textColor = [NSColor colorWithRed:1 green:0.35 blue:0.35 alpha:1];
    }
}

- (void)stopCamera:(id)sender {
    [[AppDelegate shared].pythonBridge callFunction:@"stop_camera" withArgs:nil];
    self.cameraRunning = NO;
    [self.fpsTimer invalidate]; self.fpsTimer = nil;
    self.statusLabel.stringValue = @"Camera stopped";
    self.statusLabel.textColor = camRGBA(202,211,223,0.60);
    self.fpsLabel.stringValue = @"";
}

// ── Frame callback ────────────────────────────────────────────────────────────

- (void)receivedJPEGFrame:(const char *)data length:(int)length {
    NSData *jpeg = [NSData dataWithBytes:data length:length];
    self.frameCount++;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSImage *img = [[NSImage alloc] initWithData:jpeg];
        if (img) self.imageView.image = img;
    });
}

// ── FPS timer ─────────────────────────────────────────────────────────────────

- (void)startFPSTimer {
    __block NSInteger last = 0;
    self.fpsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        NSInteger delta = self.frameCount - last;
        last = self.frameCount;
        self.fpsLabel.stringValue = [NSString stringWithFormat:@"%ld fps", (long)delta];
    }];
}

@end
