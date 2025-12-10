#import "PerformanceStats.h"
#import "FPSTracker.h"
#import <mach/mach.h>
#import <pthread.h>
#import <React/RCTBridge+Private.h>
#import <React/RCTBridge.h>
#import <React/RCTUIManager.h>

// Thanks to this guard, we won't import this header when we build for the old architecture.
#ifdef RCT_NEW_ARCH_ENABLED
#import "RNPerformanceStatsSpec.h"
#endif

// NOTICE: Mainly copied from here: https://github.com/facebook/react-native/blob/main/React/CoreModules/RCTPerfMonitor.mm

#pragma Resource usage methods
static vm_size_t RCTGetResidentMemorySize(void)
{
  vm_size_t memoryUsageInByte = 0;
  task_vm_info_data_t vmInfo;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  kern_return_t kernelReturn = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count);
  if (kernelReturn == KERN_SUCCESS) {
    memoryUsageInByte = (vm_size_t)vmInfo.phys_footprint;
  }
  return memoryUsageInByte;
}

// https://stackoverflow.com/a/8382889/3668241
float cpu_usage()
{
    kern_return_t kr;
    task_info_data_t tinfo;
    mach_msg_type_number_t task_info_count;

    task_info_count = TASK_INFO_MAX;
    kr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)tinfo, &task_info_count);
    if (kr != KERN_SUCCESS) {
        return -1;
    }

    task_basic_info_t      basic_info;
    thread_array_t         thread_list;
    mach_msg_type_number_t thread_count;

    thread_info_data_t     thinfo;
    mach_msg_type_number_t thread_info_count;

    thread_basic_info_t basic_info_th;
    uint32_t stat_thread = 0; // Mach threads

    basic_info = (task_basic_info_t)tinfo;

    // get threads in the task
    kr = task_threads(mach_task_self(), &thread_list, &thread_count);
    if (kr != KERN_SUCCESS) {
        return -1;
    }
    if (thread_count > 0)
        stat_thread += thread_count;

    long tot_sec = 0;
    long tot_usec = 0;
    float tot_cpu = 0;
    int j;

    for (j = 0; j < (int)thread_count; j++)
    {
        thread_info_count = THREAD_INFO_MAX;
        kr = thread_info(thread_list[j], THREAD_BASIC_INFO,
                         (thread_info_t)thinfo, &thread_info_count);
        if (kr != KERN_SUCCESS) {
            return -1;
        }

        basic_info_th = (thread_basic_info_t)thinfo;

        if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
            tot_sec = tot_sec + basic_info_th->user_time.seconds + basic_info_th->system_time.seconds;
            tot_usec = tot_usec + basic_info_th->user_time.microseconds + basic_info_th->system_time.microseconds;
            tot_cpu = tot_cpu + basic_info_th->cpu_usage / (float)TH_USAGE_SCALE * 100.0;
        }

    } // for each thread

    kr = vm_deallocate(mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_t));
    assert(kr == KERN_SUCCESS);

    return tot_cpu;
}

