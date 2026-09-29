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
static NSDictionary *Check(IOHIDEventSystemClientRef client, BOOL force) {
    NSArray *services = CFBridgingRelease(IOHIDEventSystemClientCopyServices(client));
    if (!services) return @{ @"state":@"error", @"reason":@"HID services unavailable" };
    NSUInteger matched = 0, verified = 0, repaired = 0;
    NSArray *profiles = Profiles();
    BOOL leaseActive = HoldLeaseValid();
    NSMutableArray *registryIDs = [NSMutableArray array];
    for (id item in services) {
        IOHIDServiceClientRef service = (__bridge IOHIDServiceClientRef)item;
        if (!IOHIDServiceClientConformsTo(service,12,1)) continue;
        NSDictionary *profile = nil;
        for (NSDictionary *p in profiles) {
            if ([Property(service,@"VendorID") isEqual:p[@"vendorID"]] && [Property(service,@"ProductID") isEqual:p[@"productID"]]) { profile = p; break; }
        }
        if (!profile) continue;
        matched++;
        id registryID = (__bridge id)IOHIDServiceClientGetRegistryID(service);
        if (registryID) [registryIDs addObject:registryID];
        id current = Property(service,MapKey);
        NSArray *desired = MergeHold(current, leaseActive && [profile[@"supportsHold"] boolValue]);
        if (!desired) continue; // Do not overwrite an unknown property format.
        if (force || ![current isEqual:desired]) {
            BOOL set = IOHIDServiceClientSetProperty(service,(__bridge CFStringRef)MapKey,(__bridge CFArrayRef)desired);
            if (!set) continue;
            repaired++;
        }
        if ([Property(service,MapKey) isEqual:desired]) verified++;
    }
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
