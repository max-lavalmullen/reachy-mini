/*
 * TerminalPanel.m — Reachy Terminal
 * Claude Code + Gemini CLI + Codex with voice input, TTS, and head animations.
 *
 * Design notes:
 *  - TermTextView never becomes first responder → inputField always gets keys
 *  - CLIs are wrapped via /usr/bin/script to get a real PTY (fixes buffering + readline)
 *  - ANSI + carriage-return sequences are stripped before display
 *  - Head animates while Reachy speaks; pattern-matched output triggers robot moves
 */

#import "TerminalPanel.h"
#import "../AppDelegate.h"
#import "../HTTPClient.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>

// ── Palette ──────────────────────────────────────────────────────────────────

#define RGB(r,g,b) [NSColor colorWithRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:1]
#define RGBA(r,g,b,a) [NSColor colorWithRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:(a)]
static NSColor *kTermBg;
static NSColor *kCardBg;
static NSColor *kBorderColor;
static NSColor *kBodyText;
static NSColor *kDimText;
static NSColor *kTermFg;
static NSColor *kTermGreen;
static NSColor *kTermAmber;
static NSColor *kTermBlue;
static NSColor *kTermRed;
static NSColor *kToolbarBg;
static NSColor *kInputBg;

static void initColors(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kTermBg      = RGB(5, 10, 18);
        kCardBg      = RGB(14, 25, 42);
        kBorderColor = RGBA(255, 255, 255, 0.08);
        kBodyText    = [NSColor colorWithWhite:0.85 alpha:1.0];
        kDimText     = RGBA(202, 211, 223, 0.55);
        kTermGreen   = RGB(61, 222, 153);
        kTermFg      = kTermGreen;
        kTermAmber   = RGB(255, 193, 92);
        kTermBlue    = kTermGreen;
        kTermRed     = RGB(255, 120, 120);
        kToolbarBg   = kCardBg;
        kInputBg     = kCardBg;
    });
}

// ── ANSI stripper ─────────────────────────────────────────────────────────────

static NSRegularExpression *sAnsiRE = nil;

static NSString *stripAnsiAndCR(NSString *raw) {
    if (!raw.length) return raw;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sAnsiRE = [NSRegularExpression
            regularExpressionWithPattern:
                @"\x1b(?:\\[[0-9;?]*[A-Za-z]|\\][^\x07\x1b]*(?:\x07|\x1b\\\\)|[@-Z\\-_])"
                                 options:0 error:nil];
    });
    NSMutableString *m = [raw mutableCopy];
    [sAnsiRE replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@""];
    // Handle progress-bar carriage returns: keep only the last segment per line
    NSArray *lines = [m componentsSeparatedByString:@"\n"];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSString *ln in lines) {
        NSArray *parts = [ln componentsSeparatedByString:@"\r"];
        [out addObject:parts.lastObject ?: @""];
    }
    return [out componentsJoinedByString:@"\n"];
}

// ── Non-focusable NSTextView (prevents stealing keyboard focus) ───────────────

@interface TermTextView : NSTextView
@end
@implementation TermTextView
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)canBecomeKeyView       { return NO; }
@end

// ── TerminalPanel ─────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, TermCLI) {
    TermCLIClaudeCode = 0,
    TermCLIGemini = 1,
    TermCLICodex = 2,
};

static NSString * const kMoveRE = @"<!--\\s*(?:MOVE|BEHAVIOR):\\s*(\\S+)\\s*-->";

@interface TerminalPanel () <SFSpeechRecognizerDelegate>

// ── Top bar
@property (nonatomic, strong) NSButton    *claudeBtn;
@property (nonatomic, strong) NSButton    *geminiBtn;
@property (nonatomic, strong) NSButton    *codexBtn;
@property (nonatomic, strong) NSView      *statusDot;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton    *stopBtn;
@property (nonatomic, strong) NSButton    *clearBtn;

// ── Options row
@property (nonatomic, strong) NSButton *yoloCheck;
@property (nonatomic, strong) NSButton *ttsCheck;

// ── Terminal
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) TermTextView *textView;

// ── Input bar
@property (nonatomic, strong) NSButton    *voiceBtn;
@property (nonatomic, strong) NSTextField *inputField;
@property (nonatomic, strong) NSButton    *sendBtn;
@property (nonatomic, strong) NSTextField *transcriptLabel;

// ── Process
@property (nonatomic, strong) NSTask       *cliTask;
@property (nonatomic, strong) NSFileHandle *stdinFH;
@property (nonatomic, strong) NSFileHandle *stdoutFH;
@property (nonatomic, strong) NSFileHandle *stderrFH;
@property (nonatomic, assign) BOOL          running;
@property (nonatomic, assign) TermCLI       activeCLI;

// ── STT
@property (nonatomic, strong) SFSpeechRecognizer                    *recognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *sttRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask               *sttTask;
@property (nonatomic, strong) AVAudioEngine                        *audioEngine;
@property (nonatomic, assign) BOOL                                   listening;

