#import <CommonCrypto/CommonDigest.h>
#import "Core/SGCore.h"
#import "RecordScans.h"

// MusicBrainz asks every program to say who it is.
static NSString *const kUserAgent = @"VitrineEditz/1.0 ( https://github.com/JakeGitHubAcc/vitrineeditz )";
static const NSTimeInterval kSpacing = 1.1, kAskAgain = 30 * 24 * 3600, kTimeout = 15;
// The search's lowest score taken, the pressings whose pictures are asked for at most, and how drawn out a picture
// must be to be a spine.
static const NSInteger kLowestScore = 90;
static const NSUInteger kPressingsTried = 4;
static const CGFloat kSpineLong = 6;
// How alike a scan's front and the streaming cover must be (sameCover()).
static const double kSameCover = 0.38;
// Pressings never taken, by their note.
static NSString *const kNeverPattern = @"picture|zoetrope|deluxe|expanded|anniversary|bonus|super|box";
// A picture of the gatefold's inside, by its comment, and not one of the other things inside a sleeve.
static NSString *const kGatefoldPattern = @"gatefold|inside|inner|interior|open", *const kNotGatefoldPattern = @"sleeve|insert|poster|lyric";
// The picture kinds in the cache's entries.
static NSArray<NSString *> *pictureKinds(void) {
    return @[@"front", @"back", @"spine", @"sticker", @"gatefold1", @"gatefold2"];
}

typedef void (^SGRSleeveDone)(SGRSleeve *sleeve);

@implementation SGRSleeve
@end

@interface SGRScanJob : NSObject
@property (nonatomic, copy) NSString *key, *title, *artist, *kind;
@property (nonatomic, strong) UIImage *cover;
@property (nonatomic, strong) NSMutableArray<SGRSleeveDone> *waiting;
@end

@implementation SGRScanJob
@end

static NSMutableDictionary<NSString *, SGRScanJob *> *sg_jobs;
static NSMutableArray<SGRScanJob *> *sg_queue;
static NSMutableDictionary<NSString *, NSDictionary *> *sg_index;
// Albums whose search failed this launch (no network, MusicBrainz busy): not asked again until the next.
static NSMutableSet<NSString *> *sg_failed;
static BOOL sg_busy;
static CFTimeInterval sg_lastSearch;

#pragma mark - the cache

static NSString *folder(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [caches stringByAppendingPathComponent:@"VitrineRecords"];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

static NSString *indexPath(void) {
    return [folder() stringByAppendingPathComponent:@"sleeves.plist"];
}

// The first build kept any scan, a CD's too, under scans.plist: what it kept is let go.
static void forgetFirstScans(void) {
    NSString *base = folder();
    if (![NSFileManager.defaultManager fileExistsAtPath:[base stringByAppendingPathComponent:@"scans.plist"]]) return;
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:base error:nil]) {
        if ([name isEqualToString:@"scans.plist"] || [name hasSuffix:@"-front.jpg"] || [name hasSuffix:@"-spine.jpg"])
            [NSFileManager.defaultManager removeItemAtPath:[base stringByAppendingPathComponent:name] error:nil];
    }
}

static NSMutableDictionary<NSString *, NSDictionary *> *scanIndex(void) {
    if (!sg_index) {
        forgetFirstScans();
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:indexPath()];
        sg_index = [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    }
    return sg_index;
}

static NSString *fileName(NSString *key, NSString *what) {
    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *name = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [name appendFormat:@"%02x", digest[i]];
    return [NSString stringWithFormat:@"%@-%@.jpg", name, what];
}

static BOOL entryHasFront(NSDictionary *entry) {
    return [entry[@"front"] isKindOfClass:NSString.class] && ((NSString *)entry[@"front"]).length;
}

