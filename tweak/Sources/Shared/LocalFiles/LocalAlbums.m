// LocalAlbums.h says what the albums are made of and how one plays.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Shared/Player/PlayerState.h"
#import "LocalFiles.h"
#import "LocalAlbums.h"

// The URIs the player has played, by the names in them: "artist\nalbum\ntitle" (decoded) -> URI.
static NSString *const kSeenKey = @"spotifyglass.localAlbums.seen";
static const NSUInteger kSeenMost = 4000;
// A URI the player played is taken for a file whose length is within this many seconds of it.
static const NSInteger kSecondsSlack = 2;
// What Spotify plays from Documents; the mod's own folder there is left out.
static NSString *const kOwnFolder = @"Vitrine";

NSNotificationName const SGLocalAlbumsDidChangeNotification = @"spotifyglass.localAlbums.didChange";

@interface SPTPlayerTrack (SGLocalAlbums)
- (instancetype)initWithURI:(NSURL *)uri albumURI:(NSURL *)album artistURI:(NSURL *)artist andUID:(NSString *)uid;
@end
@interface SPTask : NSObject
- (id)addCallback:(void (^)(id))callback on:(dispatch_queue_t)queue;
- (id)addErrorCallback:(void (^)(NSError *))callback on:(dispatch_queue_t)queue;
@end
@interface SPTPlayerQueueWrapperImpl : NSObject
- (instancetype)initWithPlayer:(id)player;
- (SPTask *)queueMultipleTracks:(NSArray *)tracks loggingParams:(id)params;
@end

#pragma mark - tracks and albums

@interface SGLocalTrack ()
@property (nonatomic, copy, readwrite) NSString *uri, *path, *title, *artist, *album;
// The artist before the title's guests were added to it, which is whose album it is.
@property (nonatomic, copy) NSString *lead;
@property (nonatomic, readwrite) NSInteger number, disc, year, seconds;
@property (nonatomic, strong, readwrite) NSDate *added;
@end
@implementation SGLocalTrack
@end

@interface SGLocalAlbum ()
@property (nonatomic, copy, readwrite) NSString *title, *artist, *key;
@property (nonatomic, readwrite) NSInteger year, seconds;
@property (nonatomic, strong, readwrite) NSDate *added;
@property (nonatomic, copy, readwrite) NSArray<SGLocalTrack *> *tracks;
@end
@implementation SGLocalAlbum
@end

// A file's tags as AudioToolbox reads them, kept by path with the file's date and size, so a scan reads
// only what changed.
@interface SGLocalFileTagsRead : NSObject
@property (nonatomic, copy) NSString *title, *artist, *album;
@property (nonatomic) NSInteger number, disc, year, seconds;
@property (nonatomic, strong) NSDate *modified;
@property (nonatomic) unsigned long long size;
@end
@implementation SGLocalFileTagsRead
@end

static NSArray<SGLocalAlbum *> *sg_albums;
static NSDictionary<NSString *, SGLocalAlbum *> *sg_albumOfURI;
static NSMutableDictionary<NSString *, SGLocalFileTagsRead *> *sg_read;   // the scan queue's only
static BOOL sg_scanning;
static NSMutableArray<void (^)(void)> *sg_waiting;

static dispatch_queue_t scanQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.localAlbums", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSString *documents(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static NSString *folded(NSString *text) {
    return [[text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch locale:nil]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

#pragma mark - the URI

// Spotify's form encoding of a URI's part: letters, digits and ".-*_" as they are, a space as "+", every
// other byte of its UTF-8 as %XX.
static NSString *formEncoded(NSString *text) {
    NSMutableString *out = [NSMutableString string];
    const char *bytes = text.UTF8String ?: "";
    for (const unsigned char *c = (const unsigned char *)bytes; *c; c++) {
        if ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || strchr(".-*_", *c)) {
            [out appendFormat:@"%c", *c];
        } else if (*c == ' ') {
            [out appendString:@"+"];
        } else {
            [out appendFormat:@"%%%02X", *c];
        }
    }
    return out;
}

static NSString *seenName(NSString *artist, NSString *album, NSString *title) {
    return [NSString stringWithFormat:@"%@\n%@\n%@", folded(artist ?: @""), folded(album ?: @""), folded(title ?: @"")];
}

