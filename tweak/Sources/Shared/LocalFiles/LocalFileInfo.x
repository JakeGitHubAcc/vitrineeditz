// A local file's edit laid over what Spotify read from it (LocalFiles.h).
//
// -[SPTPlayerTrack metadata] is the one place: trackTitle, artistName, albumTitle and imageURL each read
// self.metadata and take title, artist_name, album_title and image_url from it (their code in the
// binary, through NSDictionary's spt_metadata_* in IDZKAdditions), and the player, the now playing bar
// and the system's now playing info are built from the player's track. So the names go in there, and
// the cover as an image address of the kind Spotify gives a local file, spotify:localfileimage:<path>.
//
// Spotify's loader hands such an address (three parts, no ipod-library in it) to
// SPTLocalAVAssetImageLoaderRequest, whose -loadLocalFileImage reads the cover out of the file at the
// path with AVAsset and passes its bytes to -dispatchSuccess:, which gives them to the delegate's
// imageLoaderRequest:didLoadImageData:. The request caches nothing (preventInMemoryCaching and
// preventPersistentCaching answer YES), so a stored cover is read from disk each time and passed on
// the same way. The system's now playing artwork is added too, in case Spotify fetches it apart.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Headers/SPTLocalAVAssetImageLoaderRequest.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"
#import "LocalAlbums.h"
#import "LocalFiles.h"

// Called for every track in every list many times a second: one prefix check for any other track.
// The names are SGLocalFileShown's, so the guests a title names are credited as artists, edited or not.
static NSDictionary *withEdit(NSDictionary *metadata, NSString *uri) {
    NSDictionary *edit = SGLocalFileEditFor(uri), *shown = SGLocalFileShown(uri);
    if (!edit && ![shown[@"credited"] boolValue]) return metadata;
    NSMutableDictionary *edited = metadata ? [metadata mutableCopy] : [NSMutableDictionary dictionary];
    if ([shown[@"title"] length]) edited[@"title"] = shown[@"title"];
    if ([shown[@"artist"] length]) edited[@"artist_name"] = shown[@"artist"];
    if ([edit[@"album"] length]) edited[@"album_title"] = edit[@"album"];
    NSString *cover = SGLocalFileCoverURL(SGLocalFileCoverPath(edit));
    // Every size, since a reader may take any of them: Spotify's loader, and the redesign's artwork bridge
    // (Redesigned/Kit/SGRBridges.x), which reads the stored file itself.
    if (cover) {
        for (NSString *field in @[@"image_small_url", @"image_url", @"image_large_url", @"image_xlarge_url"]) edited[field] = cover;
    }
    return edited;
}

#pragma mark - the full player's title and artist

// The full player names the track from a model of its own rather than from -metadata (device, 9.1.94: the bar
// showed "Song" by "C, A", the player "Song (feat. A)" by "C"). So while a local file whose title names guests
// plays, the labels showing its own title, and the player's artist label showing its own artist, are given the
// credited names as they are set.
//
// And a local album played from its page plays from the queue (LocalAlbums.h), so the player's header says
// Queue; while one of its tracks plays, the header names the album instead. The header's label is the one in the
// row with the player's close button. Main thread only: UILabel is set there.
static NSString *sg_rawTitle, *sg_shownTitle, *sg_rawArtist, *sg_shownArtist;
static NSString *const kPlayerArtist = @"now-playing-subtitle-label", *const kPlayerClose = @"now-playing-minimize-button";
// The album the header names now, nil when none; the header's label; and what Spotify had it say.
static NSString *sg_headerTitle, *sg_headerWord;
static __weak UILabel *sg_headerLabel;
// The most a row the header's label shares with the close button can be, in points.
static const CGFloat kHeaderRow = 90;

static BOOL inPlayerArtist(UIView *label) {
    UIView *v = label;
    for (NSUInteger i = 0; v && i < 4; i++, v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:kPlayerArtist]) return YES;
    }
    return NO;
}

// Whether `label` is the player's header: in a short row that also holds the close button.
static BOOL inPlayerHeader(UILabel *label) {
    if (label == sg_headerLabel) return YES;
    UIView *row = label.superview;
    for (NSUInteger i = 0; row && i < 3 && row.bounds.size.height <= kHeaderRow; i++, row = row.superview) {
        __block BOOL close = NO;
        SGForEachView(row, ^(UIView *view) {
            if (!close && [view.accessibilityIdentifier isEqualToString:kPlayerClose]) close = YES;
        });
        if (close) {
            sg_headerLabel = label;
            return YES;
        }
    }
    return NO;
}

static NSString *credited(UILabel *label, NSString *text) {
    if ((!sg_rawTitle && !sg_headerTitle) || !text.length || !NSThread.isMainThread) return nil;
    if (sg_rawTitle && [text isEqualToString:sg_rawTitle]) return sg_shownTitle;
    if (sg_rawArtist && [text isEqualToString:sg_rawArtist] && inPlayerArtist(label)) return sg_shownArtist;
    // Once the header's word is known only it is looked at; before, any short line might be the header.
    if (sg_headerTitle && ![text isEqualToString:sg_headerTitle] && (sg_headerWord ? [text isEqualToString:sg_headerWord] : text.length <= 40)
        && inPlayerHeader(label)) {
        sg_headerWord = text;
        return sg_headerTitle;
    }
    return nil;
}