NSDictionary* threadStats(double appLaunchTime,
                          double totalMemory,
                          NSArray<NSString *> *threadNameFilter,
                          NSMutableDictionary<NSNumber*,
                          NSDictionary*> *lastThreadTimes,
                          thread_act_t jsThread)
{
    thread_act_array_t threadList;
    mach_msg_type_number_t threadCount = 0;
    
    kern_return_t kr = task_threads(mach_task_self(),
                                    &threadList,
                                    &threadCount);
    if (kr != KERN_SUCCESS) {
        return nil;
    }
    
    NSMutableArray *result = [NSMutableArray array];
    double now = [NSProcessInfo processInfo].systemUptime;
    double uptime = now - appLaunchTime;
    double usedMemory = RCTGetResidentMemorySize();
    
    NSMutableSet<NSNumber *> *activeThreadIds = [NSMutableSet set];
    
    for (int i = 0; i < threadCount; i++) {
        thread_act_t thread = threadList[i];
        thread_basic_info_data_t info;
        mach_msg_type_number_t infoCount = THREAD_INFO_MAX;
        
        kr = thread_info(thread,
                         THREAD_BASIC_INFO,
                         (thread_info_t)&info,
                         &infoCount);
        if (kr != KERN_SUCCESS) {
            continue;
        }
        
        if ((info.flags & TH_FLAGS_IDLE) != 0) {
            continue;
        }
        
        double userTime = (double)info.user_time.seconds + (double)info.user_time.microseconds / 1e6;
        double systemTime = (double)info.system_time.seconds + (double)info.system_time.microseconds / 1e6;
        
        NSString *threadName = nil;
        
        if (jsThread == thread) {
            threadName = @"com.facebook.react.JavaScript";
        } else {
            pthread_t pthread = pthread_from_mach_thread_np(thread);
            char name[256] = {
                0
            };
            
            if (pthread != NULL) {
                pthread_getname_np(pthread,
                                   name,
                                   sizeof(name));
            }
            
            threadName = [NSString stringWithUTF8String:name];
        }
        
        if (threadName == nil || [threadName length] == 0) {
            threadName = @"(unnamed)";
        }
        
        if (threadNameFilter != nil && ![threadNameFilter containsObject:threadName] && i > 0) {
            continue;
        }
        
        NSNumber *threadIdKey = @(thread);
        [activeThreadIds addObject:threadIdKey];
        
        NSDictionary *last = lastThreadTimes[threadIdKey];
        
        id deltaTime = [NSNull null];
        id deltaUser = [NSNull null];
        id deltaSystem = [NSNull null];
        double threadLifetime = 0;
        
        if (last == nil) {
            lastThreadTimes[threadIdKey] = @{
                @"user": @(userTime),
                @"system": @(systemTime),
                @"timestamp": @(now),
                @"first_seen": @(now)
            };
        } else {
            double lastUser = [last[@"user"] doubleValue];
            double lastSystem = [last[@"system"] doubleValue];
            double lastTimestamp = [last[@"timestamp"] doubleValue];
            double firstSeen = [last[@"first_seen"] doubleValue];

            deltaTime = @(now - lastTimestamp);
            deltaUser = @(userTime - lastUser);
            deltaSystem = @(systemTime - lastSystem);
            threadLifetime = now - firstSeen;

            NSMutableDictionary *updated = [last mutableCopy];
            updated[@"user"] = @(userTime);
            updated[@"system"] = @(systemTime);
            updated[@"timestamp"] = @(now);
            lastThreadTimes[threadIdKey] = updated;
        }
        
        [result addObject:@{
            @"threadId": threadIdKey,
            @"threadName": threadName,
            @"totalUserTimeSeconds": @(userTime),
            @"totalSystemTimeSeconds": @(systemTime),
            @"totalTimeSeconds": @(threadLifetime),
            @"deltaUserTimeSeconds": deltaUser,
            @"deltaSystemTimeSeconds": deltaSystem,
            @"deltaTimeSeconds": deltaTime,
        }];
    }
    
    NSSet<NSNumber *> *allStoredThreadIds = [NSSet setWithArray:lastThreadTimes.allKeys];
    
    for (NSNumber *threadId in allStoredThreadIds) {
        if (![activeThreadIds containsObject:threadId]) {
            [lastThreadTimes removeObjectForKey:threadId];
        }
    }
    
    vm_deallocate(mach_task_self(),
                  (vm_address_t)threadList,
                  threadCount * sizeof(thread_t));

    return @{
        @"threads": result,
        @"uptimeSeconds": @(uptime),
        @"ramTotalBytes": @(totalMemory),
        @"ramUsedBytes": @(usedMemory),
        @"ramLoadPercent": @((usedMemory / totalMemory) * 100.0)
    };
}

#pragma Module implementation

@implementation PerformanceStats {
    bool _isRunning;
    
    FPSTracker *_uiFPSTracker;
    FPSTracker *_jsFPSTracker;
    
    CADisplayLink *_uiDisplayLink;
    CADisplayLink *_jsDisplayLink;
    
    double appLaunchTime;
    double totalMemory;
    NSMutableDictionary<NSNumber*, NSDictionary*> *lastThreadTimes;
    
    thread_act_t _jsThread;
}

