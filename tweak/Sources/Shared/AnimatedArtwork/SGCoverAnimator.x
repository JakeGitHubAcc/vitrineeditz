// SGCoverAnimator.h says what this is. Vitrine Animate answers four requests: POST /animate?key=&album=
// &artist= with the cover as PNG, GET /status?key= ({"state": queued, running, done, failed or unknown, "progress",
// "position", "error"}), GET /clip?key= for the MP4, and GET /health. A sent cover is asked about every
// few seconds while Spotify runs, which it keeps doing in the background while music plays; the cover is
// kept until its loop is saved, so a computer restarted halfway is sent it again.
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "SGCoverAnimator.h"

NSNotificationName const SGAnimatedCoverSavedNotification = @"SGAnimatedCoverSavedNotification";

static const NSTimeInterval kPollSeconds = 8;

static NSMutableDictionary<NSString *, NSString *> *sg_status;   // by key, what the rows read out
static NSMutableSet<NSString *> *sg_asking;   // keys with a request on the way, so a slow one is not doubled
static NSTimer *sg_timer;

// Application Support/Vitrine/AnimatedCovers, or the folder `sub` inside it.
static NSURL *folder(NSString *sub) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *url = [support URLByAppendingPathComponent:@"Vitrine/AnimatedCovers" isDirectory:YES];
    if (sub.length) url = [url URLByAppendingPathComponent:sub isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
    return url;
}

// {artist\nalbum, folded: key}, kept beside the loops so it goes with them.
static NSURL *listFile(void) { return [folder(nil) URLByAppendingPathComponent:@"albums.plist"]; }

static NSString *albumName(NSString *artist, NSString *album) {
    if (!artist.length || !album.length) return nil;
    NSString *joined = [NSString stringWithFormat:@"%@\n%@", artist, album];
    joined = [joined stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
    return [joined stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static NSURL *savedFor(NSString *key) { return [folder(nil) URLByAppendingPathComponent:[key stringByAppendingPathExtension:@"mp4"]]; }
static NSURL *frameFor(NSString *key) { return [folder(@"sent") URLByAppendingPathComponent:[key stringByAppendingPathExtension:@"png"]]; }
// The album's name and artist, and the text and sway settings, sent with the cover, kept beside it as a
// plist so a cover sent again has them.
static NSURL *namesFor(NSString *key) { return [folder(@"sent") URLByAppendingPathComponent:[key stringByAppendingPathExtension:@"plist"]]; }

NSString *SGAnimatedCoverPicture(NSString *uri, NSDictionary *metadata) {
    // A local file's picture is its own file, so each song of a local album had a cover of its own: they share
    // their album's instead, by its artist (the file's own, before a title's guests) and name.
    if (SGLocalFileIs(uri)) {
        NSDictionary *info = SGLocalFileInfo(uri);
        NSString *album = SGAnimatedCoverAlbumPicture(info[@"artist"], info[@"album"]);
        if (album) return album;
    }
    for (NSString *field in @[@"image_xlarge_url", @"image_large_url", @"image_url"]) {
        id value = [metadata isKindOfClass:NSDictionary.class] ? metadata[field] : nil;
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return uri;
}

NSString *SGAnimatedCoverKey(NSString *picture) {
    NSData *data = [picture dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *key = [NSMutableString string];
    for (int i = 0; i < 16; i++) [key appendFormat:@"%02x", digest[i]];
    return key;
}

NSURL *SGAnimatedCoverFile(NSString *picture) {
    if (!picture.length) return nil;
    NSURL *file = savedFor(SGAnimatedCoverKey(picture));
    return [NSFileManager.defaultManager fileExistsAtPath:file.path] ? file : nil;
}

NSString *SGAnimatedCoverAlbumPicture(NSString *artist, NSString *album) {
    NSString *name = albumName(artist, album);
    return name ? [@"spotify-album:" stringByAppendingString:name] : nil;
}

static void listKey(NSString *name, NSString *key) {
    NSMutableDictionary *list = [NSMutableDictionary dictionaryWithContentsOfURL:listFile()] ?: [NSMutableDictionary dictionary];
    if ([list[name] isEqual:key]) return;
    list[name] = key;
    [list writeToURL:listFile() error:nil];
}

void SGAnimatedCoverList(NSString *picture, NSString *artist, NSString *album) {
    NSString *name = albumName(artist, album);
    if (!name || !picture.length) return;
    NSString *key = SGAnimatedCoverKey(picture);
    NSMutableDictionary *list = [NSMutableDictionary dictionaryWithContentsOfURL:listFile()] ?: [NSMutableDictionary dictionary];
    if ([list[name] isEqual:key]) return;
    list[name] = key;
    [list writeToURL:listFile() error:nil];
}

NSURL *SGAnimatedCoverFileForAlbum(NSString *artist, NSString *album) {
    NSString *name = albumName(artist, album);
    if (!name) return nil;
    NSURL *own = SGAnimatedCoverFile(SGAnimatedCoverAlbumPicture(artist, album));
    if (own) return own;
    NSString *key = [NSDictionary dictionaryWithContentsOfURL:listFile()][name];
    if (![key isKindOfClass:NSString.class]) return nil;
    NSURL *file = savedFor(key);
    return [NSFileManager.defaultManager fileExistsAtPath:file.path] ? file : nil;
}

NSString *SGAnimatedCoverServer(void) {
    NSString *server = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyAnimateServer];
    return server.length ? server : nil;
}

static NSDictionary<NSString *, NSString *> *pending(void) {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyAnimatePending];
    return [stored isKindOfClass:NSDictionary.class] ? stored : @{};
}

static void setPending(NSString *key, NSString *album) {
    NSMutableDictionary *all = [pending() mutableCopy];
    all[key] = album;
    [NSUserDefaults.standardUserDefaults setObject:all forKey:SGKeyAnimatePending];
}

static NSURL *endpoint(NSString *path, NSString *key, NSDictionary<NSString *, NSString *> *names) {
    NSString *server = SGAnimatedCoverServer();
    if (!server) return nil;
    NSString *base = [server containsString:@"://"] ? server : [@"http://" stringByAppendingString:server];
    NSURLComponents *url = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"%@/%@", base, path]];
    NSMutableArray *query = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"key" value:key]];
    for (NSString *name in @[@"album", @"artist", @"text", @"sway"]) {
        if ([names[name] isKindOfClass:NSString.class] && names[name].length) [query addObject:[NSURLQueryItem queryItemWithName:name value:names[name]]];
    }
    url.queryItems = query;
    return url.URL;
}

