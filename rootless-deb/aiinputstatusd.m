#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <signal.h>
// Import RootHide path translation when building the daemon for roothide.
#include <roothide.h>

static const int kPort = 17891;
static const int kPollInterval = 30;
static const int kMinimumPollInterval = 5;
static const int kRequestTimeout = 10;
static NSString * const kEndpoint = @"https://status.input.im/api/status";
static NSString * const kStatePath = @"/var/aiinputstatusd-state.json";
static NSString * const kLegacyStatePath = @"/var/mobile/Library/Preferences/com.gan1quan.aiinputstatus.background.json";
static NSString * const kRefreshNotification = @"com.gan1quan.aiinputstatus.refresh";
static volatile sig_atomic_t running = 1;
static dispatch_queue_t workQueue;

@interface PollState : NSObject
@property(nonatomic) NSInteger version;
@property(nonatomic) NSInteger attempts;
@property(nonatomic) NSInteger successes;
@property(nonatomic) NSInteger failures;
@property(nonatomic) NSTimeInterval lastAttempt;
@property(nonatomic) NSTimeInterval lastSuccess;
@property(nonatomic) NSTimeInterval lastFailure;
@property(nonatomic) NSTimeInterval lastInterval;
@property(nonatomic, copy) NSString *lastError;
@property(nonatomic, copy) NSString *payload;
@end
@implementation PollState @end

static void stopHandler(int sig) { (void)sig; running = 0; }

static NSString *ResolvedPath(NSString *path) {
    return jbroot(path);
}

static PollState *LoadState(void) {
    PollState *s = [PollState new];
    s.version = 2;
    NSData *data = [NSData dataWithContentsOfFile:ResolvedPath(kStatePath)];
    if (!data) data = [NSData dataWithContentsOfFile:ResolvedPath(kLegacyStatePath)];
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![d isKindOfClass:[NSDictionary class]]) return s;
    s.version = [d[@"version"] integerValue] ?: 2;
    s.attempts = [d[@"attempts"] integerValue];
    s.successes = [d[@"successes"] integerValue];
    s.failures = [d[@"failures"] integerValue];
    s.lastAttempt = [d[@"last_attempt"] doubleValue];
    s.lastSuccess = [d[@"last_success"] doubleValue];
    s.lastFailure = [d[@"last_failure"] doubleValue];
    s.lastInterval = [d[@"last_interval"] doubleValue];
    if ([d[@"last_error"] isKindOfClass:[NSString class]]) s.lastError = d[@"last_error"];
    if ([d[@"payload"] isKindOfClass:[NSString class]]) s.payload = d[@"payload"];
    return s;
}

static NSDictionary *StateDictionary(PollState *s) {
    return @{ @"version": @(s.version ?: 2),
              @"daemon": @"aiinputstatusd",
              @"attempts": @(s.attempts),
              @"successes": @(s.successes),
              @"failures": @(s.failures),
              @"last_attempt": @(s.lastAttempt),
              @"last_success": @(s.lastSuccess),
              @"last_failure": @(s.lastFailure),
              @"last_interval": @(s.lastInterval),
              @"last_error": s.lastError ?: [NSNull null],
              @"payload": s.payload ?: [NSNull null] };
}

static void SaveState(PollState *s) {
    NSDictionary *d = StateDictionary(s);
    NSData *data = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (data) [data writeToFile:ResolvedPath(kStatePath) atomically:YES];
}

static BOOL RequestOnce(NSData **bodyOut, NSInteger *codeOut, NSString **errorOut) {
    NSURL *url = [NSURL URLWithString:kEndpoint];
    if (!url) { if (errorOut) *errorOut = @"无效状态服务地址"; return NO; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kRequestTimeout];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"AIInputStatusBackground/1.1" forHTTPHeaderField:@"User-Agent"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSError *error = nil;
    __block NSInteger code = 0;
    __block NSURLSessionDataTask *task = nil;
    task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
        body = data;
        error = e;
        code = [(NSHTTPURLResponse *)response statusCode];
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (kRequestTimeout + 2LL) * NSEC_PER_SEC));
    if (waitResult != 0) {
        [task cancel];
        if (errorOut) *errorOut = @"状态服务请求超时";
        return NO;
    }
    if (bodyOut) *bodyOut = body;
    if (codeOut) *codeOut = code;
    if (errorOut) *errorOut = error.localizedDescription ?: (code ? [NSString stringWithFormat:@"HTTP %ld", (long)code] : @"未收到 HTTP 响应");
    return body != nil && error == nil && code >= 200 && code < 300;
}