// ── TTS + head animation
@property (nonatomic, strong) NSTimer  *ttsDebounce;
@property (nonatomic, strong) NSString *pendingOutput;
@property (nonatomic, strong) NSTask   *sayTask;
@property (nonatomic, strong) NSTimer  *headTimer;
@property (nonatomic, assign) double    headPhase;
@property (nonatomic, copy)   NSString *lastSpokenStatus;

// ── Regexes
@property (nonatomic, strong) NSRegularExpression *moveRegex;

@end

@implementation TerminalPanel

// ── Lifecycle ─────────────────────────────────────────────────────────────────

- (void)loadView {
    initColors();
    self.view = [[NSView alloc] init];
    self.moveRegex = [NSRegularExpression regularExpressionWithPattern:kMoveRE
                                                              options:NSRegularExpressionCaseInsensitive
                                                                error:nil];
    [self buildUI];
    [self requestSpeechPermission];
}

// ── UI Construction ───────────────────────────────────────────────────────────

- (void)buildUI {
    NSView *v = self.view;
    v.wantsLayer = YES;
    v.layer.backgroundColor = kTermBg.CGColor;

    // ── Top toolbar ───────────────────────────────────────────────────────────
    NSView *toolbar = [[NSView alloc] init];
    toolbar.wantsLayer = YES;
    toolbar.layer.backgroundColor = kToolbarBg.CGColor;
    toolbar.layer.cornerRadius = 14;
    toolbar.layer.borderWidth = 1;
    toolbar.layer.borderColor = kBorderColor.CGColor;
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:toolbar];

    self.claudeBtn = [self makeLaunchButton:@"⚡  Claude Code" action:@selector(launchClaude:)];
    self.geminiBtn = [self makeLaunchButton:@"✦  Gemini CLI"  action:@selector(launchGemini:)];
    self.codexBtn  = [self makeLaunchButton:@"◎  Codex CLI"   action:@selector(launchCodex:)];

    self.statusDot = [[NSView alloc] init];
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.cornerRadius = 4;
    self.statusDot.layer.backgroundColor = kDimText.CGColor;

    self.statusLabel = [NSTextField labelWithString:
        [NSString stringWithFormat:@"Workspace: %@  ·  choose a CLI to start",
            [AppDelegate shared].workspacePath.lastPathComponent ?: @"Home"]];
    self.statusLabel.textColor = kDimText;
    self.statusLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];

    self.stopBtn  = [self makeSmallButton:@"■  Stop"  action:@selector(stopCLI:)];
    self.clearBtn = [self makeSmallButton:@"⌫  Clear" action:@selector(clearTerminal:)];
    self.stopBtn.enabled = NO;

    self.yoloCheck = [NSButton checkboxWithTitle:@"Auto-approve" target:nil action:nil];
    self.yoloCheck.state = NSControlStateValueOn;
    self.yoloCheck.font = [NSFont systemFontOfSize:11];
    self.yoloCheck.contentTintColor = kTermGreen;

    self.ttsCheck = [NSButton checkboxWithTitle:@"Reachy speaks" target:nil action:nil];
    self.ttsCheck.state = NSControlStateValueOn;
    self.ttsCheck.font = [NSFont systemFontOfSize:11];
    self.ttsCheck.contentTintColor = kTermGreen;

    // ── Terminal ──────────────────────────────────────────────────────────────
    self.textView = [[TermTextView alloc] init];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.backgroundColor = kTermBg;
    self.textView.textColor = kTermFg;
    self.textView.font = [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightRegular];
    self.textView.automaticQuoteSubstitutionEnabled = NO;
    self.textView.automaticDashSubstitutionEnabled  = NO;
    self.textView.textContainerInset = NSMakeSize(8, 8);

    self.scroll = [[NSScrollView alloc] init];
    self.scroll.hasVerticalScroller   = YES;
    self.scroll.autohidesScrollers    = YES;
    self.scroll.borderType            = NSNoBorder;
    self.scroll.backgroundColor       = kTermBg;
    self.scroll.documentView          = self.textView;
    self.scroll.wantsLayer            = YES;
    self.scroll.layer.cornerRadius    = 14;
    self.scroll.layer.borderWidth     = 1;
    self.scroll.layer.borderColor     = kBorderColor.CGColor;
    self.scroll.layer.backgroundColor = kTermBg.CGColor;

    // ── Input bar ─────────────────────────────────────────────────────────────
    NSView *inputBar = [[NSView alloc] init];
    inputBar.wantsLayer = YES;
    inputBar.layer.backgroundColor = kInputBg.CGColor;
    inputBar.layer.cornerRadius = 14;
    inputBar.layer.borderWidth = 1;
    inputBar.layer.borderColor = kBorderColor.CGColor;
    inputBar.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:inputBar];

    self.voiceBtn = [[NSButton alloc] init];
    self.voiceBtn.title = @"🎙";
    self.voiceBtn.target = self;
    self.voiceBtn.action = @selector(toggleVoice:);
    self.voiceBtn.bezelStyle = NSBezelStyleCircular;
    self.voiceBtn.enabled = NO;
    self.voiceBtn.font = [NSFont systemFontOfSize:16];
    self.voiceBtn.wantsLayer = YES;
    self.voiceBtn.layer.cornerRadius = 17;
    self.voiceBtn.layer.backgroundColor = RGBA(255,255,255,0.05).CGColor;
    self.voiceBtn.layer.borderWidth = 1;
    self.voiceBtn.layer.borderColor = RGBA(255,255,255,0.12).CGColor;
    self.voiceBtn.contentTintColor = kTermGreen;

    self.inputField = [[NSTextField alloc] init];
    self.inputField.placeholderString = @"Speak or type  ⏎ to send…";
    self.inputField.font = [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightRegular];
    self.inputField.textColor = kBodyText;
    self.inputField.backgroundColor = kTermBg;
    self.inputField.bezeled = NO;
    self.inputField.drawsBackground = YES;
    self.inputField.focusRingType = NSFocusRingTypeNone;
    self.inputField.target = self;
    self.inputField.action = @selector(sendInput:);
    self.inputField.enabled = NO;
    self.inputField.wantsLayer = YES;
    self.inputField.layer.cornerRadius = 6;
    self.inputField.layer.borderColor = RGBA(255,255,255,0.12).CGColor;
    self.inputField.layer.borderWidth = 1;

    self.sendBtn = [[NSButton alloc] init];
    self.sendBtn.title = @"↵";
    self.sendBtn.target = self;
    self.sendBtn.action = @selector(sendInput:);
    self.sendBtn.bezelStyle = NSBezelStyleRounded;
    self.sendBtn.font = [NSFont boldSystemFontOfSize:15];
    self.sendBtn.enabled = NO;
    self.sendBtn.wantsLayer = YES;
    self.sendBtn.layer.cornerRadius = 10;
    self.sendBtn.layer.backgroundColor = RGBA(61,222,153,0.15).CGColor;
    self.sendBtn.layer.borderWidth = 1;
    self.sendBtn.layer.borderColor = RGBA(61,222,153,0.55).CGColor;
    self.sendBtn.contentTintColor = kTermGreen;

    self.transcriptLabel = [NSTextField labelWithString:@""];
    self.transcriptLabel.textColor = kTermGreen;
    self.transcriptLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];

    // ── Add all to subview hierarchy ─────────────────────────────────────────
    for (NSView *sub in @[self.claudeBtn, self.geminiBtn, self.codexBtn,
                           self.statusDot, self.statusLabel,
                           self.stopBtn, self.clearBtn, self.yoloCheck, self.ttsCheck]) {
        sub.translatesAutoresizingMaskIntoConstraints = NO;
        [toolbar addSubview:sub];
    }
    for (NSView *sub in @[self.voiceBtn, self.inputField, self.sendBtn, self.transcriptLabel]) {
        sub.translatesAutoresizingMaskIntoConstraints = NO;
        [inputBar addSubview:sub];
    }
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:self.scroll];

    // ── Constraints ───────────────────────────────────────────────────────────
    CGFloat tbH  = 78;  // toolbar height
    CGFloat ibH  = 72;  // input bar height

    [NSLayoutConstraint activateConstraints:@[
        // Toolbar — pinned to top
        [toolbar.topAnchor    constraintEqualToAnchor:v.topAnchor constant:14],
        [toolbar.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:18],
        [toolbar.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-18],
        [toolbar.heightAnchor  constraintEqualToConstant:tbH],

        // Terminal scroll — fills the middle
        [self.scroll.topAnchor    constraintEqualToAnchor:toolbar.bottomAnchor constant:12],
        [self.scroll.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:18],
        [self.scroll.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-18],
        [self.scroll.bottomAnchor  constraintEqualToAnchor:inputBar.topAnchor constant:-12],

        // Input bar — pinned to bottom
        [inputBar.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:18],
        [inputBar.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-18],
        [inputBar.bottomAnchor   constraintEqualToAnchor:v.bottomAnchor constant:-14],
        [inputBar.heightAnchor   constraintEqualToConstant:ibH],

        // ── Toolbar contents ──────────────────────────────────────────────
        // Row 1: Launch buttons + stop/clear
        [self.claudeBtn.topAnchor    constraintEqualToAnchor:toolbar.topAnchor constant:12],
        [self.claudeBtn.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor constant:16],
        [self.claudeBtn.widthAnchor  constraintEqualToConstant:136],
        [self.claudeBtn.heightAnchor constraintEqualToConstant:32],

        [self.geminiBtn.topAnchor    constraintEqualToAnchor:toolbar.topAnchor constant:12],
        [self.geminiBtn.leadingAnchor constraintEqualToAnchor:self.claudeBtn.trailingAnchor constant:8],
        [self.geminiBtn.widthAnchor  constraintEqualToConstant:128],
        [self.geminiBtn.heightAnchor constraintEqualToConstant:32],

        [self.codexBtn.topAnchor    constraintEqualToAnchor:toolbar.topAnchor constant:12],
        [self.codexBtn.leadingAnchor constraintEqualToAnchor:self.geminiBtn.trailingAnchor constant:8],
        [self.codexBtn.widthAnchor  constraintEqualToConstant:120],
        [self.codexBtn.heightAnchor constraintEqualToConstant:32],

        [self.clearBtn.centerYAnchor constraintEqualToAnchor:self.claudeBtn.centerYAnchor],
        [self.clearBtn.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor constant:-16],
        [self.clearBtn.widthAnchor   constraintEqualToConstant:72],

        [self.stopBtn.centerYAnchor  constraintEqualToAnchor:self.claudeBtn.centerYAnchor],
        [self.stopBtn.trailingAnchor constraintEqualToAnchor:self.clearBtn.leadingAnchor constant:-8],
        [self.stopBtn.widthAnchor    constraintEqualToConstant:72],

        // Row 2: status dot + label + option checks
        [self.statusDot.topAnchor    constraintEqualToAnchor:self.claudeBtn.bottomAnchor constant:10],
        [self.statusDot.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor constant:18],
        [self.statusDot.widthAnchor  constraintEqualToConstant:8],
        [self.statusDot.heightAnchor constraintEqualToConstant:8],

        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.statusDot.centerYAnchor],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.statusDot.trailingAnchor constant:6],

        [self.yoloCheck.centerYAnchor constraintEqualToAnchor:self.statusDot.centerYAnchor],
        [self.yoloCheck.trailingAnchor constraintEqualToAnchor:self.clearBtn.trailingAnchor],

        [self.ttsCheck.centerYAnchor constraintEqualToAnchor:self.statusDot.centerYAnchor],
        [self.ttsCheck.trailingAnchor constraintEqualToAnchor:self.yoloCheck.leadingAnchor constant:-16],

        // ── Input bar contents ────────────────────────────────────────────
        [self.voiceBtn.leadingAnchor constraintEqualToAnchor:inputBar.leadingAnchor constant:14],
        [self.voiceBtn.topAnchor    constraintEqualToAnchor:inputBar.topAnchor constant:10],
        [self.voiceBtn.widthAnchor  constraintEqualToConstant:34],
        [self.voiceBtn.heightAnchor constraintEqualToConstant:34],

        [self.sendBtn.trailingAnchor constraintEqualToAnchor:inputBar.trailingAnchor constant:-14],
        [self.sendBtn.centerYAnchor  constraintEqualToAnchor:self.voiceBtn.centerYAnchor],
        [self.sendBtn.widthAnchor    constraintEqualToConstant:38],
        [self.sendBtn.heightAnchor   constraintEqualToConstant:34],

        [self.inputField.leadingAnchor  constraintEqualToAnchor:self.voiceBtn.trailingAnchor constant:10],
        [self.inputField.trailingAnchor constraintEqualToAnchor:self.sendBtn.leadingAnchor constant:-10],
        [self.inputField.centerYAnchor  constraintEqualToAnchor:self.voiceBtn.centerYAnchor],
        [self.inputField.heightAnchor   constraintEqualToConstant:32],

        [self.transcriptLabel.leadingAnchor  constraintEqualToAnchor:inputBar.leadingAnchor constant:14],
        [self.transcriptLabel.trailingAnchor constraintEqualToAnchor:inputBar.trailingAnchor constant:-14],
        [self.transcriptLabel.bottomAnchor   constraintEqualToAnchor:inputBar.bottomAnchor constant:-8],
        [self.transcriptLabel.heightAnchor   constraintEqualToConstant:14],
    ]];

    // Welcome banner
    [self appendLine:@"┌────────────────────────────────────────────┐" color:kTermGreen];
    [self appendLine:@"│ Reachy Agent Tools — Claude, Gemini, Codex │" color:kTermGreen];
    [self appendLine:@"└────────────────────────────────────────────┘\n" color:kTermGreen];
}

