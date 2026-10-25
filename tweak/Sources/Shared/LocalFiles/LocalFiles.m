// LocalFiles.h says what is kept and why the file is not written.
//
// Threading: the edits are read on whatever thread Spotify reads a track's metadata on, so the table is
// swapped whole under a lock; they are written on the main thread.
#import <os/lock.h>
#import "Core/SGCore.h"
#import "LocalFiles.h"

static NSString *const kLocalPrefix = @"spotify:local:";
// A cover is kept no larger than this on its longer side; the player draws it at under half that.
static const CGFloat kCoverSide = 1200;

NSNotificationName const SGLocalFileEditsDidChangeNotification = @"spotifyglass.localFiles.editsDidChange";

static NSDictionary<NSString *, NSDictionary *> *sg_edits;
static os_unfair_lock sg_lock = OS_UNFAIR_LOCK_INIT;

BOOL SGLocalFileIs(NSString *uri) {
    return [uri isKindOfClass:NSString.class] && [uri hasPrefix:kLocalPrefix];
}

static NSDictionary<NSString *, NSDictionary *> *allEdits(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyLocalFileEdits];
        os_unfair_lock_lock(&sg_lock);
        sg_edits = [stored isKindOfClass:NSDictionary.class] ? stored : @{};
        os_unfair_lock_unlock(&sg_lock);
    });
    os_unfair_lock_lock(&sg_lock);
    NSDictionary *edits = sg_edits;
    os_unfair_lock_unlock(&sg_lock);
    return edits;
}

static void storeEdits(NSDictionary<NSString *, NSDictionary *> *edits) {
    os_unfair_lock_lock(&sg_lock);
    sg_edits = [edits copy];
    os_unfair_lock_unlock(&sg_lock);
    if (edits.count) [NSUserDefaults.standardUserDefaults setObject:edits forKey:SGKeyLocalFileEdits];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyLocalFileEdits];
}

NSDictionary<NSString *, id> *SGLocalFileEditFor(NSString *uri) {
    if (!SGLocalFileIs(uri)) return nil;
    id edit = allEdits()[uri];
    return [edit isKindOfClass:NSDictionary.class] ? edit : nil;
}

NSString *SGLocalFileLyricsKey(NSString *uri) {
    if (!SGLocalFileIs(uri)) return nil;
    id number = SGLocalFileEditFor(uri)[@"number"];
    return number ? [NSString stringWithFormat:@"%@#%@", uri, number] : uri;
}

#pragma mark - the URI's own names