static void poll(void);

// The timer runs while any cover is pending, and stops once none is.
static void follow(void) {
    if (sg_timer || !pending().count) return;
    sg_timer = [NSTimer scheduledTimerWithTimeInterval:kPollSeconds repeats:YES block:^(NSTimer *timer) { poll(); }];
    poll();
}

static void unfollow(NSString *key) {
    NSMutableDictionary *all = [pending() mutableCopy];
    [all removeObjectForKey:key];
    [NSUserDefaults.standardUserDefaults setObject:all forKey:SGKeyAnimatePending];
    [NSFileManager.defaultManager removeItemAtURL:frameFor(key) error:nil];
    [NSFileManager.defaultManager removeItemAtURL:namesFor(key) error:nil];
    if (!all.count) {
        [sg_timer invalidate];
        sg_timer = nil;
    }
}

// The JSON object the computer answered, or nil.
static NSDictionary *answerIn(NSData *data, NSURLResponse *response, NSError *error) {
    if (error || ![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode != 200 || !data) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static void send(NSString *key, NSData *png, void (^done)(NSString *error)) {
    NSURL *url = endpoint(@"animate", key, [NSDictionary dictionaryWithContentsOfURL:namesFor(key)]);
    if (!url) {
        if (done) done(@"No computer address is entered.");
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    request.HTTPMethod = @"POST";
    [request setValue:@"image/png" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = png;
    [sg_asking addObject:key];
    sg_status[key] = @"Sending…";
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *answer = answerIn(data, response, error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [sg_asking removeObject:key];
            if (!answer) {
                sg_status[key] = @"Computer not reachable";
                SGLog(@"animate: %@ not sent (%@)", key, error.localizedDescription ?: @"no answer");
                if (done) done([NSString stringWithFormat:@"Vitrine Animate did not answer at %@. Check that it is running on "
                                                          @"your computer and that both are on the same Wi-Fi.", SGAnimatedCoverServer()]);
                return;
            }
            SGLog(@"animate: %@ sent, %@", key, answer[@"state"]);
            sg_status[key] = @"Waiting";
            if (done) done(nil);
        });
    }] resume];
}