static void Poll(PollState *s) {
    NSDate *started = [NSDate date];
    NSTimeInterval now = started.timeIntervalSince1970;
    if (s.lastAttempt > 0) s.lastInterval = now - s.lastAttempt;
    s.lastAttempt = now;
    s.attempts++;
    SaveState(s);

    NSData *body = nil;
    NSInteger code = 0;
    NSString *errorText = nil;
    BOOL success = NO;
    for (NSInteger attempt = 0; attempt < 2 && running; attempt++) {
        if (attempt > 0) [NSThread sleepForTimeInterval:1.5];
        if (RequestOnce(&body, &code, &errorText)) { success = YES; break; }
    }
    if (success) {
        s.successes++;
        s.lastSuccess = [NSDate date].timeIntervalSince1970;
        s.lastError = nil;
        s.payload = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    } else {
        s.failures++;
        s.lastFailure = [NSDate date].timeIntervalSince1970;
        s.lastError = errorText ?: [NSString stringWithFormat:@"HTTP %ld", (long)code];
    }
    SaveState(s);
}

static NSData *JSONResponse(PollState *s) {
    return [NSJSONSerialization dataWithJSONObject:StateDictionary(s) options:0 error:nil];
}

static void WriteHTTP(int fd, NSInteger code, NSString *reason, NSData *body) {
    NSData *safeBody = body ?: [NSData data];
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (long)code, reason, (unsigned long)safeBody.length];
    NSMutableData *out = [header dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
    [out appendData:safeBody];
    const uint8_t *bytes = out.bytes;
    ssize_t remaining = (ssize_t)out.length;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, (size_t)remaining);
        if (written <= 0) break;
        bytes += written;
        remaining -= written;
    }
}

static NSString *RequestPath(const char *buffer) {
    NSString *request = [[NSString alloc] initWithUTF8String:buffer ?: ""];
    NSArray<NSString *> *parts = [request componentsSeparatedByString:@" "];
    if (parts.count >= 2) return parts[1];
    return @"/status";
}

static void Serve(PollState *s) {
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) return;
    int yes = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(server, 8) < 0) { close(server); return; }
    while (running) {
        int fd = accept(server, NULL, NULL);
        if (fd < 0) { if (errno == EINTR) continue; break; }
        char buffer[1024] = {0};
        read(fd, buffer, sizeof(buffer) - 1);
        NSString *path = RequestPath(buffer);
        __block NSData *json = nil;
        __block NSInteger code = 200;
        __block NSString *reason = @"OK";
        dispatch_sync(workQueue, ^{
            BOOL refresh = [path isEqualToString:@"/refresh"] || [path hasPrefix:@"/refresh?"];
            if (refresh) {
                NSTimeInterval age = [NSDate date].timeIntervalSince1970 - s.lastAttempt;
                if (s.lastAttempt == 0 || age >= kMinimumPollInterval) Poll(s);
                else if (s.lastError && s.lastSuccess < s.lastAttempt) { code = 503; reason = @"Service Unavailable"; }
            } else if (![path isEqualToString:@"/"] && ![path isEqualToString:@"/status"] && ![path hasPrefix:@"/status?"] && ![path isEqualToString:@"/health"]) {
                code = 404; reason = @"Not Found";
            }
            if (code == 200 && s.lastError && s.lastSuccess < s.lastAttempt && [path isEqualToString:@"/refresh"]) { code = 503; reason = @"Service Unavailable"; }
            json = JSONResponse(s);
        });
        WriteHTTP(fd, code, reason, json);
        close(fd);
    }
    close(server);
}

static void DarwinRefreshCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(workQueue, ^{
        PollState *s = (__bridge PollState *)observer;
        if (!s) return;
        NSTimeInterval age = [NSDate date].timeIntervalSince1970 - s.lastAttempt;
        if (s.lastAttempt == 0 || age >= kMinimumPollInterval) Poll(s);
    });
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argc; (void)argv;
        signal(SIGTERM, stopHandler);
        signal(SIGINT, stopHandler);
        workQueue = dispatch_queue_create("com.gan1quan.aiinputstatus.work", DISPATCH_QUEUE_SERIAL);
        PollState *state = LoadState();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge void *)state, DarwinRefreshCallback, (__bridge CFStringRef)kRefreshNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_async(workQueue, ^{ if (running) Poll(state); });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ Serve(state); });
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, workQueue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, kPollInterval * NSEC_PER_SEC), kPollInterval * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            if (!running) return;
            NSTimeInterval age = [NSDate date].timeIntervalSince1970 - state.lastAttempt;
            if (state.lastAttempt == 0 || age >= kMinimumPollInterval) Poll(state);
        });
        dispatch_resume(timer);
        while (running) [NSThread sleepForTimeInterval:1.0];
        dispatch_source_cancel(timer);
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge void *)state, (__bridge CFStringRef)kRefreshNotification, NULL);
    }
    return 0;
}