- (instancetype)init {
  self = [super init];
  if (self) {
      appLaunchTime = [NSProcessInfo processInfo].systemUptime;
      totalMemory = [NSProcessInfo processInfo].physicalMemory;
      lastThreadTimes = [NSMutableDictionary dictionary];
      _jsThread = MACH_PORT_NULL;
  }
  return self;
}

RCT_EXPORT_MODULE(PerformanceStats)

+ (BOOL)requiresMainQueueSetup
{
  return YES;
}

- (dispatch_queue_t)methodQueue
{
  return dispatch_get_main_queue();
}

- (NSArray<NSString *> *)supportedEvents
{
  return @[ @"performanceStatsUpdate" ];
}

- (void)updateStats:(bool)withCPU
{
    // View count
    NSDictionary<NSNumber *, UIView *> *views = [self.bridge.uiManager valueForKey:@"viewRegistry"];
    NSUInteger viewCount = views.count;
    NSUInteger visibleViewCount = 0;
    for (UIView *view in views.allValues) {
      if (view.window || view.superview.window) {
        visibleViewCount++;
      }
    }
    
    // Memory
    double mem = (double)RCTGetResidentMemorySize() / 1024 / 1024;
    float cpu = 0;
    if (withCPU) {
        cpu = cpu_usage();
    }

    if (self.bridge && self.bridge.valid) {
      [self sendEventWithName:@"performanceStatsUpdate" body:@{
          @"jsFps": [NSNumber numberWithUnsignedInteger:_jsFPSTracker.FPS],
          @"uiFps": [NSNumber numberWithUnsignedInteger:_uiFPSTracker.FPS],
          @"usedCpu": [NSNumber numberWithFloat:cpu],
          @"usedRam": [NSNumber numberWithDouble:mem],
          @"viewCount": [NSNumber numberWithUnsignedInteger:viewCount],
          @"visibleViewCount": [NSNumber numberWithUnsignedInteger:visibleViewCount]
      }];
    }
    
    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      __strong __typeof__(weakSelf) strongSelf = weakSelf;
      if (strongSelf && strongSelf->_isRunning) {
        [strongSelf updateStats:withCPU];
      }
    });
}

- (void)threadUpdate:(CADisplayLink *)displayLink
{
  FPSTracker *tracker = displayLink == _jsDisplayLink ? _jsFPSTracker : _uiFPSTracker;
  [tracker onTick:displayLink.timestamp];
}

RCT_REMAP_METHOD(start, withCpu:(BOOL)withCpu)
{
    _isRunning = true;
    _uiFPSTracker= [[FPSTracker alloc] init];
    _jsFPSTracker= [[FPSTracker alloc] init];
    
    [self updateStats:withCpu];
    
    // Get FPS for UI Thread
    _uiDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(threadUpdate:)];
    [_uiDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    
    // Get FPS for JS thread
    [self.bridge
        dispatchBlock:^{
          self->_jsDisplayLink =
              [CADisplayLink displayLinkWithTarget:self
                                          selector:@selector(threadUpdate:)];
          [self->_jsDisplayLink addToRunLoop:[NSRunLoop currentRunLoop]
                                     forMode:NSRunLoopCommonModes];
          thread_act_t jsThread = mach_thread_self();
          self->_jsThread = jsThread;
        }
                queue:RCTJSThread];
}

RCT_EXPORT_METHOD(stop)
{
    _isRunning = false;
    _jsFPSTracker = nil;
    _uiFPSTracker = nil;
    
    [_uiDisplayLink invalidate];
    [_jsDisplayLink invalidate];
    
    _uiDisplayLink = nil;
    _jsDisplayLink = nil;
    _jsThread = MACH_PORT_NULL;
}

RCT_EXPORT_METHOD(getPerThreadCPUUsage:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    
    NSDictionary *stats = threadStats(appLaunchTime,
                                      totalMemory,
                                      nil,
                                      lastThreadTimes,
                                      _jsThread);
    
    if (stats == nil) {
                reject(@"E_CPU",
                       @"Failed to retrieve thread list",
                       nil);
    }
  
    resolve(stats);
}

// Thanks to this guard, we won't compile this code when we build for the old architecture.
#ifdef RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativePerformanceStatsSpecJSI>(params);
}
#endif

@end