static NSDictionary<NSString *, NSString *> *seenURIs(void) {
    id seen = [NSUserDefaults.standardUserDefaults dictionaryForKey:kSeenKey];
    return [seen isKindOfClass:NSDictionary.class] ? seen : @{};
}

// The URI Spotify plays the file under: one the player played for the same names and about the same length,
// else made as Spotify's core makes it.
static NSString *uriFor(SGLocalFileTagsRead *tags, NSDictionary<NSString *, NSString *> *seen) {
    NSString *played = seen[seenName(tags.artist, tags.album, tags.title)];
    if (played) {
        NSInteger seconds = [SGLocalFileTags(played)[@"seconds"] integerValue];
        if (labs(seconds - tags.seconds) <= kSecondsSlack) return played;
    }
    return [NSString stringWithFormat:@"spotify:local:%@:%@:%@:%ld", formEncoded(tags.artist ?: @""), formEncoded(tags.album ?: @""),
            formEncoded(tags.title ?: @""), (long)tags.seconds];
}

// Every local file the player plays is remembered by its names, for uriFor.
@interface SGLocalAlbumsWatcher : NSObject <SGPlayerStateObserver>
@end
@implementation SGLocalAlbumsWatcher {
    NSString *_last;
}
- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *uri = SGURIString(state.track.URI);
    if (!SGLocalFileIs(uri) || [uri isEqualToString:_last]) return;
    _last = uri;
    NSDictionary *tags = SGLocalFileTags(uri);
    if (!tags) return;
    NSString *name = seenName(tags[@"artist"], tags[@"album"], tags[@"title"]);
    NSDictionary *seen = seenURIs();
    if ([seen[name] isEqualToString:uri]) return;
    NSMutableDictionary *more = [seen mutableCopy];
    if (more.count >= kSeenMost) [more removeAllObjects];
    more[name] = uri;
    [NSUserDefaults.standardUserDefaults setObject:more forKey:kSeenKey];
    // A track of a scanned album played under another URI than the one made for it: made again.
    if (sg_albums.count && !sg_albumOfURI[uri]) SGLocalAlbumsRefresh(nil);
}
@end

#pragma mark - reading a file

static NSString *infoString(NSDictionary *info, const char *key) {
    id value = info[@(key)];
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : nil;
}

// The disc number in a file's tags, which AudioToolbox's info dictionary has no key for: an MP4's iTunes "disk"
// (two big-endian numbers after two zero bytes), an MP3's ID3 TPOS ("2/2"), or wherever else AVFoundation finds
// one. 0 when there is none.
static NSInteger discTagOf(NSString *path) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    NSSet<NSString *> *disc = [NSSet setWithArray:@[AVMetadataIdentifieriTunesMetadataDiscNumber, AVMetadataIdentifierID3MetadataPartOfASet,
                                                    @"itsk/disk", @"udta/disk", @"id3/TPOS", @"id3/TPA"]];
    for (AVMetadataItem *item in asset.metadata) {
        if (!item.identifier || ![disc containsObject:item.identifier]) continue;
        id value = item.value;
        if ([value isKindOfClass:NSString.class]) return MAX(0, [value integerValue]);
        if ([value isKindOfClass:NSNumber.class]) return MAX(0, [value integerValue]);
        if ([value isKindOfClass:NSData.class] && ((NSData *)value).length >= 4) {
            const uint8_t *bytes = ((NSData *)value).bytes;
            return bytes[2] << 8 | bytes[3];
        }
    }
    return 0;
}

// The disc from a file's name, for a file whose tags have none: "CD2", "Disc 2" or "disk-2" anywhere in it, or a
// number before the track's in front of it ("2-05 Title", "2.05 Title"); else a track number of three digits,
// as some taggers write a second disc's fifth track (205). Sets the track's number too where the name gave both.
static void discFromName(NSString *name, SGLocalFileTagsRead *tags) {
    static NSRegularExpression *word, *pair;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        word = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[^a-z])(?:cd|disc|disk)\\s*[-_.#]?\\s*(\\d{1,2})(?!\\d)"
                                                         options:NSRegularExpressionCaseInsensitive error:nil];
        pair = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{1,2})[-.](\\d{2,3})(?!\\d)" options:0 error:nil];
    });
    NSRange all = NSMakeRange(0, name.length);
    NSTextCheckingResult *found = [word firstMatchInString:name options:0 range:all];
    if (found) {
        tags.disc = [name substringWithRange:[found rangeAtIndex:1]].integerValue;
        return;
    }
    found = [pair firstMatchInString:name options:0 range:all];
    if (found) {
        tags.disc = [name substringWithRange:[found rangeAtIndex:1]].integerValue;
        if (!tags.number) tags.number = [name substringWithRange:[found rangeAtIndex:2]].integerValue;
        return;
    }
    if (tags.number >= 101 && tags.number <= 999 && tags.number % 100) {
        tags.disc = tags.number / 100;
        tags.number %= 100;
    }
}