// ── Button factory ─────────────────────────────────────────────────────────

- (NSButton *)makeLaunchButton:(NSString *)title action:(SEL)action {
    NSButton *btn = [[NSButton alloc] init];
    btn.title = title;
    btn.target = self;
    btn.action = action;
    btn.bezelStyle = NSBezelStyleRounded;
    btn.wantsLayer = YES;
    btn.layer.cornerRadius = 10;
    btn.layer.borderColor  = RGBA(255,255,255,0.12).CGColor;
    btn.layer.borderWidth  = 1;
    btn.layer.backgroundColor = RGBA(255,255,255,0.05).CGColor;
    btn.font = [NSFont boldSystemFontOfSize:13];
    btn.contentTintColor = kBodyText;
    return btn;
}

- (NSButton *)makeSmallButton:(NSString *)title action:(SEL)action {
    NSButton *btn = [NSButton buttonWithTitle:title target:self action:action];
    btn.bezelStyle = NSBezelStyleRounded;
    btn.font = [NSFont systemFontOfSize:11];
    btn.wantsLayer = YES;
    btn.layer.cornerRadius = 8;
    btn.layer.backgroundColor = RGBA(255,255,255,0.05).CGColor;
    btn.layer.borderWidth = 1;
    btn.layer.borderColor = RGBA(255,255,255,0.12).CGColor;
    btn.contentTintColor = kBodyText;
    return btn;
}