// The sleeve a cache entry names, read off main.
static void loadEntry(NSDictionary *entry, SGRSleeveDone done) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *base = folder();
        NSMutableDictionary<NSString *, UIImage *> *pictures = [NSMutableDictionary dictionary];
        for (NSString *what in pictureKinds()) {
            NSString *name = [entry[what] isKindOfClass:NSString.class] ? entry[what] : nil;
            UIImage *picture = name.length ? [UIImage imageWithContentsOfFile:[base stringByAppendingPathComponent:name]] : nil;
            if (picture) pictures[what] = [picture imageByPreparingForDisplay] ?: picture;
        }
        SGRSleeve *sleeve = nil;
        if (pictures[@"front"]) {
            sleeve = [SGRSleeve new];
            sleeve.front = pictures[@"front"];
            sleeve.back = pictures[@"back"];
            sleeve.spine = pictures[@"spine"];
            sleeve.sticker = pictures[@"sticker"];
            if (pictures[@"gatefold1"] && pictures[@"gatefold2"]) sleeve.gatefold = @[pictures[@"gatefold1"], pictures[@"gatefold2"]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(sleeve); });
    });
}

#pragma mark - asking

static void getJSON(NSURL *url, BOOL musicBrainz, void (^done)(NSInteger status, id answer)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = kTimeout;
    [request setValue:kUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (musicBrainz) sg_lastSearch = CACurrentMediaTime();
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id answer = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(status, answer); });
    }] resume];
}

// MusicBrainz again, no sooner than kSpacing after its last request.
static void getMusicBrainz(NSURL *url, void (^done)(NSInteger status, id answer)) {
    NSTimeInterval wait = MAX(0, kSpacing - (CACurrentMediaTime() - sg_lastSearch));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        getJSON(url, YES, done);
    });
}

