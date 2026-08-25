#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <signal.h>

static const int kPort = 17891;
static NSString * const kEndpoint = @"https://status.input.im/api/status";
static NSString * const kStatePath = @"/var/mobile/Library/Preferences/com.gan1quan.aiinputstatus.background.json";
static volatile sig_atomic_t running = 1;

@interface PollState : NSObject
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
static NSDictionary *StateDictionary(PollState *s) {
    return @{ @"version": @1, @"daemon": @"aiinputstatusd", @"attempts": @(s.attempts), @"successes": @(s.successes), @"failures": @(s.failures), @"last_attempt": @(s.lastAttempt), @"last_success": @(s.lastSuccess), @"last_failure": @(s.lastFailure), @"last_interval": @(s.lastInterval), @"last_error": s.lastError ?: [NSNull null], @"payload": s.payload ?: [NSNull null] };
}
static void SaveState(PollState *s) {
    NSDictionary *d = StateDictionary(s);
    NSData *data = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    [data writeToFile:kStatePath atomically:YES];
}
static void Poll(PollState *s) {
    NSDate *started = [NSDate date];
    NSTimeInterval now = started.timeIntervalSince1970;
    if (s.lastAttempt > 0) s.lastInterval = now - s.lastAttempt;
    s.lastAttempt = now; s.attempts++;
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:kEndpoint] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *body = nil; __block NSError *error = nil; __block NSInteger code = 0;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) { body = data; error = e; code = [(NSHTTPURLResponse *)response statusCode]; dispatch_semaphore_signal(sem); }];
    [task resume]; dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15LL * NSEC_PER_SEC));
    if (body && code >= 200 && code < 300 && !error) { s.successes++; s.lastSuccess = [NSDate date].timeIntervalSince1970; s.lastError = nil; s.payload = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]; }
    else { s.failures++; s.lastFailure = [NSDate date].timeIntervalSince1970; s.lastError = error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)code]; }
    SaveState(s);
}
static NSData *JSONResponse(PollState *s) { return [NSJSONSerialization dataWithJSONObject:StateDictionary(s) options:0 error:nil]; }
static void Serve(PollState *s) {
    int server = socket(AF_INET, SOCK_STREAM, 0); int yes = 1; setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0}; addr.sin_len = sizeof(addr); addr.sin_family = AF_INET; addr.sin_port = htons(kPort); addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(server, 4) < 0) return;
    while (running) { struct sockaddr_in client = {0}; socklen_t len = sizeof(client); int fd = accept(server, (struct sockaddr *)&client, &len); if (fd < 0) continue; char buffer[512] = {0}; read(fd, buffer, sizeof(buffer)-1); NSData *json = JSONResponse(s); NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)json.length]; NSMutableData *out = [header dataUsingEncoding:NSUTF8StringEncoding].mutableCopy; [out appendData:json]; write(fd, out.bytes, out.length); close(fd); }
    close(server);
}
int main(int argc, const char *argv[]) { @autoreleasepool { signal(SIGTERM, stopHandler); signal(SIGINT, stopHandler); PollState *state = [PollState new]; Poll(state); dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ Serve(state); }); while (running) { sleep(30); if (running) Poll(state); } } return 0; }