static SGLocalFileTagsRead *readTags(NSString *path) {
    AudioFileID file = NULL;
    if (AudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kAudioFileReadPermission, 0, &file) != noErr || !file) return nil;
    SGLocalFileTagsRead *tags = [SGLocalFileTagsRead new];
    CFDictionaryRef info = NULL;
    UInt32 size = sizeof(info);
    if (AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &info) == noErr && info) {
        NSDictionary *read = (__bridge_transfer NSDictionary *)info;
        tags.title = infoString(read, kAFInfoDictionary_Title);
        tags.artist = infoString(read, kAFInfoDictionary_Artist);
        tags.album = infoString(read, kAFInfoDictionary_Album);
        // "3/12" and "2004-11-12" both read as their first number.
        tags.number = infoString(read, kAFInfoDictionary_TrackNumber).integerValue;
        tags.year = infoString(read, kAFInfoDictionary_Year).integerValue;
    }
    Float64 duration = 0;
    size = sizeof(duration);
    if (AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration) == noErr && duration > 0) {
        tags.seconds = (NSInteger)duration;
    }
    AudioFileClose(file);
    tags.disc = discTagOf(path);
    if (!tags.disc) discFromName(path.lastPathComponent.stringByDeletingPathExtension, tags);
    // A file with no title goes by its name, as in Spotify's Local Files.
    if (!tags.title) tags.title = path.lastPathComponent.stringByDeletingPathExtension;
    return tags;
}

static UIImage *artworkOf(NSString *path, CGFloat side) {
    AudioFileID file = NULL;
    if (AudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kAudioFileReadPermission, 0, &file) != noErr || !file) return nil;
    CFDataRef data = NULL;
    UInt32 size = sizeof(data);
    UIImage *image = nil;
    if (AudioFileGetProperty(file, kAudioFilePropertyAlbumArtwork, &size, &data) == noErr && data) {
        image = [UIImage imageWithData:(__bridge_transfer NSData *)data];
    }
    AudioFileClose(file);
    if (!image) return nil;
    CGFloat scale = MIN(1, side * UIScreen.mainScreen.scale / MAX(image.size.width * image.scale, image.size.height * image.scale));
    if (scale >= 1) return image;
    CGSize target = CGSizeMake(round(image.size.width * scale), round(image.size.height * scale));
    return [[[UIGraphicsImageRenderer alloc] initWithSize:target] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:(CGRect){CGPointZero, target}];
    }];
}

#pragma mark - the scan

static NSSet<NSString *> *audioExtensions(void) {
    static NSSet *extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        extensions = [NSSet setWithArray:@[@"mp3", @"m4a", @"mp4", @"aac", @"wav", @"aif", @"aiff", @"flac", @"caf", @"alac"]];
    });
    return extensions;
}