- (void)setLaunchButton:(NSButton *)btn active:(BOOL)active {
    if (active) {
        btn.layer.backgroundColor = RGBA(61,222,153,0.14).CGColor;
        btn.layer.borderColor = RGBA(61,222,153,0.55).CGColor;
        btn.contentTintColor = kTermGreen;
    } else {
        btn.layer.backgroundColor = RGBA(255,255,255,0.05).CGColor;
        btn.layer.borderColor = RGBA(255,255,255,0.12).CGColor;
        btn.contentTintColor = kBodyText;
    }
}

- (NSArray<NSButton *> *)launchButtons {
    return @[self.claudeBtn, self.geminiBtn, self.codexBtn];
}

- (NSButton *)buttonForCLI:(TermCLI)cliType {
    switch (cliType) {
        case TermCLIClaudeCode: return self.claudeBtn;
        case TermCLIGemini:     return self.geminiBtn;
        case TermCLICodex:      return self.codexBtn;
    }
    return self.claudeBtn;
}

// ── Speech permission ─────────────────────────────────────────────────────────

- (void)requestSpeechPermission {
    self.recognizer  = [[SFSpeechRecognizer alloc]
        initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    self.recognizer.delegate = self;
    self.audioEngine = [[AVAudioEngine alloc] init];

    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.voiceBtn.enabled = (s == SFSpeechRecognizerAuthorizationStatusAuthorized);
        });
    }];
}

