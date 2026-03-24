#import <Cocoa/Cocoa.h>

@class PythonBridge;
@class HTTPClient;

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) NSWindow *mainWindow;
@property (nonatomic, strong) PythonBridge *pythonBridge;
@property (nonatomic, strong) HTTPClient *httpClient;
@property (nonatomic, copy, readonly) NSString *workspacePath;

+ (AppDelegate *)shared;

@end