// Letters and digits only, lowercased and without accents, for telling whether two titles are the same.
static NSString *bare(NSString *text) {
    NSMutableString *out = [NSMutableString string];
    NSCharacterSet *keep = NSCharacterSet.alphanumericCharacterSet;
    NSString *folded = [text.lowercaseString stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
    for (NSUInteger i = 0; i < folded.length; i++) {
        unichar c = [folded characterAtIndex:i];
        if ([keep characterIsMember:c]) [out appendFormat:@"%C", c];
    }
    return out;
}

// The album's title without what a streaming release adds to it: "(Deluxe Edition)", "[Remastered 2009]",
// " - 20th Anniversary Edition".
static NSString *plainTitle(NSString *title) {
    static NSRegularExpression *brackets, *dash;
    if (!brackets) {
        NSString *words = @"deluxe|remaster|edition|expanded|anniversary|version|bonus|explicit|special|collector";
        brackets = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"\\s*[\\(\\[][^\\)\\]]*(%@)[^\\)\\]]*[\\)\\]]", words]
                                                             options:NSRegularExpressionCaseInsensitive error:nil];
        dash = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"\\s+-\\s+[^-]*(%@).*$", words]
                                                         options:NSRegularExpressionCaseInsensitive error:nil];
    }
    NSString *plain = [brackets stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
    plain = [dash stringByReplacingMatchesInString:plain options:0 range:NSMakeRange(0, plain.length) withTemplate:@""];
    plain = [plain stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return plain.length ? plain : title;
}

static NSString *quoted(NSString *text) {
    NSString *escaped = [[text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

static BOOL matches(NSString *text, NSString *pattern) {
    return [text isKindOfClass:NSString.class] && [text rangeOfString:pattern options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound;
}

// The search's terms for Spotify's album_type.
static NSString *kindTerms(NSString *kind) {
    if ([kind isEqualToString:@"single"]) return @"(primarytype:single OR primarytype:ep)";
    if ([kind isEqualToString:@"ep"]) return @"primarytype:ep";
    if ([kind isEqualToString:@"compilation"]) return @"secondarytype:compilation";
    return @"primarytype:album";
}

// The release group of exactly this title among the search's, nil for none.
static NSString *groupOf(id answer, NSString *title) {
    NSString *wanted = bare(title);
    for (id group in [answer isKindOfClass:NSDictionary.class] && [answer[@"release-groups"] isKindOfClass:NSArray.class] ? answer[@"release-groups"] : @[]) {
        if (![group isKindOfClass:NSDictionary.class] || ![group[@"id"] isKindOfClass:NSString.class]) continue;
        if ([group[@"score"] integerValue] < kLowestScore) continue;
        NSString *name = [group[@"title"] isKindOfClass:NSString.class] ? group[@"title"] : @"";
        if (wanted.length && [bare(name) isEqualToString:wanted]) return group[@"id"];
    }
    return nil;
}

// The group's vinyl pressings worth asking for pictures, best first: official, the group's own title, a front
// picture, never a picture disc or a deluxe pressing; plain ones before noted ones, then those with a back
// picture, then the oldest.
static NSArray<NSString *> *pressings(id answer, NSString *title) {
    NSString *wanted = bare(title);
    NSMutableArray<NSDictionary *> *kept = [NSMutableArray array];
    for (id release in [answer isKindOfClass:NSDictionary.class] && [answer[@"releases"] isKindOfClass:NSArray.class] ? answer[@"releases"] : @[]) {
        if (![release isKindOfClass:NSDictionary.class] || ![release[@"id"] isKindOfClass:NSString.class]) continue;
        NSDictionary *art = [release[@"cover-art-archive"] isKindOfClass:NSDictionary.class] ? release[@"cover-art-archive"] : @{};
        if (![art[@"front"] boolValue]) continue;
        if ([release[@"status"] isKindOfClass:NSString.class] && ![release[@"status"] isEqualToString:@"Official"]) continue;
        NSString *name = [release[@"title"] isKindOfClass:NSString.class] ? release[@"title"] : @"";
        if (![bare(name) isEqualToString:wanted]) continue;
        NSString *note = [release[@"disambiguation"] isKindOfClass:NSString.class] ? release[@"disambiguation"] : @"";
        if (matches(note, kNeverPattern)) continue;
        BOOL vinyl = NO;
        for (id medium in [release[@"media"] isKindOfClass:NSArray.class] ? release[@"media"] : @[]) {
            if ([medium isKindOfClass:NSDictionary.class] && matches(medium[@"format"], @"vinyl")) vinyl = YES;
        }
        if (!vinyl) continue;
        NSString *date = [release[@"date"] isKindOfClass:NSString.class] && ((NSString *)release[@"date"]).length ? release[@"date"] : @"9999";
        [kept addObject:@{@"id": release[@"id"], @"noted": @(note.length > 0), @"back": @(![art[@"back"] boolValue]), @"date": date}];
    }
    [kept sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"noted" ascending:YES],
                                 [NSSortDescriptor sortDescriptorWithKey:@"back" ascending:YES],
                                 [NSSortDescriptor sortDescriptorWithKey:@"date" ascending:YES]]];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSDictionary *release in kept) {
        if (ids.count == kPressingsTried) break;
        [ids addObject:release[@"id"]];
    }
    return ids;
}

static NSString *addressOf(NSDictionary *image) {
    NSDictionary *thumbs = [image[@"thumbnails"] isKindOfClass:NSDictionary.class] ? image[@"thumbnails"] : @{};
    for (NSString *size in @[@"1200", @"large"]) {
        if ([thumbs[size] isKindOfClass:NSString.class]) return thumbs[size];
    }
    return [image[@"image"] isKindOfClass:NSString.class] ? image[@"image"] : nil;
}

// What a release's pictures give of the sleeve, as addresses by kind: the front (none, none of the rest either), the
// back, a spine that is only a spine, a sticker scanned on its own, and the gatefold's inside, a spread or its halves.
static NSDictionary<NSString *, NSString *> *sleeveIn(id answer) {
    NSMutableDictionary<NSString *, NSString *> *found = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *inside = [NSMutableArray array];
    for (id image in [answer isKindOfClass:NSDictionary.class] && [answer[@"images"] isKindOfClass:NSArray.class] ? answer[@"images"] : @[]) {
        if (![image isKindOfClass:NSDictionary.class] || ![image[@"types"] isKindOfClass:NSArray.class]) continue;
        NSArray *types = image[@"types"];
        NSString *address = addressOf(image), *comment = [image[@"comment"] isKindOfClass:NSString.class] ? image[@"comment"] : @"";
        if (!address) continue;
        if ([types containsObject:@"Front"]) {
            if (!found[@"front"]) found[@"front"] = address;
        } else if ([types containsObject:@"Back"]) {
            if (!found[@"back"]) found[@"back"] = address;
        } else if (types.count == 1 && [types containsObject:@"Spine"]) {
            if (!found[@"spine"]) found[@"spine"] = address;
        } else if (types.count == 1 && [types containsObject:@"Sticker"]) {
            if (!found[@"sticker"]) found[@"sticker"] = address;
        } else if (matches(comment, kGatefoldPattern) && !matches(comment, kNotGatefoldPattern) && ![types containsObject:@"Medium"]) {
            [inside addObject:address];
        }
    }
    if (!found[@"front"]) return nil;
    if (inside.count) found[@"gatefold1"] = inside[0];
    if (inside.count > 1) found[@"gatefold2"] = inside[1];
    return found;
}

#pragma mark - telling covers apart

// The picture at 8 by 8, each channel brought to no mean and unit spread, so a scan's light and color cast weigh
// nothing; NO when it cannot be read.
static BOOL normalized(UIImage *picture, float out[8 * 8 * 3]) {
    CGImageRef image = picture.CGImage;
    if (!image) return NO;
    enum { kSmall = 8 };
    uint8_t pixels[kSmall * kSmall * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, kSmall, kSmall, 8, kSmall * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(space);
    if (!context) return NO;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    // A scan's edge is often the room around the sleeve: a twentieth off each side.
    CGFloat inset = kSmall * 0.05;
    CGContextDrawImage(context, CGRectMake(-inset, -inset, kSmall + 2 * inset, kSmall + 2 * inset), image);
    CGContextRelease(context);
    for (int c = 0; c < 3; c++) {
        double sum = 0, squares = 0;
        for (int i = 0; i < kSmall * kSmall; i++) sum += pixels[i * 4 + c];
        double mean = sum / (kSmall * kSmall);
        for (int i = 0; i < kSmall * kSmall; i++) squares += pow(pixels[i * 4 + c] - mean, 2);
        double spread = MAX(sqrt(squares / (kSmall * kSmall)), 4);
        for (int i = 0; i < kSmall * kSmall; i++) out[c * kSmall * kSmall + i] = (float)((pixels[i * 4 + c] - mean) / spread);
    }
    return YES;
}

// Whether a scan shows the same picture as `cover`, the streaming one, allowing for a scan's light and color cast:
// Dookie's 1994 sleeve scored 0.46 against its cover, its picture disc in its clear sleeve 0.31, and different
// covers 0.25 at most.
static BOOL sameCover(UIImage *scan, UIImage *cover) {
    float a[8 * 8 * 3], b[8 * 8 * 3];
    if (!normalized(scan, a) || !normalized(cover, b)) return NO;
    double together = 0;
    for (int i = 0; i < 8 * 8 * 3; i++) together += a[i] * b[i];
    return together / (8 * 8 * 3) > kSameCover;
}

static NSURL *secure(NSString *address) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:address];
    // The archive's addresses are often http; the app only loads https.
    parts.scheme = @"https";
    return parts.URL ?: [NSURL URLWithString:address];
}

// Each pressing's pictures in turn until one has a front showing the album's cover (`cover`; any front without it).
static void lookThrough(NSArray<NSString *> *ids, NSUInteger at, UIImage *cover, void (^done)(NSDictionary<NSString *, NSString *> *found)) {
    if (at >= ids.count) {
        done(nil);
        return;
    }
    void (^next)(void) = ^{ lookThrough(ids, at + 1, cover, done); };
    NSURL *url = [NSURL URLWithString:[@"https://coverartarchive.org/release/" stringByAppendingString:ids[at]]];
    getJSON(url, NO, ^(NSInteger status, id answer) {
        NSDictionary<NSString *, NSString *> *found = status == 200 ? sleeveIn(answer) : nil;
        if (!found) {
            next();
            return;
        }
        if (!cover) {
            done(found);
            return;
        }
        [[NSURLSession.sharedSession dataTaskWithURL:secure(found[@"front"]) completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UIImage *front = data.length ? [UIImage imageWithData:data] : nil;
            BOOL same = front && sameCover(front, cover);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (same) done(found);
                else {
                    SGLog(@"records: a pressing's front is not the album's cover");
                    next();
                }
            });
        }] resume];
    });
}

