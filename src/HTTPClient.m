#import "HTTPClient.h"

@interface HTTPClient ()
@property (nonatomic, strong) NSURLSession *session;        // short-timeout: status polls
@property (nonatomic, strong) NSURLSession *actionSession;  // long-timeout: blocking moves
@property (nonatomic, copy)   NSString *baseURL;
@end

@implementation HTTPClient

static NSURLSession *_makeSession(NSTimeInterval requestTimeout, NSTimeInterval resourceTimeout) {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest  = requestTimeout;
    cfg.timeoutIntervalForResource = resourceTimeout;
    return [NSURLSession sessionWithConfiguration:cfg];
}

- (instancetype)initWithBaseURL:(NSString *)baseURL {
    self = [super init];
    if (self) {
        _baseURL      = [baseURL copy];
        _session      = _makeSession(5.0, 30.0);    // fast polls
        _actionSession = _makeSession(120.0, 180.0); // blocking move endpoints
    }
    return self;
}

- (void)getJSON:(NSString *)path completion:(HTTPJSONBlock)completion {
    NSURL *url = [NSURL URLWithString:[self.baseURL stringByAppendingString:path]];
    NSURLRequest *req = [NSURLRequest requestWithURL:url];
    [[self.session dataTaskWithRequest:req
                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        [self deliverData:d response:(NSHTTPURLResponse *)r error:e completion:completion];
    }] resume];
}

- (void)postJSON:(NSString *)path body:(id)body completion:(HTTPJSONBlock)completion {
    NSURL *url = [NSURL URLWithString:[self.baseURL stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    if (body) {
        NSError *encErr = nil;
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encErr];
        if (encErr) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, encErr); });
            return;
        }
    }

    // Use short session for postJSON — real-time goto/control calls
    [[self.session dataTaskWithRequest:req
                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        [self deliverData:d response:(NSHTTPURLResponse *)r error:e completion:completion];
    }] resume];
}

- (void)postAction:(NSString *)path body:(id)body completion:(HTTPJSONBlock)completion {
    NSURL *url = [NSURL URLWithString:[self.baseURL stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    if (body) {
        NSError *encErr = nil;
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encErr];
        if (encErr) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, encErr); });
            return;
        }
    }

    // Use action session (120s timeout) — blocking move endpoints (wake_up, goto_sleep, behaviors)
    [[self.actionSession dataTaskWithRequest:req
                           completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        [self deliverData:d response:(NSHTTPURLResponse *)r error:e completion:completion];
    }] resume];
}

- (void)cancelAll {
    [self.session invalidateAndCancel];
    [self.actionSession invalidateAndCancel];
    self.session       = _makeSession(5.0, 30.0);
    self.actionSession = _makeSession(120.0, 180.0);
}

// ── Private ──────────────────────────────────────────────────────────────────

- (void)deliverData:(NSData *)data
           response:(NSHTTPURLResponse *)response
              error:(NSError *)error
         completion:(HTTPJSONBlock)completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) { completion(nil, error); return; }
        if (response.statusCode < 200 || response.statusCode >= 300) {
            NSError *e = [NSError errorWithDomain:@"HTTPClient"
                                             code:response.statusCode
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode]}];
            completion(nil, e);
            return;
        }
        if (!data || data.length == 0) { completion(nil, nil); return; }
        NSError *jsonErr = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        completion(json, jsonErr);
    });
}

@end