// On the scan queue.
static NSArray<SGLocalAlbum *> *scan(NSDictionary<NSString *, NSString *> *seen) {
    if (!sg_read) sg_read = [NSMutableDictionary dictionary];
    NSString *root = documents();
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *rootURL = [NSURL fileURLWithPath:root isDirectory:YES];
    NSArray *keys = @[NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLCreationDateKey, NSURLFileSizeKey];
    NSDirectoryEnumerator *walk = [files enumeratorAtURL:rootURL includingPropertiesForKeys:keys
                                                 options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    NSMutableDictionary<NSString *, NSMutableArray<SGLocalTrack *> *> *groups = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *present = [NSMutableSet set];
    for (NSURL *url in walk) {
        NSDictionary *values = [url resourceValuesForKeys:keys error:nil];
        if ([values[NSURLIsDirectoryKey] boolValue]) {
            if (walk.level == 1 && [url.lastPathComponent isEqualToString:kOwnFolder]) [walk skipDescendants];
            continue;
        }
        if (![audioExtensions() containsObject:url.pathExtension.lowercaseString]) continue;
        NSString *path = url.path;
        [present addObject:path];
        NSDate *modified = values[NSURLContentModificationDateKey];
        unsigned long long size = [values[NSURLFileSizeKey] unsignedLongLongValue];
        SGLocalFileTagsRead *tags = sg_read[path];
        if (!tags || ![tags.modified isEqual:modified] || tags.size != size) {
            tags = readTags(path);
            if (!tags) continue;
            tags.modified = modified;
            tags.size = size;
            sg_read[path] = tags;
        }
        SGLocalTrack *track = [SGLocalTrack new];
        track.uri = uriFor(tags, seen);
        track.path = path;
        // Shown as the player shows it, the title's guests credited as artists (LocalFiles.h).
        NSDictionary *info = SGLocalFileInfo(track.uri), *shown = SGLocalFileShown(track.uri);
        track.title = shown[@"title"] ?: tags.title;
        track.artist = shown[@"artist"] ?: tags.artist ?: @"";
        track.lead = info[@"artist"] ?: tags.artist ?: @"";
        track.album = info[@"album"] ?: tags.album ?: @"";
        track.number = tags.number;
        track.disc = tags.disc;
        track.year = tags.year;
        track.seconds = tags.seconds;
        track.added = values[NSURLCreationDateKey] ?: modified ?: NSDate.distantPast;
        // Tracks with no album go together by their artist, as the Music app's Unknown Album does.
        NSString *key = track.album.length ? folded(track.album) : [@"\n" stringByAppendingString:folded(track.artist)];
        if (!groups[key]) groups[key] = [NSMutableArray array];
        [groups[key] addObject:track];
    }
    for (NSString *path in sg_read.allKeys) {
        if (![present containsObject:path]) [sg_read removeObjectForKey:path];
    }

    NSMutableArray<SGLocalAlbum *> *albums = [NSMutableArray array];
    for (NSString *key in groups) {
        NSArray<SGLocalTrack *> *tracks = [groups[key] sortedArrayUsingComparator:^NSComparisonResult(SGLocalTrack *a, SGLocalTrack *b) {
            if (a.disc != b.disc) return a.disc < b.disc ? NSOrderedAscending : NSOrderedDescending;
            // A numbered track before an unnumbered one.
            if (a.number != b.number) {
                if (!a.number || !b.number) return a.number ? NSOrderedAscending : NSOrderedDescending;
                return a.number < b.number ? NSOrderedAscending : NSOrderedDescending;
            }
            return [a.title localizedStandardCompare:b.title];
        }];
        SGLocalAlbum *album = [SGLocalAlbum new];
        album.key = key;
        album.tracks = tracks;
        album.title = tracks.firstObject.album.length ? tracks.firstObject.album : @"Unknown Album";
        NSMutableSet<NSString *> *artists = [NSMutableSet set];
        NSInteger seconds = 0, year = 0;
        NSDate *added = NSDate.distantPast;
        for (SGLocalTrack *track in tracks) {
            if (track.lead.length) [artists addObject:folded(track.lead)];
            seconds += track.seconds;
            year = MAX(year, track.year);
            added = [added laterDate:track.added];
        }
        NSString *first = nil;
        for (SGLocalTrack *track in tracks) if (track.lead.length) { first = track.lead; break; }
        album.artist = artists.count > 1 ? @"Various Artists" : first ?: @"Unknown Artist";
        // The artist the user named the album by, over the one its tracks give it.
        id named = [[NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyLocalAlbumArtists] objectForKey:key];
        if ([named isKindOfClass:NSString.class] && [named length]) album.artist = named;
        album.seconds = seconds;
        album.year = year;
        album.added = added;
        [albums addObject:album];
    }
    return albums;
}

static void finishScan(NSArray<SGLocalAlbum *> *albums) {
    NSMutableDictionary<NSString *, SGLocalAlbum *> *ofURI = [NSMutableDictionary dictionary];
    for (SGLocalAlbum *album in albums) {
        for (SGLocalTrack *track in album.tracks) ofURI[track.uri] = album;
    }
    NSUInteger before = sg_albums.count;
    sg_albums = albums;
    sg_albumOfURI = ofURI;
    sg_scanning = NO;
    static BOOL logged;
    if (!logged || before != albums.count) {
        logged = YES;
        SGLog(@"local albums: %lu albums of %lu tracks in Documents", (unsigned long)albums.count, (unsigned long)ofURI.count);
    }
    NSArray<void (^)(void)> *waiting = sg_waiting;
    sg_waiting = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalAlbumsDidChangeNotification object:nil];
    for (void (^done)(void) in waiting) done();
}

