// MegaLinks.h says what is read and how.
#import <CommonCrypto/CommonCryptor.h>
#import "Core/SGCore.h"
#import "MegaLinks.h"

static NSTimeInterval const kTimeout = 20;
// How much of a download is decrypted at a time, a whole number of blocks.
static const NSUInteger kChunk = 1 << 20;

@implementation SGMegaFile
@end

#pragma mark - keys

// Mega's base64: URL-safe, unpadded.
static NSData *base64url(NSString *text) {
    NSMutableString *plain = [[[text stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                                    stringByReplacingOccurrencesOfString:@"_" withString:@"/"] mutableCopy];
    while (plain.length % 4) [plain appendString:@"="];
    return [[NSData alloc] initWithBase64EncodedString:plain options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

// AES-128 over whole blocks, ECB or CBC from a zero IV, no padding.
static NSData *aes(CCOperation operation, BOOL ecb, NSData *key, NSData *data) {
    if (key.length != kCCKeySizeAES128 || !data.length || data.length % kCCBlockSizeAES128) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:data.length];
    size_t moved = 0;
    CCCryptorStatus status = CCCrypt(operation, kCCAlgorithmAES, ecb ? kCCOptionECBMode : 0, key.bytes, key.length, NULL,
                                     data.bytes, data.length, out.mutableBytes, out.length, &moved);
    return status == kCCSuccess && moved == data.length ? out : nil;
}

// A file's 32-byte key folded into its AES key, its two halves XORed, and the counter's start, the second half's
// first 8 bytes and 8 zeros.
static NSData *aesKeyOf(NSData *key) {
    if (key.length == 16) return key;
    if (key.length < 32) return nil;
    const uint8_t *k = key.bytes;
    uint8_t folded[16];
    for (int i = 0; i < 16; i++) folded[i] = k[i] ^ k[i + 16];
    return [NSData dataWithBytes:folded length:16];
}

static NSData *counterOf(NSData *key) {
    uint8_t start[16] = {0};
    if (key.length >= 32) memcpy(start, (const uint8_t *)key.bytes + 16, 8);
    return [NSData dataWithBytes:start length:16];
}

// A node's name, from its attributes ("MEGA{\"n\":\"name\"}" encrypted with its AES key).
static NSString *nameIn(NSString *attributes, NSData *aesKey) {
    NSData *plain = [attributes isKindOfClass:NSString.class] ? aes(kCCDecrypt, NO, aesKey, base64url(attributes)) : nil;
    NSString *text = plain ? [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding] : nil;
    if (![text hasPrefix:@"MEGA{"]) return nil;
    NSRange last = [text rangeOfString:@"}" options:NSBackwardsSearch];
    if (last.location == NSNotFound) return nil;
    NSData *json = [[text substringWithRange:NSMakeRange(4, last.location - 3)] dataUsingEncoding:NSUTF8StringEncoding];
    id fields = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    id name = [fields isKindOfClass:NSDictionary.class] ? fields[@"n"] : nil;
    return [name isKindOfClass:NSString.class] ? name : nil;
}

#pragma mark - links

static NSArray<NSString *> *groups(NSString *text, NSString *pattern) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *found = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!found) return nil;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSUInteger i = 1; i < found.numberOfRanges; i++) {
        NSRange range = [found rangeAtIndex:i];
        [out addObject:range.location == NSNotFound ? @"" : [text substringWithRange:range]];
    }
    return out;
}

// The link's handle and key, and whether it is a folder's.
static BOOL parse(NSString *link, NSString **handle, NSString **key, BOOL *folder) {
    NSArray<NSString *> *found = groups(link, @"mega(?:\\.co)?\\.nz/(file|folder)/([A-Za-z0-9_-]+)#([A-Za-z0-9_-]+)");
    if (found) {
        *folder = [found[0].lowercaseString isEqualToString:@"folder"];
        *handle = found[1];
        *key = found[2];
        return YES;
    }
    found = groups(link, @"mega(?:\\.co)?\\.nz/#(F?)!([A-Za-z0-9_-]+)!([A-Za-z0-9_-]+)");
    if (!found) return NO;
    *folder = found[0].length > 0;
    *handle = found[1];
    *key = found[2];
    return YES;
}

BOOL SGMegaIsLink(NSString *link) {
    NSString *handle = nil, *key = nil;
    BOOL folder = NO;
    return parse(link, &handle, &key, &folder);
}

#pragma mark - the API

