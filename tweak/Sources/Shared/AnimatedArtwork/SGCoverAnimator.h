// Album covers animated on the user's own computer (SGCoverAnimator.x): a tap sends the playing album's
// extended cover to Vitrine Animate (animate/ at the repo root) on the same Wi-Fi, which animates it with a
// local video model, and the finished loop is downloaded and kept on the iPhone for good, in Application
// Support rather than the downloads Caches trims, so it plays with the computer off. LockScreenMotion.x
// shows it wherever the album has no Canvas or animated cover of its own. Main queue throughout.
#import <Foundation/Foundation.h>

// The computer, as host:port (Vitrine Animate prints it as it starts). Unset until the user enters it.
#define SGKeyAnimateServer @"spotifyglass.animate.server"
// The albums sent and not yet downloaded, {key: album name}, so a relaunch picks them up again.
#define SGKeyAnimatePending @"spotifyglass.animate.pending"

// Posted once a cover's loop is saved; the object is its key (SGAnimatedCoverKey).
extern NSNotificationName const SGAnimatedCoverSavedNotification;

// The name a cover is kept and asked for under: a hash of the picture the track names.
NSString *SGAnimatedCoverKey(NSString *picture);
// The saved loop for the picture, or nil.
NSURL *SGAnimatedCoverFile(NSString *picture);
// Sends `png`, the cover's frame, to the computer and follows it until its loop is saved. `done` gets nil
// once the computer has it, else what went wrong.
void SGAnimatedCoverRequest(NSString *picture, NSString *album, NSData *png, void (^done)(NSString *error));
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
