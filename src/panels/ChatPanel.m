#import "ChatPanel.h"
#import "../AppDelegate.h"
#import "../HTTPClient.h"
#import "../PythonBridge.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>

static NSString * const kMovePattern = @"<!--\\s*(?:MOVE|BEHAVIOR):\\s*(\\S+)\\s*-->";

typedef NS_ENUM(NSInteger, ChatBot) {
    ChatBotClaude       = 0,
    ChatBotGemini       = 1,
    ChatBotCodex        = 2,
    ChatBotLiveGemini   = 3,
    ChatBotLiveOpenAI   = 4,
};

// ── Simple chat bubble ────────────────────────────────────────────────────────

@interface ChatBubble : NSView
@end
@implementation ChatBubble
@end

// ── ChatPanel ─────────────────────────────────────────────────────────────────

@interface ChatPanel () <SFSpeechRecognizerDelegate>
// UI — shared
@property (nonatomic, strong) NSSegmentedControl *botPicker;
@property (nonatomic, strong) NSButton           *ttsCheck;
@property (nonatomic, strong) NSButton           *yoloCheck;
@property (nonatomic, strong) NSTextField        *statusLabel;
@property (nonatomic, strong) NSScrollView       *chatScroll;
@property (nonatomic, strong) NSView             *chatStack;
@property (nonatomic, strong) NSTextField        *transcriptLabel;
@property (nonatomic, strong) NSButton           *clearBtn;

// UI — classic chat mode (segments 0,1)
@property (nonatomic, strong) NSButton    *talkBtn;
@property (nonatomic, strong) NSTextField *textInput;
@property (nonatomic, strong) NSButton    *sendBtn;

// UI — live mode (segments 2,3)
@property (nonatomic, strong) NSButton *liveStartBtn;
@property (nonatomic, assign) BOOL      liveActive;

// Speech (classic push-to-talk)
@property (nonatomic, strong) SFSpeechRecognizer                    *recognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *sttRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask               *sttTask;
@property (nonatomic, strong) AVAudioEngine                        *audioEngine;
@property (nonatomic, assign) BOOL                                   listening;

// LLM (classic -p mode)
@property (nonatomic, strong) NSTask *llmTask;
@property (nonatomic, assign) BOOL    thinking;

// History for classic mode context
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *history;

// Chat stack layout
@property (nonatomic, assign) CGFloat stackH;

// Head animation timer (during live speaking)
@property (nonatomic, strong) NSTimer *headTimer;
@property (nonatomic, assign) double   headPhase;

// Move marker regex
@property (nonatomic, strong) NSRegularExpression *moveRE;

// Methods called from C callbacks
- (void)addBubble:(NSString *)text isUser:(BOOL)isUser;
- (void)setSpeaking:(BOOL)speaking;
- (void)updateIdleStatus;
- (void)checkForMoveMarkers:(NSString *)text;
@end

// ── C callbacks (called from Python background thread) ────────────────────────
// Defined here so the compiler can see the ChatPanel class extension above.

static ChatPanel *_livePanel = nil;

static void liveStatusCB(const char *msg) {
    NSString *s = msg ? [NSString stringWithUTF8String:msg] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        _livePanel.statusLabel.stringValue = s;
    });
}

static void liveTranscriptCB(const char *text, int isUser) {
    NSString *s = text ? [NSString stringWithUTF8String:text] : @"";
    BOOL user = (isUser != 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!s.length) return;
        [_livePanel addBubble:s isUser:user];
        // Trigger robot animations embedded in assistant replies
        if (!user) [_livePanel checkForMoveMarkers:s];
    });
}

static void liveSpeakingCB(int speaking) {
    BOOL isSpeaking = (speaking != 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [_livePanel setSpeaking:isSpeaking];
    });
}

@implementation ChatPanel

- (void)loadView {
    self.view = [[NSView alloc] init];
    self.history = [NSMutableArray array];
    self.moveRE  = [NSRegularExpression regularExpressionWithPattern:kMovePattern
                                                             options:NSRegularExpressionCaseInsensitive
                                                               error:nil];
    [self buildUI];
    [self requestSpeechAccess];
    [self addBubble:@"Reachy conversation is ready. Use Claude, Gemini, Codex, or a live voice model."
             isUser:NO];
}