static NSString *errorText(NSInteger code) {
    switch (code) {
        case -9: return @"Mega says the link is gone. Check that it is complete, key and all.";
        case -11: case -16: return @"Mega has taken this link down.";
        case -17: return @"Mega's download limit for this network is used up. Try again in a few hours, or on another network.";
        case -3: case -18: return @"Mega is busy. Try again in a minute.";
        default: return [NSString stringWithFormat:@"Mega answered with error %ld.", (long)code];
    }
}

// One command to Mega's API, as the folder `folder` when there is one; `done` on main with its answer, or the error.
static void request(NSDictionary *command, NSString *folder, void (^done)(NSDictionary *answer, NSString *error)) {
    NSString *address = [NSString stringWithFormat:@"https://g.api.mega.co.nz/cs?id=%u%@", arc4random(), folder ? [@"&n=" stringByAppendingString:folder] : @""];
    NSMutableURLRequest *post = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    post.HTTPMethod = @"POST";
    post.timeoutInterval = kTimeout;
    post.HTTPBody = [NSJSONSerialization dataWithJSONObject:@[command] options:0 error:nil];
    [post setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [[NSURLSession.sharedSession dataTaskWithRequest:post completionHandler:^(NSData *data, NSURLResponse *response, NSError *failure) {
        id answer = data.length ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil] : nil;
        if ([answer isKindOfClass:NSArray.class]) answer = [answer firstObject];
        NSString *error = nil;
        if ([answer isKindOfClass:NSNumber.class]) error = errorText([answer integerValue]);
        else if (![answer isKindOfClass:NSDictionary.class]) error = failure.localizedDescription ?: @"Mega did not answer.";
        dispatch_async(dispatch_get_main_queue(), ^{ done(error ? nil : answer, error); });
    }] resume];
}

