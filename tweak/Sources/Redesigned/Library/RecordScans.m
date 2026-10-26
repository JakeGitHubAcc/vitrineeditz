#import <CommonCrypto/CommonDigest.h>
#import "Core/SGCore.h"
#import "RecordScans.h"

// MusicBrainz asks every program to say who it is.
static NSString *const kUserAgent = @"VitrineEditz/1.0 ( https://github.com/JakeGitHubAcc/vitrineeditz )";
static const NSTimeInterval kSpacing = 1.1, kAskAgain = 30 * 24 * 3600, kTimeout = 15;
// The releases whose pictures are asked for, at most, and the search's lowest score taken.
static const NSUInteger kReleasesTried = 8;
static const NSInteger kLowestScore = 90;

typedef void (^SGRScansDone)(UIImage *front, UIImage *spine);

@interface SGRScanJob : NSObject
@property (nonatomic, copy) NSString *key, *title, *artist;
@property (nonatomic, strong) NSMutableArray<SGRScansDone> *waiting;
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
    return [folder() stringByAppendingPathComponent:@"scans.plist"];
}

static NSMutableDictionary<NSString *, NSDictionary *> *scanIndex(void) {
    if (!sg_index) {
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

// The pictures a cache entry names, read off main.
static void loadEntry(NSDictionary *entry, SGRScansDone done) {
    NSString *front = entry[@"front"], *spine = entry[@"spine"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *base = folder();
        UIImage *frontImage = front.length ? [UIImage imageWithContentsOfFile:[base stringByAppendingPathComponent:front]] : nil;
        UIImage *spineImage = spine.length ? [UIImage imageWithContentsOfFile:[base stringByAppendingPathComponent:spine]] : nil;
        frontImage = [frontImage imageByPreparingForDisplay] ?: frontImage;
        spineImage = [spineImage imageByPreparingForDisplay] ?: spineImage;
        dispatch_async(dispatch_get_main_queue(), ^{ done(frontImage, spineImage); });
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

// Letters and digits only, lowercased, for telling whether two titles name the same album.
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

// 0 vinyl, 1 CD, 2 anything else on a medium; -1 digital, or no medium said.
static NSInteger formatRank(NSDictionary *release) {
    NSInteger best = -1;
    for (id medium in [release[@"media"] isKindOfClass:NSArray.class] ? release[@"media"] : @[]) {
        NSString *format = [medium isKindOfClass:NSDictionary.class] && [medium[@"format"] isKindOfClass:NSString.class] ? medium[@"format"] : @"";
        NSInteger rank = [format containsString:@"Vinyl"] ? 0 : [format containsString:@"CD"] ? 1
                       : (!format.length || [format containsString:@"Digital"]) ? -1 : 2;
        if (rank >= 0 && (best < 0 || rank < best)) best = rank;
    }
    return best;
}

// The search's releases of this album, the vinyl ones first, then the CDs, then the rest.
static NSArray<NSString *> *candidates(id answer, NSString *title) {
    NSString *wanted = bare(title);
    NSMutableArray<NSDictionary *> *kept = [NSMutableArray array];
    for (id release in [answer isKindOfClass:NSDictionary.class] && [answer[@"releases"] isKindOfClass:NSArray.class] ? answer[@"releases"] : @[]) {
        if (![release isKindOfClass:NSDictionary.class] || ![release[@"id"] isKindOfClass:NSString.class]) continue;
        if ([release[@"score"] integerValue] < kLowestScore) continue;
        NSString *name = bare([release[@"title"] isKindOfClass:NSString.class] ? release[@"title"] : @"");
        if (!name.length || !wanted.length || !([name containsString:wanted] || [wanted containsString:name])) continue;
        NSInteger rank = formatRank(release);
        if (rank < 0) continue;
        [kept addObject:@{@"id": release[@"id"], @"rank": @(rank), @"order": @(kept.count)}];
    }
    [kept sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult byRank = [a[@"rank"] compare:b[@"rank"]];
        return byRank != NSOrderedSame ? byRank : [a[@"order"] compare:b[@"order"]];
    }];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSDictionary *release in kept) {
        if (ids.count == kReleasesTried) break;
        [ids addObject:release[@"id"]];
    }
    return ids;
}

// The address of a picture of `type` among a release's, the 1200 point copy when there is one.
static NSString *pictureOf(id answer, NSString *type) {
    for (id image in [answer isKindOfClass:NSDictionary.class] && [answer[@"images"] isKindOfClass:NSArray.class] ? answer[@"images"] : @[]) {
        if (![image isKindOfClass:NSDictionary.class] || ![image[@"types"] isKindOfClass:NSArray.class]) continue;
        if (![image[@"types"] containsObject:type]) continue;
        NSDictionary *thumbs = [image[@"thumbnails"] isKindOfClass:NSDictionary.class] ? image[@"thumbnails"] : @{};
        for (NSString *size in @[@"1200", @"large", @"500"]) {
            if ([thumbs[size] isKindOfClass:NSString.class]) return thumbs[size];
        }
        if ([image[@"image"] isKindOfClass:NSString.class]) return image[@"image"];
    }
    return nil;
}

// Each release's pictures in turn until there is a front and a spine, or no release left.
static void lookThrough(NSArray<NSString *> *ids, NSUInteger at, NSMutableDictionary *found, void (^done)(void)) {
    if (at >= ids.count || (found[@"front"] && found[@"spine"])) {
        done();
        return;
    }
    NSURL *url = [NSURL URLWithString:[@"https://coverartarchive.org/release/" stringByAppendingString:ids[at]]];
    getJSON(url, NO, ^(NSInteger status, id answer) {
        if (status == 200) {
            if (!found[@"front"]) found[@"front"] = pictureOf(answer, @"Front");
            if (!found[@"spine"]) found[@"spine"] = pictureOf(answer, @"Spine");
        }
        lookThrough(ids, at + 1, found, done);
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

// Downloads what was found into the cache, `done` on main with the entry to keep.
static void download(NSString *key, NSDictionary *found, void (^done)(NSDictionary *entry)) {
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary *entry = [@{@"at": NSDate.date, @"front": @"", @"spine": @""} mutableCopy];
    for (NSString *what in @[@"front", @"spine"]) {
        NSURL *url = found[what] ? [NSURL URLWithString:found[what]] : nil;
        if (!url) continue;
        // Cover Art Archive answers on http too; the app only loads https.
        NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        parts.scheme = @"https";
        dispatch_group_enter(group);
        [[NSURLSession.sharedSession dataTaskWithURL:parts.URL ?: url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UIImage *picture = data.length ? [UIImage imageWithData:data] : nil;
            if ([what isEqualToString:@"spine"]) picture = picture ? lying(picture) : nil;
            NSData *jpeg = picture ? UIImageJPEGRepresentation(picture, 0.88) : nil;
            NSString *name = fileName(key, what);
            BOOL saved = jpeg && [jpeg writeToFile:[folder() stringByAppendingPathComponent:name] atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (saved) entry[what] = name;
                dispatch_group_leave(group);
            });
        }] resume];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{ done(entry); });
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
    NSArray<SGRScansDone> *waiting = [job.waiting copy];
    void (^tell)(UIImage *, UIImage *) = ^(UIImage *front, UIImage *spine) {
        for (SGRScansDone done in waiting) done(front, spine);
    };
    if (entry) loadEntry(entry, tell);
    else tell(nil, nil);
    sg_busy = NO;
    pump();
}

static void run(SGRScanJob *job) {
    NSString *title = plainTitle(job.title);
    NSString *artist = [job.artist componentsSeparatedByString:@", "].firstObject ?: @"";
    NSString *query = artist.length ? [NSString stringWithFormat:@"release:%@ AND artist:%@", quoted(title), quoted(artist)]
                                    : [@"release:" stringByAppendingString:quoted(title)];
    NSString *escaped = [query stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
    NSURL *url = [NSURL URLWithString:[@"https://musicbrainz.org/ws/2/release/?fmt=json&limit=50&query=" stringByAppendingString:escaped]];
    getJSON(url, YES, ^(NSInteger status, id answer) {
        if (status != 200) {
            SGLog(@"records: MusicBrainz answered %ld for a search", (long)status);
            finish(job, nil);
            return;
        }
        NSArray<NSString *> *ids = candidates(answer, title);
        NSMutableDictionary *found = [NSMutableDictionary dictionary];
        lookThrough(ids, 0, found, ^{
            SGLog(@"records: %lu releases, front %@, spine %@", (unsigned long)ids.count, found[@"front"] ? @"found" : @"none",
                  found[@"spine"] ? @"found" : @"none");
            download(job.key, found, ^(NSDictionary *entry) { finish(job, entry); });
        });
    });
}

// One album at a time, the latest asked for first, a search no sooner than kSpacing after the last.
static void pump(void) {
    if (sg_busy || !sg_queue.count) return;
    sg_busy = YES;
    NSTimeInterval wait = kSpacing - (CACurrentMediaTime() - sg_lastSearch);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(wait, 0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGRScanJob *job = sg_queue.lastObject;
        if (!job) {
            sg_busy = NO;
            return;
        }
        [sg_queue removeLastObject];
        run(job);
    });
}

void SGRRecordScans(NSString *title, NSString *artist, void (^done)(UIImage *front, UIImage *spine)) {
    if (!title.length) {
        done(nil, nil);
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@\t%@", artist.lowercaseString ?: @"", title.lowercaseString];
    NSDictionary *entry = scanIndex()[key];
    BOOL nothing = entry && !((NSString *)entry[@"front"]).length && !((NSString *)entry[@"spine"]).length;
    BOOL stale = nothing && -((NSDate *)entry[@"at"]).timeIntervalSinceNow > kAskAgain;
    if (entry && !stale) {
        if (nothing) done(nil, nil);
        else loadEntry(entry, done);
        return;
    }
    if (!sg_failed) sg_failed = [NSMutableSet set];
    if ([sg_failed containsObject:key]) {
        done(nil, nil);
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
        job.waiting = [NSMutableArray array];
        sg_jobs[key] = job;
    } else {
        [sg_queue removeObject:job];
    }
    [job.waiting addObject:[done copy]];
    [sg_queue addObject:job];
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
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, kSide * 4, space, kCGImageAlphaNoneSkipLast);
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
