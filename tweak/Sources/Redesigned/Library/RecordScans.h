// A record's own sleeve for the Records page (RecordsPage.m), scanned from a vinyl pressing of the album: its front,
// its back, its spine, a hype sticker scanned on its own, and the inside of a gatefold, from the Cover Art Archive
// (coverartarchive.org), which keeps MusicBrainz's releases' pictures with what each shows.
//
// The album is MusicBrainz's release group of that title, artist and kind (album, single or EP, compilation), the
// title the same letter for letter but for case and accents, so a single of the same name or a deluxe edition is not
// taken for it (musicbrainz.org/ws/2, at most one request a second as it asks). Of that group's releases only the
// official vinyl ones of the same title with a front picture are looked at, plain pressings before any with a note
// (a colored vinyl, a reissue) and never a picture disc or a deluxe, anniversary or expanded one, the oldest first.
// The first whose pictures have a front gives the whole sleeve. A CD is never used: an album without a vinyl scan
// keeps its streaming cover. Pictures are kept by what MusicBrainz says they show: a spine only when that is all it
// shows and it is drawn out like one (a back photographed with its spine is a back).
//
// What is found, and what is not, is kept in Caches, so an album is asked about once (one that had nothing is asked
// again after a month).
//
// Threading: main thread, but for the downloads, which report on main.
#import <UIKit/UIKit.h>

@interface SGRSleeve : NSObject
@property (nonatomic, strong) UIImage *front, *back, *spine, *sticker;
// The inside of a gatefold, its left and right halves; nil when the sleeve has none, or no scan of it.
@property (nonatomic, copy) NSArray<UIImage *> *gatefold;
@end

// `kind` is Spotify's album_type: album, single (a single or an EP), ep or compilation. A pressing's front must show the
// same picture as `cover`, the streaming one, allowing for a scan's light and color, so a picture disc in its clear
// sleeve, or another edition's cover, is passed over for the next. `done` on main, once, with the sleeve, or nil when
// no vinyl pressing has a scan of it.
void SGRRecordSleeve(NSString *title, NSString *artist, NSString *kind, UIImage *cover, void (^done)(SGRSleeve *sleeve));

// A sleeve of the pictures that came with a local album's songs (Shared/LocalFiles/DriveImport.h, SGLocalAlbumArtwork),
// by kind; its front is `cover` when none came. The inside is its first two pictures, or one spread cut in half. nil
// when there is nothing but a front. Any thread.
SGRSleeve *SGRSleeveOfArtwork(NSDictionary<NSString *, NSArray<NSString *> *> *artwork, UIImage *cover);

// The colors a label strip in the cover's colors takes: the cover's most common color, and of the cover's other
// colors the one that reads best on it, else white or black. Any thread.
void SGRSpineColors(UIImage *cover, UIColor **back, UIColor **text);
