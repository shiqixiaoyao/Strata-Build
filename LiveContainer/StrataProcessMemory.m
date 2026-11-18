#import "StrataProcessMemory.h"
#import <os/proc.h>
#import <mach/mach.h>
#import <Security/Security.h>
#import <unistd.h>
#import <sys/sysctl.h>
#import <TargetConditionals.h>

#if !TARGET_OS_OSX
extern void *SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(void *task, CFStringRef key, CFErrorRef *error);
#endif

// Capture the real process identity before the guest runtime replaces bundle/home metadata.
// Samples contain no pairing data, account identifiers, paths, or game contents.
void StrataStartProcessMemoryDiagnostics(NSString *group, NSString *guestName, NSString *executionMode) {
    NSURL *root = group.length ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] : nil;
    if (!root) return;
    NSURL *directory = [root URLByAppendingPathComponent:@"Library/StrataDiagnostics" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]) return;
    void *task = SecTaskCreateFromSelf(NULL);
    CFTypeRef value = task ? SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.developer.kernel.increased-memory-limit"), NULL) : NULL;
    BOOL increased = value && CFEqual(value, kCFBooleanTrue);
    if (value) CFRelease(value);
    if (task) CFRelease(task);
    const pid_t pid = getpid();
    NSString *name = guestName.lastPathComponent ?: @"Guest";
    NSURL *latest = [directory URLByAppendingPathComponent:@"guest-memory.json"];
    NSURL *byPID = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%d-memory.json", pid]];
    NSTimeInterval startedAt = NSDate.date.timeIntervalSince1970;
    void (^sample)(BOOL) = ^(BOOL detailed) {
        @autoreleasepool {
            task_vm_info_data_t vm = {0};
            mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
            BOOL hasFootprint = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS;
#if TARGET_OS_OSX
            uint64_t available = 0; // iOS headroom API is unavailable on native macOS.
#else
            uint64_t available = os_proc_available_memory();
#endif
            struct kinfo_proc process = {0}; size_t processSize = sizeof(process); int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
            BOOL attached = sysctl(mib, 4, &process, &processSize, NULL, 0) == 0 && (process.kp_proc.p_flag & P_TRACED);
            NSMutableDictionary *record = [@{@"schema":@1, @"pid":@(pid), @"guest":name, @"executionMode":executionMode ?: @"unknown",
                @"startedAt":@(startedAt), @"sampledAt":@(NSDate.date.timeIntervalSince1970),
                @"increasedMemoryEntitlement":@(increased), @"debuggerAttached":@(attached), @"availableBytes":@(available),
                @"availableReported":@(available > 0), @"footprintReported":@(hasFootprint)} mutableCopy];
            if (hasFootprint) record[@"footprintBytes"] = @(vm.phys_footprint);
            NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
            // 管理库存的是 guest-memory.json（latest）；按 PID 那份只有排查多进程时才用得上。
            [json writeToURL:latest options:NSDataWritingAtomic error:nil];
            if (detailed) [json writeToURL:byPID options:NSDataWritingAtomic error:nil];
        }
    };
    sample(YES);
    // 采样只为诊断：15 秒一次、5 秒宽限（系统能把这次唤醒并到别的 timer 上），按 PID 的明细
    // 再降一档。原来 5 秒写两个文件且后台照跑，白白吃掉后台的 IO 与唤醒配额。
    static dispatch_source_t timer;
    if (timer) dispatch_source_cancel(timer);
    __block NSUInteger tick = 0;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), 15 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        BOOL detailed = (tick++ % 4) == 0;
        sample(detailed);
    });
    dispatch_resume(timer);
}

// Live memory overlay: every Strata process (Strata, apps in their own process, helper/donor processes)
// writes its footprint and limit once a second while the overlay is enabled.
void StrataStartMemoryOverlaySampler(NSString *group, NSString *role, NSString *name) {
    static dispatch_source_t timer;
    static NSString *currentRole, *currentName;
    static NSUserDefaults *settings;
    static NSURL *file;
    @synchronized ([NSProcessInfo class]) { currentRole = [role copy]; currentName = [name copy]; }
    if (timer || !group) return;
    NSURL *root = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return;
    NSURL *directory = [root URLByAppendingPathComponent:@"Library/StrataDiagnostics/Live" isDirectory:YES];
    file = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"proc-%d.json", getpid()]];
    settings = [[NSUserDefaults alloc] initWithSuiteName:group];
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    // 浮层自己看的是秒级数据，2 秒一次足够；宽限给满 1 秒，后台时系统可以合并唤醒。
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        if (![settings boolForKey:@"StrataMemoryOverlay"]) { [NSFileManager.defaultManager removeItemAtURL:file error:nil]; return; }
        task_vm_info_data_t vm = {0};
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) != KERN_SUCCESS) return;
        NSString *r, *n;
        @synchronized ([NSProcessInfo class]) { r = currentRole ?: @"process"; n = currentName ?: @""; }
        NSDictionary *sample = @{@"pid": @(getpid()), @"role": r, @"name": n, @"footprint": @(vm.phys_footprint),
                                 @"available": @(os_proc_available_memory()), @"time": @(NSDate.date.timeIntervalSince1970)};
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSJSONSerialization dataWithJSONObject:sample options:0 error:nil] writeToURL:file atomically:YES];
    });
    dispatch_resume(timer);
}
