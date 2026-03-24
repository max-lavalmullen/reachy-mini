#import "JoystickView.h"

@interface JoystickView ()
@property (nonatomic, assign) CGFloat thumbX;   // pixels from center
@property (nonatomic, assign) CGFloat thumbY;
@property (nonatomic, assign) BOOL dragging;
@end

@implementation JoystickView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = frame.size.width / 2;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// ── Drawing ───────────────────────────────────────────────────────────────────

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat cx = w / 2;
    CGFloat cy = h / 2;
    CGFloat outerR = MIN(cx, cy) - 2;
    CGFloat thumbR = outerR * 0.25;

    // Background circle
    NSBezierPath *bg = [NSBezierPath bezierPathWithOvalInRect:
                        NSMakeRect(cx - outerR, cy - outerR, outerR*2, outerR*2)];
    [[NSColor colorWithRed:14/255.0 green:25/255.0 blue:42/255.0 alpha:1] setFill];
    [bg fill];
    [[NSColor colorWithWhite:1.0 alpha:0.12] setStroke];
    bg.lineWidth = 1.5;
    [bg stroke];

    // Cross-hair
    [[NSColor colorWithWhite:1.0 alpha:0.18] setStroke];
    NSBezierPath *cross = [NSBezierPath bezierPath];
    [cross moveToPoint:NSMakePoint(cx - outerR + 4, cy)];
    [cross lineToPoint:NSMakePoint(cx + outerR - 4, cy)];
    [cross moveToPoint:NSMakePoint(cx, cy - outerR + 4)];
    [cross lineToPoint:NSMakePoint(cx, cy + outerR - 4)];
    cross.lineWidth = 1;
    [cross stroke];

    // Thumb
    CGFloat tx = cx + self.thumbX;
    CGFloat ty = cy + self.thumbY;
    NSColor *thumbColor = self.dragging
        ? [NSColor colorWithRed:61/255.0 green:222/255.0 blue:153/255.0 alpha:1]
        : [NSColor colorWithWhite:1.0 alpha:0.65];
    NSBezierPath *thumb = [NSBezierPath bezierPathWithOvalInRect:
                           NSMakeRect(tx - thumbR, ty - thumbR, thumbR*2, thumbR*2)];
    [thumbColor setFill];
    [thumb fill];
}

// ── Mouse handling ────────────────────────────────────────────────────────────

- (void)mouseDown:(NSEvent *)event {
    self.dragging = YES;
    [self updateThumbFromEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self updateThumbFromEvent:event];
}

- (void)mouseUp:(NSEvent *)event {
    self.dragging = NO;
    self.thumbX = 0;
    self.thumbY = 0;
    _normalizedX = 0;
    _normalizedY = 0;
    [self setNeedsDisplay:YES];
    [self.delegate joystickDidRelease];
}

- (void)updateThumbFromEvent:(NSEvent *)event {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat cx = self.bounds.size.width  / 2;
    CGFloat cy = self.bounds.size.height / 2;
    CGFloat outerR = MIN(cx, cy) - 2;

    CGFloat dx = local.x - cx;
    CGFloat dy = local.y - cy;
    CGFloat dist = sqrt(dx*dx + dy*dy);

    if (dist > outerR) {
        CGFloat scale = outerR / dist;
        dx *= scale;
        dy *= scale;
    }

    self.thumbX = dx;
    self.thumbY = dy;
    _normalizedX = dx / outerR;
    _normalizedY = dy / outerR;

    [self setNeedsDisplay:YES];
    [self.delegate joystickDidMoveToX:_normalizedX y:_normalizedY];
}

@end