// Form encoded: "+" is a space and the rest percent escapes, so a part never holds a raw ":".
static NSString *decoded(NSString *part) {
    NSString *spaced = [part stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return spaced.stringByRemovingPercentEncoding ?: spaced;
}

NSDictionary<NSString *, id> *SGLocalFileTags(NSString *uri) {
    if (!SGLocalFileIs(uri)) return nil;
    NSArray<NSString *> *parts = [[uri substringFromIndex:kLocalPrefix.length] componentsSeparatedByString:@":"];
    if (parts.count != 4) return nil;
    NSMutableDictionary<NSString *, id> *tags = [NSMutableDictionary dictionary];
    NSString *artist = decoded(parts[0]), *album = decoded(parts[1]), *title = decoded(parts[2]);
    if (title.length) tags[@"title"] = title;
    if (artist.length) tags[@"artist"] = artist;
    if (album.length) tags[@"album"] = album;
    // A lyrics key carries "#<number>" after the seconds, which integerValue stops at.
    tags[@"seconds"] = @(MAX(parts[3].integerValue, 0));
    return tags;
}

NSDictionary<NSString *, id> *SGLocalFileInfo(NSString *uri) {
    NSDictionary *tags = SGLocalFileTags(uri);
    if (!tags) return nil;
    NSRange mark = [uri rangeOfString:@"#" options:NSBackwardsSearch];
    NSDictionary *edit = SGLocalFileEditFor(mark.location == NSNotFound ? uri : [uri substringToIndex:mark.location]);
    if (!edit) return tags;
    NSMutableDictionary<NSString *, id> *info = [tags mutableCopy];
    for (NSString *field in @[@"title", @"artist", @"album"]) {
        if ([edit[field] length]) info[field] = edit[field];
    }
    return info;
}

#pragma mark - the guests a title names

static NSString *trimmed(NSString *text) {
    NSArray<NSString *> *words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}

BOOL SGLocalFileSplitCredits(NSString *title, NSString *artist, NSString **bareTitle, NSString **creditedArtist) {
    if (!title.length) return NO;
    static NSRegularExpression *bracketed, *trailing, *between;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *marker = @"(?:feat\\.?|ft\\.?|featuring)\\s+";
        // Anywhere in the title, so "(feat. A) [Remix]" keeps its remix; a bare marker only at the end, with its dot
        // or as featuring, so a title with "ft" in a word of its own is left alone.
        bracketed = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"\\s*(?:\\(\\s*%@([^()]+?)\\s*\\)|\\[\\s*%@([^\\[\\]]+?)\\s*\\])", marker, marker]
                                                              options:NSRegularExpressionCaseInsensitive error:NULL];
        trailing = [NSRegularExpression regularExpressionWithPattern:@"\\s+(?:feat\\.|ft\\.|featuring)\\s+(.+?)\\s*$"
                                                             options:NSRegularExpressionCaseInsensitive error:NULL];
        // Guests are listed with commas and "&"; "and" and " x " stay, being parts of names as often as not.
        between = [NSRegularExpression regularExpressionWithPattern:@"\\s*(?:,|&)\\s*" options:0 error:NULL];
    });
    NSRange whole = NSMakeRange(0, title.length);
    NSTextCheckingResult *match = [bracketed firstMatchInString:title options:0 range:whole] ?: [trailing firstMatchInString:title options:0 range:whole];
    if (!match) return NO;
    NSString *guests = nil;
    for (NSUInteger i = 1; i < match.numberOfRanges && !guests; i++) {
        NSRange range = [match rangeAtIndex:i];
        if (range.location != NSNotFound) guests = [title substringWithRange:range];
    }
    NSString *bare = trimmed([title stringByReplacingCharactersInRange:match.range withString:@" "]);
    if (!guests.length || !bare.length) return NO;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableSet<NSString *> *named = [NSMutableSet set];
    NSString *lead = trimmed(artist ?: @"");
    // A guest the artist line already names is not named twice.
    NSString *leads = [between stringByReplacingMatchesInString:lead options:0 range:NSMakeRange(0, lead.length) withTemplate:@"\n"];
    for (NSString *name in [leads componentsSeparatedByString:@"\n"]) {
        NSString *key = trimmed(name).lowercaseString.precomposedStringWithCanonicalMapping;
        if (key.length) [named addObject:key];
    }
    if (lead.length) [names addObject:lead];
    NSString *list = [between stringByReplacingMatchesInString:guests options:0 range:NSMakeRange(0, guests.length) withTemplate:@"\n"];
    for (NSString *guest in [list componentsSeparatedByString:@"\n"]) {
        NSString *name = trimmed(guest), *key = name.lowercaseString.precomposedStringWithCanonicalMapping;
        if (!name.length || [named containsObject:key]) continue;
        [named addObject:key];
        [names addObject:name];
    }
    if (bareTitle) *bareTitle = bare;
    if (creditedArtist) *creditedArtist = [names componentsJoinedByString:@", "];
    return YES;
}

// Asked for every row many times a second, so each URI is split once; an edit empties it.
static NSCache *shownCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    return cache;
}

NSDictionary<NSString *, id> *SGLocalFileShown(NSString *uri) {
    if (!SGLocalFileIs(uri)) return nil;
    id cached = [shownCache() objectForKey:uri];
    if (cached) return cached;
    NSDictionary *info = SGLocalFileInfo(uri);
    if (!info) return nil;
    NSString *title = nil, *artist = nil;
    NSDictionary *shown = info;
    if (SGLocalFileSplitCredits(info[@"title"], info[@"artist"], &title, &artist)) {
        NSMutableDictionary *credited = [info mutableCopy];
        credited[@"title"] = title;
        if (artist.length) credited[@"artist"] = artist;
        credited[@"credited"] = @YES;
        shown = credited;
    }
    [shownCache() setObject:shown forKey:uri];
    return shown;
}

#pragma mark - explicit

// The URIs marked explicit, swapped whole under the edits' lock: read on whatever thread Spotify reads metadata on.
static NSSet<NSString *> *sg_explicit;

