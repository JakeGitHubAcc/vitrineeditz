// Local files gathered into albums, the way the Music app and YouTube Music show them, where Spotify only
// lists the tracks in its Local Files playlist and has no page for their album. Either look can show them;
// the redesign's pages are Redesigned/Library/LocalAlbums.m.
//
// The tracks are the audio files in Documents, the folder Spotify scans and the Files app shows as Spotify's,
// read by AudioToolbox for their tags and length. Each track's URI is made the way Spotify's core makes it
// from the same tags (LocalFiles.h), and corrected by the URIs the player has played: Spotify's length may
// differ from AudioToolbox's by a second, and a URI the player reported for the same names is Spotify's own.
// The user's Edit info names (LocalFiles.h) are what the albums are gathered and shown by.
//
// Playing an album puts its tracks in the queue and skips to the first: the album plays from the queue, and what
// was playing goes on after it. The player's header, which then says Queue, names the album while it plays
// (LocalFileInfo.x). A context of its own (+[SPTPlayerContext contextWithTracks:]) stopped the player, 9.1.94.
//
// Threading: main thread, but for the scan, which runs on a queue of its own and reports on main.
#import <UIKit/UIKit.h>

// How the albums are sorted, kept as an int.
#define SGKeyLocalAlbumsSort @"spotifyglass.localAlbums.sort"
typedef NS_ENUM(NSInteger, SGLocalAlbumSort) {
    SGLocalAlbumSortTitle,
    SGLocalAlbumSortArtist,
    SGLocalAlbumSortAdded,
};

@interface SGLocalTrack : NSObject
@property (nonatomic, copy, readonly) NSString *uri;
@property (nonatomic, copy, readonly) NSString *path;
// The user's names over the file's own.
@property (nonatomic, copy, readonly) NSString *title, *artist, *album;
@property (nonatomic, readonly) NSInteger number, disc, year, seconds;
@property (nonatomic, strong, readonly) NSDate *added;
@end

@interface SGLocalAlbum : NSObject
@property (nonatomic, copy, readonly) NSString *title;
// The artist every track shares, or Various Artists.
@property (nonatomic, copy, readonly) NSString *artist;
@property (nonatomic, readonly) NSInteger year, seconds;
// The newest file's.
@property (nonatomic, strong, readonly) NSDate *added;
// By disc, then number, then title.
@property (nonatomic, copy, readonly) NSArray<SGLocalTrack *> *tracks;
@end

// The albums as last scanned, empty before the first scan finishes; the scan starts on first use.
NSArray<SGLocalAlbum *> *SGLocalAlbums(void);
// Scans Documents again; `done` on main once SGLocalAlbums() has the result.
void SGLocalAlbumsRefresh(void (^done)(void));
// Posted on main when the albums change.
extern NSNotificationName const SGLocalAlbumsDidChangeNotification;
NSArray<SGLocalAlbum *> *SGLocalAlbumsSorted(NSArray<SGLocalAlbum *> *albums, SGLocalAlbumSort sort);
// The album a local file's URI belongs to, nil when it is none of the scanned ones.
SGLocalAlbum *SGLocalAlbumOfTrack(NSString *uri);
// The album's cover: one picked in Edit info for any of its tracks, else the first file's own artwork, at
// most `side` points on its longer side; `done` on main, nil when there is none.
void SGLocalAlbumCover(SGLocalAlbum *album, CGFloat side, void (^done)(UIImage *cover));
// Plays the album from its track at `from`, or its tracks shuffled; `done` on main with what went wrong.
void SGLocalAlbumPlay(SGLocalAlbum *album, NSUInteger from, BOOL shuffle, void (^done)(NSString *error));
// The title of the album last played from its page while one of its tracks is playing, else nil. Main thread.
NSString *SGLocalAlbumPlayingTitle(void);
