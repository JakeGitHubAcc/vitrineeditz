// Player redesign: while Mosaic is behind the player, a soft shadow under its text and buttons, the header, the
// title and artist, the times and the bar, the controls and the footer, so a bright dot right under a word never
// washes it out. A layer shadow on each of those units' views, which draws under whatever they hold: one shadow a
// unit rather than one a label, and no label of Spotify's is touched. Off again when the background changes away
// from Mosaic or the switch on the Player page is turned off (SGRKeyMosaicTextShadow).
//
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Player.h"

static const float kShadowOpacity = 0.85f;
static const CGFloat kShadowRadius = 6;
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

// The views that show something: a label with text, an image view with an image, a glyph, a slider or progress
// bar, and a bare view filled with a color (the redesign's bars). A unit's own full-width rows are passed through.
static void collect(UIView *view, UIView *target, CGFloat widest, NSMutableArray<NSValue *> *rects, int depth) {
    if (view.hidden || view.alpha < 0.05 || depth > 14) return;
    BOOL shows = NO;
    if ([view isKindOfClass:UILabel.class]) shows = ((UILabel *)view).text.length > 0;
    else if ([view isKindOfClass:UIImageView.class]) shows = ((UIImageView *)view).image != nil;
    else if ([view isKindOfClass:UISlider.class] || [view isKindOfClass:UIProgressView.class]) shows = YES;
    else if ([NSStringFromClass(view.class) containsString:@"Glyph"]) shows = YES;
    else if (!view.subviews.count && view.backgroundColor && CGColorGetAlpha(view.backgroundColor.CGColor) > 0.1) shows = YES;
    if (shows) {
        CGRect rect = [view convertRect:view.bounds toView:target];
        if (rect.size.width > 0 && rect.size.height > 0 && rect.size.width < widest) [rects addObject:[NSValue valueWithCGRect:rect]];
        return;
    }
    for (UIView *sub in view.subviews) collect(sub, target, widest, rects, depth + 1);
}

NSArray<NSValue *> *SGRPlayerTextRectsIn(UIView *view) {
    if (!wanted() || !view.window) return @[];
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    CGFloat widest = view.window.bounds.size.width * 0.95;
    for (UIView *unit in sg_units.allObjects) {
        if (unit.window == view.window) collect(unit, view, widest, rects, 0);
    }
    return rects;
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