static void watchPlayer(void) {
    static SGLocalAlbumsWatcher *watcher;
    if (watcher) return;
    watcher = [SGLocalAlbumsWatcher new];
    SGAddPlayerStateObserver(watcher);
    // An edit renames a track or moves it to another album.
    [NSNotificationCenter.defaultCenter addObserverForName:SGLocalFileEditsDidChangeNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGLocalAlbumsRefresh(nil); });
    }];
}

void SGLocalAlbumsRefresh(void (^done)(void)) {
    NSCAssert(NSThread.isMainThread, @"local albums run on main");
    watchPlayer();
    if (done) {
        if (!sg_waiting) sg_waiting = [NSMutableArray array];
        [sg_waiting addObject:[done copy]];
    }
    if (sg_scanning) return;
    sg_scanning = YES;
    NSDictionary *seen = seenURIs();
    dispatch_async(scanQueue(), ^{
        NSArray<SGLocalAlbum *> *albums = scan(seen);
        dispatch_async(dispatch_get_main_queue(), ^{ finishScan(albums); });
    });
}

NSArray<SGLocalAlbum *> *SGLocalAlbums(void) {
    if (!sg_albums && !sg_scanning) SGLocalAlbumsRefresh(nil);
    return sg_albums ?: @[];
}

NSArray<SGLocalAlbum *> *SGLocalAlbumsSorted(NSArray<SGLocalAlbum *> *albums, SGLocalAlbumSort sort) {
    return [albums sortedArrayUsingComparator:^NSComparisonResult(SGLocalAlbum *a, SGLocalAlbum *b) {
        if (sort == SGLocalAlbumSortAdded) {
            NSComparisonResult newer = [b.added compare:a.added];
            if (newer != NSOrderedSame) return newer;
        } else if (sort == SGLocalAlbumSortArtist) {
            NSComparisonResult artist = [a.artist localizedStandardCompare:b.artist];
            if (artist != NSOrderedSame) return artist;
        }
        return [a.title localizedStandardCompare:b.title];
    }];
}

SGLocalAlbum *SGLocalAlbumOfTrack(NSString *uri) {
    if (!SGLocalFileIs(uri)) return nil;
    SGLocalAlbum *album = sg_albumOfURI[uri];
    if (album) return album;
    // A track played under another URI than the one made for it: found by its names.
    NSDictionary *info = SGLocalFileShown(uri);
    NSString *title = folded(info[@"title"] ?: @""), *albumName = folded(info[@"album"] ?: @"");
    for (SGLocalAlbum *candidate in sg_albums) {
        if (![folded(candidate.title) isEqualToString:albumName]) continue;
        for (SGLocalTrack *track in candidate.tracks) {
            if ([folded(track.title) isEqualToString:title]) return candidate;
        }
    }
    return nil;
}

#pragma mark - the cover

void SGLocalAlbumCover(SGLocalAlbum *album, CGFloat side, void (^done)(UIImage *cover)) {
    static NSCache<NSString *, UIImage *> *covers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ covers = [NSCache new]; covers.countLimit = 120; });
    NSString *picked = nil;
    for (SGLocalTrack *track in album.tracks) {
        picked = SGLocalFileCoverPath(SGLocalFileEditFor(track.uri));
        if (picked) break;
    }
    // A cover picked is a file of its own, named afresh each time: a new one is a new key.
    NSString *cacheKey = [NSString stringWithFormat:@"%@#%.0f#%@#%@", album.key, side, album.tracks.firstObject.uri, picked.lastPathComponent ?: @""];
    UIImage *kept = [covers objectForKey:cacheKey];
    if (kept) { done(kept); return; }
    NSArray<SGLocalTrack *> *tracks = album.tracks;
    dispatch_async(scanQueue(), ^{
        UIImage *cover = picked ? [UIImage imageWithContentsOfFile:picked] : nil;
        for (SGLocalTrack *track in cover ? @[] : tracks) {
            cover = artworkOf(track.path, side);
            if (cover) break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cover) [covers setObject:cover forKey:cacheKey];
            done(cover);
        });
    });
}

