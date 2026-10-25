// SGMotionFollower (AnimatedArtwork.h): one track's walk of the sources at a time, for the lock screen
// (LockScreenMotion.x) and the redesign's player (Redesigned/Player/PlayerMotion.x) alike. A track none of
// the sources has a clip for gets its album's cover animated on the user's computer, where one is saved
// (SGCoverAnimator.h), and is walked again when one is saved for it.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Shared/Player/PlayerState.h"
#import "AnimatedArtwork.h"
#import "SGCoverAnimator.h"
#import "SGMotionClip.h"

@interface SGMotionFollower () <SGPlayerStateObserver>
@end

@implementation SGMotionFollower {
    BOOL (^_begin)(NSString *, SPTPlayerState *);
    void (^_found)(NSString *, NSURL *);
    NSString *_track;    // the URI walked last
    BOOL _walked;        // whether `begin` let it be walked
    NSURL *_canvas;      // the Canvas its metadata named as the walk began, nil for none
    NSString *_source;   // where the clip found came from, nil for none or not found yet
    NSUInteger _walk;    // counts the walks, so an overtaken one is told from the newest
    NSString *_ahead;    // the next track whose clip was fetched ahead
    NSString *_picture;  // the picture the track walked last names, whose animated cover stands in
}

- (instancetype)initWithBegin:(BOOL (^)(NSString *, SPTPlayerState *))begin found:(void (^)(NSString *, NSURL *))found {
    if (!(self = [super init])) return nil;
    _begin = [begin copy];
    _found = [found copy];
    SGAddPlayerStateObserver(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(animatedCoverSaved:)
                                               name:SGAnimatedCoverSavedNotification object:nil];
    return self;
}

- (void)animatedCoverSaved:(NSNotification *)note {
    if (!_picture) return;
    SGLog(@"motion: the animated cover of %@ was saved, walked again", _track);
    [self restart];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *uri = SGURIString(state.track.URI);
    if (!uri) return;
    NSURL *canvas = SGMotionCanvasIn(state.track.metadata);
    if ([uri isEqualToString:_track]) {
        if (!_walked || _canvas || !canvas || !SGMotionCanvasOutranks(SGMotionSourceOrder(), _source)) return;
        SGLog(@"motion: the Canvas of %@ came after the track, asked again", uri);
    }
    [self walk:state uri:uri canvas:canvas];
}

- (void)walk:(SPTPlayerState *)state uri:(NSString *)uri canvas:(NSURL *)canvas {
    _track = uri;
    _canvas = canvas;
    _source = nil;
    NSUInteger walk = ++_walk;
    _walked = _begin(uri, state);
    if (!_walked) {
        if (SGLocalFileIs(uri)) SGLog(@"motion: a local file not walked, its screen wants no clip now");
        return;
    }
    NSDictionary *metadata = [state.track.metadata isKindOfClass:NSDictionary.class] ? state.track.metadata : nil;
    NSString *picture = SGAnimatedCoverPicture(uri, metadata);
    _picture = picture;
    NSString *album = [metadata[@"album_title"] isKindOfClass:NSString.class] ? metadata[@"album_title"] : nil;
    NSString *artist = [metadata[@"album_artist_name"] isKindOfClass:NSString.class] ? metadata[@"album_artist_name"]
                     : [metadata[@"artist_name"] isKindOfClass:NSString.class] ? metadata[@"artist_name"] : state.track.artistName;
    __weak SGMotionFollower *weakSelf = self;
    // A local file has no Canvas or Apple Music cover to ask for (the ask for its Canvas never answered, and the
    // cover made for it never showed): only the one the user's computer made, found by its album, the file's own
    // artist and album rather than the credited names the player shows.
    if (SGLocalFileIs(uri)) {
        NSDictionary *info = SGLocalFileInfo(uri);
        NSURL *file = SGAnimatedCoverFile(picture) ?: SGAnimatedCoverFileForAlbum(info[@"artist"], info[@"album"]);
        SGLog(@"motion: a local file of \"%@\" by \"%@\", its album's cover %@", info[@"album"], info[@"artist"],
              file ? file.lastPathComponent : @"not saved");
        dispatch_async(dispatch_get_main_queue(), ^{
            SGMotionFollower *follower = weakSelf;
            if (follower && walk == follower->_walk) follower->_found(uri, file);
        });
        return;
    }
    SGMotionClipFor(uri, canvas, state.track.artistName, metadata[@"album_title"], SGMotionTall, SGMotionPixels(), ^(NSURL *file, NSString *source) {
        SGMotionFollower *follower = weakSelf;
        if (!follower || walk != follower->_walk) return;
        follower->_source = source;
        // The source stays none, so a Canvas that comes late still takes over from the animated cover. One made
        // from the album's page is found by the album's name; one made from a song is listed under it.
        if (!file) {
            file = SGAnimatedCoverFile(picture);
            if (file) SGAnimatedCoverList(picture, artist, album);
            else file = SGAnimatedCoverFileForAlbum(artist, album);
        }
        follower->_found(uri, file);
        [follower fetchAhead];
    });
}

// The next track's clip, fetched into the store once, so a skip finds it there.
- (void)fetchAhead {
    SPTPlayerState *state = SGPlayerState();
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    id next = [future isKindOfClass:NSArray.class] ? [(NSArray *)future firstObject] : nil;
    if (![next isKindOfClass:objc_getClass("SPTPlayerTrack")]) return;
    SPTPlayerTrack *track = next;
    NSString *uri = SGURIString(track.URI);
    if (!uri || [uri isEqualToString:_track] || [uri isEqualToString:_ahead]) return;
    _ahead = uri;
    NSDictionary *metadata = [track.metadata isKindOfClass:NSDictionary.class] ? track.metadata : nil;
    SGMotionClipFor(uri, SGMotionCanvasIn(metadata), track.artistName, metadata[@"album_title"], SGMotionTall, SGMotionPixels(),
                    ^(NSURL *file, NSString *source) {
        SGLog(@"motion: the next track's clip fetched ahead: %@", file ? source : @"none");
    });
}

- (void)restart {
    _track = nil;
    _walk++;
    SPTPlayerState *state = SGPlayerState();
    if (state) [self playerStateDidChange:state];
}

@end