// Moves the finished loop into the kept folder, which the downloads' trimming never touches.
static void fetch(NSString *key) {
    NSURL *url = endpoint(@"clip", key, nil);
    if (!url || [sg_asking containsObject:key]) return;
    [sg_asking addObject:key];
    sg_status[key] = @"Downloading…";
    [[NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *temporary, NSURLResponse *response, NSError *error) {
        BOOL ok = !error && temporary && [response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse *)response).statusCode == 200;
        NSURL *saved = savedFor(key);
        if (ok) {
            [NSFileManager.defaultManager removeItemAtURL:saved error:nil];
            ok = [NSFileManager.defaultManager moveItemAtURL:temporary toURL:saved error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [sg_asking removeObject:key];
            if (!ok) {
                sg_status[key] = @"Computer not reachable";
                return;
            }
            SGLog(@"animate: %@ saved", key);
            [sg_status removeObjectForKey:key];
            unfollow(key);
            [NSNotificationCenter.defaultCenter postNotificationName:SGAnimatedCoverSavedNotification object:key];
        });
    }] resume];
}

static void ask(NSString *key) {
    NSURL *url = endpoint(@"status", key, nil);
    if (!url || [sg_asking containsObject:key]) return;
    [sg_asking addObject:key];
    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *answer = answerIn(data, response, error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [sg_asking removeObject:key];
            if (!pending()[key]) return;
            NSString *state = [answer[@"state"] isKindOfClass:NSString.class] ? answer[@"state"] : nil;
            if (!state) {
                sg_status[key] = @"Computer not reachable";
            } else if ([state isEqual:@"done"]) {
                fetch(key);
            } else if ([state isEqual:@"running"]) {
                double progress = [answer[@"progress"] isKindOfClass:NSNumber.class] ? [answer[@"progress"] doubleValue] : 0;
                sg_status[key] = [NSString stringWithFormat:@"Animating %.0f%%", MIN(MAX(progress, 0), 0.99) * 100];
            } else if ([state isEqual:@"queued"]) {
                NSInteger ahead = [answer[@"position"] isKindOfClass:NSNumber.class] ? [answer[@"position"] integerValue] : 0;
                sg_status[key] = ahead > 0 ? [NSString stringWithFormat:@"Waiting, %ld ahead", (long)ahead] : @"Waiting";
            } else if ([state isEqual:@"failed"]) {
                sg_status[key] = @"Failed";
                SGLog(@"animate: %@ failed on the computer: %@", key, answer[@"error"]);
                unfollow(key);
            } else {
                // The computer restarted and lost it: the kept frame goes again.
                NSData *png = [NSData dataWithContentsOfURL:frameFor(key)];
                if (png) send(key, png, nil);
                else unfollow(key);
            }
        });
    }] resume];
}

static void poll(void) {
    for (NSString *key in pending()) ask(key);
}

void SGAnimatedCoverRequest(NSString *picture, NSString *album, NSString *artist, NSData *png, void (^done)(NSString *error)) {
    if (!picture.length || !png.length) {
        if (done) done(@"The album's cover is not loaded yet. Try again in a moment.");
        return;
    }
    NSString *key = SGAnimatedCoverKey(picture);
    [png writeToURL:frameFor(key) atomically:YES];
    SGAnimatedCoverList(picture, artist, album);
    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    if (album.length) names[@"album"] = album;
    if (artist.length) names[@"artist"] = artist;
    names[@"text"] = @[@"keep", @"fade", @"hide"][(NSUInteger)MIN(MAX(SGInt(SGKeyAnimateText, SGAnimateTextKeep), 0), 2)];
    names[@"sway"] = SGHidden(SGKeyAnimateSway) ? @"1" : @"0";   // an option row: off until switched on
    [names writeToURL:namesFor(key) error:nil];
    setPending(key, album ?: @"");
    send(key, png, ^(NSString *error) {
        if (!error) follow();
        if (done) done(error);
    });
}

void SGAnimatedCoverForget(NSString *picture) {
    if (!picture.length) return;
    NSString *key = SGAnimatedCoverKey(picture);
    unfollow(key);
    [sg_status removeObjectForKey:key];
    [NSFileManager.defaultManager removeItemAtURL:savedFor(key) error:nil];
}

NSString *SGAnimatedCoverStatus(NSString *picture) {
    if (!picture.length) return nil;
    NSString *key = SGAnimatedCoverKey(picture);
    if (SGAnimatedCoverFile(picture)) return @"Saved";
    return sg_status[key] ?: (pending()[key] ? @"Waiting" : nil);
}

BOOL SGAnimatedCoverPending(NSString *picture) {
    return picture.length && pending()[SGAnimatedCoverKey(picture)] != nil;
}

NSUInteger SGAnimatedCoverCount(void) {
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder(nil).path error:nil];
    return [files filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.mp4'"]].count;
}

