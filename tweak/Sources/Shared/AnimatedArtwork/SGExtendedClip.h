// The lock screen's artwork for a song with no moving artwork of its own, when the cover style is Extended
// cover (LockScreenMotion.x): the cover across the screen's whole width, held still, its top and bottom
// edges drawn out to the screen's edges and softened as they go, the way the Music app extends a still
// cover. The lock screen takes only video under its 3:4 key, so it is a short clip of one frame. Core
// Graphics, Core Image and AVFoundation on the CPU only, as SGFluidClip.m is, since the lock screen asks
// while Spotify is in the background.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// The clip's frame, for the lock screen's preview image. `size` is SGLyricsClipSize's; the lock screen
// shows it at the screen's full width, so the cover is drawn across the clip's.
CGImageRef SGExtendedClipFrame(CGImageRef cover, CGSize size) CF_RETURNS_RETAINED;
// Writes the clip as H.264 to `file`, replacing it, and returns once it is written; NO if it was not.
BOOL SGExtendedClipWrite(NSURL *file, CGImageRef cover, CGSize size);
