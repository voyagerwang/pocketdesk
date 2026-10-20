/**
 * [INPUT]: 依赖 IOKit 的实时 Consumer HID 服务及其 IORegistry 父链、已配对型号和绑定当前设备 registry 的短时操作租约。
 * [OUTPUT]: 合并中键原生 Option 映射；仅真实父链包含租约设备且型号一致才接管指定 usage，健康按规则 identity 回读已核验 registry；不要求服务暴露序列号，未知身份不接管，租约失效按持久化备份恢复来源，不发送语音快捷键。
 * [POS]: Helpers 的独立映射守护；主应用负责语义动作与输入框准备，本程序只协调硬件映射及失效回退。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
#import <Foundation/Foundation.h>
#import <signal.h>
#import <math.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>

static NSString * const MapKey = @"UserKeyMapping";
static NSString * const SrcKey = @"HIDKeyboardModifierMappingSrc";
static NSString * const DstKey = @"HIDKeyboardModifierMappingDst";
static const uint64_t PlayPause = 0xC000000CD;
static const uint64_t LeftOption = 0x7000000E2;

static NSArray *MergeMapping(id current) {
    if (current && ![current isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *merged = [NSMutableArray array];
    BOOL found = NO;
    for (id entry in current ?: @[]) {
        if (![entry isKindOfClass:NSDictionary.class]) return nil;
        id src = entry[SrcKey];
        if ([src isKindOfClass:NSNumber.class] && [src unsignedLongLongValue] == PlayPause) {
            if (!found) [merged addObject:@{SrcKey:@(PlayPause),DstKey:@(LeftOption)}];
            found = YES;
        } else {
            [merged addObject:entry]; // Preserve every unrelated mapping.
        }
    }
    if (!found) [merged addObject:@{SrcKey:@(PlayPause),DstKey:@(LeftOption)}];
    return merged;
}
// Reserve F20 only while the app's active event tap is publishing a fresh lease.
static const uint64_t VolumeDown = 0xC000000EA;
static const uint64_t HoldKey = 0x700000000; // HID keyboard usage 0: no key event.
static const uint64_t LegacyHoldKey = 0x70000006F;
static NSString *LeasePath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/VoiceDeck/headset/hold-lease.json"];
}
static BOOL HoldLeaseValid(void) {
    NSData *data = [NSData dataWithContentsOfFile:LeasePath()];
    NSDictionary *lease = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![lease isKindOfClass:NSDictionary.class]) return NO;
    double age = NSDate.date.timeIntervalSince1970 - [lease[@"time"] doubleValue];
    int pid = [lease[@"pid"] intValue];
    return pid > 0 && age >= 0 && age < 3 && kill(pid, 0) == 0;
}
static NSArray *MergeHold(id current, BOOL enabled) {
    NSArray *base = MergeMapping(current);
    if (!base) return nil;
    NSMutableArray *out = [NSMutableArray array];
    BOOL found = NO;
    for (NSDictionary *entry in base) {
        if ([entry[SrcKey] unsignedLongLongValue] == VolumeDown) {
            // Never overwrite a custom volume-down mapping owned by another tool.
            if ([entry[DstKey] unsignedLongLongValue] != HoldKey && [entry[DstKey] unsignedLongLongValue] != LegacyHoldKey) return base;
            if (enabled && !found) [out addObject:@{SrcKey:@(VolumeDown),DstKey:@(HoldKey)}];
            found = YES;
        } else [out addObject:entry];
    }
    if (enabled && !found) [out addObject:@{SrcKey:@(VolumeDown),DstKey:@(HoldKey)}];
    return out;
}
static id Property(IOHIDServiceClientRef service, NSString *key) {
    return CFBridgingRelease(IOHIDServiceClientCopyProperty(service, (__bridge CFStringRef)key));
}
static NSArray *Profiles(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/VoiceDeck/headset/profiles.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    id saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *fallback = @[@{@"vendorID":@13058, @"productID":@4827, @"supportsHold":@YES}];
    if (![saved isKindOfClass:NSArray.class]) return fallback;
    for (id p in saved) {
        if (![p isKindOfClass:NSDictionary.class] || ![p[@"vendorID"] isKindOfClass:NSNumber.class] ||
            ![p[@"productID"] isKindOfClass:NSNumber.class] || ![p[@"supportsHold"] isKindOfClass:NSNumber.class] ||
            [p[@"vendorID"] intValue] <= 0 || [p[@"vendorID"] intValue] > 65535 ||
            [p[@"productID"] intValue] <= 0 || [p[@"productID"] intValue] > 65535) return fallback;
    }
    return saved;
}
// Custom rules override only their own sources under an app-owned short lease.
// Save previous per-source entries so crash/restart never leaves a swallowed key.
static NSString *OperationPath(NSString *name) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/VoiceDeck/headset"] stringByAppendingPathComponent:name];
}
static NSArray *OperationSourcesFromLease(id lease, double now, BOOL (^alive)(int)) {
    if (![lease isKindOfClass:NSDictionary.class]) return @[];
    double age = now - [lease[@"time"] doubleValue];
    int pid = [lease[@"pid"] intValue];
    if (pid <= 0 || !isfinite(age) || age < 0 || age >= 3 || !alive(pid) || ![lease[@"sources"] isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id s in lease[@"sources"]) {
        if (![s isKindOfClass:NSDictionary.class] || ![s[@"kind"] isEqual:@"hid"] || ![s[@"device"] isKindOfClass:NSString.class] ||
            ![s[@"page"] isKindOfClass:NSNumber.class] || ![s[@"usage"] isKindOfClass:NSNumber.class] || ![s[@"vendor"] isKindOfClass:NSNumber.class] || ![s[@"product"] isKindOfClass:NSNumber.class] ||
            ![s[@"registryID"] isKindOfClass:NSNumber.class] || [s[@"registryID"] unsignedLongLongValue] == 0 ||
            [s[@"page"] intValue] != 12 || [s[@"usage"] intValue] <= 0 || [s[@"usage"] intValue] > 65535 || [s[@"vendor"] intValue] <= 0 || [s[@"product"] intValue] <= 0) continue;
        [out addObject:s];
    }
    return out;
}
static NSArray *OperationSources(void) {
    NSData *data = [NSData dataWithContentsOfFile:OperationPath(@"operation-lease.json")];
    id lease = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return OperationSourcesFromLease(lease, NSDate.date.timeIntervalSince1970, ^BOOL(int pid) { return kill(pid, 0) == 0; });
}
static BOOL OperationSourceMatchesService(NSDictionary *source, id vendor, id product, NSArray *ancestry) {
    NSNumber *registry = source[@"registryID"];
    return [registry isKindOfClass:NSNumber.class] && registry.unsignedLongLongValue > 0 &&
        [source[@"vendor"] isEqual:vendor] && [source[@"product"] isEqual:product] && [ancestry containsObject:registry];
}
static NSArray *ServiceRegistryAncestry(IOHIDServiceClientRef service) {
    id registry = (__bridge id)IOHIDServiceClientGetRegistryID(service);
    if (![registry isKindOfClass:NSNumber.class] || [registry unsignedLongLongValue] == 0) return @[];
    io_registry_entry_t entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching([registry unsignedLongLongValue]));
    NSMutableArray *ancestry = [NSMutableArray array];
    // ---------- 绑定真实 HID 父设备 ----------
    // EventService 不一定暴露 SerialNumber；沿真实父链确认租约设备，不能按同型号兜底。
    for (NSUInteger depth = 0; entry && depth < 32; depth++) {
        uint64_t identifier = 0;
        if (IORegistryEntryGetRegistryEntryID(entry, &identifier) != KERN_SUCCESS) break;
        if (IOObjectConformsTo(entry, "IOHIDDevice")) [ancestry addObject:@(identifier)];
        io_registry_entry_t parent = 0;
        kern_return_t result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent);
        IOObjectRelease(entry); entry = result == KERN_SUCCESS ? parent : 0;
    }
    if (entry) IOObjectRelease(entry);
    return ancestry;
}
static NSDictionary *OperationHealth(NSArray *verified, double timestamp) {
    NSMutableArray *identities = [NSMutableArray array];
    NSMutableDictionary *registries = [NSMutableDictionary dictionary];
    for (NSDictionary *source in verified) {
        NSString *identity = [NSString stringWithFormat:@"hid:%@:12:%@",source[@"device"],source[@"usage"]];
        [identities addObject:identity]; registries[identity] = source[@"registryID"];
    }
    return @{@"time":@(timestamp),@"sources":identities,@"registries":registries};
}
static NSArray *RestoreOperations(id current, NSDictionary *owned) {
    if (![owned isKindOfClass:NSDictionary.class]) return nil;
    if (current && ![current isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id entry in current ?: @[]) {
        if (![entry isKindOfClass:NSDictionary.class]) return nil;
        NSString *source = [entry[SrcKey] description];
        id previous = owned[source];
        if (previous && [entry[DstKey] unsignedLongLongValue] == HoldKey) {
            if ([previous isKindOfClass:NSDictionary.class]) [out addObject:previous];
        } else [out addObject:entry];
    }
    return out;
}
static NSArray *TakeOperations(NSArray *base, NSArray *sources, NSMutableDictionary *owned) {
    NSMutableArray *out = [base mutableCopy];
    for (NSDictionary *s in sources) {
        uint64_t code = ((uint64_t)[s[@"page"] intValue] << 32) | [s[@"usage"] unsignedLongLongValue];
        NSString *key = [@(code) description];
        if (owned[key]) continue;
        id previous = NSNull.null;
        for (NSDictionary *entry in out) { if ([entry[SrcKey] unsignedLongLongValue] == code) { previous = entry; break; } }
        owned[key] = previous;
        NSIndexSet *indexes = [out indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger i, BOOL *stop) { (void)i; (void)stop; return [entry[SrcKey] unsignedLongLongValue] == code; }];
        [out removeObjectsAtIndexes:indexes];
        [out addObject:@{SrcKey:@(code),DstKey:@(HoldKey)}];
    }
    return out;
}
static NSDictionary *Check(IOHIDEventSystemClientRef client, BOOL force) {
    NSArray *services = CFBridgingRelease(IOHIDEventSystemClientCopyServices(client));
    if (!services) return @{ @"state":@"error", @"reason":@"HID services unavailable" };
    NSUInteger matched = 0, verified = 0, repaired = 0;
    NSArray *profiles = Profiles();
    BOOL leaseActive = HoldLeaseValid();
    NSArray *operationSources = OperationSources();
    NSData *backupData = [NSData dataWithContentsOfFile:OperationPath(@"operation-mapping-backup.json")];
    id backupJSON = backupData ? [NSJSONSerialization JSONObjectWithData:backupData options:NSJSONReadingMutableContainers error:nil] : nil;
    NSMutableDictionary *backups = [backupJSON isKindOfClass:NSMutableDictionary.class] ? backupJSON : [NSMutableDictionary dictionary];
    NSMutableArray *operationVerified = [NSMutableArray array];
    NSMutableArray *registryIDs = [NSMutableArray array];
    for (id item in services) {
        IOHIDServiceClientRef service = (__bridge IOHIDServiceClientRef)item;
        if (!IOHIDServiceClientConformsTo(service,12,1)) continue;
        NSDictionary *profile = nil;
        for (NSDictionary *p in profiles) {
            if ([Property(service,@"VendorID") isEqual:p[@"vendorID"]] && [Property(service,@"ProductID") isEqual:p[@"productID"]]) { profile = p; break; }
        }
        NSArray *ancestry = operationSources.count ? ServiceRegistryAncestry(service) : @[];
        id vendor = Property(service,@"VendorID"), product = Property(service,@"ProductID");
        NSArray *custom = [operationSources filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *s, NSDictionary *bindings) { (void)bindings; return OperationSourceMatchesService(s, vendor, product, ancestry); }]];
        NSString *serviceKey = [(__bridge id)IOHIDServiceClientGetRegistryID(service) description];
        if (!serviceKey || (!profile && custom.count == 0 && !backups[serviceKey])) continue;
        matched++;
        id registryID = (__bridge id)IOHIDServiceClientGetRegistryID(service);
        if (registryID) [registryIDs addObject:registryID];
        id current = Property(service,MapKey);
        NSArray *restored = RestoreOperations(current, backups[serviceKey] ?: @{});
        if (!restored) continue; // An invalid property must never become an empty baseline.
        NSArray *base = profile ? MergeHold(restored, leaseActive && [profile[@"supportsHold"] boolValue]) : restored;
        if (!base) continue;
        NSMutableDictionary *owned = [NSMutableDictionary dictionary];
        NSArray *desired = TakeOperations(base, custom, owned);
        // Persist recovery before applying the takeover; retain it on a failed write.
        if (owned.count) backups[serviceKey] = owned;
        if (custom.count || backups[serviceKey]) {
            NSData *recovery = [NSJSONSerialization dataWithJSONObject:backups options:0 error:nil];
            if (!recovery || ![recovery writeToFile:OperationPath(@"operation-mapping-backup.json") atomically:YES]) continue;
        }
        if (!desired) continue; // Do not overwrite an unknown property format.
        if (force || ![current isEqual:desired]) {
            BOOL set = IOHIDServiceClientSetProperty(service,(__bridge CFStringRef)MapKey,(__bridge CFArrayRef)desired);
            if (!set) continue;
            repaired++;
        }
        if ([Property(service,MapKey) isEqual:desired]) {
            verified++;
            if (owned.count == 0) [backups removeObjectForKey:serviceKey];
            [operationVerified addObjectsFromArray:custom];
        }
    }
    if (operationSources.count || backupJSON) {
        NSData *recovery = [NSJSONSerialization dataWithJSONObject:backups options:0 error:nil];
        [recovery writeToFile:OperationPath(@"operation-mapping-backup.json") atomically:YES];
    }
    if (operationSources.count) {
        NSData *health = [NSJSONSerialization dataWithJSONObject:OperationHealth(operationVerified, NSDate.date.timeIntervalSince1970) options:0 error:nil];
        [health writeToFile:OperationPath(@"operation-health.json") atomically:YES];
    } else [NSFileManager.defaultManager removeItemAtPath:OperationPath(@"operation-health.json") error:nil];
    return @{@"state": matched == 0 ? @"waiting_for_headset" : verified == matched ? @"verified" : @"error",
             @"holdLeaseActive":@(leaseActive), @"serviceRegistryIDs":registryIDs, @"matchingServices":@(matched), @"verifiedServices":@(verified), @"writes":@(repaired)};
}
// A simple HID client retains its service snapshot across unplug/replug.
// Recreate it for every check so writes always target the current connection.
static NSDictionary *FreshCheck(BOOL force) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    if (!client) return @{ @"state":@"error", @"reason":@"Unable to create HID client" };
    NSDictionary *result = Check(client, force);
    CFRelease(client);
    return result;
}
static void Expect(BOOL condition, NSString *message) { if (!condition) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); } }
static void SelfTest(void) {
    NSDictionary *other = @{SrcKey:@(0xC000000E9),DstKey:@(0x70000003A)};
    NSDictionary *wrong = @{SrcKey:@(PlayPause),DstKey:@(0x70000006D)};
    NSDictionary *correct = @{SrcKey:@(PlayPause),DstKey:@(LeftOption)};
    Expect([MergeMapping(nil) isEqual:@[correct]], @"Missing mapping restores Option");
    Expect([MergeMapping(@[]) isEqual:@[correct]], @"Empty mapping restores Option");
    Expect([MergeMapping(@[other,wrong]) isEqual:@[other,correct]], @"Repair preserves another button mapping");
    Expect([MergeMapping(@[correct,wrong,other]) isEqual:@[correct,other]], @"Duplicate mappings removed only for target key");
    Expect([MergeMapping(@[other,correct]) isEqual:@[other,correct]], @"Correct state does not need a write");
    Expect(MergeMapping(@"unexpected") == nil, @"Unknown property format is not overwritten");
    NSDictionary *hold = @{SrcKey:@(VolumeDown),DstKey:@(HoldKey)};
    Expect([MergeHold(@[correct], YES) isEqual:@[correct,hold]], @"Active listener maps volume-down only");
    Expect([MergeHold(@[correct,hold], NO) isEqual:@[correct]], @"Expired listener restores volume without touching Option");
    NSDictionary *custom = @{SrcKey:@(VolumeDown),DstKey:@(0x70000003A)};
    Expect([MergeHold(@[correct,custom], YES) isEqual:@[correct,custom]], @"Preserve custom minus mapping");
    Expect([MergeHold(@[correct,@{SrcKey:@(VolumeDown),DstKey:@(LegacyHoldKey)}], YES) isEqual:@[correct,hold]], @"Replace legacy F20 hold without changing Option");
    NSDictionary *source = @{@"page":@12,@"usage":@0xCD};
    NSMutableDictionary *owned = [NSMutableDictionary dictionary];
    NSArray *taken = TakeOperations(@[correct,custom], @[source,source], owned);
    Expect(owned.count == 1 && [owned[[@(PlayPause) description]] isEqual:correct], @"Duplicate gestures retain the original mapping once");
    Expect([RestoreOperations(taken, owned) isEqual:@[custom,correct]], @"Custom mapping takeover restores only owned source");
    NSDictionary *otherTool = @{SrcKey:@(PlayPause),DstKey:@(0x70000003B)};
    Expect([RestoreOperations(@[otherTool], owned) isEqual:@[otherTool]], @"Another tool's later mapping is not overwritten");
    Expect(RestoreOperations(@[correct], (id)NSNull.null) == nil, @"Malformed recovery refused");
    Expect(RestoreOperations((id)NSNull.null, @{}) == nil, @"Malformed native property is not treated as an empty baseline");
    // ---------- 租约身份与过期恢复 ----------
    NSDictionary *bound = @{@"kind":@"hid",@"device":@"13058:4827:serial-A",@"page":@12,@"usage":@0xCD,@"vendor":@13058,@"product":@4827,@"registryID":@101};
    NSDictionary *lease = @{@"pid":@42,@"time":@100,@"sources":@[bound]};
    BOOL (^alive)(int) = ^BOOL(int pid) { return pid == 42; };
    Expect([OperationSourcesFromLease(lease, 102.9, alive) isEqual:@[bound]], @"Fresh lease retains configured identity and current registry");
    Expect(OperationSourceMatchesService(bound, @13058, @4827, @[@301,@201,@101]), @"Real device ancestor matches even when service has no serial property");
    Expect(!OperationSourceMatchesService(bound, @13058, @4827, @[@302,@202]), @"Same model on another physical device cannot match");
    Expect(!OperationSourceMatchesService(bound, @13058, @4827, @[]), @"Missing registry ancestry cannot take over");
    Expect(!OperationSourceMatchesService(bound, @13058, @9999, @[@101]), @"Registry does not bypass model verification");
    NSDictionary *health = OperationHealth(@[bound], 102);
    NSString *identity = @"hid:13058:4827:serial-A:12:205";
    Expect([health[@"sources"] isEqual:@[identity]] && [health[@"registries"][identity] isEqual:@101], @"Health retains configured identity and acknowledges its verified device registry");
    Expect([OperationHealth(@[], 102)[@"registries"] count] == 0, @"No unverified registry is acknowledged");
    Expect(OperationSourcesFromLease(lease, 103, alive).count == 0, @"Expired lease stops custom takeover");
    Expect(OperationSourcesFromLease(lease, 99, alive).count == 0, @"Future lease cannot take over");
    Expect(OperationSourcesFromLease(lease, 101, ^BOOL(int pid) { (void)pid; return NO; }).count == 0, @"Retired app cannot retain takeover");
    NSMutableDictionary *unknown = [bound mutableCopy]; [unknown removeObjectForKey:@"registryID"];
    Expect(OperationSourcesFromLease(@{@"pid":@42,@"time":@100,@"sources":@[unknown]}, 101, alive).count == 0, @"Legacy source without a bound registry stays native");
    unknown[@"registryID"] = @0;
    Expect(OperationSourcesFromLease(@{@"pid":@42,@"time":@100,@"sources":@[unknown]}, 101, alive).count == 0, @"Unknown device registry stays native");
    NSMutableDictionary *boundOwned = [NSMutableDictionary dictionary];
    NSArray *boundTaken = TakeOperations(@[correct,custom], OperationSourcesFromLease(lease, 102, alive), boundOwned);
    Expect([RestoreOperations(boundTaken, boundOwned) isEqual:@[custom,correct]], @"Expired bound takeover restores only its original source");
    puts("PASS: registry-bound source identity, same-model isolation, missing ancestry, lease expiry/retirement, hold takeover, restore, custom preservation, idempotence, malformed input");
}
int main(void) {
    @autoreleasepool {
        NSArray *args = NSProcessInfo.processInfo.arguments;
        if ([args containsObject:@"--self-test"]) { SelfTest(); return 0; }
        BOOL once = [args containsObject:@"--once"];
        BOOL force = [args containsObject:@"--reapply"];
        NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/VoiceDeck/headset"];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *healthPath = [directory stringByAppendingPathComponent:@"option-mapping-health.json"];
        __block NSDictionary *previous = nil;
        __block NSDate *lastHealth = NSDate.distantPast;
        void (^tick)(void) = ^{
            @autoreleasepool {
                NSDictionary *result = FreshCheck(force);
                BOOL changed = ![previous isEqual:result];
                if (changed || -lastHealth.timeIntervalSinceNow >= 30) {
                    NSMutableDictionary *health = [result mutableCopy];
                    health[@"checkedAt"] = [NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.localTimeZone formatOptions:NSISO8601DateFormatWithInternetDateTime];
                    health[@"target"] = @"Configured headsets: play/pause -> left Option";
                    health[@"checkIntervalSeconds"] = @1;
                    NSData *json = [NSJSONSerialization dataWithJSONObject:health options:NSJSONWritingSortedKeys error:nil];
                    if (json) [json writeToFile:healthPath atomically:YES];
                    if (changed || once) { fwrite(json.bytes,1,json.length,stdout); fputc('\n',stdout); fflush(stdout); }
                    lastHealth = NSDate.date;
                }
                previous = result;
            }
        };
        tick();
        if (once) { return [previous[@"state"] isEqual:@"verified"] ? 0 : 1; }
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { (void)timer; tick(); }];
        [NSRunLoop.currentRunLoop run];
    }
    return 0;
}
