// Google Drive import: songs from a Drive share link saved as local files, where Spotify and Local Albums
// (LocalAlbums.h) find them. A link to a file, to a folder (its files and those of its folders, read from
// Drive's public folder view) or to a .zip, which is unpacked. Only links shared with anyone who has the
// link work, as nothing signs in to Google.
//
// What is lossless (FLAC, WAV, AIFF) is converted to AAC at 256 kbps in an .m4a, which sounds the same and
// is about a fifth of a FLAC's size, its tags and cover carried over (a FLAC's read from its own Vorbis
// comment and picture blocks). What is already lossy (MP3, AAC, M4A) is kept as it is, since converting it
// again would only lose quality. Each song is saved in Documents, the folder Spotify reads local files from
// (the Files app's Spotify folder), as "Artist - Title".
//
// Threading: start and the job's changes are on main; the work runs on queues of its own.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SGDriveItemState) {
    SGDriveItemWaiting,
    SGDriveItemDownloading,
    SGDriveItemConverting,
    SGDriveItemSaved,
    SGDriveItemSkipped,   // not a song
    SGDriveItemFailed,
};

@interface SGDriveItem : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) SGDriveItemState state;
// 0 to 1 while downloading.
@property (nonatomic, readonly) double progress;
// What went wrong, or for a saved song what it was saved as ("Converted to AAC 256 kbps, 9.1 MB").
@property (nonatomic, copy, readonly) NSString *detail;
@end

@interface SGDriveJob : NSObject
@property (nonatomic, copy, readonly) NSString *link;
// The files found so far; a folder's are listed before any downloads.
@property (nonatomic, copy, readonly) NSArray<SGDriveItem *> *items;
// Set when the link itself could not be read.
@property (nonatomic, copy, readonly) NSString *error;
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
- (void)cancel;
@end

// Posted on main whenever a job or one of its items changes, object the job.
extern NSNotificationName const SGDriveJobDidChangeNotification;

// Starts importing what `link` shares; nil when it is not a Google Drive link.
SGDriveJob *SGDriveImportStart(NSString *link);
// The jobs started since launch, newest first.
NSArray<SGDriveJob *> *SGDriveImportJobs(void);
// Where the songs are saved.
NSString *SGDriveImportFolder(void);
