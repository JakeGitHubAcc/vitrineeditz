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
    SGAnimateTextSpray,      // the text is sprayed off along its diagonal and back on, a spray paint edge
};
// Line boil, for a drawn cover: off until switched on (read with SGHidden, as the sway).
#define SGKeyAnimateBoil @"spotifyglass.animate.boil"
// Each of what moves on a cover, on until switched off: the prefix and the server's name of it (SGAnimateEffects).
#define SGKeyAnimateEffectPrefix @"spotifyglass.animate.effect."
// What moves on a cover, each {the server's name, title, what it does}, in the page's order.
NSArray<NSArray<NSString *> *> *SGAnimateEffects(void);
// The Animated Covers page: the computer, the text, the style and what moves. Defined in AnimatedArtworkSettings.m.
@class UIViewController;
UIViewController *SGAnimatedCoversPage(void);

// Posted once a cover's loop is saved; the object is its key (SGAnimatedCoverKey).
extern NSNotificationName const SGAnimatedCoverSavedNotification;

// The picture a track names, so the songs of an album share a cover; the track's URI when it names none.
NSString *SGAnimatedCoverPicture(NSString *uri, NSDictionary *metadata);
// The name a cover is kept and asked for under: a hash of the picture the track names.
NSString *SGAnimatedCoverKey(NSString *picture);
// The saved loop for the picture, or nil.
NSURL *SGAnimatedCoverFile(NSString *picture);
// The picture an album page sends its cover under, which it has no track's picture for: made of the
// album's artist and name.
NSString *SGAnimatedCoverAlbumPicture(NSString *artist, NSString *album);
// The saved loop for an album by its artist and name, whichever way it was made: from a song of it playing
// or from its page. Each cover sent is listed under its album's artist and name, and a saved one found for a
// song is listed as the song plays, so an album page finds one made before the list was kept.
NSURL *SGAnimatedCoverFileForAlbum(NSString *artist, NSString *album);
void SGAnimatedCoverList(NSString *picture, NSString *artist, NSString *album);
// The playing album's cover sent, as the lock screen's row and the player's menu send it; what went wrong
// in an alert. Defined in AnimatedArtworkSettings.m.
void SGAnimatedCoverSendPlaying(void);
// The ⋯ menus' items for an album's animated cover, the player's (the playing album) and an album page's:
// in an Animated Cover submenu, Animate Album Cover, or Animate Again and Delete once saved, or Stop while
// the computer has it, then the Text and Camera Sway settings, which go with the next cover sent. `send`
// sends the cover. The computer's address is asked for first when none is entered.
@class UIMenuElement;
NSArray<UIMenuElement *> *SGAnimatedCoverMenu(NSString *picture, void (^send)(void));
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
// Copies every loop the computer keeps that this iPhone lacks (Spotify deleted and installed again), listed under
// its album where the computer kept the names. Runs on its own a few seconds after launch and once an address is
// entered; `done` (main) with how many were added, or what went wrong.
void SGAnimatedCoverRestore(void (^done)(NSUInteger added, NSString *error));
// The computer's address, or nil when none is entered.
NSString *SGAnimatedCoverServer(void);
// An alert asking for the computer's address; `then` runs once one is stored.
void SGAnimatedCoverAskServer(void (^then)(void));
