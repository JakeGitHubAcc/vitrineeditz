// Player redesign: while Mosaic is behind the player, a soft shadow under its text and buttons, the header, the
// title and artist, the times and the bar, the controls and the footer, so a bright dot right under a word never
// washes it out. A layer shadow on each of those units' views, which draws under whatever they hold: one shadow a
// unit rather than one a label, and no label of Spotify's is touched. Off again when the background changes away
// from Mosaic or the switch on the Player page is turned off (SGRKeyMosaicTextShadow).
//
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Player.h"

static const float kShadowOpacity = 0.6f;
static const CGFloat kShadowRadius = 4;
static const CGSize kShadowOffset = {0, 1};

// The units' views laid out so far, held weakly; and the ones given a shadow, so only ours are taken off.
static NSHashTable<UIView *> *sg_units, *sg_shadowed;

static BOOL wanted(void) {
    return SGRPlayerBackground() == SGRPlayerBackgroundMosaic && SGEnabled(SGRKeyMosaicTextShadow);
}

static void shade(UIView *view, BOOL on) {
    if (!view) return;
    CALayer *layer = view.layer;
    if (on) {
        if ([sg_shadowed containsObject:view]) return;
        [sg_shadowed addObject:view];
        layer.shadowColor = UIColor.blackColor.CGColor;
        layer.shadowOffset = kShadowOffset;
        layer.shadowRadius = kShadowRadius;
        layer.shadowOpacity = kShadowOpacity;
    } else if ([sg_shadowed containsObject:view]) {
        [sg_shadowed removeObject:view];
        layer.shadowOpacity = 0;
    }
}

static void unitLaidOut(UIViewController *unit) {
    UIView *view = unit.viewIfLoaded;
    if (!view) return;
    [sg_units addObject:view];
    shade(view, wanted());
}

void SGRPlayerTextShadowsChanged(void) {
    BOOL on = wanted();
    for (UIView *view in sg_units.allObjects) shade(view, on);
}

%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    unitLaidOut((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    unitLaidOut((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl19DurationElementUnit
- (void)viewDidLayoutSubviews {
    %orig;
    unitLaidOut((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    unitLaidOut((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    unitLaidOut((UIViewController *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    sg_units = [NSHashTable weakObjectsHashTable];
    sg_shadowed = [NSHashTable weakObjectsHashTable];
    %init;
    // The switch on the Player page; the defaults change on any thread.
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGRPlayerTextShadowsChanged(); });
    }];
}
