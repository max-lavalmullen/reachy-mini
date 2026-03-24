#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol JoystickViewDelegate <NSObject>
/// Called on mouseDragged with normalized coordinates in [-1, 1]
- (void)joystickDidMoveToX:(CGFloat)x y:(CGFloat)y;
/// Called on mouseUp (released)
- (void)joystickDidRelease;
@end

/**
 * JoystickView — circular drag-to-move NSView.
 * Tracks mouse drag within a unit circle and notifies delegate with (x, y) in [-1, 1].
 */
@interface JoystickView : NSView

@property (nonatomic, weak, nullable) id<JoystickViewDelegate> delegate;

/// Current normalized position, (-1,-1) to (1,1)
@property (nonatomic, readonly) CGFloat normalizedX;
@property (nonatomic, readonly) CGFloat normalizedY;

@end

NS_ASSUME_NONNULL_END
