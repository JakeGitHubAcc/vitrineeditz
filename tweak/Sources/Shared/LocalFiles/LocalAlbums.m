// LocalAlbums.h says what the albums are made of and how one plays.
#import <AudioToolbox/AudioToolbox.h>
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
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
@property (nonatomic) NSInteger number, year, seconds;
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
        NSDictionary *info = SGLocalFileInfo(track.uri);
        track.title = info[@"title"] ?: tags.title;
        track.artist = info[@"artist"] ?: tags.artist ?: @"";
        track.album = info[@"album"] ?: tags.album ?: @"";
        track.number = tags.number;
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
            if (track.artist.length) [artists addObject:folded(track.artist)];
            seconds += track.seconds;
            year = MAX(year, track.year);
            added = [added laterDate:track.added];
        }
        NSString *first = nil;
        for (SGLocalTrack *track in tracks) if (track.artist.length) { first = track.artist; break; }
        album.artist = artists.count > 1 ? @"Various Artists" : first ?: @"Unknown Artist";
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
    NSDictionary *info = SGLocalFileInfo(uri);
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
    NSString *cacheKey = [NSString stringWithFormat:@"%@#%.0f#%@", album.key, side, album.tracks.firstObject.uri];
    UIImage *kept = [covers objectForKey:cacheKey];
    if (kept) { done(kept); return; }
    NSString *picked = nil;
    for (SGLocalTrack *track in album.tracks) {
        picked = SGLocalFileCoverPath(SGLocalFileEditFor(track.uri));
        if (picked) break;
    }
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

void SGLocalAlbumPlay(SGLocalAlbum *album, NSUInteger from, BOOL shuffle, void (^done)(NSString *error)) {
    NSCAssert(NSThread.isMainThread, @"local albums run on main");
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
