// Player redesign: while Mosaic is behind the player, a soft shadow under its text and icons, in the header, the
// title and artist, the times and the bar, the controls and the footer, so a bright dot right under a word never
// washes it out. A layer shadow on each label, image view and glyph in those units (and on the bars, bare views
// filled with a color), which the render server draws as a blurred copy of what the view shows, under it. Off
// again when the background changes away from Mosaic or the switch on the Player page is turned off
// (SGRKeyMosaicTextShadow).
//
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Player.h"

static const float kShadowOpacity = 0.7f;
static const CGFloat kShadowRadius = 5;
static const CGSize kShadowOffset = {0, 1};

// The units' views laid out so far, held weakly; and the views given a shadow, so only ours are taken off.
static NSHashTable<UIView *> *sg_units, *sg_shadowed;

static BOOL wanted(void) {
    return SGRPlayerBackground() == SGRPlayerBackgroundMosaic && SGEnabled(SGRKeyMosaicTextShadow);
}

static void shade(UIView *view, BOOL on) {
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

// The views that show something: a label, an image view (a glyph is one), a slider or progress bar, and a bare
// view filled with a color. The containers between them are passed through, so a row's shadow is its contents'.
static void shadeShown(UIView *view, int depth) {
    if (depth > 14) return;
    BOOL shows = [view isKindOfClass:UILabel.class] || [view isKindOfClass:UIImageView.class]
              || [view isKindOfClass:UISlider.class] || [view isKindOfClass:UIProgressView.class]
              || (!view.subviews.count && view.backgroundColor && CGColorGetAlpha(view.backgroundColor.CGColor) > 0.1);
    if (shows) {
        shade(view, YES);
        return;
    }
    for (UIView *sub in view.subviews) shadeShown(sub, depth + 1);
}

static void unitLaidOut(UIViewController *unit) {
    UIView *view = unit.viewIfLoaded;
    if (!view) return;
    [sg_units addObject:view];
    if (wanted()) shadeShown(view, 0);
}

void SGRPlayerTextShadowsChanged(void) {
    if (wanted()) {
        for (UIView *unit in sg_units.allObjects) shadeShown(unit, 0);
    } else {
        for (UIView *view in sg_shadowed.allObjects) shade(view, NO);
    }
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
