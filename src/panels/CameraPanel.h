#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface CameraPanel : NSViewController

/// Called from C callback (any thread) with a JPEG frame
- (void)receivedJPEGFrame:(const char *)data length:(int)length;

@end

/// Global camera callback — forwards to the active CameraPanel instance
void camera_frame_callback(const char *data, int length);

NS_ASSUME_NONNULL_END
