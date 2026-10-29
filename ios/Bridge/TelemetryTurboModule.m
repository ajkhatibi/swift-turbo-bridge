#import <React/RCTBridgeModule.h>
#import <TelemetryBridgeSpec/TelemetryBridgeSpec.h>
#if __has_include(<TelemetryBridge/TelemetryBridge-Swift.h>)
#import <TelemetryBridge/TelemetryBridge-Swift.h>
#else
#import "TelemetryBridge-Swift.h"
#endif

// This .m is compiled as Objective-C++ by TelemetryBridge.podspec.
@interface TelemetryTurboModule : NSObject <NativeTelemetryBridgeSpec>
@end

@implementation TelemetryTurboModule {
  TelemetryBridgeImplementation *_implementation;
}

RCT_EXPORT_MODULE(NativeTelemetryBridge)

+ (BOOL)requiresMainQueueSetup { return NO; }

- (instancetype)init
{
  if ((self = [super init])) {
    _implementation = [TelemetryBridgeImplementation new];
  }
  return self;
}

static NSDictionary *SnapshotDictionary(JS::NativeTelemetryBridge::TelemetrySnapshot &snapshot)
{
  return @{
    @"entityId" : snapshot.entityId() ?: @"",
    @"displayName" : snapshot.displayName() ?: @"",
    @"batteryOrProgressPercent" : @(snapshot.batteryOrProgressPercent()),
    @"lockState" : snapshot.lockState() ?: @"",
    @"lastUpdatedTimestamp" : @(snapshot.lastUpdatedTimestamp())
  };
}

- (void)syncTelemetryToWidget:(JS::NativeTelemetryBridge::TelemetrySnapshot &)snapshot
                     resolve:(RCTPromiseResolveBlock)resolve
                      reject:(RCTPromiseRejectBlock)reject
{
  [_implementation syncTelemetryToWidget:SnapshotDictionary(snapshot) resolve:resolve reject:reject];
}

- (void)upsertLiveActivity:(JS::NativeTelemetryBridge::TelemetrySnapshot &)snapshot
                  resolve:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject
{
  [_implementation upsertLiveActivity:SnapshotDictionary(snapshot) resolve:resolve reject:reject];
}

- (void)endAllLiveActivities:(RCTPromiseResolveBlock)resolve
                     reject:(RCTPromiseRejectBlock)reject
{
  [_implementation endAllLiveActivitiesWithResolve:resolve reject:reject];
}

- (NSNumber *)setSharedKeychainToken:(NSString *)token accessGroup:(NSString *)accessGroup
{
  return @([_implementation setSharedKeychainToken:token accessGroup:accessGroup]);
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeTelemetryBridgeSpecJSI>(params);
}
@end
