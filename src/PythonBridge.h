#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * PythonBridge — embeds CPython 3.12 and provides access to python/bridge.py
 */
@interface PythonBridge : NSObject

/// Initialize the Python interpreter. Returns YES on success.
- (BOOL)initialize;

/// Call a function in bridge.py with optional keyword args (dict -> JSON).
/// Returns the string result, or nil on error.
- (nullable NSString *)callFunction:(NSString *)name withArgs:(nullable NSDictionary *)args;

/// Start the camera loop, registering a C callback for JPEG frames.
/// The callback signature is: void callback(const char *jpeg, int length)
- (BOOL)startCameraWithCallback:(void *)callbackPtr;

/// Start a live voice session (Gemini Live or OpenAI Realtime).
/// api: @"gemini" or @"openai"
/// statusFn:     void (*)(const char *msg)
/// transcriptFn: void (*)(const char *text, int is_user)   0=assistant 1=user
/// speakingFn:   void (*)(int speaking)                     1=started 0=stopped
- (BOOL)startLiveSessionWithAPI:(NSString *)api
                       statusFn:(void *)statusPtr
                   transcriptFn:(void *)transcriptPtr
                      speakingFn:(void *)speakingPtr;

/// Stop the running live session.
- (void)stopLiveSession;

/// Finalize the Python interpreter (call before app exit).
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