// A spine is photographed standing; it is turned a quarter to the left to lie along the edge, its writing,
// which runs down a standing spine, reading left to right.
static UIImage *lying(UIImage *spine) {
    if (spine.size.height <= spine.size.width) return spine;
    CGSize size = CGSizeMake(spine.size.height, spine.size.width);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef cg = context.CGContext;
        CGContextTranslateCTM(cg, 0, size.height);
        CGContextRotateCTM(cg, -M_PI_2);
        [spine drawInRect:CGRectMake(0, 0, spine.size.width, spine.size.height)];
    }];
}

// One picture of a gatefold's inside that is the whole spread is cut into its halves.
static NSArray<UIImage *> *halves(UIImage *spread) {
    CGImageRef image = spread.CGImage;
    if (!image) return nil;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGImageRef left = CGImageCreateWithImageInRect(image, CGRectMake(0, 0, width / 2, height));
    CGImageRef right = CGImageCreateWithImageInRect(image, CGRectMake(width / 2, 0, width - width / 2, height));
    NSArray<UIImage *> *both = left && right ? @[[UIImage imageWithCGImage:left], [UIImage imageWithCGImage:right]] : nil;
    if (left) CGImageRelease(left);
    if (right) CGImageRelease(right);
    return both;
}

// Downloads what was found into the cache, `done` on main with the entry to keep.
static void download(NSString *key, NSDictionary<NSString *, NSString *> *found, void (^done)(NSDictionary *entry)) {
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary *entry = [@{@"at": NSDate.date} mutableCopy];
    NSMutableDictionary<NSString *, UIImage *> *pictures = [NSMutableDictionary dictionary];
    for (NSString *what in pictureKinds()) {
        if (!found[what]) continue;
        dispatch_group_enter(group);
        [[NSURLSession.sharedSession dataTaskWithURL:secure(found[what]) completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UIImage *picture = data.length ? [UIImage imageWithData:data] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (picture) pictures[what] = picture;
                dispatch_group_leave(group);
            });
        }] resume];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (pictures[@"spine"]) {
                UIImage *spine = lying(pictures[@"spine"]);
                CGFloat drawn = spine.size.width / MAX(spine.size.height, 1);
                if (drawn >= kSpineLong) pictures[@"spine"] = spine;
                else [pictures removeObjectForKey:@"spine"];
            }
            // A spread is wider than tall; two halves come as two pictures.
            UIImage *first = pictures[@"gatefold1"];
            if (first && !pictures[@"gatefold2"] && first.size.width > first.size.height * 1.5) {
                NSArray<UIImage *> *both = halves(first);
                if (both) {
                    pictures[@"gatefold1"] = both[0];
                    pictures[@"gatefold2"] = both[1];
                }
            }
            if (!pictures[@"gatefold2"]) [pictures removeObjectForKey:@"gatefold1"];
            NSMutableDictionary *saved = [NSMutableDictionary dictionary];
            if (pictures[@"front"]) {
                for (NSString *what in pictures) {
                    NSData *jpeg = UIImageJPEGRepresentation(pictures[what], 0.88);
                    NSString *name = fileName(key, what);
                    if (jpeg && [jpeg writeToFile:[folder() stringByAppendingPathComponent:name] atomically:YES]) saved[what] = name;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [entry addEntriesFromDictionary:saved];
                done(entry);
            });
        });
    });
}

