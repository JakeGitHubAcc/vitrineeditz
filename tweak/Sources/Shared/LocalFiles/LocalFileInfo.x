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
static NSString *const kPlayerArtist = @"now-playing-subtitle-label";
// The close button goes by either name (Redesigned/Player/PlayerHeader.x).
static NSString *const kPlayerClose = @"now-playing-minimize-button", *const kPlayerCloseOld = @"mobile-nowplaying-close-button";
// The album the header names now, nil when none; the header's label; and what Spotify had it say.
static NSString *sg_headerTitle, *sg_headerWord;
static __weak UILabel *sg_headerLabel;
// The most a row the header's label shares with the close button can be, in points, and how many views up from
// the label it is looked for.
static const CGFloat kHeaderRow = 140;
static const NSUInteger kHeaderDepth = 5;

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
    for (NSUInteger i = 0; row && i < kHeaderDepth && row.bounds.size.height <= kHeaderRow; i++, row = row.superview) {
        __block BOOL close = NO;
        SGForEachView(row, ^(UIView *view) {
            NSString *name = view.accessibilityIdentifier;
            if (!close && ([name isEqualToString:kPlayerClose] || [name isEqualToString:kPlayerCloseOld])) close = YES;
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
// The header's label is as wide as Spotify's word ("Queue"), so an album's name in it was cut short ("King…").
// While it names an album it is widened about its middle to fit the name, short of the buttons on either side.
static const CGFloat kHeaderClear = 76;

static CGRect headerBounds(UILabel *label, CGRect bounds) {
    if (label != sg_headerLabel || !sg_headerTitle || !label.window) return bounds;
    CGFloat room = label.window.bounds.size.width - 2 * kHeaderClear;
    CGFloat need = ceil([label sizeThatFits:CGSizeMake(CGFLOAT_MAX, bounds.size.height)].width);
    bounds.size.width = MAX(bounds.size.width, MIN(need, room));
    return bounds;
}

// Widened now, and nothing around it cutting it off.
static void widenHeader(UILabel *label) {
    if (label != sg_headerLabel || !sg_headerTitle) return;
    CGRect wide = headerBounds(label, label.bounds);
    if (wide.size.width <= label.bounds.size.width) return;
    label.bounds = wide;
    UIView *up = label.superview;
    for (NSUInteger i = 0; up && i < 2; i++, up = up.superview) {
        if (up.clipsToBounds && up.bounds.size.width < wide.size.width) up.clipsToBounds = NO;
    }
}

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
// The header's label found from the close button down: in the short row around it, the label nearest the middle.
static void findHeaderFrom(UIView *close) {
    UIView *row = close.superview;
    for (NSUInteger i = 0; row && i < kHeaderDepth && row.bounds.size.height <= kHeaderRow; i++, row = row.superview) {
        __block UILabel *best = nil;
        __block CGFloat nearest = CGFLOAT_MAX;
        CGFloat middle = row.bounds.size.width / 2;
        SGForEachView(row, ^(UIView *view) {
            if (![view isKindOfClass:UILabel.class] || !((UILabel *)view).text.length || view.hidden || view.alpha < 0.01) return;
            CGFloat off = fabs([view convertPoint:CGPointMake(view.bounds.size.width / 2, 0) toView:row].x - middle);
            if (off < nearest) {
                nearest = off;
                best = (UILabel *)view;
            }
        });
        if (best) {
            sg_headerLabel = best;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ SGLog(@"local files: the player's header is %@ \"%@\"", NSStringFromClass(best.class), best.text); });
            return;
        }
    }
}

static void recreditLabels(void) {
    UILabel *header = sg_headerLabel;
    if (header && !sg_headerTitle && sg_headerWord && ![header.text isEqualToString:sg_headerWord]) setAgain(header, sg_headerWord);
    if (!sg_rawTitle && !sg_headerTitle) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            SGForEachView(window, ^(UIView *view) {
                NSString *name = view.accessibilityIdentifier;
                if (sg_headerTitle && !sg_headerLabel.window && ([name isEqualToString:kPlayerClose] || [name isEqualToString:kPlayerCloseOld])) {
                    findHeaderFrom(view);
                }
                if (![view isKindOfClass:UILabel.class]) return;
                UILabel *label = (UILabel *)view;
                if (credited(label, label.text)) setAgain(label, label.text);
            });
        }
    }
    // A header found from the close button after its label was passed in the walk above.
    UILabel *found = sg_headerLabel;
    if (sg_headerTitle && found && ![found.text isEqualToString:sg_headerTitle] && credited(found, found.text)) setAgain(found, found.text);
}

static void artistLinesNow(void);

static void showGlyphsAgain(void);

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
    if (!sg_headerTitle) showGlyphsAgain();
    recreditLabels();
    artistLinesNow();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        recreditLabels();
        artistLinesNow();
    });
}

void SGLocalFilesRecredit(void) {
    creditPlaying(SGURIString(SGPlayerState().track.URI));
}

#pragma mark - the artist line, tapped

// A tap on the player's artist line opens a local file's artists and album (LocalLinks.m), as it opens a Spotify
// track's artist. The recognizer goes on the first view from the line up that takes touches, the one Spotify's
// own tap is on, and begins only while a local file plays, so a Spotify track's tap is left as it was.
static NSString *sg_playingLocal;
static char kArtistTapKey;

@interface SGLocalArtistTap : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SGLocalArtistTap
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    return sg_playingLocal != nil;
}