#pragma mark - restoring from the computer

// The computer keeps every loop it made (GET /clips), and Spotify deleted and installed again keeps none: each one
// this iPhone lacks is downloaded, one at a time, into the kept folder, and listed under its album where the
// computer kept its names. A loop is kept under the same key it was made under, so a song finds it as it did.
static BOOL sg_restoring;

static void restoreNext(NSArray<NSDictionary *> *clips, NSUInteger index, NSUInteger added,
                        void (^done)(NSUInteger added, NSString *error)) {
    if (index >= clips.count) {
        sg_restoring = NO;
        if (added) SGLog(@"animate: %lu animated covers restored from the computer", (unsigned long)added);
        if (added) [NSNotificationCenter.defaultCenter postNotificationName:SGAnimatedCoverSavedNotification object:nil];
        if (done) done(added, nil);
        return;
    }
    NSDictionary *clip = clips[index];
    NSString *key = clip[@"key"];
    NSString *name = albumName(clip[@"artist"], clip[@"album"]);
    if (name) listKey(name, key);
    if ([NSFileManager.defaultManager fileExistsAtPath:savedFor(key).path]) {
        restoreNext(clips, index + 1, added, done);
        return;
    }
    [[NSURLSession.sharedSession downloadTaskWithURL:endpoint(@"clip", key, nil) completionHandler:^(NSURL *temporary, NSURLResponse *response, NSError *error) {
        BOOL ok = !error && temporary && [response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse *)response).statusCode == 200;
        if (ok) ok = [NSFileManager.defaultManager moveItemAtURL:temporary toURL:savedFor(key) error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ restoreNext(clips, index + 1, added + (ok ? 1 : 0), done); });
    }] resume];
}

void SGAnimatedCoverRestore(void (^done)(NSUInteger added, NSString *error)) {
    NSURL *base = endpoint(@"clips", @"", nil);
    if (!base || sg_restoring) {
        if (done) done(0, base ? @"Already copying covers from your computer." : @"No computer address is entered.");
        return;
    }
    sg_restoring = YES;
    NSURLComponents *url = [NSURLComponents componentsWithURL:base resolvingAgainstBaseURL:NO];
    url.queryItems = nil;
    NSURLRequest *request = [NSURLRequest requestWithURL:url.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *answer = answerIn(data, response, error);
        NSMutableArray<NSDictionary *> *clips = [NSMutableArray array];
        id listed = answer[@"clips"];
        for (id clip in [listed isKindOfClass:NSArray.class] ? listed : @[]) {
            if (![clip isKindOfClass:NSDictionary.class] || ![clip[@"key"] isKindOfClass:NSString.class]) continue;
            NSString *key = clip[@"key"];
            if (key.length != 32 || [key rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location != NSNotFound) continue;
            NSMutableDictionary *kept = [NSMutableDictionary dictionaryWithObject:key forKey:@"key"];
            for (NSString *field in @[@"album", @"artist"]) {
                if ([clip[field] isKindOfClass:NSString.class]) kept[field] = clip[field];
            }
            [clips addObject:kept];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!answer) {
                sg_restoring = NO;
                if (done) done(0, [NSString stringWithFormat:@"Vitrine Animate did not answer at %@. Check that it is running on "
                                                             @"your computer and that both are on the same Wi-Fi.", SGAnimatedCoverServer()]);
                return;
            }
            restoreNext(clips, 0, 0, done);
        });
    }] resume];
}

void SGAnimatedCoverAskServer(void (^then)(void)) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Your computer"
        message:@"The address Vitrine Animate shows when it starts on your computer, such as 192.168.1.20:8790."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = SGAnimatedCoverServer();
        field.placeholder = @"192.168.1.20:8790";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *server = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        while ([server hasSuffix:@"/"]) server = [server substringToIndex:server.length - 1];
        if (!server.length) return;
        [NSUserDefaults.standardUserDefaults setObject:server forKey:SGKeyAnimateServer];
        poll();
        // The covers the computer made before, which a reinstalled Spotify no longer has.
        SGAnimatedCoverRestore(nil);
        if (then) then();
    }]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

%ctor {
    sg_status = [NSMutableDictionary dictionary];
    sg_asking = [NSMutableSet set];
    // Covers sent before a relaunch are followed again once the app has settled, and any the computer kept that
    // this iPhone lacks are copied over, quietly: a computer out of reach just leaves them for the next launch.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        follow();
        if (SGAnimatedCoverServer()) SGAnimatedCoverRestore(nil);
    });
}
