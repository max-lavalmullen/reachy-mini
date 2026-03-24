#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^HTTPResponseBlock)(NSData * _Nullable data,
                                  NSHTTPURLResponse * _Nullable response,
                                  NSError * _Nullable error);
typedef void (^HTTPJSONBlock)(id _Nullable json, NSError * _Nullable error);
typedef void (^WSMessageBlock)(NSData *data);

/**
 * HTTPClient — shared NSURLSession wrapper for daemon REST API.
 * All callbacks are delivered on the main queue unless noted.
 */
@interface HTTPClient : NSObject

- (instancetype)initWithBaseURL:(NSString *)baseURL;

/// GET /path → JSON callback
- (void)getJSON:(NSString *)path completion:(HTTPJSONBlock)completion;

/// POST /path with JSON body → JSON callback (5 s timeout — real-time control)
- (void)postJSON:(NSString *)path body:(nullable id)body completion:(HTTPJSONBlock)completion;

/// POST /path — long-timeout action (wake_up, goto_sleep, behavior play — may block 30+ s)
- (void)postAction:(NSString *)path body:(nullable id)body completion:(HTTPJSONBlock)completion;

/// Cancel all in-flight requests
- (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
