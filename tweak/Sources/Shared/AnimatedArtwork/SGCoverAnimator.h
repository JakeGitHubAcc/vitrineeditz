// Album covers animated on the user's own computer (SGCoverAnimator.x): a tap sends the playing album's
// extended cover to Vitrine Animate (animate/ at the repo root) on the same Wi-Fi, which animates it with a
// local video model, and the finished loop is downloaded and kept on the iPhone for good, in Application
// Support rather than the downloads Caches trims, so it plays with the computer off. SGMotionFollower.m
// hands it to the lock screen and the player wherever the album has no Canvas or animated cover of its own.
// Main queue throughout.
#import <Foundation/Foundation.h>

// The computer, as host:port (Vitrine Animate prints it as it starts). Unset until the user enters it.
#define SGKeyAnimateServer @"spotifyglass.animate.server"
// The albums sent and not yet downloaded, {key: album name}, so a relaunch picks them up again.
#define SGKeyAnimatePending @"spotifyglass.animate.pending"
// What the computer does with a cover's text, stored as the index of SGAnimateText, and whether it adds a
// slow camera sway. Read as a cover is sent, so they apply to covers animated from then on.
#define SGKeyAnimateText @"spotifyglass.animate.text"
#define SGKeyAnimateSway @"spotifyglass.animate.sway"
typedef NS_ENUM(NSInteger, SGAnimateText) {
    SGAnimateTextKeep = 0,   // the text stays, still
    SGAnimateTextFade,       // the text fades out and back in over each loop
    SGAnimateTextHide,       // the text is painted out
};

// Posted once a cover's loop is saved; the object is its key (SGAnimatedCoverKey).
extern NSNotificationName const SGAnimatedCoverSavedNotification;

// The picture a track names, so the songs of an album share a cover; the track's URI when it names none.
NSString *SGAnimatedCoverPicture(NSString *uri, NSDictionary *metadata);
// The name a cover is kept and asked for under: a hash of the picture the track names.
NSString *SGAnimatedCoverKey(NSString *picture);
// The saved loop for the picture, or nil.
NSURL *SGAnimatedCoverFile(NSString *picture);
// Sends `png`, the cover, to the computer and follows it until its loop is saved. `done` gets nil
// once the computer has it, else what went wrong.
void SGAnimatedCoverRequest(NSString *picture, NSString *album, NSString *artist, NSData *png, void (^done)(NSString *error));
// Stops following a sent cover, or deletes a saved one.
void SGAnimatedCoverForget(NSString *picture);
// What a settings row reads out for the picture: Saved, Sending…, Waiting, Animating 40%, the computer
// being out of reach, Failed, or nil when it was never sent.
NSString *SGAnimatedCoverStatus(NSString *picture);
BOOL SGAnimatedCoverPending(NSString *picture);
NSUInteger SGAnimatedCoverCount(void);
// The computer's address, or nil when none is entered.
NSString *SGAnimatedCoverServer(void);
// An alert asking for the computer's address; `then` runs once one is stored.
void SGAnimatedCoverAskServer(void (^then)(void));