// Spotify's own recognizers there wait for this one, which fails at once for a Spotify track.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)tapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded && sg_playingLocal) SGLocalFileShowLinks(sg_playingLocal, recognizer.view);
}
@end

// The glyph before the artist that says the track plays from the queue goes while a local album played from its
// page plays (the header names the album then), and the artist moves into its place. It is the small view that
// ends before the artist line in the row they share, the line or the view wrapping it; Spotify's own are put
// back once the album is over.
static NSHashTable<UIView *> *sg_hiddenGlyphs;
static NSHashTable<UIView *> *sg_movedLines;
static const CGFloat kGlyphLargest = 32;

static void showGlyphsAgain(void) {
    for (UIView *glyph in sg_hiddenGlyphs.allObjects) glyph.alpha = 1;
    for (UIView *line in sg_movedLines.allObjects) line.transform = CGAffineTransformIdentity;
    [sg_hiddenGlyphs removeAllObjects];
    [sg_movedLines removeAllObjects];
}

static void hideQueueGlyph(UIView *line) {
    if (!sg_headerTitle) return;
    if (!sg_hiddenGlyphs) {
        sg_hiddenGlyphs = [NSHashTable weakObjectsHashTable];
        sg_movedLines = [NSHashTable weakObjectsHashTable];
    }
    UIView *level = line;
    for (NSUInteger i = 0; level.superview && i < 2; i++, level = level.superview) {
        // Where the line starts, from its center, which a transform does not move.
        CGFloat start = level.center.x - level.bounds.size.width / 2;
        UIView *glyph = nil;
        for (UIView *sub in level.superview.subviews) {
            if (sub == level || [sg_movedLines containsObject:sub]) continue;
            CGSize size = sub.bounds.size;
            CGFloat end = sub.center.x + size.width / 2;
            if (end <= start + 1 && size.width > 2 && size.width <= kGlyphLargest && size.height <= kGlyphLargest) glyph = sub;
        }
        if (!glyph) continue;
        if (glyph.alpha != 0) glyph.alpha = 0;
        [sg_hiddenGlyphs addObject:glyph];
        CGAffineTransform move = CGAffineTransformMakeTranslation((glyph.center.x - glyph.bounds.size.width / 2) - start, 0);
        if (!CGAffineTransformEqualToTransform(level.transform, move)) level.transform = move;
        [sg_movedLines addObject:level];
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"local files: the queue glyph %@ before the player's artist hidden", NSStringFromClass(glyph.class)); });
        return;
    }
}

static void watchArtistTap(UIView *label) {
    static SGLocalArtistTap *tap;
    if (!tap) tap = [SGLocalArtistTap new];
    UIView *line = label;
    for (NSUInteger i = 0; line && i < 4 && ![line.accessibilityIdentifier isEqualToString:kPlayerArtist]; i++) line = line.superview;
    if (![line.accessibilityIdentifier isEqualToString:kPlayerArtist]) return;
    hideQueueGlyph(line);
    UIView *host = line;
    while (host && !host.userInteractionEnabled) host = host.superview;
    if (!host || objc_getAssociatedObject(host, &kArtistTapKey)) return;
    UITapGestureRecognizer *recognizer = [[UITapGestureRecognizer alloc] initWithTarget:tap action:@selector(tapped:)];
    recognizer.delegate = tap;
    [host addGestureRecognizer:recognizer];
    objc_setAssociatedObject(host, &kArtistTapKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// What plays now, and the artist line of a player already on screen, which sets no label until the track changes.
static void artistLinesNow(void) {
    NSString *uri = SGURIString(SGPlayerState().track.URI);
    sg_playingLocal = SGLocalFileIs(uri) ? uri : nil;
    if (!sg_playingLocal) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            SGForEachView(window, ^(UIView *view) {
                if ([view.accessibilityIdentifier isEqualToString:kPlayerArtist]) watchArtistTap(view);
            });
        }
    }
}

// Every label the player sets while a local file plays is looked at, a few views up, for the artist line.
static void artistLineSet(UILabel *label) {
    if (!sg_playingLocal || !NSThread.isMainThread || !inPlayerArtist(label)) return;
    watchArtistTap(label);
    // A player just opened sets its artist line; its header, set before it was in a window, is found once it is.
    static BOOL asked;
    if (sg_headerTitle && !sg_headerLabel.window && !asked) {
        asked = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            asked = NO;
            recreditLabels();
        });
    }
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
    artistLineSet(self);
    %orig(credited(self, text) ?: text);
    widenHeader(self);
}

- (void)setAttributedText:(NSAttributedString *)text {
    artistLineSet(self);
    NSString *swap = credited(self, text.string);
    if (!swap) {
        %orig;
        return;
    }
    // The new words in the attributes the old ones had.
    NSMutableAttributedString *changed = [text mutableCopy];
    [changed replaceCharactersInRange:NSMakeRange(0, changed.length) withString:swap];
    %orig(changed);
    widenHeader(self);
}

// Auto Layout sizes a view through its bounds: the header's label keeps the width the album's name needs.
- (void)setBounds:(CGRect)bounds {
    %orig(sg_headerTitle && self == sg_headerLabel ? headerBounds(self, bounds) : bounds);
}

// And a frame set by hand grows the same about its middle.
- (void)setFrame:(CGRect)frame {
    if (sg_headerTitle && self == sg_headerLabel) {
        CGRect wide = headerBounds(self, (CGRect){CGPointZero, frame.size});
        frame = CGRectInset(frame, -(wide.size.width - frame.size.width) / 2, 0);
    }
    %orig(frame);
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