// A folder's nodes as files: each node's key unlocked with the folder's, its name read with it, and each file named
// by the folders it is in below the shared one.
static NSArray<SGMegaFile *> *filesIn(NSArray *nodes, NSString *folder, NSData *folderKey) {
    NSMutableDictionary<NSString *, NSDictionary *> *byHandle = [NSMutableDictionary dictionary];
    for (id node in nodes) {
        if (![node isKindOfClass:NSDictionary.class] || ![node[@"h"] isKindOfClass:NSString.class] || ![node[@"k"] isKindOfClass:NSString.class]) continue;
        // "owner:key", or several separated by "/": the first that unlocks is the folder's.
        NSData *key = nil;
        for (NSString *pair in [node[@"k"] componentsSeparatedByString:@"/"]) {
            NSRange colon = [pair rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            key = aes(kCCDecrypt, YES, folderKey, base64url([pair substringFromIndex:colon.location + 1]));
            if (key) break;
        }
        BOOL isFile = [node[@"t"] integerValue] == 0;
        if (!key || (isFile && key.length < 32)) continue;
        NSString *name = nameIn(node[@"a"], isFile ? aesKeyOf(key) : [key subdataWithRange:NSMakeRange(0, 16)]);
        if (!name.length) continue;
        byHandle[node[@"h"]] = @{@"name": name, @"parent": [node[@"p"] isKindOfClass:NSString.class] ? node[@"p"] : @"",
                                 @"file": @(isFile), @"key": key, @"size": [node[@"s"] isKindOfClass:NSNumber.class] ? node[@"s"] : @0};
    }
    NSMutableArray<SGMegaFile *> *files = [NSMutableArray array];
    for (NSString *handle in byHandle) {
        NSDictionary *node = byHandle[handle];
        if (![node[@"file"] boolValue]) continue;
        // Up through its folders to the shared one, whose own name is left out.
        NSString *path = node[@"name"];
        NSDictionary *parent = byHandle[node[@"parent"]];
        for (NSUInteger depth = 0; parent && byHandle[parent[@"parent"]] && depth < 16; depth++) {
            path = [NSString stringWithFormat:@"%@/%@", parent[@"name"], path];
            parent = byHandle[parent[@"parent"]];
        }
        SGMegaFile *file = [SGMegaFile new];
        file.name = path;
        file.handle = handle;
        file.folder = folder;
        file.key = node[@"key"];
        file.size = [node[@"size"] longLongValue];
        [files addObject:file];
    }
    [files sortUsingComparator:^NSComparisonResult(SGMegaFile *a, SGMegaFile *b) { return [a.name localizedStandardCompare:b.name]; }];
    return files;
}

void SGMegaList(NSString *link, void (^done)(NSArray<SGMegaFile *> *files, NSString *error)) {
    NSString *handle = nil, *keyText = nil;
    BOOL folder = NO;
    if (!parse(link, &handle, &keyText, &folder)) {
        done(nil, @"Not a Mega link.");
        return;
    }
    NSData *key = base64url(keyText);
    if (folder) {
        if (key.length != 16) {
            done(nil, @"The folder link's key is missing or cut short. Copy the whole link, with what comes after the #.");
            return;
        }
        request(@{@"a": @"f", @"c": @1, @"ca": @1, @"r": @1}, handle, ^(NSDictionary *answer, NSString *error) {
            if (error) {
                done(nil, error);
                return;
            }
            NSArray *nodes = [answer[@"f"] isKindOfClass:NSArray.class] ? answer[@"f"] : @[];
            NSArray<SGMegaFile *> *files = filesIn(nodes, handle, key);
            SGLog(@"link import: Mega folder, %lu nodes, %lu files", (unsigned long)nodes.count, (unsigned long)files.count);
            done(files, nodes.count && !files.count ? @"The folder's files could not be unlocked. Check that the link's key is complete." : nil);
        });
        return;
    }
    if (key.length != 32) {
        done(nil, @"The file link's key is missing or cut short. Copy the whole link, with what comes after the #.");
        return;
    }
    request(@{@"a": @"g", @"p": handle}, nil, ^(NSDictionary *answer, NSString *error) {
        if (error) {
            done(nil, error);
            return;
        }
        SGMegaFile *file = [SGMegaFile new];
        file.handle = handle;
        file.key = key;
        file.name = nameIn(answer[@"at"], aesKeyOf(key));
        file.size = [answer[@"s"] isKindOfClass:NSNumber.class] ? [answer[@"s"] longLongValue] : 0;
        if (!file.name.length) {
            done(nil, @"The file could not be unlocked. Check that the link's key is complete.");
            return;
        }
        done(@[file], nil);
    });
}

void SGMegaAddress(SGMegaFile *file, void (^done)(NSURL *address, NSString *error)) {
    // ssl 2: an https address, which the app may load.
    NSMutableDictionary *command = [@{@"a": @"g", @"g": @1, @"ssl": @2} mutableCopy];
    command[file.folder ? @"n" : @"p"] = file.handle;
    request(command, file.folder, ^(NSDictionary *answer, NSString *error) {
        NSString *address = [answer[@"g"] isKindOfClass:NSString.class] ? answer[@"g"] : nil;
        NSURL *url = address ? [NSURL URLWithString:address] : nil;
        done(url, url ? nil : error ?: @"Mega gave no address for the file.");
    });
}

#pragma mark - decrypting

BOOL SGMegaDecrypt(SGMegaFile *file, NSString *source, NSString *target) {
    NSData *key = aesKeyOf(file.key);
    if (!key) return NO;
    NSFileHandle *input = [NSFileHandle fileHandleForReadingAtPath:source];
    if (!input || ![NSFileManager.defaultManager createFileAtPath:target contents:nil attributes:nil]) return NO;
    NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:target];
    CCCryptorRef blocks = NULL;
    if (!output || CCCryptorCreate(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode, key.bytes, key.length, NULL, &blocks) != kCCSuccess) return NO;
    // Counter mode by hand: the counter's blocks encrypted, XORed over the file, the counter a 128-bit big-endian number.
    uint8_t counter[16];
    memcpy(counter, counterOf(file.key).bytes, 16);
    NSMutableData *counters = [NSMutableData dataWithLength:kChunk], *stream = [NSMutableData dataWithLength:kChunk];
    BOOL fine = YES;
    while (fine) {
        @autoreleasepool {
            NSError *error = nil;
            NSData *chunk = [input readDataUpToLength:kChunk error:&error];
            if (error) { fine = NO; break; }
            if (!chunk.length) break;
            NSUInteger padded = (chunk.length + 15) / 16 * 16;
            uint8_t *c = counters.mutableBytes;
            for (NSUInteger at = 0; at < padded; at += 16) {
                memcpy(c + at, counter, 16);
                for (int i = 15; i >= 0 && ++counter[i] == 0; i--) {}
            }
            size_t moved = 0;
            if (CCCryptorUpdate(blocks, c, padded, stream.mutableBytes, padded, &moved) != kCCSuccess || moved != padded) { fine = NO; break; }
            NSMutableData *plain = [chunk mutableCopy];
            uint8_t *p = plain.mutableBytes;
            const uint8_t *s = stream.bytes;
            for (NSUInteger i = 0; i < plain.length; i++) p[i] ^= s[i];
            if (![output writeData:plain error:&error]) fine = NO;
        }
    }
    CCCryptorRelease(blocks);
    [input closeAndReturnError:nil];
    [output closeAndReturnError:nil];
    return fine;
}