// ── Launch buttons ────────────────────────────────────────────────────────────

- (void)launchClaude:(id)sender {
    if (self.running) [self stopCLI:nil];
    NSString *path = [self findExe:@"claude" extra:@[@"/Users/maxl/.local/bin"]];
    if (!path) { [self appendLine:@"Error: 'claude' not found in PATH." color:kTermRed]; return; }
    NSMutableArray *args = [NSMutableArray arrayWithObject:path];
    if (self.yoloCheck.state == NSControlStateValueOn)
        [args addObject:@"--dangerously-skip-permissions"];
    [self startWithScript:args cli:TermCLIClaudeCode displayName:@"claude"];
}

- (void)launchGemini:(id)sender {
    if (self.running) [self stopCLI:nil];
    NSString *path = [self findExe:@"gemini" extra:@[@"/opt/homebrew/bin"]];
    if (!path) { [self appendLine:@"Error: 'gemini' not found in PATH." color:kTermRed]; return; }
    NSMutableArray *args = [NSMutableArray arrayWithObject:path];
    if (self.yoloCheck.state == NSControlStateValueOn) [args addObject:@"--yolo"];
    [self startWithScript:args cli:TermCLIGemini displayName:@"gemini"];
}

- (void)launchCodex:(id)sender {
    if (self.running) [self stopCLI:nil];
    NSString *path = [self findExe:@"codex" extra:@[@"/opt/homebrew/bin"]];
    if (!path) { [self appendLine:@"Error: 'codex' not found in PATH." color:kTermRed]; return; }
    NSMutableArray *args = [NSMutableArray arrayWithObjects:path, @"--no-alt-screen", nil];
    if (self.yoloCheck.state == NSControlStateValueOn) [args addObject:@"--full-auto"];
    [self startWithScript:args cli:TermCLICodex displayName:@"codex"];
}

// ── Core process launch ───────────────────────────────────────────────────────
//
// Wraps the CLI in /usr/bin/script -q /dev/null <cmd> to allocate a real PTY.
// This fixes readline buffering so Gemini/Claude output immediately.
//
- (void)startWithScript:(NSArray *)cmdArgs cli:(TermCLI)cliType displayName:(NSString *)name {
    self.activeCLI = cliType;

    // Build: /usr/bin/script -q /dev/null <cmd> [args]
    NSMutableArray *scriptArgs = [@[@"-q", @"/dev/null"] mutableCopy];
    [scriptArgs addObjectsFromArray:cmdArgs];

    self.cliTask = [[NSTask alloc] init];
    self.cliTask.launchPath = @"/usr/bin/script";
    self.cliTask.arguments  = scriptArgs;
    self.cliTask.currentDirectoryURL =
        [NSURL fileURLWithPath:[AppDelegate shared].workspacePath isDirectory:YES];

    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"PATH"]  = [@"/Users/maxl/.local/bin:/opt/homebrew/bin:/usr/local/bin:" stringByAppendingString:env[@"PATH"] ?: @""];
    env[@"HOME"]  = NSHomeDirectory();
    env[@"TERM"]  = @"xterm-256color";
    env[@"COLUMNS"] = @"100";
    env[@"LINES"]   = @"40";
    // Force Claude/Gemini into a mode that still outputs richly but won't crash without real PTY
    self.cliTask.environment = env;

    NSPipe *inPipe  = [NSPipe pipe];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    self.cliTask.standardInput  = inPipe;
    self.cliTask.standardOutput = outPipe;
    self.cliTask.standardError  = errPipe;

    self.stdinFH  = inPipe.fileHandleForWriting;
    self.stdoutFH = outPipe.fileHandleForReading;
    self.stderrFH = errPipe.fileHandleForReading;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReadOut:)
        name:NSFileHandleDataAvailableNotification object:self.stdoutFH];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReadErr:)
        name:NSFileHandleDataAvailableNotification object:self.stderrFH];
    [self.stdoutFH waitForDataInBackgroundAndNotify];
    [self.stderrFH waitForDataInBackgroundAndNotify];

    __weak typeof(self) ws = self;
    self.cliTask.terminationHandler = ^(NSTask *t) {
        dispatch_async(dispatch_get_main_queue(), ^{ [ws processEnded]; });
    };

    NSError *err = nil;
    [self.cliTask launchAndReturnError:&err];
    if (err) {
        [self appendLine:[NSString stringWithFormat:@"Launch error: %@", err.localizedDescription] color:kTermRed];
        return;
    }

    self.running = YES;
    for (NSButton *button in [self launchButtons]) {
        [self setLaunchButton:button active:(button == [self buttonForCLI:cliType])];
    }
    self.stopBtn.enabled    = YES;
    self.inputField.enabled = YES;
    self.sendBtn.enabled    = YES;
    self.statusDot.layer.backgroundColor = kTermGreen.CGColor;
    self.statusLabel.stringValue = [NSString stringWithFormat:
        @"%@  ·  %@  ·  PID %d",
        name,
        [AppDelegate shared].workspacePath.lastPathComponent ?: @"Home",
        self.cliTask.processIdentifier];
    self.statusLabel.textColor = kTermGreen;

    [self appendLine:@"" color:nil];
    [self appendLine:[NSString stringWithFormat:@"▶  Started %@  [PID %d]", name, self.cliTask.processIdentifier]
               color:kTermGreen];
    [self appendLine:@"" color:nil];

    // Announce startup
    if (self.ttsCheck.state == NSControlStateValueOn) {
        NSString *greeting = (cliType == TermCLIClaudeCode)
            ? @"Claude Code is ready. Go ahead."
            : (cliType == TermCLIGemini)
                ? @"Gemini is ready. Go ahead."
                : @"Codex is ready. Go ahead.";
        [self speakAndBobble:greeting move:nil];
    }

    [self.view.window makeFirstResponder:self.inputField];
}