// ── Build UI (Auto Layout) ────────────────────────────────────────────────────

- (void)buildUI {
    NSView *v = self.view;
    v.wantsLayer = YES;
    v.layer.backgroundColor = [NSColor colorWithWhite:0.06 alpha:1].CGColor;

    // Bot picker — 5 segments
    self.botPicker = [NSSegmentedControl
        segmentedControlWithLabels:@[@"Claude", @"Gemini", @"Codex", @"Live Gemini", @"Live OpenAI"]
                      trackingMode:NSSegmentSwitchTrackingSelectOne
                            target:self action:@selector(pickerChanged:)];
    self.botPicker.selectedSegment = 0;

    // TTS (classic mode)
    self.ttsCheck = [NSButton checkboxWithTitle:@"Speak replies" target:nil action:nil];
    self.ttsCheck.state = NSControlStateValueOn;
    self.ttsCheck.contentTintColor = [NSColor colorWithRed:0.35 green:0.8 blue:0.95 alpha:1];

    // Auto-approve (classic mode)
    self.yoloCheck = [NSButton checkboxWithTitle:@"Auto-approve" target:nil action:nil];
    self.yoloCheck.state = NSControlStateValueOn;
    self.yoloCheck.contentTintColor = [NSColor colorWithRed:0.48 green:0.88 blue:0.63 alpha:1];

    // Status
    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.textColor = [NSColor colorWithWhite:0.72 alpha:1];
    self.statusLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];

    // Chat scroll view
    self.chatStack  = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 820, 40)];
    self.chatStack.wantsLayer = YES;
    self.chatStack.layer.backgroundColor = [NSColor colorWithWhite:0.09 alpha:1].CGColor;
    self.chatScroll = [[NSScrollView alloc] init];
    self.chatScroll.hasVerticalScroller = YES;
    self.chatScroll.borderType = NSNoBorder;
    self.chatScroll.backgroundColor = [NSColor clearColor];
    self.chatScroll.documentView = self.chatStack;
    self.chatScroll.wantsLayer = YES;
    self.chatScroll.layer.cornerRadius = 18;
    self.chatScroll.layer.borderWidth = 1;
    self.chatScroll.layer.borderColor = [NSColor colorWithWhite:0.18 alpha:1].CGColor;
    self.chatScroll.layer.backgroundColor = [NSColor colorWithWhite:0.09 alpha:1].CGColor;
    self.stackH = 8;

    // Live transcript label
    self.transcriptLabel = [NSTextField labelWithString:@""];
    self.transcriptLabel.textColor = [NSColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1];
    self.transcriptLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];

    // Clear button
    self.clearBtn = [NSButton buttonWithTitle:@"Reset" target:self action:@selector(clearChat:)];
    self.clearBtn.bezelStyle = NSBezelStyleRounded;

    // ── Classic mode controls ──────────────────────────────────────────────────
    self.talkBtn = [NSButton buttonWithTitle:@"🎙  Push to Talk"
                                      target:self
                                      action:@selector(toggleTalk:)];
    self.talkBtn.bezelStyle = NSBezelStyleRounded;
    self.talkBtn.font = [NSFont boldSystemFontOfSize:13];
    self.talkBtn.enabled = NO;
    self.talkBtn.wantsLayer = YES;
    self.talkBtn.layer.cornerRadius = 10;
    self.talkBtn.layer.backgroundColor = [NSColor colorWithWhite:0.14 alpha:1].CGColor;
    self.talkBtn.layer.borderWidth = 1;
    self.talkBtn.layer.borderColor = [NSColor colorWithWhite:0.22 alpha:1].CGColor;

    self.textInput = [[NSTextField alloc] init];
    self.textInput.placeholderString = @"Ask Reachy or dictate into the active model…";
    self.textInput.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    self.textInput.target = self;
    self.textInput.action = @selector(sendText:);
    self.textInput.bezeled = NO;
    self.textInput.drawsBackground = YES;
    self.textInput.backgroundColor = [NSColor colorWithWhite:0.1 alpha:1];
    self.textInput.textColor = [NSColor colorWithWhite:0.94 alpha:1];
    self.textInput.focusRingType = NSFocusRingTypeNone;
    self.textInput.wantsLayer = YES;
    self.textInput.layer.cornerRadius = 10;
    self.textInput.layer.borderWidth = 1;
    self.textInput.layer.borderColor = [NSColor colorWithWhite:0.18 alpha:1].CGColor;

    self.sendBtn = [NSButton buttonWithTitle:@"Send" target:self action:@selector(sendText:)];
    self.sendBtn.bezelStyle = NSBezelStyleRounded;
    self.sendBtn.wantsLayer = YES;
    self.sendBtn.layer.cornerRadius = 10;
    self.sendBtn.layer.backgroundColor = [NSColor colorWithRed:0.18 green:0.48 blue:0.85 alpha:0.3].CGColor;
    self.sendBtn.layer.borderWidth = 1;
    self.sendBtn.layer.borderColor = [NSColor colorWithRed:0.3 green:0.68 blue:0.95 alpha:0.8].CGColor;

    // ── Live mode controls ─────────────────────────────────────────────────────
    self.liveStartBtn = [NSButton buttonWithTitle:@"▶  Start Live Session"
                                           target:self
                                           action:@selector(toggleLiveSession:)];
    self.liveStartBtn.bezelStyle = NSBezelStyleRounded;
    self.liveStartBtn.font = [NSFont boldSystemFontOfSize:14];
    self.liveStartBtn.hidden = YES;
    self.liveStartBtn.wantsLayer = YES;
    self.liveStartBtn.layer.cornerRadius = 12;
    self.liveStartBtn.layer.backgroundColor = [NSColor colorWithRed:0.12 green:0.38 blue:0.24 alpha:0.4].CGColor;
    self.liveStartBtn.layer.borderWidth = 1;
    self.liveStartBtn.layer.borderColor = [NSColor colorWithRed:0.3 green:0.8 blue:0.48 alpha:0.85].CGColor;

    // Add all subviews
    for (NSView *sub in @[self.botPicker, self.ttsCheck, self.yoloCheck,
                           self.statusLabel, self.chatScroll, self.transcriptLabel,
                           self.clearBtn,
                           self.talkBtn, self.textInput, self.sendBtn,
                           self.liveStartBtn]) {
        sub.translatesAutoresizingMaskIntoConstraints = NO;
        [v addSubview:sub];
    }

    // ── Constraints ───────────────────────────────────────────────────────────
    [NSLayoutConstraint activateConstraints:@[
        // Row 1: picker + checkboxes + clear
        [self.botPicker.topAnchor constraintEqualToAnchor:v.topAnchor constant:12],
        [self.botPicker.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],

        [self.ttsCheck.centerYAnchor constraintEqualToAnchor:self.botPicker.centerYAnchor],
        [self.ttsCheck.leadingAnchor constraintEqualToAnchor:self.botPicker.trailingAnchor constant:14],

        [self.yoloCheck.centerYAnchor constraintEqualToAnchor:self.botPicker.centerYAnchor],
        [self.yoloCheck.leadingAnchor constraintEqualToAnchor:self.ttsCheck.trailingAnchor constant:14],

        [self.clearBtn.centerYAnchor constraintEqualToAnchor:self.botPicker.centerYAnchor],
        [self.clearBtn.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
        [self.clearBtn.widthAnchor constraintEqualToConstant:64],

        // Row 2: status
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.botPicker.bottomAnchor constant:6],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
        [self.statusLabel.heightAnchor constraintEqualToConstant:16],

        // Chat scroll — fills middle
        [self.chatScroll.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:6],
        [self.chatScroll.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [self.chatScroll.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
        [self.chatScroll.bottomAnchor constraintEqualToAnchor:self.talkBtn.topAnchor constant:-8],

        // ── Classic mode row ───────────────────────────────────────────────────
        [self.talkBtn.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [self.talkBtn.bottomAnchor constraintEqualToAnchor:self.transcriptLabel.topAnchor constant:-4],
        [self.talkBtn.widthAnchor constraintEqualToConstant:150],
        [self.talkBtn.heightAnchor constraintEqualToConstant:36],

        [self.textInput.leadingAnchor constraintEqualToAnchor:self.talkBtn.trailingAnchor constant:10],
        [self.textInput.centerYAnchor constraintEqualToAnchor:self.talkBtn.centerYAnchor],
        [self.textInput.heightAnchor constraintEqualToConstant:30],
        [self.textInput.trailingAnchor constraintEqualToAnchor:self.sendBtn.leadingAnchor constant:-8],

        [self.sendBtn.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
        [self.sendBtn.centerYAnchor constraintEqualToAnchor:self.talkBtn.centerYAnchor],
        [self.sendBtn.widthAnchor constraintEqualToConstant:72],

        // ── Live mode button — same vertical slot ─────────────────────────────
        [self.liveStartBtn.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [self.liveStartBtn.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
        [self.liveStartBtn.bottomAnchor constraintEqualToAnchor:self.transcriptLabel.topAnchor constant:-4],
        [self.liveStartBtn.heightAnchor constraintEqualToConstant:40],

        // ── Transcript row ────────────────────────────────────────────────────
        [self.transcriptLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:20],
        [self.transcriptLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
        [self.transcriptLabel.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-10],
        [self.transcriptLabel.heightAnchor constraintEqualToConstant:16],
    ]];

    [self updateIdleStatus];
}

// ── Picker changed ────────────────────────────────────────────────────────────

- (void)pickerChanged:(id)sender {
    ChatBot bot = (ChatBot)self.botPicker.selectedSegment;
    BOOL isLive = (bot == ChatBotLiveGemini || bot == ChatBotLiveOpenAI);

    self.talkBtn.hidden       = isLive;
    self.textInput.hidden     = isLive;
    self.sendBtn.hidden       = isLive;
    self.ttsCheck.hidden      = isLive;
    self.yoloCheck.hidden     = isLive;
    self.liveStartBtn.hidden  = !isLive;

    if (!isLive && self.liveActive) {
        [self stopLiveSession];
        return;
    }

    [self updateIdleStatus];
}

// ── Speech permission ─────────────────────────────────────────────────────────

- (void)requestSpeechAccess {
    self.recognizer  = [[SFSpeechRecognizer alloc]
        initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    self.recognizer.delegate = self;
    self.audioEngine = [[AVAudioEngine alloc] init];

    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.talkBtn.enabled = (s == SFSpeechRecognizerAuthorizationStatusAuthorized);
            [self updateIdleStatus];
        });
    }];
}

- (void)updateIdleStatus {
    ChatBot bot = (ChatBot)self.botPicker.selectedSegment;
    BOOL isLive = (bot == ChatBotLiveGemini || bot == ChatBotLiveOpenAI);
    BOOL micReady = ([SFSpeechRecognizer authorizationStatus] ==
                     SFSpeechRecognizerAuthorizationStatusAuthorized);

    if (isLive) {
        self.statusLabel.stringValue = [NSString stringWithFormat:
            @"Mac mic → %@ → Reachy speaker",
            bot == ChatBotLiveGemini ? @"Gemini Live" : @"OpenAI Realtime"];
        return;
    }

    self.statusLabel.stringValue = [NSString stringWithFormat:
        @"Workspace: %@  ·  %@ input",
        [AppDelegate shared].workspacePath.lastPathComponent ?: @"Home",
        micReady ? @"voice + text" : @"text only"];
}

// ── Classic push-to-talk ──────────────────────────────────────────────────────

- (void)toggleTalk:(id)sender {
    self.listening ? [self stopListening] : [self startListening];
}

- (void)startListening {
    if (self.listening || self.thinking) return;

    self.sttRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.sttRequest.shouldReportPartialResults = YES;

    AVAudioInputNode *node = self.audioEngine.inputNode;
    AVAudioFormat *fmt = [node outputFormatForBus:0];

    __weak typeof(self) ws = self;
    self.sttTask = [self.recognizer recognitionTaskWithRequest:self.sttRequest
        resultHandler:^(SFSpeechRecognitionResult *res, NSError *e) {
            if (res) {
                ws.transcriptLabel.stringValue = [NSString stringWithFormat:@"🎙 %@",
                    res.bestTranscription.formattedString];
                if (res.isFinal && res.bestTranscription.formattedString.length) {
                    [ws stopListening];
                    [ws sendMessage:res.bestTranscription.formattedString];
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
    [self.talkBtn setTitle:@"⏹  Stop Listening"];
    self.talkBtn.wantsLayer = YES;
    self.talkBtn.layer.backgroundColor =
        [[NSColor systemRedColor] colorWithAlphaComponent:0.3].CGColor;
    self.statusLabel.stringValue = @"Listening… speak, then click Stop";
    self.transcriptLabel.stringValue = @"";
}

- (void)stopListening {
    if (!self.listening) return;
    self.listening = NO;
    [self.audioEngine.inputNode removeTapOnBus:0];
    [self.audioEngine stop];
    [self.sttRequest endAudio];
    [self.talkBtn setTitle:@"🎙  Push to Talk"];
    self.talkBtn.layer.backgroundColor = nil;
    self.transcriptLabel.stringValue = @"";
    if (!self.thinking) [self updateIdleStatus];
}

// ── Classic send ──────────────────────────────────────────────────────────────

- (void)sendText:(id)sender {
    NSString *t = self.textInput.stringValue;
    if (!t.length || self.thinking) return;
    self.textInput.stringValue = @"";
    [self sendMessage:t];
}

- (void)sendMessage:(NSString *)userMsg {
    if (self.thinking) return;
    self.thinking = YES;
    self.talkBtn.enabled = NO;
    self.sendBtn.enabled = NO;

    [self addBubble:userMsg isUser:YES];
    [self.history addObject:@{@"role": @"user", @"content": userMsg}];

    ChatBot bot = (ChatBot)self.botPicker.selectedSegment;
    NSString *cliPath = (bot == ChatBotClaude)
        ? [self findExe:@"claude" extra:@[@"/Users/maxl/.local/bin"]]
        : (bot == ChatBotGemini)
            ? [self findExe:@"gemini" extra:@[@"/opt/homebrew/bin"]]
            : [self findExe:@"codex" extra:@[@"/opt/homebrew/bin"]];

    if (!cliPath) {
        [self addBubble:[NSString stringWithFormat:@"Error: %@ not found.",
                         bot == ChatBotClaude ? @"claude" : (bot == ChatBotGemini ? @"gemini" : @"codex")]
                isUser:NO];
        [self finishThinking];
        return;
    }

    self.statusLabel.stringValue = [NSString stringWithFormat:@"Asking %@ in %@…",
        bot == ChatBotClaude ? @"Claude" : (bot == ChatBotGemini ? @"Gemini" : @"Codex"),
        [AppDelegate shared].workspacePath.lastPathComponent ?: @"Home"];

    NSMutableString *prompt = [NSMutableString string];
    [prompt appendString:
        @"You are Reachy, a friendly robot assistant embodied in a Reachy Mini robot. "
        @"Keep responses conversational and brief (1-3 sentences). "
        @"You can trigger robot behaviors by including <!-- MOVE: name --> in your response. "
        @"Available emotions: happy1, happy2, sad1, surprised1. "];

    NSArray *recent = self.history.count > 6
        ? [self.history subarrayWithRange:NSMakeRange(self.history.count - 6, 6)]
        : self.history;
    for (NSDictionary *turn in recent) {
        [prompt appendFormat:@"%@: %@\n",
            [turn[@"role"] isEqual:@"user"] ? @"Human" : @"Reachy", turn[@"content"]];
    }
    [prompt appendString:@"Reachy:"];

    BOOL yolo = (self.yoloCheck.state == NSControlStateValueOn);
    NSMutableArray *args = [NSMutableArray array];
    if (bot == ChatBotClaude) {
        [args addObjectsFromArray:@[@"-p", [prompt copy]]];
        if (yolo) [args addObject:@"--dangerously-skip-permissions"];
    } else if (bot == ChatBotGemini) {
        [args addObjectsFromArray:@[@"-p", [prompt copy]]];
        if (yolo) [args addObject:@"--yolo"];
    } else {
        [args addObjectsFromArray:@[@"exec", @"--skip-git-repo-check"]];
        if (yolo) [args addObject:@"--full-auto"];
        [args addObject:[prompt copy]];
    }

    [self addBubble:@"…" isUser:NO];
    [self runLLM:cliPath args:args];
}

- (void)runLLM:(NSString *)path args:(NSArray *)args {
    self.llmTask = [[NSTask alloc] init];
    self.llmTask.launchPath = @"/usr/bin/script";
    NSMutableArray *scriptArgs = [@[@"-q", @"/dev/null", path] mutableCopy];
    [scriptArgs addObjectsFromArray:args];
    self.llmTask.arguments = scriptArgs;
    self.llmTask.currentDirectoryURL =
        [NSURL fileURLWithPath:[AppDelegate shared].workspacePath isDirectory:YES];

    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"PATH"] = [@"/Users/maxl/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
                    stringByAppendingString:env[@"PATH"] ?: @""];
    env[@"HOME"] = NSHomeDirectory();
    env[@"TERM"] = @"xterm-256color";
    self.llmTask.environment = env;

    NSPipe *out = [NSPipe pipe];
    self.llmTask.standardOutput = out;
    self.llmTask.standardError  = out;

    NSMutableString *accum = [NSMutableString string];
    NSFileHandle *outFH = out.fileHandleForReading;
    outFH.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *d = [handle availableData];
        if (!d.length) return;
        NSString *chunk = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        @synchronized (accum) {
            [accum appendString:chunk];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (accum) {
                [self replaceLastBubble:[accum copy]];
            }
        });
    };

    __weak typeof(self) ws = self;
    self.llmTask.terminationHandler = ^(NSTask *t) {
        dispatch_async(dispatch_get_main_queue(), ^{
            outFH.readabilityHandler = nil;
            NSString *reply = nil;
            @synchronized (accum) {
                reply = [accum copy];
            }
            if (!reply.length) reply = @"(no response)";
            [ws.history addObject:@{@"role": @"assistant", @"content": reply}];
            [ws replaceLastBubble:reply];
            [ws checkForMoveMarkers:reply];
            if (ws.ttsCheck.state == NSControlStateValueOn) [ws speak:reply];
            [ws finishThinking];
        });
    };

    NSError *e = nil;
    [self.llmTask launchAndReturnError:&e];
    if (e) {
        [self replaceLastBubble:[NSString stringWithFormat:@"Error: %@", e.localizedDescription]];
        [self finishThinking];
    }
}

- (void)finishThinking {
    self.thinking = NO;
    self.talkBtn.enabled = YES;
    self.sendBtn.enabled = YES;
    [self updateIdleStatus];
}

// ── Live session ──────────────────────────────────────────────────────────────

- (void)toggleLiveSession:(id)sender {
    self.liveActive ? [self stopLiveSession] : [self startLiveSession];
}

- (void)startLiveSession {
    _livePanel = self;
    self.liveActive = YES;
    self.liveStartBtn.title = @"⏹  Stop Live Session";
    self.liveStartBtn.wantsLayer = YES;
    self.liveStartBtn.layer.backgroundColor =
        [[NSColor systemRedColor] colorWithAlphaComponent:0.25].CGColor;
    self.statusLabel.stringValue = @"Starting live session…";

    ChatBot bot = (ChatBot)self.botPicker.selectedSegment;
    NSString *apiStr = (bot == ChatBotLiveGemini) ? @"gemini" : @"openai";

    BOOL started = [[AppDelegate shared].pythonBridge
        startLiveSessionWithAPI:apiStr
                       statusFn:(void *)liveStatusCB
                   transcriptFn:(void *)liveTranscriptCB
                      speakingFn:(void *)liveSpeakingCB];
    if (!started) {
        [self stopLiveSession];
        self.statusLabel.stringValue = @"Live session failed to start";
    }
}

- (void)stopLiveSession {
    [[AppDelegate shared].pythonBridge stopLiveSession];
    _livePanel = nil;
    self.liveActive = NO;
    self.liveStartBtn.title = @"▶  Start Live Session";
    self.liveStartBtn.layer.backgroundColor =
        [NSColor colorWithRed:0.12 green:0.38 blue:0.24 alpha:0.4].CGColor;
    [self updateIdleStatus];
    [self setSpeaking:NO];
}

// ── Head animation ────────────────────────────────────────────────────────────

- (void)setSpeaking:(BOOL)speaking {
    if (speaking) {
        if (!self.headTimer) {
            self.headPhase = 0.0;
            self.headTimer = [NSTimer scheduledTimerWithTimeInterval:0.7
                                                             target:self
                                                           selector:@selector(animateHead)
                                                           userInfo:nil
                                                            repeats:YES];
        }
    } else {
        [self.headTimer invalidate];
        self.headTimer = nil;
        // Return head to neutral
        [[AppDelegate shared].httpClient
            postJSON:@"/api/move/goto"
                body:@{@"head_pose": @{@"pan": @0, @"tilt": @(0.1)},
                       @"antennas": @[@(0), @(0)],
                       @"duration": @(0.6)}
          completion:^(id j, NSError *e){}];
    }
}

- (void)animateHead {
    self.headPhase += 0.9;
    double pan  = sin(self.headPhase * 0.7) * 0.12;
    double tilt = 0.08 + sin(self.headPhase * 1.1 + 1.0) * 0.06;
    double ant  = sin(self.headPhase * 1.3) * 0.25;

    [[AppDelegate shared].httpClient
        postJSON:@"/api/move/goto"
            body:@{@"head_pose": @{@"pan": @(pan), @"tilt": @(tilt)},
                   @"antennas": @[@(ant), @(-ant)],
                   @"duration": @(0.5)}
      completion:^(id j, NSError *e){}];
}

// ── TTS (classic mode) ────────────────────────────────────────────────────────

- (void)speak:(NSString *)text {
    NSMutableString *s = [text mutableCopy];
    for (NSString *pat in @[@"<!--.*?-->", @"```[\\s\\S]*?```", @"`[^`]+`"]) {
        [[NSRegularExpression regularExpressionWithPattern:pat
            options:NSRegularExpressionDotMatchesLineSeparators error:nil]
         replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    }
    NSString *clean = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!clean.length) return;
    NSTask *say = [[NSTask alloc] init];
    NSString *voice = [[NSProcessInfo processInfo] environment][@"REACHY_SAY_VOICE"] ?: @"Samantha";
    say.launchPath = @"/usr/bin/say";
    say.arguments  = @[@"-v", voice, clean];
    [say launch];
}

// ── MOVE markers ─────────────────────────────────────────────────────────────

- (void)checkForMoveMarkers:(NSString *)text {
    for (NSTextCheckingResult *m in [self.moveRE matchesInString:text options:0
                                                           range:NSMakeRange(0, text.length)]) {
        if (m.numberOfRanges >= 2) {
            NSString *name = [text substringWithRange:[m rangeAtIndex:1]];
            [[AppDelegate shared].httpClient
             postJSON:[NSString stringWithFormat:
                       @"/api/move/play/recorded-move-dataset/emotions/%@", name]
                 body:nil completion:^(id j, NSError *e){}];
        }
    }
}

// ── Chat bubble UI ────────────────────────────────────────────────────────────

- (void)addBubble:(NSString *)text isUser:(BOOL)isUser {
    CGFloat w  = MAX(self.chatScroll.frame.size.width - 4, 400);
    CGFloat maxW = w * 0.75;

    NSTextField *lbl = [NSTextField wrappingLabelWithString:text];
    lbl.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    lbl.textColor = [NSColor colorWithWhite:0.97 alpha:1];
    lbl.maximumNumberOfLines = 0;
    NSSize fit = [lbl sizeThatFits:NSMakeSize(maxW - 24, 9999)];
    fit.width  = MIN(fit.width, maxW - 24);

    CGFloat bw = fit.width + 24;
    CGFloat bh = MAX(fit.height, 18) + 22;
    CGFloat bx = isUser ? w - bw - 12 : 12;

    NSView *bubble = [[NSView alloc] initWithFrame:NSMakeRect(bx, self.stackH, bw, bh)];
    bubble.wantsLayer = YES;
    bubble.layer.cornerRadius = 16;
    bubble.layer.borderWidth = 1;
    bubble.layer.backgroundColor = isUser
        ? [[NSColor colorWithRed:0.18 green:0.46 blue:0.84 alpha:1] CGColor]
        : [[NSColor colorWithWhite:0.16 alpha:1] CGColor];
    bubble.layer.borderColor = isUser
        ? [[NSColor colorWithRed:0.36 green:0.7 blue:1 alpha:0.85] CGColor]
        : [[NSColor colorWithWhite:0.24 alpha:1] CGColor];
    lbl.frame = NSMakeRect(12, (bh - fit.height) / 2, fit.width, fit.height);
    [bubble addSubview:lbl];

    CGFloat newH = MAX(self.stackH + bh + 8, self.chatScroll.contentView.bounds.size.height);
    [self.chatStack setFrameSize:NSMakeSize(w, newH)];
    [self.chatStack addSubview:bubble];
    self.stackH += bh + 8;
    [self scrollToBottom];
}

- (void)replaceLastBubble:(NSString *)newText {
    NSArray *subs = self.chatStack.subviews;
    if (!subs.count) { [self addBubble:newText isUser:NO]; return; }

    NSView *last = subs.lastObject;
    CGFloat oldY = last.frame.origin.y;
    [last removeFromSuperview];
    self.stackH = oldY;

    CGFloat w    = MAX(self.chatScroll.frame.size.width - 4, 400);
    CGFloat maxW = w * 0.75;

    NSTextField *lbl = [NSTextField wrappingLabelWithString:newText];
    lbl.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    lbl.textColor = [NSColor colorWithWhite:0.97 alpha:1];
    lbl.maximumNumberOfLines = 0;
    NSSize fit = [lbl sizeThatFits:NSMakeSize(maxW - 24, 9999)];
    fit.width  = MIN(fit.width, maxW - 24);

    CGFloat bw = fit.width + 24;
    CGFloat bh = MAX(fit.height, 18) + 22;

    NSView *bubble = [[NSView alloc] initWithFrame:NSMakeRect(12, oldY, bw, bh)];
    bubble.wantsLayer = YES;
    bubble.layer.cornerRadius = 16;
    bubble.layer.borderWidth = 1;
    bubble.layer.backgroundColor = [[NSColor colorWithWhite:0.16 alpha:1] CGColor];
    bubble.layer.borderColor = [[NSColor colorWithWhite:0.24 alpha:1] CGColor];
    lbl.frame = NSMakeRect(12, (bh - fit.height) / 2, fit.width, fit.height);
    [bubble addSubview:lbl];

    CGFloat newH = MAX(oldY + bh + 8, self.chatScroll.contentView.bounds.size.height);
    [self.chatStack setFrameSize:NSMakeSize(w, newH)];
    [self.chatStack addSubview:bubble];
    self.stackH = oldY + bh + 8;
    [self scrollToBottom];
}

- (void)scrollToBottom {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSView *doc = self.chatScroll.documentView;
        NSRect vis  = self.chatScroll.contentView.visibleRect;
        NSPoint pt  = NSMakePoint(0, doc.frame.size.height - vis.size.height);
        [self.chatScroll.contentView scrollToPoint:pt];
        [self.chatScroll reflectScrolledClipView:self.chatScroll.contentView];
    });
}

- (void)clearChat:(id)sender {
    for (NSView *sub in [self.chatStack.subviews copy]) [sub removeFromSuperview];
    self.stackH = 8;
    [self.history removeAllObjects];
    [self.chatStack setFrameSize:NSMakeSize(self.chatScroll.frame.size.width - 4, 40)];
    [self addBubble:@"Conversation reset. Reachy is ready for the next prompt." isUser:NO];
}

// ── SFSpeechRecognizerDelegate ────────────────────────────────────────────────

- (void)speechRecognizer:(SFSpeechRecognizer *)r availabilityDidChange:(BOOL)available {
    self.talkBtn.enabled = available && !self.thinking;
    if (!self.listening && !self.thinking) [self updateIdleStatus];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

- (NSString *)findExe:(NSString *)name extra:(NSArray *)extra {
    NSMutableArray *dirs = [extra mutableCopy];
    [dirs addObjectsFromArray:
     [([[NSProcessInfo processInfo] environment][@"PATH"] ?: @"") componentsSeparatedByString:@":"]];
    for (NSString *d in dirs) {
        NSString *p = [d stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

- (void)dealloc {
    [self stopListening];
    if (self.liveActive) [self stopLiveSession];
    [self.llmTask terminate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
