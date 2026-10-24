// What the lock screen fills the screen with, the lyrics' style and whether the downloads run in Low Data
// Mode. iOS 26 and up only.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "AnimatedArtwork.h"
#import "SGCoverAnimator.h"

SGLockArtwork SGLockScreenArtwork(void) {
    if (@available(iOS 26.0, *)) {
        // The old switch's YES and NO read as Moving artwork and Off, the enum's first two.
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGMigrateKey(SGKeyLockScreenMotion, SGKeyLockScreenArtwork); });
        return (SGLockArtwork)SGInt(SGKeyLockScreenArtwork, SGLockArtworkOff);
    }
    return SGLockArtworkOff;
}

static void tell(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static void sendPlaying(void) {
    SGLockMotionAnimatePlaying(^(NSString *error) {
        if (error) tell(@"Not sent", error);
    });
}

// The animate row's tap: the computer's address first if none is entered, then, for the playing album, send
// it, or offer to stop, make again or delete what it already has.
static void animateTapped(void) {
    if (!SGAnimatedCoverServer()) {
        SGAnimatedCoverAskServer(^{ animateTapped(); });
        return;
    }
    NSString *picture = SGLockMotionPlayingPicture();
    if (!picture) {
        tell(@"Nothing is playing", @"Play a song from the album first.");
        return;
    }
    BOOL saved = SGAnimatedCoverFile(picture) != nil, waiting = SGAnimatedCoverPending(picture);
    if (!saved && !waiting) {
        sendPlaying();
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:SGLockMotionPlayingAlbum()
        message:saved ? @"This album's animated cover is saved on this iPhone." : @"Your computer is animating this album's cover."
        preferredStyle:UIAlertControllerStyleActionSheet];
    if (saved) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Animate Again" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            SGAnimatedCoverForget(picture);
            sendPlaying();
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:saved ? @"Delete Animated Cover" : @"Stop Waiting" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) { SGAnimatedCoverForget(picture); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *top = SGTopController();
    sheet.popoverPresentationController.sourceView = top.view;
    [top presentViewController:sheet animated:YES completion:nil];
}

NSArray *SGLockScreenMotionRows(void) {
    if (@available(iOS 26.0, *)) {
        SGLockScreenArtwork();   // moves the old switch over before the row reads the new key
        SGModRow *style = SGChoiceRow(@"Lyrics style", @"Still draws each line once; Animated breathes the cover behind it. "
                                                       @"With moving artwork, for songs that have none",
                                      SGKeyLockScreenLyricsStyle, @[@"Still", @"Animated"], 0);
        style.visible = ^BOOL { return SGLockArtworkShowsLyrics(SGLockScreenArtwork()); };
        SGModRow *cover = SGChoiceRow(@"Songs without moving artwork", @"Moving blur puts the cover over a slowly turning "
                                                                        @"blur of it. Extended cover lays it across the screen, "
                                                                        @"still, its edges drawn out to the top and bottom",
                                      SGKeyLockScreenCoverStyle, @[@"Moving blur", @"Extended cover"], SGLockCoverMovingBlur);
        cover.visible = ^BOOL { return SGLockScreenArtwork() == SGLockArtworkEverySong; };
        SGModRow *lowData = SGOptionRow(@"Download in Low Data Mode", @"Moving artwork, up to about 7 MB a song", SGKeyMotionLowData);
        lowData.visible = ^BOOL {
            SGLockArtwork artwork = SGLockScreenArtwork();
            return artwork == SGLockArtworkMotion || artwork == SGLockArtworkEverySong || artwork == SGLockArtworkMotionLyrics;
        };
        SGModRow *sources = SGMotionSourcesRow();
        sources.visible = lowData.visible;
        SGModRow *star = SGOptionRow(@"Switch with the star", @"The lock screen widget's star swaps the moving artwork for the lyrics "
                                                             @"and back. It takes the place of Spotify's like and dislike buttons",
                                     SGKeyLockScreenStar);
        star.visible = ^BOOL { return SGLockScreenArtwork() != SGLockArtworkOff; };
        SGModRow *animate = SGStatActionRow(@"Animate this album's cover",
                                            @"Your computer makes a moving version of the playing album's cover with Vitrine Animate. "
                                            @"It is saved on this iPhone and plays, on the lock screen and behind the player, for "
                                            @"every song of the album that has no Canvas or animated cover, with the computer off",
                                            ^NSString *{ return SGAnimatedCoverStatus(SGLockMotionPlayingPicture()) ?: @"Not animated"; },
                                            ^{ animateTapped(); });
        animate.visible = lowData.visible;
        SGModRow *computer = SGStatActionRow(@"Computer", @"Where Vitrine Animate runs, as it shows when it starts",
                                             ^NSString *{ return SGAnimatedCoverServer() ?: @"Not set"; },
                                             ^{ SGAnimatedCoverAskServer(nil); });
        computer.visible = lowData.visible;
        SGModRow *text = SGChoiceRow(@"Text on animated covers", @"Keep holds the cover's text still. Fade lets it fade out "
                                                                  @"and back in over each loop, as some animated covers do. "
                                                                  @"Hide paints it out. For covers animated from now on; "
                                                                  @"Animate Again remakes one",
                                     SGKeyAnimateText, @[@"Keep", @"Fade", @"Hide"], SGAnimateTextKeep);
        text.visible = lowData.visible;
        SGModRow *sway = SGOptionRow(@"Camera sway", @"A slow, slight drift and push of the whole picture. For covers animated "
                                                     @"from now on", SGKeyAnimateSway);
        sway.visible = lowData.visible;
        SGModRow *kept = SGStatRow(@"Animated covers saved", ^NSString *{ return [NSString stringWithFormat:@"%lu", (unsigned long)SGAnimatedCoverCount()]; });
        kept.visible = lowData.visible;
        return @[
            SGChoiceRow(@"Full-screen artwork", @"The Canvas or Apple Music's animated cover, or the lyrics a line at a time. "
                                                 @"Every song shows the cover where a song has neither, in the style picked below. "
                                                 @"Moving artwork with lyrics puts the lines over the Canvas or animated cover",
                        SGKeyLockScreenArtwork, @[@"Off", @"Moving artwork", @"Lyrics", @"Every song", @"Moving artwork with lyrics"],
                        SGLockArtworkOff),
            cover,
            style,
            star,
            sources,
            animate,
            text,
            sway,
            computer,
            kept,
            lowData,
        ];
    }
    return @[SGLockScreenArtworkNeedsRow()];
}

// Below iOS 26 the section stays, with one row that says why there is nothing to pick.
SGModRow *SGLockScreenArtworkNeedsRow(void) {
    return SGStatActionRow(@"Full-screen artwork", nil, ^NSString *{ return @"Needs iOS 26"; }, ^{
        NSString *message = [NSString stringWithFormat:@"This iPhone has iOS %@. The lock screen takes moving artwork "
                                                       @"from apps from iOS 26 on, so the Canvas and Apple Music's animated "
                                                       @"covers can show there once the iPhone is updated.", UIDevice.currentDevice.systemVersion];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Needs iOS 26" message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
    });
}