#pragma mark - playing

// The first of `future` that is `uri`, nil when the queue does not hold it yet.
static SPTPlayerTrack *queued(NSArray *future, NSString *uri) {
    for (id item in future) {
        if ([item isKindOfClass:NSClassFromString(@"SPTPlayerTrack")] && [SGURIString(((SPTPlayerTrack *)item).URI) isEqualToString:uri]) return item;
    }
    return nil;
}

// Skips to `uri` once the player's state has it in the queue, trying for a few seconds.
static void skipTo(NSString *uri, NSUInteger tries, void (^done)(NSString *error)) {
    id<SPTPlayer> player = SGPlayer();
    SPTPlayerTrack *target = queued(SGPlayerState().future, uri);
    if (!target) {
        if (!tries) { done(@"Spotify put the album in the queue but has not shown it there yet. Open the queue to play it."); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ skipTo(uri, tries - 1, done); });
        return;
    }
    if (![player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) { done(@"Spotify's player cannot skip to the album."); return; }
    [player skipToNextTrackWithOptions:nil track:target];
    if (SGPlayerState().isPaused && [player respondsToSelector:@selector(resume:)]) [player resume:nil];
    SGLog(@"local albums: playing from %@", uri);
    done(nil);
}

// The album put after what is queued, then skipped to.
static void playThroughQueue(SGLocalAlbum *album, NSUInteger from, BOOL shuffle, void (^done)(NSString *error)) {
    NSMutableArray<SGLocalTrack *> *order = [NSMutableArray array];
    if (shuffle) {
        [order addObjectsFromArray:album.tracks];
        for (NSUInteger i = order.count; i > 1; i--) [order exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    } else if (from < album.tracks.count) {
        [order addObjectsFromArray:[album.tracks subarrayWithRange:NSMakeRange(from, album.tracks.count - from)]];
    }
    if (!order.count) { done(@"The album has no tracks."); return; }
    id player = SGPlayer();
    Class wrapperClass = NSClassFromString(@"SPTPlayerQueueWrapperImpl"), trackClass = NSClassFromString(@"SPTPlayerTrack");
    // The player's own state when the mod has not been told one yet.
    SPTPlayerState *state = SGPlayerState() ?: ([player respondsToSelector:@selector(state)] ? [(id<SPTPlayer>)player state] : nil);
    if (!player) {
        SGLog(@"local albums: no player");
        done(@"Spotify's player was not found. Play any song, then try again.");
        return;
    }
    if (![wrapperClass instancesRespondToSelector:@selector(initWithPlayer:)] ||
        ![wrapperClass instancesRespondToSelector:@selector(queueMultipleTracks:loggingParams:)] ||
        ![trackClass instancesRespondToSelector:@selector(initWithURI:albumURI:artistURI:andUID:)]) {
        SGLog(@"local albums: the queue's methods are missing");
        done(@"This version of Spotify has no queue the mod can play an album through.");
        return;
    }
    if (![state isKindOfClass:objc_getClass("SPTPlayerState")] || !state.track) {
        SGLog(@"local albums: no track in the player's state (%@)", [state class]);
        done(@"Play any song first: Spotify's queue is not ready until something has played.");
        return;
    }
    NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:order.count];
    for (SGLocalTrack *track in order) {
        id item = [[trackClass alloc] initWithURI:[NSURL URLWithString:track.uri] albumURI:nil artistURI:nil andUID:nil];
        if (!item) { done(@"Spotify could not prepare the album."); return; }
        [tracks addObject:item];
    }
    // Held until Spotify answers, which it does on a queue of its own.
    __block SPTPlayerQueueWrapperImpl *wrapper = [[wrapperClass alloc] initWithPlayer:player];
    SPTask *task = [wrapper queueMultipleTracks:tracks loggingParams:nil];
    if (![task respondsToSelector:@selector(addCallback:on:)] || ![task respondsToSelector:@selector(addErrorCallback:on:)]) {
        done(@"Spotify did not take the album.");
        return;
    }
    __block BOOL answered = NO;
    NSString *first = order.firstObject.uri;
    [task addCallback:^(id value) {
        if (answered) return;
        answered = YES;
        wrapper = nil;
        skipTo(first, 16, done);
    } on:dispatch_get_main_queue()];
    [task addErrorCallback:^(NSError *error) {
        if (answered) return;
        answered = YES;
        wrapper = nil;
        SGLog(@"local albums: the queue refused the album: %@", error);
        done(@"Spotify could not play the album.");
    } on:dispatch_get_main_queue()];
}

