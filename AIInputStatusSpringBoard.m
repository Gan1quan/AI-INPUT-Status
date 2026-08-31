#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString * const kRefreshNotification = @"com.gan1quan.aiinputstatus.refresh";
static dispatch_source_t gRefreshTimer;

static void AIInputStatusNotify(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFNotificationName)kRefreshNotification, NULL, NULL, true);
}

__attribute__((constructor))
static void AIInputStatusSpringBoardLoaded(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        AIInputStatusNotify();
        gRefreshTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gRefreshTimer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(gRefreshTimer, ^{ AIInputStatusNotify(); });
        dispatch_resume(gRefreshTimer);
    });
}