- (void)stopCLI:(id)sender {
    [self.cliTask terminate];
}

- (void)processEnded {
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:NSFileHandleDataAvailableNotification object:self.stdoutFH];
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:NSFileHandleDataAvailableNotification object:self.stderrFH];

    self.running = NO;
    self.stopBtn.enabled    = NO;
    self.inputField.enabled = NO;
    self.sendBtn.enabled    = NO;
    self.statusDot.layer.backgroundColor = kDimText.CGColor;
    self.statusLabel.stringValue = [NSString stringWithFormat:
        @"Workspace: %@  ·  choose a CLI to restart",
        [AppDelegate shared].workspacePath.lastPathComponent ?: @"Home"];
    self.statusLabel.textColor = kDimText;
    for (NSButton *button in [self launchButtons]) [self setLaunchButton:button active:NO];
    [self.ttsDebounce invalidate];
    self.ttsDebounce = nil;
    self.pendingOutput = @"";
    self.lastSpokenStatus = nil;

    [self appendLine:@"" color:nil];
    [self appendLine:@"◼  Session ended" color:kTermAmber];
}

// ── I/O ───────────────────────────────────────────────────────────────────────

- (void)sendInput:(id)sender {
    NSString *text = [self.inputField.stringValue
                        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!text.length || !self.running) {
        [self.view.window makeFirstResponder:self.inputField];
        return;
    }
    [self sendRawText:text];
    self.inputField.stringValue = @"";
    [self.view.window makeFirstResponder:self.inputField];
}

- (void)sendRawText:(NSString *)text {
    if (!self.running || !self.stdinFH) return;
    NSString *line = [text stringByAppendingString:@"\n"];
    [self.stdinFH writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [self appendLine:[NSString stringWithFormat:@"  ➤  %@", text] color:kBodyText];
}

- (void)didReadOut:(NSNotification *)n {
    NSData *data = [self.stdoutFH availableData];
    if (data.length) {
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        NSString *clean = stripAnsiAndCR(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendText:clean color:kTermFg];
            [self announceInterestingStatusFromChunk:clean];
            [self accumOutputForTTS:clean];
            [self checkMoveMarkers:clean];
            [self triggerDanceForOutput:clean];
        });
    }
    if (self.running) [self.stdoutFH waitForDataInBackgroundAndNotify];
}

- (void)didReadErr:(NSNotification *)n {
    NSData *data = [self.stderrFH availableData];
    if (data.length) {
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        NSString *clean = stripAnsiAndCR(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendText:clean color:kTermAmber];
        });
    }
    if (self.running) [self.stderrFH waitForDataInBackgroundAndNotify];
}

// ── Spoken status taps ───────────────────────────────────────────────────────

- (void)announceInterestingStatusFromChunk:(NSString *)chunk {
    if (self.ttsCheck.state != NSControlStateValueOn || !chunk.length) return;
    if (self.sayTask.isRunning) return;

    for (NSString *line in [chunk componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *candidate = [self interestingStatusFromLine:line];
        if (!candidate.length) continue;
        if ([candidate isEqualToString:self.lastSpokenStatus]) continue;
        self.lastSpokenStatus = candidate;
        [self speakAndBobble:candidate move:nil];
        break;
    }
}

- (NSString *)interestingStatusFromLine:(NSString *)line {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length || trimmed.length > 140) return nil;
    if ([trimmed hasPrefix:@"➤"] || [trimmed hasPrefix:@"$"] || [trimmed hasPrefix:@"```"]) return nil;

    NSString *lower = trimmed.lowercaseString;
    NSArray<NSString *> *keywords = @[
        @"thinking", @"reading", @"running", @"searching", @"planning",
        @"editing", @"writing", @"inspecting", @"analyzing", @"done",
        @"complete", @"completed", @"error", @"failed"
    ];
    for (NSString *keyword in keywords) {
        if ([lower containsString:keyword]) return trimmed;
    }
    return nil;
}

