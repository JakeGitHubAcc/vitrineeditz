// Scans of a record's own sleeve for the Records page (RecordsPage.m): the front and the spine, photographed or
// scanned from a vinyl or CD release, from the Cover Art Archive (coverartarchive.org), which keeps MusicBrainz's
// releases' pictures with what each shows (Front, Spine, ...).
//
// The album is looked for by name among MusicBrainz's releases (musicbrainz.org/ws/2/release, its search, at most
// one request a second as it asks), the vinyl ones first, then the CDs; digital releases are left out. The first
// of them with a front picture gives the front, and the first with a spine picture the spine, turned to lie along
// the record's bottom edge. What is found, and what is not, is kept in Caches, so an album is asked about once
// (one that had nothing is asked again after a month).
//
// Threading: main thread, but for the downloads, which report on main.
#import <UIKit/UIKit.h>

// `done` on main, once, with the front and the spine, either nil when there is none. Albums asked for later are
// looked for first, so the one on screen goes before the ones scrolled past.
void SGRRecordScans(NSString *title, NSString *artist, void (^done)(UIImage *front, UIImage *spine));

// The colors a label strip in the cover's colors takes: the cover's most common color, and of the cover's other
// colors the one that reads best on it, else white or black. Any thread.
void SGRSpineColors(UIImage *cover, UIColor **back, UIColor **text);
