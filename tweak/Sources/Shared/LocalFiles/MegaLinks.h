// Mega (mega.nz) share links for DriveImport.h, read the way Mega's own web client reads a public link, through its
// API (g.api.mega.co.nz/cs) with nothing signed in: a file link names one file and carries its key; a folder link
// carries the folder's key, which unlocks each of its files' keys and names. Every file on Mega is encrypted with its
// own key (AES-128 in counter mode), so a download is decrypted once it is in.
//
//     https://mega.nz/file/<handle>#<key>       https://mega.nz/folder/<handle>#<key>
//     https://mega.nz/#!<handle>!<key>          https://mega.nz/#F!<handle>!<key>      (the older form)
//
// Threading: the lists and addresses report on main; decrypting runs where it is called.
#import <Foundation/Foundation.h>

@interface SGMegaFile : NSObject
// Its name, under its folders' names inside the shared folder ("Disc 2/01 Song.flac").
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *handle;
// The shared folder's handle, nil for a file shared on its own.
@property (nonatomic, copy) NSString *folder;
// The file's own key, 32 bytes.
@property (nonatomic, copy) NSData *key;
@property (nonatomic) long long size;
@end

BOOL SGMegaIsLink(NSString *link);
// What `link` shares: the one file, or every file in the folder and its folders. `done` on main with them, or with
// what went wrong.
void SGMegaList(NSString *link, void (^done)(NSArray<SGMegaFile *> *files, NSString *error));
// Where to download `file` from now (Mega's addresses last a while, not for good). `done` on main.
void SGMegaAddress(SGMegaFile *file, void (^done)(NSURL *address, NSString *error));
// Decrypts the download of `file` at `source` into `target`; NO when it could not.
BOOL SGMegaDecrypt(SGMegaFile *file, NSString *source, NSString *target);
