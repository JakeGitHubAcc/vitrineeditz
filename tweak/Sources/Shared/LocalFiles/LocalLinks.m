// LocalFiles.h says what a tap on a local file's artist in the player offers.
//
// An artist is found by name with the Web API's search (GET api.spotify.com/v1/search, type artist), asked with
// the signed-in app's own bearer token (SGSpclientHeaders): the artist named exactly, else the first one found.
// What cannot be asked, or finds no one, opens Spotify's search for the name instead.
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Navigation/Links.h"
#import "Shared/Player/PlayerState.h"
#import "LocalAlbums.h"
#import "LocalFiles.h"

static NSTimeInterval const kSearchTimeout = 8;
static BOOL (*sg_albumOpener)(UIViewController *owner, NSString *uri);

void SGLocalFilesSetAlbumOpener(BOOL (*open)(UIViewController *owner, NSString *uri)) {
    sg_albumOpener = open;
}

// Everything but letters and digits escaped, so an "&" or a "+" in a name stays part of it.
static NSString *escaped(NSString *text) {
    return [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet] ?: @"";
}

static void openSearch(NSString *name) {
    SGOpenSpotifyURI([NSURL URLWithString:[@"spotify:search:" stringByAppendingString:escaped(name)]]);
}

// The artist's page, by name.
static void openArtist(NSString *name) {
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        NSString *bearer = headers[@"Authorization"] ?: headers[@"authorization"];
        if (!bearer.length) {
            openSearch(name);
            return;
        }
        NSString *address = [NSString stringWithFormat:@"https://api.spotify.com/v1/search?type=artist&limit=10&q=%@", escaped(name)];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
        request.timeoutInterval = kSearchTimeout;
        [request setValue:bearer forHTTPHeaderField:@"Authorization"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            id answer = status == 200 && data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            id items = [answer isKindOfClass:NSDictionary.class] ? answer[@"artists"][@"items"] : nil;
            NSString *uri = nil;
            for (id item in [items isKindOfClass:NSArray.class] ? items : @[]) {
                if (![item isKindOfClass:NSDictionary.class] || ![item[@"uri"] isKindOfClass:NSString.class]) continue;
                BOOL same = [item[@"name"] isKindOfClass:NSString.class] &&
                            [item[@"name"] caseInsensitiveCompare:name] == NSOrderedSame;
                if (same || !uri) uri = item[@"uri"];
                if (same) break;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (uri && SGOpenSpotifyURI([NSURL URLWithString:uri])) return;
                SGLog(@"local files: no artist page for a local file's artist (search status %ld)", (long)status);
                openSearch(name);
            });
        }] resume];
    });
}

// The names of the artists, as the player shows them ("C, A, B").
static NSArray<NSString *> *artistsOf(NSString *line) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *part in [line componentsSeparatedByString:@","]) {
        NSString *name = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length && ![names containsObject:name]) [names addObject:name];
    }
    return names;
}

void SGLocalFileShowLinks(NSString *uri, UIView *source) {
    NSDictionary *shown = SGLocalFileShown(uri);
    UIViewController *top = SGTopController();
    if (!shown || !top) return;
    NSArray<NSString *> *artists = artistsOf(shown[@"artist"] ?: @"");
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:shown[@"title"] message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *artist in artists) {
        NSString *title = artists.count > 1 ? [NSString stringWithFormat:@"Go to %@", artist] : @"Go to Artist";
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            openArtist(artist);
        }]];
    }
    BOOL (*opener)(UIViewController *, NSString *) = sg_albumOpener;
    // The albums are scanned on first use, so Go to Album shows from the next tap on.
    if (opener && SGLocalAlbums() && SGLocalAlbumOfTrack(uri)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Go to Album" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UIViewController *owner = SGTopController();
            if (owner && !opener(owner, uri)) SGLog(@"local files: no local album for %@", uri);
        }]];
    }
    if (!sheet.actions.count) return;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    [top presentViewController:sheet animated:YES completion:nil];
}