// The album last played from its page, by its key, for the player's header to name while it plays: played from
// the queue, the player's header says Queue. (Played as a context of its own through
// +[SPTPlayerContext contextWithTracks:] and -playContext:options:, the player stopped instead, 9.1.94.)
static NSString *sg_playingKey, *sg_playingTitle;

#pragma mark - song into song

// From one song of a local album into the next with no gap: Spotify's player leaves a moment of silence as it opens
// the next file from the queue, but a crossfade has it start the next file before the last one ends. So while a
// local album played from its page plays, Spotify's crossfade is set to kSeamMilliseconds, too short to hear as a
// fade, and Automix off (it has nothing to go on for a local file); Spotify's own settings are put back as the
// album ends. They are kept under SGKeyLocalAlbumSavedTransitions while the album's are set, so an app quit mid-album
// puts them back on the next launch, at the first state the player reports.
#define SGKeyLocalAlbumSavedTransitions @"spotifyglass.localAlbums.savedTransitions"
static const NSInteger kSeamMilliseconds = 300;

static void songIntoSong(BOOL on) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray<NSNumber *> *saved = [defaults arrayForKey:SGKeyLocalAlbumSavedTransitions];
    if (on) {
        SGTransitionSettings now;
        if (saved.count == 3 || !SGTransitionSettingsRead(&now)) return;
        [defaults setObject:@[@(now.automix), @(now.crossfade), @(now.milliseconds)] forKey:SGKeyLocalAlbumSavedTransitions];
        SGTransitionSettingsWrite((SGTransitionSettings){NO, YES, kSeamMilliseconds});
        SGLog(@"local albums: crossfade %ld ms while the album plays", (long)kSeamMilliseconds);
    } else if (saved.count == 3) {
        if (!SGTransitionSettingsWrite((SGTransitionSettings){saved[0].boolValue, saved[1].boolValue, saved[2].integerValue})) return;
        [defaults removeObjectForKey:SGKeyLocalAlbumSavedTransitions];
        SGLog(@"local albums: Spotify's crossfade put back");
    }
}

@interface SGLocalAlbumSeams : NSObject <SGPlayerStateObserver>
@end

@implementation SGLocalAlbumSeams
- (void)playerStateDidChange:(SPTPlayerState *)state {
    songIntoSong(SGLocalAlbumPlayingTitle() != nil);
}
@end

__attribute__((constructor)) static void watchSeams(void) {
    static SGLocalAlbumSeams *seams;
    dispatch_async(dispatch_get_main_queue(), ^{
        seams = [SGLocalAlbumSeams new];
        SGAddPlayerStateObserver(seams);
    });
}

void SGLocalAlbumPlay(SGLocalAlbum *album, NSUInteger from, BOOL shuffle, void (^done)(NSString *error)) {
    NSCAssert(NSThread.isMainThread, @"local albums run on main");
    playThroughQueue(album, from, shuffle, ^(NSString *error) {
        if (!error) {
            sg_playingKey = album.key;
            sg_playingTitle = album.title;
            SGLocalFilesRecredit();
            songIntoSong(YES);
        }
        done(error);
    });
}

NSString *SGLocalAlbumPlayingTitle(void) {
    if (!sg_playingKey) return nil;
    SGLocalAlbum *album = SGLocalAlbumOfTrack(SGURIString(SGPlayerState().track.URI));
    return [album.key isEqualToString:sg_playingKey] ? sg_playingTitle : nil;
}

#pragma mark - the album's type