static NSSet<NSString *> *explicitMarks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id stored = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyLocalFileExplicit];
        os_unfair_lock_lock(&sg_lock);
        sg_explicit = [NSSet setWithArray:[stored isKindOfClass:NSArray.class] ? stored : @[]];
        os_unfair_lock_unlock(&sg_lock);
    });
    os_unfair_lock_lock(&sg_lock);
    NSSet *marks = sg_explicit;
    os_unfair_lock_unlock(&sg_lock);
    return marks;
}

BOOL SGLocalFileExplicit(NSString *uri) {
    if (!SGLocalFileIs(uri)) return NO;
    NSRange mark = [uri rangeOfString:@"#" options:NSBackwardsSearch];
    return [explicitMarks() containsObject:mark.location == NSNotFound ? uri : [uri substringToIndex:mark.location]];
}

static void changed(NSString *uri);

void SGLocalFileSetExplicit(NSString *uri, BOOL marked) {
    if (!SGLocalFileIs(uri) || SGLocalFileExplicit(uri) == marked) return;
    NSMutableSet *marks = [explicitMarks() mutableCopy];
    if (marked) [marks addObject:uri];
    else [marks removeObject:uri];
    os_unfair_lock_lock(&sg_lock);
    sg_explicit = [marks copy];
    os_unfair_lock_unlock(&sg_lock);
    if (marks.count) [NSUserDefaults.standardUserDefaults setObject:marks.allObjects forKey:SGKeyLocalFileExplicit];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyLocalFileExplicit];
    changed(uri);
}

#pragma mark - storing an edit

NSString *SGLocalFileCoversDirectory(void) {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Application Support rather than Documents: Spotify scans Documents for music, and the Files app shows it.
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        directory = [support stringByAppendingPathComponent:@"Vitrine/Local file covers"];
    });
    return directory;
}

NSString *SGLocalFileCoverPath(NSDictionary<NSString *, id> *edit) {
    NSString *name = edit[@"cover"];
    return [name isKindOfClass:NSString.class] && name.length ? [SGLocalFileCoversDirectory() stringByAppendingPathComponent:name] : nil;
}

static NSString *const kImagePrefix = @"spotify:localfileimage:";

NSString *SGLocalFileCoverURL(NSString *path) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *set = [NSCharacterSet.URLPathAllowedCharacterSet mutableCopy];
        // -[NSURL spotifyURIComponents] splits the address on ":"; "/" goes too, so the path is one plain part.
        [set removeCharactersInString:@":/"];
        allowed = set;
    });
    NSString *escaped = [path stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return escaped ? [kImagePrefix stringByAppendingString:escaped] : nil;
}

NSString *SGLocalFileCoverInURL(NSString *url) {
    if (![url isKindOfClass:NSString.class] || ![url hasPrefix:kImagePrefix]) return nil;
    NSString *path = [url substringFromIndex:kImagePrefix.length].stringByRemovingPercentEncoding;
    NSString *directory = [SGLocalFileCoversDirectory() stringByAppendingString:@"/"];
    // Only a file of the covers' own, by its name alone, so no address reaches anything else.
    if (![path hasPrefix:directory] || [path substringFromIndex:directory.length].pathComponents.count != 1) return nil;
    return path;
}

static NSString *writeCover(UIImage *image) {
    CGFloat scale = MIN(1, kCoverSide / MAX(image.size.width, image.size.height));
    CGSize size = CGSizeMake(round(image.size.width * scale), round(image.size.height * scale));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIImage *drawn = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:(CGRect){CGPointZero, size}];
    }];
    NSData *data = UIImageJPEGRepresentation(drawn, 0.9);
    NSString *name = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"jpg"];
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:SGLocalFileCoversDirectory() withIntermediateDirectories:YES attributes:nil error:&error];
    if (!data || ![data writeToFile:[SGLocalFileCoversDirectory() stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error]) {
        SGLog(@"local files: the cover was not written: %@", error);
        return nil;
    }
    return name;
}

