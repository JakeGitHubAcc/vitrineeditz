#import "Core/SGCore.h"
#import "RecordCustom.h"

NSString *const SGRPartFront = @"front";
NSString *const SGRPartBack = @"back";
NSString *const SGRPartSpine = @"spine";
NSString *const SGRPartInsideLeft = @"insideLeft";
NSString *const SGRPartInsideRight = @"insideRight";
NSString *const SGRPartSticker = @"sticker";

static NSString *folder(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [support stringByAppendingPathComponent:@"VitrineRecords"];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

static NSString *listPath(void) {
    return [folder() stringByAppendingPathComponent:@"custom.plist"];
}

// By record: {parts: {part: file name}, stickerX, stickerY, stickerHidden}.
static NSMutableDictionary<NSString *, NSDictionary *> *list(void) {
    static NSMutableDictionary *records;
    if (!records) {
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:listPath()];
        records = [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    }
    return records;
}

static NSCache<NSString *, UIImage *> *pictures(void) {
    static NSCache *cache;
    if (!cache) cache = [NSCache new];
    return cache;
}

// The record's entry changed by `change`, kept, or dropped once nothing is left in it.
static void changeEntry(NSString *record, void (^change)(NSMutableDictionary *entry)) {
    NSMutableDictionary *entry = [list()[record] mutableCopy] ?: [NSMutableDictionary dictionary];
    change(entry);
    NSDictionary *parts = entry[@"parts"];
    BOOL empty = ![parts count] && !entry[@"stickerX"] && ![entry[@"stickerHidden"] boolValue];
    if (empty) [list() removeObjectForKey:record];
    else list()[record] = entry;
    [list() writeToFile:listPath() atomically:YES];
}

UIImage *SGRCustomPicture(NSString *record, NSString *part) {
    NSString *name = list()[record][@"parts"][part];
    if (![name isKindOfClass:NSString.class]) return nil;
    UIImage *picture = [pictures() objectForKey:name];
    if (!picture) {
        picture = [UIImage imageWithContentsOfFile:[folder() stringByAppendingPathComponent:name]];
        if (picture) [pictures() setObject:picture forKey:name];
    }
    return picture;
}

void SGRSetCustomPicture(NSString *record, NSString *part, UIImage *picture) {
    if (!record.length) return;
    NSString *old = list()[record][@"parts"][part];
    if ([old isKindOfClass:NSString.class]) [NSFileManager.defaultManager removeItemAtPath:[folder() stringByAppendingPathComponent:old] error:nil];
    NSString *name = nil;
    if (picture) {
        BOOL png = [part isEqualToString:SGRPartSticker];
        NSData *data = png ? UIImagePNGRepresentation(picture) : UIImageJPEGRepresentation(picture, 0.9);
        name = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:png ? @"png" : @"jpg"];
        if (![data writeToFile:[folder() stringByAppendingPathComponent:name] atomically:YES]) name = nil;
    }
    changeEntry(record, ^(NSMutableDictionary *entry) {
        NSMutableDictionary *parts = [entry[@"parts"] mutableCopy] ?: [NSMutableDictionary dictionary];
        parts[part] = name;
        entry[@"parts"] = parts;
        // A new sticker shows, wherever it was moved to.
        if (name && [part isEqualToString:SGRPartSticker]) [entry removeObjectForKey:@"stickerHidden"];
    });
}

BOOL SGRHasCustom(NSString *record) {
    return list()[record] != nil;
}

BOOL SGRCustomStickerCenter(NSString *record, CGPoint *center) {
    NSDictionary *entry = list()[record];
    if (!entry[@"stickerX"] || !entry[@"stickerY"]) return NO;
    *center = CGPointMake([entry[@"stickerX"] doubleValue], [entry[@"stickerY"] doubleValue]);
    return YES;
}

void SGRSetCustomStickerCenter(NSString *record, CGPoint center) {
    changeEntry(record, ^(NSMutableDictionary *entry) {
        entry[@"stickerX"] = @(MIN(MAX(center.x, 0), 1));
        entry[@"stickerY"] = @(MIN(MAX(center.y, 0), 1));
    });
}

BOOL SGRCustomStickerHidden(NSString *record) {
    return [list()[record][@"stickerHidden"] boolValue];
}

void SGRSetCustomStickerHidden(NSString *record, BOOL hidden) {
    changeEntry(record, ^(NSMutableDictionary *entry) {
        if (hidden) entry[@"stickerHidden"] = @YES;
        else [entry removeObjectForKey:@"stickerHidden"];
    });
}

void SGRForgetCustom(NSString *record) {
    NSDictionary *parts = list()[record][@"parts"];
    for (NSString *part in [parts isKindOfClass:NSDictionary.class] ? parts : @{}) {
        NSString *name = parts[part];
        if ([name isKindOfClass:NSString.class]) [NSFileManager.defaultManager removeItemAtPath:[folder() stringByAppendingPathComponent:name] error:nil];
    }
    changeEntry(record, ^(NSMutableDictionary *entry) { [entry removeAllObjects]; });
}