SGLocalAlbumType SGLocalAlbumPickedType(SGLocalAlbum *album) {
    id types = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyLocalAlbumTypes];
    id picked = album.key && [types isKindOfClass:NSDictionary.class] ? types[album.key] : nil;
    NSInteger type = [picked isKindOfClass:NSNumber.class] ? [picked integerValue] : SGLocalAlbumTypeAutomatic;
    return type >= SGLocalAlbumTypeAlbum && type <= SGLocalAlbumTypeCompilation ? (SGLocalAlbumType)type : SGLocalAlbumTypeAutomatic;
}

SGLocalAlbumType SGLocalAlbumGuessedType(SGLocalAlbum *album) {
    if ([album.artist isEqualToString:@"Various Artists"]) return SGLocalAlbumTypeCompilation;
    NSUInteger count = album.tracks.count;
    if (album.seconds < 30 * 60 && count <= 3) return SGLocalAlbumTypeSingle;
    if (album.seconds < 30 * 60 && count <= 6) return SGLocalAlbumTypeEP;
    return SGLocalAlbumTypeAlbum;
}

SGLocalAlbumType SGLocalAlbumShownType(SGLocalAlbum *album) {
    SGLocalAlbumType picked = SGLocalAlbumPickedType(album);
    return picked != SGLocalAlbumTypeAutomatic ? picked : SGLocalAlbumGuessedType(album);
}

NSString *SGLocalAlbumTypeName(SGLocalAlbumType type) {
    switch (type) {
        case SGLocalAlbumTypeAutomatic: return @"Automatic";
        case SGLocalAlbumTypeAlbum: return @"Album";
        case SGLocalAlbumTypeSingle: return @"Single";
        case SGLocalAlbumTypeEP: return @"EP";
        case SGLocalAlbumTypeCompilation: return @"Compilation";
    }
    return @"Album";
}

void SGLocalAlbumSetType(SGLocalAlbum *album, SGLocalAlbumType type) {
    if (!album.key) return;
    NSMutableDictionary *types = [[NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyLocalAlbumTypes] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (type == SGLocalAlbumTypeAutomatic) [types removeObjectForKey:album.key];
    else types[album.key] = @(type);
    if (types.count) [NSUserDefaults.standardUserDefaults setObject:types forKey:SGKeyLocalAlbumTypes];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyLocalAlbumTypes];
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalAlbumsDidChangeNotification object:nil];
}

#pragma mark - the album's own edits

// A dictionary of the defaults' with `value` under `key`, nil removing it.
static void storeByAlbum(NSString *defaultsKey, NSString *key, id value) {
    NSMutableDictionary *all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:defaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value) all[key] = value;
    else [all removeObjectForKey:key];
    if (all.count) [NSUserDefaults.standardUserDefaults setObject:all forKey:defaultsKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:defaultsKey];
}

void SGLocalAlbumSetArtist(SGLocalAlbum *album, NSString *artist) {
    if (!album.key) return;
    NSString *name = [artist stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    storeByAlbum(SGKeyLocalAlbumArtists, album.key, name.length ? name : nil);
    SGLocalAlbumsRefresh(nil);
}

void SGLocalAlbumRename(SGLocalAlbum *album, NSString *title) {
    NSString *name = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!album.key || !name.length || [name isEqualToString:album.title]) return;
    // What was kept for the album goes with it to the key its new name gathers it under.
    NSString *key = folded(name);
    for (NSString *defaultsKey in @[SGKeyLocalAlbumArtists, SGKeyLocalAlbumTypes]) {
        id kept = [[NSUserDefaults.standardUserDefaults dictionaryForKey:defaultsKey] objectForKey:album.key];
        if (!kept || [key isEqualToString:album.key]) continue;
        storeByAlbum(defaultsKey, key, kept);
        storeByAlbum(defaultsKey, album.key, nil);
    }
    NSMutableArray<NSString *> *uris = [NSMutableArray array];
    for (SGLocalTrack *track in album.tracks) [uris addObject:track.uri];
    SGLocalFilesSaveAlbum(uris, name, nil);
}

void SGLocalAlbumSetCover(SGLocalAlbum *album, UIImage *cover) {
    if (!cover) return;
    NSMutableArray<NSString *> *uris = [NSMutableArray array];
    for (SGLocalTrack *track in album.tracks) [uris addObject:track.uri];
    SGLocalFilesSaveAlbum(uris, nil, cover);
}