// ── TTS debounce ──────────────────────────────────────────────────────────────

- (void)accumOutputForTTS:(NSString *)chunk {
    if (self.ttsCheck.state != NSControlStateValueOn) return;
    self.pendingOutput = [[self.pendingOutput ?: @"" stringByAppendingString:chunk]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self.ttsDebounce invalidate];
    // Fire 2.5 s after last output chunk
    self.ttsDebounce = [NSTimer scheduledTimerWithTimeInterval:2.5
                                                        target:self
                                                      selector:@selector(flushTTS)
                                                      userInfo:nil
                                                       repeats:NO];
}

- (void)flushTTS {
    self.ttsDebounce = nil;
    NSString *txt = self.pendingOutput;
    self.pendingOutput = @"";
    if (!txt.length) return;
    // Trim to last meaningful portion (skip code blocks etc.)
    NSString *cleaned = [self cleanForSpeech:txt];
    if (cleaned.length) [self speakAndBobble:cleaned move:nil];
}

// ── Voice input ───────────────────────────────────────────────────────────────

- (void)toggleVoice:(id)sender {
    self.listening ? [self stopListening] : [self startListening];
}

- (void)startListening {
    if (self.listening) return;
    self.sttRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.sttRequest.shouldReportPartialResults = YES;

    AVAudioInputNode *node = self.audioEngine.inputNode;
    AVAudioFormat *fmt = [node outputFormatForBus:0];

    __weak typeof(self) ws = self;
    self.sttTask = [self.recognizer recognitionTaskWithRequest:self.sttRequest
        resultHandler:^(SFSpeechRecognitionResult *res, NSError *e) {
            if (res) {
                NSString *t = res.bestTranscription.formattedString;
                ws.transcriptLabel.stringValue = [NSString stringWithFormat:@"🎙  %@", t];
                ws.inputField.stringValue = t;   // fill input field live
                if (res.isFinal && t.length) {
                    [ws stopListening];
                    [ws sendRawText:t];
                    ws.inputField.stringValue = @"";
                }
            }
            if (e && ws.listening) [ws stopListening];
        }];

    [node installTapOnBus:0 bufferSize:1024 format:fmt
                    block:^(AVAudioPCMBuffer *buf, AVAudioTime *w) {
        [ws.sttRequest appendAudioPCMBuffer:buf];
    }];
    NSError *err = nil;
    [self.audioEngine prepare];
    [self.audioEngine startAndReturnError:&err];

    self.listening = YES;
    self.voiceBtn.layer.backgroundColor = RGBA(61,222,153,0.16).CGColor;
    self.voiceBtn.layer.borderColor = RGBA(61,222,153,0.55).CGColor;
    self.voiceBtn.contentTintColor = kTermGreen;
    self.transcriptLabel.stringValue = @"🎙  Listening…";
}

- (void)stopListening {
    if (!self.listening) return;
    self.listening = NO;
    [self.audioEngine.inputNode removeTapOnBus:0];
    [self.audioEngine stop];
    [self.sttRequest endAudio];
    self.voiceBtn.layer.backgroundColor = RGBA(255,255,255,0.05).CGColor;
    self.voiceBtn.layer.borderColor = RGBA(255,255,255,0.12).CGColor;
    self.voiceBtn.contentTintColor = kTermGreen;
    self.transcriptLabel.stringValue = @"";
}

// ── TTS + Head bobble ─────────────────────────────────────────────────────────

- (void)speakAndBobble:(NSString *)text move:(NSString *)moveName {
    [self.sayTask terminate];
    [self.headTimer invalidate];
    self.headTimer = nil;

    if (moveName) {
        [[AppDelegate shared].httpClient
            postJSON:[NSString stringWithFormat:@"/api/move/play/recorded-move-dataset/emotions/%@", moveName]
                body:nil completion:^(id j, NSError *e){}];
    }

    self.headPhase = 0;
    self.headTimer = [NSTimer scheduledTimerWithTimeInterval:0.65
                                                     target:self
                                                   selector:@selector(animateHead)
                                                   userInfo:nil
                                                    repeats:YES];

    self.sayTask = [[NSTask alloc] init];
    NSString *voice = [[NSProcessInfo processInfo] environment][@"REACHY_SAY_VOICE"] ?: @"Samantha";
    self.sayTask.launchPath = @"/usr/bin/say";
    self.sayTask.arguments  = @[@"-v", voice, text];

    __weak typeof(self) ws = self;
    self.sayTask.terminationHandler = ^(NSTask *t) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws.headTimer invalidate];
            ws.headTimer = nil;
            [[AppDelegate shared].httpClient
                postJSON:@"/api/move/goto"
                    body:@{@"head_pose": @{@"pan": @0, @"tilt": @(0.08)},
                           @"antennas": @[@0, @0], @"duration": @(0.5)}
              completion:^(id j, NSError *e){}];
        });
    };
    NSError *e = nil;
    [self.sayTask launchAndReturnError:&e];
}

