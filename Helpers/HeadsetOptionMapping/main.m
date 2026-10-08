#import <Foundation/Foundation.h>
#import <signal.h>
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
static NSArray *OperationSources(void) {
    NSData *data = [NSData dataWithContentsOfFile:OperationPath(@"operation-lease.json")];
    id lease = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![lease isKindOfClass:NSDictionary.class]) return @[];
    double age = NSDate.date.timeIntervalSince1970 - [lease[@"time"] doubleValue];
    int pid = [lease[@"pid"] intValue];
    if (pid <= 0 || age < 0 || age >= 3 || kill(pid, 0) != 0 || ![lease[@"sources"] isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id s in lease[@"sources"]) {
        if (![s isKindOfClass:NSDictionary.class] || ![s[@"kind"] isEqual:@"hid"] || ![s[@"device"] isKindOfClass:NSString.class] ||
            ![s[@"page"] isKindOfClass:NSNumber.class] || ![s[@"usage"] isKindOfClass:NSNumber.class] || ![s[@"vendor"] isKindOfClass:NSNumber.class] || ![s[@"product"] isKindOfClass:NSNumber.class] ||
            [s[@"page"] intValue] != 12 || [s[@"usage"] intValue] <= 0 || [s[@"usage"] intValue] > 65535 || [s[@"vendor"] intValue] <= 0 || [s[@"product"] intValue] <= 0) continue;
        [out addObject:s];
    }
    return out;
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
        NSString *serial = Property(service,@"SerialNumber");
        NSString *device = [NSString stringWithFormat:@"%@:%@:%@",Property(service,@"VendorID"),Property(service,@"ProductID"),[serial isKindOfClass:NSString.class] ? serial : @"model"];
        NSArray *custom = [operationSources filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *s, NSDictionary *bindings) { (void)bindings; return [s[@"device"] isEqual:device]; }]];
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
            for (NSDictionary *s in custom) [operationVerified addObject:[NSString stringWithFormat:@"hid:%@:12:%@",s[@"device"],s[@"usage"]]];
        }
    }
    if (operationSources.count || backupJSON) {
        NSData *recovery = [NSJSONSerialization dataWithJSONObject:backups options:0 error:nil];
        [recovery writeToFile:OperationPath(@"operation-mapping-backup.json") atomically:YES];
    }
    if (operationSources.count) {
        NSData *health = [NSJSONSerialization dataWithJSONObject:@{@"time":@(NSDate.date.timeIntervalSince1970),@"sources":operationVerified} options:0 error:nil];
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
    puts("PASS: hold takeover, restore, custom preservation, missing, empty, incorrect, duplicate, unrelated-preservation, idempotence, malformed input");
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