// Set again as it is: the setters swap the words and keep the label's attributes.
static void setAgain(UILabel *label, NSString *text) {
    if (label.attributedText.length) {
        NSMutableAttributedString *again = [label.attributedText mutableCopy];
        [again replaceCharactersInRange:NSMakeRange(0, again.length) withString:text];
        label.attributedText = again;
    } else {
        label.text = text;
    }
}

// Labels set before the player's state said the track changed are put right once it has, and a header that named
// an album no longer playing says again what Spotify had it say.
static void recreditLabels(void) {
    UILabel *header = sg_headerLabel;
    if (header && !sg_headerTitle && sg_headerWord && ![header.text isEqualToString:sg_headerWord]) setAgain(header, sg_headerWord);
    if (!sg_rawTitle && !sg_headerTitle) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            SGForEachView(window, ^(UIView *view) {
                if (![view isKindOfClass:UILabel.class]) return;
                UILabel *label = (UILabel *)view;
                if (credited(label, label.text)) setAgain(label, label.text);
            });
        }
    }
}

static void creditPlaying(NSString *uri) {
    NSString *album = SGLocalAlbumPlayingTitle();
    if (!album && sg_headerTitle) {
        // The header said the album's title; it goes back to Spotify's word below.
        UILabel *header = sg_headerLabel;
        if (header && sg_headerWord && [header.text isEqualToString:sg_headerTitle]) {
            sg_headerTitle = nil;
            setAgain(header, sg_headerWord);
        }
    }
    sg_headerTitle = album;
    NSDictionary *shown = SGLocalFileShown(uri);
    if ([shown[@"credited"] boolValue]) {
        NSDictionary *info = SGLocalFileInfo(uri);
        sg_rawTitle = info[@"title"];
        sg_shownTitle = shown[@"title"];
        sg_rawArtist = info[@"artist"];
        sg_shownArtist = shown[@"artist"];
    } else {
        sg_rawTitle = sg_shownTitle = sg_rawArtist = sg_shownArtist = nil;
    }
    recreditLabels();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ recreditLabels(); });
}

void SGLocalFilesRecredit(void) {
    creditPlaying(SGURIString(SGPlayerState().track.URI));
}

#pragma mark - the system's now playing artwork

@interface SGLocalFileNowPlaying : NSObject <SGPlayerStateObserver>
@end

@implementation SGLocalFileNowPlaying {
    NSString *_track;
}

// Spotify's info is matched by its title, which is the edited one when Spotify built it from the
// player's track and the file's own when it did not, so the artwork rides on either.
- (void)show:(SPTPlayerState *)state {
    NSString *uri = SGURIString(state.track.URI);
    NSString *path = SGLocalFileCoverPath(SGLocalFileEditFor(uri));
    UIImage *cover = path ? [UIImage imageWithContentsOfFile:path] : nil;
    if (!cover) {
        SGNowPlayingSetExtras(@"localFiles", nil, nil);
        SGNowPlayingSetExtras(@"localFiles.tags", nil, nil);
        return;
    }
    MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:cover.size requestHandler:^UIImage *(CGSize size) {
        return cover;
    }];
    SGNowPlayingSetExtras(@"localFiles", @{MPMediaItemPropertyArtwork: artwork}, SGLocalFileShown(uri)[@"title"]);
    SGNowPlayingSetExtras(@"localFiles.tags", @{MPMediaItemPropertyArtwork: artwork}, SGLocalFileTags(uri)[@"title"]);
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *track = SGURIString(state.track.URI);
    if (!track || [track isEqualToString:_track]) return;
    _track = track;
    [self show:state];
    creditPlaying(track);
}

- (void)editsChanged:(NSNotification *)note {
    if ([note.object isEqual:_track]) [self show:SGPlayerState()];
    creditPlaying(_track);
}

@end

#pragma mark - hooks

%hook SPTPlayerTrack
- (NSDictionary *)metadata {
    NSDictionary *metadata = %orig;
    NSString *uri = SGURIString(self.URI);
    return SGLocalFileIs(uri) ? withEdit(metadata, uri) : metadata;
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    %orig(credited(self, text) ?: text);
}

- (void)setAttributedText:(NSAttributedString *)text {
    NSString *swap = credited(self, text.string);
    if (!swap) {
        %orig;
        return;
    }
    // The new words in the attributes the old ones had.
    NSMutableAttributedString *changed = [text mutableCopy];
    [changed replaceCharactersInRange:NSMakeRange(0, changed.length) withString:swap];
    %orig(changed);
}
%end

%hook SPTLocalAVAssetImageLoaderRequest
- (void)loadLocalFileImage {
    NSString *path = SGLocalFileCoverInURL(self.URL.absoluteString);
    if (!path) {
        %orig;
        return;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        SGLog(@"local files: the cover %@ is gone, the track shows none", path.lastPathComponent);
        %orig;
        return;
    }
    [self dispatchSuccess:data];
}
%end

%ctor {
    %init;
    static SGLocalFileNowPlaying *nowPlaying;
    nowPlaying = [SGLocalFileNowPlaying new];
    SGAddPlayerStateObserver(nowPlaying);
    [NSNotificationCenter.defaultCenter addObserver:nowPlaying selector:@selector(editsChanged:) name:SGLocalFileEditsDidChangeNotification object:nil];
    SGRequireClasses(@[@"SPTPlayerTrack", @"SPTLocalAVAssetImageLoaderRequest"]);
}