- (void)animateHead {
    self.headPhase += 0.85;
    double pan  = sin(self.headPhase * 0.6) * 0.11;
    double tilt = 0.07 + sin(self.headPhase * 1.05 + 0.8) * 0.06;
    double ant  = sin(self.headPhase * 1.2) * 0.22;
    [[AppDelegate shared].httpClient
        postJSON:@"/api/move/goto"
            body:@{@"head_pose": @{@"pan": @(pan), @"tilt": @(tilt)},
                   @"antennas": @[@(ant), @(-ant)], @"duration": @(0.45)}
      completion:^(id j, NSError *e){}];
}

// ── Pattern-based robot dances ─────────────────────────────────────────────────

- (void)triggerDanceForOutput:(NSString *)text {
    // Success
    if ([text containsString:@"✓"] || [text containsString:@"✔"] ||
        [text rangeOfString:@"Done!" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [[AppDelegate shared].httpClient
            postJSON:@"/api/move/play/recorded-move-dataset/emotions/happy1"
                body:nil completion:^(id j, NSError *e){}];
        return;
    }
    // Error
    if ([text containsString:@"✗"] ||
        [text rangeOfString:@"Error" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [text rangeOfString:@"Failed" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [[AppDelegate shared].httpClient
            postJSON:@"/api/move/play/recorded-move-dataset/emotions/sad1"
                body:nil completion:^(id j, NSError *e){}];
        return;
    }
    // Thinking / planning — antenna wiggle only
    if ([text rangeOfString:@"thinking" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [text rangeOfString:@"running" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [text rangeOfString:@"reading" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [[AppDelegate shared].httpClient
            postJSON:@"/api/move/goto"
                body:@{@"antennas": @[@(0.3), @(-0.3)], @"duration": @(0.3)}
          completion:^(id j, NSError *e){}];
    }
}

// ── MOVE markers ──────────────────────────────────────────────────────────────

- (void)checkMoveMarkers:(NSString *)text {
    for (NSTextCheckingResult *m in [self.moveRegex matchesInString:text options:0
                                                              range:NSMakeRange(0, text.length)]) {
        if (m.numberOfRanges >= 2) {
            NSString *name = [text substringWithRange:[m rangeAtIndex:1]];
            [[AppDelegate shared].httpClient
                postJSON:[NSString stringWithFormat:@"/api/move/play/recorded-move-dataset/emotions/%@", name]
                    body:nil completion:^(id j, NSError *e){}];
        }
    }
}

// ── NSTextView helpers ────────────────────────────────────────────────────────

- (void)appendText:(NSString *)text color:(NSColor *)color {
    if (!text.length) return;
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: color ?: kTermFg,
    }];
    [[self.textView textStorage] appendAttributedString:as];
    [self.textView scrollToEndOfDocument:nil];
}

- (void)appendLine:(NSString *)text color:(NSColor *)color {
    [self appendText:[text stringByAppendingString:@"\n"] color:color];
}

- (void)clearTerminal:(id)sender {
    [self.textView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
}

// ── Speech for text-to-speech ─────────────────────────────────────────────────
// Returns a version of `text` suitable for speaking (no code, no markers).

- (NSString *)cleanForSpeech:(NSString *)text {
    NSMutableString *s = [text mutableCopy];
    for (NSString *pat in @[@"<!--.*?-->", @"```[\\s\\S]*?```", @"`[^`]*`",
                             @"^\\s*[\\-\\*]\\s*$"]) {  // bullet-only lines
        [[NSRegularExpression regularExpressionWithPattern:pat
            options:NSRegularExpressionDotMatchesLineSeparators error:nil]
         replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@" "];
    }
    // Take last meaningful paragraph
    NSArray *paras = [[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                        componentsSeparatedByString:@"\n\n"];
    NSString *last = paras.lastObject ?: @"";
    last = [last stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (last.length > 400) last = [last substringToIndex:400];
    return last;
}

// ── Misc helpers ──────────────────────────────────────────────────────────────

- (NSString *)findExe:(NSString *)name extra:(NSArray *)extra {
    NSMutableArray *dirs = [extra mutableCopy];
    [dirs addObjectsFromArray:
     [([[NSProcessInfo processInfo] environment][@"PATH"] ?: @"") componentsSeparatedByString:@":"]];
    [dirs addObjectsFromArray:@[@"/usr/local/bin", @"/opt/homebrew/bin"]];
    for (NSString *d in dirs) {
        NSString *p = [d stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

- (void)speechRecognizer:(SFSpeechRecognizer *)r availabilityDidChange:(BOOL)available {
    self.voiceBtn.enabled = available;
}

- (void)dealloc {
    [self stopListening];
    [self.cliTask terminate];
    [self.ttsDebounce invalidate];
    [self.headTimer invalidate];
    [self.sayTask terminate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