static void pump(void);

static void finish(SGRScanJob *job, NSDictionary *entry) {
    if (entry) {
        scanIndex()[job.key] = entry;
        [scanIndex() writeToFile:indexPath() atomically:YES];
    } else {
        [sg_failed addObject:job.key];
    }
    [sg_jobs removeObjectForKey:job.key];
    NSArray<SGRSleeveDone> *waiting = [job.waiting copy];
    SGRSleeveDone tell = ^(SGRSleeve *sleeve) {
        for (SGRSleeveDone done in waiting) done(sleeve);
    };
    if (entryHasFront(entry)) loadEntry(entry, tell);
    else tell(nil);
    sg_busy = NO;
    pump();
}

static void run(SGRScanJob *job) {
    NSString *title = plainTitle(job.title);
    NSString *artist = [job.artist componentsSeparatedByString:@", "].firstObject ?: @"";
    NSMutableString *query = [NSMutableString stringWithFormat:@"releasegroup:%@ AND %@", quoted(title), kindTerms(job.kind)];
    if (artist.length) [query appendFormat:@" AND artist:%@", quoted(artist)];
    NSString *escaped = [query stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
    NSURL *search = [NSURL URLWithString:[@"https://musicbrainz.org/ws/2/release-group/?fmt=json&limit=10&query=" stringByAppendingString:escaped]];
    getMusicBrainz(search, ^(NSInteger status, id answer) {
        if (status != 200) {
            SGLog(@"records: MusicBrainz answered %ld for a search", (long)status);
            finish(job, nil);
            return;
        }
        NSString *group = groupOf(answer, title);
        if (!group) {
            finish(job, @{@"at": NSDate.date});
            return;
        }
        NSURL *browse = [NSURL URLWithString:[NSString stringWithFormat:@"https://musicbrainz.org/ws/2/release?release-group=%@&inc=media&fmt=json&limit=100", group]];
        getMusicBrainz(browse, ^(NSInteger listed, id releases) {
            if (listed != 200) {
                SGLog(@"records: MusicBrainz answered %ld for a group's releases", (long)listed);
                finish(job, nil);
                return;
            }
            NSArray<NSString *> *ids = pressings(releases, title);
            lookThrough(ids, 0, job.cover, ^(NSDictionary<NSString *, NSString *> *found) {
                SGLog(@"records: %lu vinyl pressings, sleeve %@", (unsigned long)ids.count, found ? [found.allKeys componentsJoinedByString:@" "] : @"none");
                if (!found) finish(job, @{@"at": NSDate.date});
                else download(job.key, found, ^(NSDictionary *entry) { finish(job, entry); });
            });
        });
    });
}

// One album at a time, the latest asked for first.
static void pump(void) {
    if (sg_busy || !sg_queue.count) return;
    sg_busy = YES;
    SGRScanJob *job = sg_queue.lastObject;
    [sg_queue removeLastObject];
    run(job);
}

void SGRRecordSleeve(NSString *title, NSString *artist, NSString *kind, UIImage *cover, void (^done)(SGRSleeve *sleeve)) {
    if (!title.length) {
        done(nil);
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@\t%@\t%@", artist.lowercaseString ?: @"", title.lowercaseString, kind ?: @"album"];
    NSDictionary *entry = scanIndex()[key];
    BOOL stale = entry && !entryHasFront(entry) && -((NSDate *)entry[@"at"]).timeIntervalSinceNow > kAskAgain;
    if (entry && !stale) {
        if (entryHasFront(entry)) loadEntry(entry, done);
        else done(nil);
        return;
    }
    if (!sg_failed) sg_failed = [NSMutableSet set];
    if ([sg_failed containsObject:key]) {
        done(nil);
        return;
    }
    if (!sg_jobs) sg_jobs = [NSMutableDictionary dictionary];
    if (!sg_queue) sg_queue = [NSMutableArray array];
    SGRScanJob *job = sg_jobs[key];
    if (!job) {
        job = [SGRScanJob new];
        job.key = key;
        job.title = title;
        job.artist = artist ?: @"";
        job.kind = kind ?: @"album";
        job.cover = cover;
        job.waiting = [NSMutableArray array];
        sg_jobs[key] = job;
        [sg_queue addObject:job];
    } else if ([sg_queue containsObject:job]) {
        // Asked for again: to the front of the line. One already running is not in the queue, and tells this too.
        [sg_queue removeObject:job];
        [sg_queue addObject:job];
    }
    [job.waiting addObject:[done copy]];
    pump();
}

#pragma mark - colors

static CGFloat luminance(CGFloat r, CGFloat g, CGFloat b) {
    CGFloat (^linear)(CGFloat) = ^CGFloat(CGFloat c) { return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); };
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
}

static CGFloat contrast(CGFloat a, CGFloat b) {
    return (MAX(a, b) + 0.05) / (MIN(a, b) + 0.05);
}

void SGRSpineColors(UIImage *cover, UIColor **back, UIColor **text) {
    *back = [UIColor colorWithWhite:0.106 alpha:1];
    *text = UIColor.whiteColor;
    CGImageRef image = cover.CGImage;
    if (!image) return;
    enum { kSide = 32, kBuckets = 4096 };
    uint8_t pixels[kSide * kSide * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, kSide * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(space);
    if (!context) return;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image);
    CGContextRelease(context);

    // Colors in buckets of 16 levels a channel. The rows by the bottom edge, which the strip runs along, count
    // three times.
    double *weight = calloc(kBuckets, sizeof(double));
    double (*sum)[3] = calloc(kBuckets, sizeof(double[3]));
    double total = 0;
    for (int y = 0; y < kSide; y++) {
        double w = y >= kSide - 6 ? 3 : 1;
        for (int x = 0; x < kSide; x++) {
            uint8_t *p = pixels + (y * kSide + x) * 4;
            int bucket = (p[0] >> 4) << 8 | (p[1] >> 4) << 4 | (p[2] >> 4);
            weight[bucket] += w;
            sum[bucket][0] += w * p[0];
            sum[bucket][1] += w * p[1];
            sum[bucket][2] += w * p[2];
            total += w;
        }
    }
    int top = 0;
    for (int b = 1; b < kBuckets; b++) if (weight[b] > weight[top]) top = b;
    CGFloat br = sum[top][0] / weight[top] / 255, bg = sum[top][1] / weight[top] / 255, bb = sum[top][2] / weight[top] / 255;
    CGFloat backLight = luminance(br, bg, bb);
    *back = [UIColor colorWithRed:br green:bg blue:bb alpha:1];

    // The cover's own color that reads best on it, among those it has a fair amount of.
    int pick = -1;
    CGFloat best = 0;
    for (int b = 0; b < kBuckets; b++) {
        if (weight[b] < total * 0.02 || b == top) continue;
        CGFloat r = sum[b][0] / weight[b] / 255, g = sum[b][1] / weight[b] / 255, u = sum[b][2] / weight[b] / 255;
        CGFloat c = contrast(luminance(r, g, u), backLight);
        if (c > best) {
            best = c;
            pick = b;
        }
    }
    if (pick >= 0 && best >= 4.5) {
        *text = [UIColor colorWithRed:sum[pick][0] / weight[pick] / 255 green:sum[pick][1] / weight[pick] / 255
                                 blue:sum[pick][2] / weight[pick] / 255 alpha:1];
    } else {
        *text = contrast(1, backLight) >= contrast(0, backLight) ? UIColor.whiteColor : UIColor.blackColor;
    }
    free(weight);
    free(sum);
}