// The stored covers among `names` that no edit names any more, deleted. Several files share one an album's edit
// gave them, so a cover goes only with the last file naming it.
static void forgetCovers(NSSet<NSString *> *names, NSDictionary<NSString *, NSDictionary *> *edits) {
    if (!names.count) return;
    NSMutableSet<NSString *> *named = [NSMutableSet set];
    for (NSDictionary *edit in edits.allValues) {
        if ([edit isKindOfClass:NSDictionary.class] && [edit[@"cover"] isKindOfClass:NSString.class]) [named addObject:edit[@"cover"]];
    }
    for (NSString *name in names) {
        if (![named containsObject:name]) [NSFileManager.defaultManager removeItemAtPath:[SGLocalFileCoversDirectory() stringByAppendingPathComponent:name] error:nil];
    }
}

static void changed(NSString *uri) {
    [shownCache() removeAllObjects];
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalFileEditsDidChangeNotification object:uri];
}

void SGLocalFileSaveEdit(NSString *uri, NSDictionary<NSString *, NSString *> *names, UIImage *cover, BOOL keepCover) {
    if (!SGLocalFileIs(uri)) return;
    NSDictionary *tags = SGLocalFileTags(uri), *old = SGLocalFileEditFor(uri);
    NSMutableDictionary<NSString *, id> *edit = [NSMutableDictionary dictionary];
    for (NSString *field in @[@"title", @"artist", @"album"]) {
        NSString *name = [names[field] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length && ![name isEqualToString:tags[field]]) edit[field] = name;
    }
    NSString *oldCover = SGLocalFileCoverPath(old);
    NSString *newCover = cover ? writeCover(cover) : nil;
    if (newCover) edit[@"cover"] = newCover;
    else if (keepCover && oldCover) edit[@"cover"] = old[@"cover"];

    // The lyrics key changes with the names only: a cover alone leaves the lyrics where they are, and the
    // file's own names go back to the bare URI, whose lyrics may still be kept.
    BOOL named = NO, renamed = NO;
    for (NSString *field in @[@"title", @"artist", @"album"]) {
        named = named || edit[field];
        renamed = renamed || !(edit[field] == old[field] || [edit[field] isEqual:old[field]]);
    }
    // Milliseconds, so no two renames of a track share a lyrics key, a reset in between or not.
    if (named) edit[@"number"] = renamed || !old[@"number"] ? @((long long)(NSDate.date.timeIntervalSince1970 * 1000)) : old[@"number"];

    NSMutableDictionary *edits = [allEdits() mutableCopy];
    if (edit.count) {
        edits[uri] = edit;
    } else {
        [edits removeObjectForKey:uri];
    }
    storeEdits(edits);
    if (oldCover && ![edit[@"cover"] isEqual:old[@"cover"]]) forgetCovers([NSSet setWithObject:old[@"cover"]], edits);
    SGLog(@"local files: %@ %@", uri, edit.count ? [NSString stringWithFormat:@"edited: %@", edit] : @"back to its own tags");
    changed(uri);
}

void SGLocalFilesSaveAlbum(NSArray<NSString *> *uris, NSString *album, UIImage *cover) {
    NSString *name = [album stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *picture = cover ? writeCover(cover) : nil;
    if (cover && !picture) return;
    NSMutableDictionary *edits = [allEdits() mutableCopy];
    NSMutableSet<NSString *> *replaced = [NSMutableSet set];
    // One number for the whole album's rename: its tracks' lyrics are looked up again under their new keys.
    NSNumber *number = @((long long)(NSDate.date.timeIntervalSince1970 * 1000));
    for (NSString *uri in uris) {
        if (!SGLocalFileIs(uri)) continue;
        NSDictionary *tags = SGLocalFileTags(uri);
        NSMutableDictionary<NSString *, id> *edit = [edits[uri] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (album) {
            if (name.length && ![name isEqualToString:tags[@"album"]]) edit[@"album"] = name;
            else [edit removeObjectForKey:@"album"];
            if (edit[@"title"] || edit[@"artist"] || edit[@"album"]) edit[@"number"] = number;
            else [edit removeObjectForKey:@"number"];
        }
        if (picture) {
            if (edit[@"cover"]) [replaced addObject:edit[@"cover"]];
            edit[@"cover"] = picture;
        }
        if (edit.count) edits[uri] = edit;
        else [edits removeObjectForKey:uri];
    }
    storeEdits(edits);
    forgetCovers(replaced, edits);
    SGLog(@"local files: %lu files of an album edited%@%@", (unsigned long)uris.count, album ? @", renamed" : @"", picture ? @", a new cover" : @"");
    for (NSString *uri in uris) changed(uri);
}
