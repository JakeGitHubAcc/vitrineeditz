// Player redesign: the Visualizer background, a calm spectrum of what is playing behind the player, in the
// cover's colors, over the Fluid field held still (PlayerField.x keeps the field Fluid for this choice, as for
// Animated, so the ⋯ menu moves between the three without a restart).
//
// The sound is Spotify's output as it plays, read on the render thread through the audio effects' notify
// (SGAudioSetOutputReader, Shared/AudioEffects/AudioEffects.h) into SGRSpectrum.m's bands. Here, on the main
// thread, a display link reads the bands, brings them to a share of the song's own loudness (the loudest band of
// the last few seconds at the top, so a quiet track moves as much as a loud one), eases each band up quickly
// and down slowly, and draws two soft hills across the foot of the screen, mirrored about its middle, the kick
// in the middle and the treble at either edge: a slow one behind, a quicker one in front. Each is a gradient of
// the cover's colors (SGRPalette's flow colors, brought to one luminance) masked by a shape layer, so the render
// server does the drawing and the app only hands it two paths a frame. They are light added to the field
// (plusL), never paint over it, so a dark cover's hills are a silver mist and a bright field's are brighter
// still, and the whole fades to clear toward the tallest crest, so a peak thins to light instead of ending in an
// edge. The front hill brightens on the kick and dims over a third of a second: the beat, where the heights are
// the spectrum.
//
// It moves only while it is in a window, Spotify is in front, the player is not opening or closing, Low Power
// Mode is off and the song plays; a pause lets the hills settle and the link stops, and nothing is read from
// the sound while it is stopped. At most 60 frames a second, 30 while the lyrics, which have a link of their own,
// are open and the hills are blurred behind them, and with Reduce Motion 15, with every band easing over
// seconds. While the player opens or closes the link is down, and comes back only once the animation is over:
// a link at 60 would hold the transition's 120 Hz down with it.
//
// ponytail: the hills follow what the output is handed, which a Bluetooth headset plays a fifth of a second or
// so later. Music Haptics schedules for the output latency; do the same here if the beat looks early on AirPods.
//
// Threading: main thread only, but for the reader, which runs on the render thread.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AudioEffects/AudioEffects.h"
#import "Shared/Player/PlayerEvents.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Player.h"
#import "SGRSpectrum.h"

// The two bands under 80 Hz stay out of the picture: sub-bass is quieter than the kick above it in most mixes,
// so drawn at the middle it cut a notch into the crest right under the play button.
enum { kBands = SGRSpectrumBands, kFirst = 2, kShown = kBands - kFirst, kPoints = 2 * kShown - 1 };
// The kick: the four bands from kFirst, 80 to 205 Hz; beside it the next six, 205 to 840 Hz.
enum { kKickBands = 4, kBesideBands = 6 };
// The loudness a band is drawn against: the loudest band of late at the top, kRange dB under it at the floor,
// the top falling kPeakFall dB a second after a loud passage and never under kPeakFloor, so silence stays flat.
// 30 dB rather than more: a modern mix keeps every band within 40 of the loudest, which drew one flat plateau.
static const float kRange = 30, kPeakFall = 4, kPeakFloor = -60;
// A rise toward the treble, in dB a band (three bands an octave), since music has less there: a tuning knob.
static const float kTilt = 0.6f;
// How quickly a band eases toward its level, up and down, in seconds; the hill behind is slower. With Reduce
// Motion both ease over kStillEase.
static const double kFrontUp = 0.12, kFrontDown = 0.5, kBackUp = 0.3, kBackDown = 0.9, kStillEase = 3;
// The beat: the kick's bands within kPulseRange dB of the peak light the front hill up, at once,
// and it dims again over kPulseDown; the hill never goes under kPulseFloor of its brightness.
static const float kPulseRange = 10, kPulseFloor = 0.5f;
static const double kPulseUp = 0.03, kPulseDown = 0.3;
// The luminance the hills add to the field. Under the footer's icons, where both hills lie on the field, white
// measured 7:1 on Currents in the simulator (6:1 at the very foot); 0.08 took them to 5.3:1 and 4.8:1.
static const CGFloat kGlow = 0.075;
// The glow's least saturation, for any flow color that has a hue at all (over kGrayBelow): the flow colors keep
// a dark cover's faint tint, which lifted to kGlow alone reads as silver.
static const CGFloat kGlowSaturation = 0.6, kGrayBelow = 0.08;
// No new bands for this long reads as silence (a pause, a stall, a tap that never ran).
static const double kStale = 0.3;
// The hills' height at their tallest and at rest, as shares of the screen's height; the one behind is taller.
static const CGFloat kFrontHeight = 0.2, kBackHeight = 0.26, kRestHeight = 0.008;
// The crest fade: the hills are opaque from kFadeFoot of the screen's height over the foot and clear from
// kFadeTop up, so the front hill at its tallest and the back one's crests dissolve into the field.
static const CGFloat kFadeFoot = 0.04, kFadeTop = 0.2;
// Below this every band has settled (under 2 pt at the top of the front hill), and a paused song's link can stop.
static const float kSettled = 0.02f;
// Each band shares this much with either neighbor, three times over, so one loud band is a hill and not a spike.
static const float kSpread = 0.25f;
static const NSTimeInterval kTransitionSlack = 0.05;
// Mosaic: the wall's black over the field; the bars' longest reach, a share of the view's longer side; how bright
// an unlit dot glows, and how much the kick adds to that; how bright a falling bar's trail is.
static const CGFloat kWallDark = 0.92, kReach = 0.5;
static const float kUnlit = 0.12f, kUnlitPulse = 0.08f, kTrail = 0.35f;
// The animated cover's corners, a share of its side, as Spotify rounds its square.
static const CGFloat kClipCorner = 0.025;
// The ring of dark dots between the cover and the wall, in points (a dot at least).
static const CGFloat kBorder = 14;
// How often the animated cover's frame is read for the dots' colors.
static const CFTimeInterval kFrameEvery = 0.25;
// The dimmest a lit dot of the cover's darkest part shines, so black in the cover is still a faint light.
static const float kValueFloor = 0.08f;
// The share of the colors kept from the frame before, so they flow rather than jump between frames.
static const float kFrameKeep = 0.4f;

NSInteger SGRMosaicDots(void) {
    NSInteger dots = SGInt(SGRKeyMosaicDots, SGRMosaicDotsDefault);
    return MIN(MAX(dots, SGRMosaicDotsLeast), SGRMosaicDotsMost);
}

NSInteger SGRMosaicSize(void) {
    NSInteger size = SGInt(SGRKeyMosaicSize, SGRMosaicSizeDefault);
    return MIN(MAX(size, SGRMosaicSizeLeast), SGRMosaicSizeMost);
}

NSInteger SGRMosaicThreshold(void) {
    NSInteger threshold = SGInt(SGRKeyMosaicThreshold, SGRMosaicThresholdDefault);
    return MIN(MAX(threshold, SGRMosaicThresholdLeast), SGRMosaicThresholdMost);
}

// The animated cover Mosaic plays in the cover's square, nil for none (PlayerMotion.x hands it over).
static NSURL *sg_clipFile;
static UIImage *sg_clipPoster;

static NSUInteger sg_readers;

// The reader on while any view is moving, so nothing is analyzed while none is.
static void needReader(BOOL need) {
    if (need) {
        if (sg_readers++ == 0) {
            SGRSpectrumPrepare();
            SGAudioSetOutputReader(SGRSpectrumFeed);
        }
    } else if (sg_readers && --sg_readers == 0) {
        SGAudioSetOutputReader(NULL);
    }
}

static NSDictionary *noActions(void) {
    static NSDictionary *none;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNull *off = NSNull.null;
        none = @{@"bounds": off, @"position": off, @"frame": off, @"path": off, @"colors": off};
    });
    return none;
}

@interface SGRVisualiserView : UIView <SGPlayerStateObserver>
// Where the hills stand, in points from the top: the screen's foot in the player. 0 is the bounds' foot.
@property (nonatomic) CGFloat baseline;
// The height the hills are a share of; 0 is the bounds' height.
@property (nonatomic) CGFloat screenHeight;
@property (nonatomic, readonly) BOOL blurred;
// Mosaic's wall of dots in place of the hills.
@property (nonatomic) BOOL mosaic;
// Mosaic's bars stand out of the player's cover; elsewhere (the Player page's card) out of a square in the middle.
@property (nonatomic) BOOL followsCover;
- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated;
- (void)playClip:(NSURL *)file poster:(UIImage *)poster;
- (void)placeClip;
- (void)appear:(BOOL)animated;
- (void)disappear:(void (^)(void))done;
@end

@implementation SGRVisualiserView {
    UIView *_content;   // the hills, faded in and out as one
    CAGradientLayer *_backFill, *_frontFill;
    CAShapeLayer *_backShape, *_frontShape;
    CAGradientLayer *_crestFade;   // the content's mask: clear at the tallest crest, opaque over the foot
    UIVisualEffectView *_lyricsBlur;
    CADisplayLink *_link;
    BOOL _reading, _idle;
    float _front[kBands], _back[kBands], _peak, _pulse;
    uint64_t _generation;
    CFTimeInterval _fresh, _last;
    NSUInteger _palette;
    // What draw last drew from: the same again sets the same paths and opacity, so a hill at rest hands the render
    // server nothing. The pulse is kept as the opacity it rounds to, since it decays on long after that stands still.
    struct { CGRect bounds; CGFloat baseline, screenHeight; float front[kBands], back[kBands], opacity; } _drawn;
    // Mosaic: a dark wall of dots over the field, each the cover's color where it stands, lit in bars out of the
    // cover's edges. _dots holds one pixel a dot and is masked into round lights by _holes.
    BOOL _mosaic;
    UIView *_wall;
    CALayer *_dots, *_holes;
    UIImage *_artwork;
    int _columns, _rows;
    CGFloat _pitch, _light;   // a dot's cell in points, and the light's share of it, as the settings say
    // The animated cover over the cover's square, the poster under the video until it draws.
    CALayer *_clipStill;
    AVPlayerLayer *_clipLayer;
    AVQueuePlayer *_clipPlayer;
    AVPlayerLooper *_clipLooper;
    NSURL *_clipFile;
    float *_samples;   // the cover's color under each dot, brought to full brightness, RGB a dot
    uint8_t *_pixels;
    // The animated cover's frame the colors come from while it plays, read every kFrameEvery from its file.
    UIImage *_clipFrame;
    AVAssetImageGenerator *_frames;
    CFTimeInterval _frameAt;
    BOOL _frameBusy, _blendNext;
    struct { CGRect bounds, cover; float front[kBands], back[kBands], pulse, threshold; } _lit;
}

// As PlayerMotion.x: what fades is the effect view's effect, never its alpha or an ancestor's.
static UIBlurEffect *blurEffect(void) {
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}

static CAGradientLayer *fill(CAShapeLayer *shape) {
    CAGradientLayer *layer = [CAGradientLayer layer];
    layer.actions = noActions();
    layer.startPoint = CGPointMake(0, 0.5);
    layer.endPoint = CGPointMake(1, 0.5);
    layer.compositingFilter = @"plusL";
    shape.actions = noActions();
    layer.mask = shape;
    return layer;
}

static CGFloat toLinear(CGFloat c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
static CGFloat toEncoded(CGFloat c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055; }

// `color` in its own hue at the relative luminance `luminance`, with its saturation lifted to kGlowSaturation
// so a dark red cover's glow is warm and not silver; black, near-black and gray come out gray.
static UIColor *lit(UIColor *color, CGFloat luminance) {
    CGFloat h = 0, s = 0, v = 0, r = 0, g = 0, b = 0, a = 1;
    [color getHue:&h saturation:&s brightness:&v alpha:&a];
    if (s > kGrayBelow) color = [UIColor colorWithHue:h saturation:MAX(s, kGlowSaturation) brightness:v alpha:1];
    [color getRed:&r green:&g blue:&b alpha:&a];
    CGFloat lr = toLinear(r), lg = toLinear(g), lb = toLinear(b);
    CGFloat have = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb;
    if (have < 0.001) return [UIColor colorWithWhite:toEncoded(luminance) alpha:1];
    CGFloat k = luminance / have;
    return [UIColor colorWithRed:toEncoded(MIN(1, lr * k)) green:toEncoded(MIN(1, lg * k)) blue:toEncoded(MIN(1, lb * k)) alpha:1];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    _peak = kPeakFloor;
    _content = [[UIView alloc] initWithFrame:frame];
    _crestFade = [CAGradientLayer layer];
    _crestFade.actions = noActions();
    _crestFade.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.whiteColor.CGColor];
    _content.layer.mask = _crestFade;
    _backShape = [CAShapeLayer layer];
    _backFill = fill(_backShape);
    _backFill.opacity = 0.55f;
    [_content.layer addSublayer:_backFill];
    _frontShape = [CAShapeLayer layer];
    _frontFill = fill(_frontShape);
    [_content.layer addSublayer:_frontFill];
    [self addSubview:_content];
    _lyricsBlur = [[UIVisualEffectView alloc] initWithEffect:nil];
    _lyricsBlur.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addSubview:_lyricsBlur];
    [self applyColors:@[UIColor.darkGrayColor, UIColor.darkGrayColor, UIColor.darkGrayColor, UIColor.darkGrayColor, UIColor.darkGrayColor]];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                                      NSProcessInfoPowerStateDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        [center addObserver:self selector:@selector(updateMotionSoon) name:name object:nil];
    }
    [center addObserver:self selector:@selector(artworkChanged) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    SGRObservePlayerTransition(self, ^(id owner) { [owner updateMotion]; }, ^(id owner) { [owner updateMotion]; });
    SGAddPlayerStateObserver(self);
    [self artworkChanged];
    [self draw];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_link invalidate];
    if (_reading) needReader(NO);
    free(_samples);
    free(_pixels);
}

#pragma mark - color

// Bottom left, the whole cover and bottom right in front, the top two behind, so the hills read as the cover's
// lower half under its upper.
- (void)applyColors:(NSArray<UIColor *> *)colors {
    if (colors.count < 5) return;
    _frontFill.colors = @[(id)lit(colors[2], kGlow).CGColor, (id)lit(colors[4], kGlow).CGColor, (id)lit(colors[3], kGlow).CGColor];
    _backFill.colors = @[(id)lit(colors[0], kGlow).CGColor, (id)lit(colors[1], kGlow).CGColor];
}

- (void)artworkChanged {
    UIImage *image = SGRNowPlayingArtwork(NULL, NULL);
    if (!image) return;
    _artwork = image;
    [self sampleArtwork];
    NSUInteger generation = ++_palette;
    SGRPaletteRequest request = {CGSizeZero, NO, YES, YES, NO};
    __weak SGRVisualiserView *weakSelf = self;
    [SGRPalette paletteForImage:image request:request completion:^(SGRPalette *palette) {
        SGRVisualiserView *view = weakSelf;
        if (!view || !palette.flowColors || generation != view->_palette) return;
        if (!view.window) {
            [view applyColors:palette.flowColors];
            return;
        }
        // The colors cross over as the field's do.
        [CATransaction begin];
        [CATransaction setAnimationDuration:SGRCrossfade];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        for (CAGradientLayer *layer in @[view->_frontFill, view->_backFill]) {
            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"colors"];
            fade.fromValue = (layer.presentationLayer ?: layer).colors;
            [layer addAnimation:fade forKey:@"colors"];
        }
        [view applyColors:palette.flowColors];
        [CATransaction commit];
    }];
}

#pragma mark - showing

- (void)setBaseline:(CGFloat)baseline {
    if (baseline == _baseline) return;
    _baseline = baseline;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _content.frame = bounds;
    _lyricsBlur.frame = bounds;
    _backFill.frame = bounds;
    _frontFill.frame = bounds;
    _backShape.frame = bounds;
    _frontShape.frame = bounds;
    _crestFade.frame = bounds;
    if (_mosaic) [self layOutWall];
    [self draw];
}

- (void)appear:(BOOL)animated {
    _content.alpha = 0;
    _wall.alpha = 0;
    if (animated) SGRAnimate(SGRMotionFade, ^{ self->_content.alpha = 1; self->_wall.alpha = 1; }, nil);
    else _content.alpha = _wall.alpha = 1;
}

- (void)disappear:(void (^)(void))done {
    SGRAnimate(SGRMotionFade, ^{
        self->_content.alpha = 0;
        self->_wall.alpha = 0;
        self->_lyricsBlur.effect = nil;
    }, ^(BOOL finished) { done(); });
}

- (BOOL)blurred {
    return _lyricsBlur.effect != nil;
}

- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated {
    void (^apply)(void) = ^{ self->_lyricsBlur.effect = blurred ? blurEffect() : nil; };
    if (animated) SGRAnimate(SGRMotionFade, apply, nil);
    else apply();
    [self updateMotion];
}

#pragma mark - moving

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self updateMotion];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateMotion];
}

// The power state is reported off the main thread.
- (void)updateMotionSoon {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateMotion]; });
}

- (BOOL)settled {
    for (int band = 0; band < kBands; band++) if (_front[band] > kSettled || _back[band] > kSettled) return NO;
    return YES;
}

// Moving while it may and there is something to show: the song playing, or the hills still settling after it
// stopped. While the player animates, it comes back once the animation is expected to be over.
- (void)updateMotion {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateMotion) object:nil];
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL may = self.window && front && !NSProcessInfo.processInfo.lowPowerModeEnabled;
    NSTimeInterval wait = SGPlayerTransitionEnds() - CACurrentMediaTime();
    if (may && (wait > 0 || SGRPlayerIsTransitioning())) {
        may = NO;
        // Without an expected end, the transition's ended notification brings it back.
        if (wait > 0) [self performSelector:@selector(updateMotion) withObject:nil afterDelay:wait + kTransitionSlack inModes:@[NSRunLoopCommonModes]];
    }
    BOOL playing = !SGPlayerState().isPaused;
    [self setMoving:may && (playing || !self.settled)];
    [self setReading:may && playing];
    // The animated cover holds still with the rest, on its frame, as Animated's clip does (PlayerMotion.x).
    if (may && playing && !SGRReduceMotion()) [_clipPlayer play];
    else [_clipPlayer pause];
}

- (void)setReading:(BOOL)reading {
    if (reading == _reading) return;
    _reading = reading;
    needReader(reading);
}

- (void)setMoving:(BOOL)moving {
    if (moving) {
        if (!_link) {
            _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
            [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            _last = 0;
        }
        // Calmer behind the lyrics, whose own link runs at the display's rate, and calmest with Reduce Motion.
        // While a playing song sends nothing (a stall, or no tap at all), a few frames a second watch for it.
        float most = _idle ? 4 : SGRReduceMotion() ? 15 : _lyricsBlur.effect ? 30 : 60;
        _link.preferredFrameRateRange = CAFrameRateRangeMake(most / 2, most, most);
    } else if (_link) {
        [_link invalidate];
        _link = nil;
    }
}

static float ease(float value, float target, double dt, double up, double down) {
    double tau = target > value ? up : down;
    return value + (target - value) * (float)(1 - exp(-dt / tau));
}

- (void)tick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    double dt = _last ? MIN(now - _last, 0.1) : link.duration;
    _last = now;
    float levels[kBands];
    uint64_t generation = SGRSpectrumRead(levels);
    if (generation != _generation) {
        _generation = generation;
        _fresh = now;
    }
    BOOL silent = !_reading || now - _fresh > kStale;
    float loudest = kPeakFloor;
    for (int band = 0; band < kBands; band++) {
        levels[band] += kTilt * band;
        loudest = fmaxf(loudest, levels[band]);
    }
    if (!silent) _peak = fmaxf(fmaxf(loudest, _peak - kPeakFall * (float)dt), kPeakFloor);
    BOOL still = SGRReduceMotion();
    float targets[kBands], kick = kPeakFloor;
    for (int band = 0; band < kBands; band++) targets[band] = silent ? 0 : fminf(1, fmaxf(0, (levels[band] - (_peak - kRange)) / kRange));
    for (int band = kFirst; band < kFirst + kKickBands; band++) kick = fmaxf(kick, levels[band]);
    // The middle is a mound and never a valley: between kicks the kick's bands stand as tall as the bands beside
    // them (kBesideBands up), so the centre sinks only with the hills on either side and never under them.
    float beside = 0;
    for (int band = kFirst + kKickBands; band < kFirst + kKickBands + kBesideBands; band++) beside = fmaxf(beside, targets[band]);
    for (int band = kFirst; band < kFirst + kKickBands; band++) targets[band] = fmaxf(targets[band], beside);
    for (int pass = 0; pass < 3; pass++) {
        float before = targets[0];
        for (int band = 0; band < kBands; band++) {
            float here = targets[band], next = targets[MIN(band + 1, kBands - 1)];
            targets[band] = kSpread * before + (1 - 2 * kSpread) * here + kSpread * next;
            before = here;
        }
    }
    for (int band = 0; band < kBands; band++) {
        float target = targets[band];
        _front[band] = ease(_front[band], target, dt, still ? kStillEase : kFrontUp, still ? kStillEase : kFrontDown);
        _back[band] = ease(_back[band], target, dt, still ? kStillEase : kBackUp, still ? kStillEase : kBackDown);
    }
    float beat = silent ? 0 : fminf(1, fmaxf(0, (kick - (_peak - kPulseRange)) / kPulseRange));
    _pulse = ease(_pulse, beat, dt, still ? kStillEase : kPulseUp, still ? kStillEase : kPulseDown);
    [self draw];
    BOOL idle = silent && self.settled;
    if (idle && !_idle) {
        // The last step down to rest, too small to see, so a settled hill is drawn exactly at rest.
        memset(_front, 0, sizeof _front);
        memset(_back, 0, sizeof _back);
        [self draw];
    }
    if (idle != _idle) {
        _idle = idle;
        [self updateMotion];
    }
}

#pragma mark - drawing

// A smooth line through the points (Catmull-Rom as cubic Béziers), closed down to the foot of the bounds.
static CGPathRef hillPath(const CGPoint *points, int count, CGFloat foot) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, points[0].x, foot);
    CGPathAddLineToPoint(path, NULL, points[0].x, points[0].y);
    for (int i = 0; i < count - 1; i++) {
        CGPoint before = points[MAX(i - 1, 0)], from = points[i], to = points[i + 1], after = points[MIN(i + 2, count - 1)];
        CGPathAddCurveToPoint(path, NULL, from.x + (to.x - before.x) / 6, from.y + (to.y - before.y) / 6,
                              to.x - (after.x - from.x) / 6, to.y - (after.y - from.y) / 6, to.x, to.y);
    }
    CGPathAddLineToPoint(path, NULL, points[count - 1].x, foot);
    CGPathCloseSubpath(path);
    return path;
}

// The bass in the middle, each band out to either side, the treble at the edges; a band's height eased in so
// quiet bands lie low and only the strong ones stand up.
static void shape(CAShapeLayer *layer, const float *bands, CGFloat width, CGFloat baseline, CGFloat foot, CGFloat tallest, CGFloat rest) {
    CGPoint points[kPoints];
    for (int i = 0; i < kPoints; i++) {
        float value = bands[kFirst + abs(i - (kShown - 1))];
        CGFloat height = rest + (tallest - rest) * powf(value, 1.2f);
        points[i] = CGPointMake(width * i / (kPoints - 1), baseline - height);
    }
    CGPathRef path = hillPath(points, kPoints, foot);
    layer.path = path;
    CGPathRelease(path);
}

- (void)draw {
    CGRect bounds = self.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
    if (_mosaic) {
        [self drawWall];
        return;
    }
    float opacity = kPulseFloor + (1 - kPulseFloor) * _pulse;
    if (CGRectEqualToRect(bounds, _drawn.bounds) && _baseline == _drawn.baseline && _screenHeight == _drawn.screenHeight
        && opacity == _drawn.opacity && !memcmp(_front, _drawn.front, sizeof _front) && !memcmp(_back, _drawn.back, sizeof _back)) return;
    _drawn.bounds = bounds;
    _drawn.baseline = _baseline;
    _drawn.screenHeight = _screenHeight;
    _drawn.opacity = opacity;
    memcpy(_drawn.front, _front, sizeof _front);
    memcpy(_drawn.back, _back, sizeof _back);
    CGFloat baseline = _baseline > 0 ? _baseline : bounds.size.height;
    CGFloat screen = _screenHeight > 0 ? _screenHeight : bounds.size.height;
    CGFloat foot = MAX(baseline, bounds.size.height), rest = round(screen * kRestHeight);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shape(_backShape, _back, bounds.size.width, baseline, foot, screen * kBackHeight, rest * 1.5);
    shape(_frontShape, _front, bounds.size.width, baseline, foot, screen * kFrontHeight, rest);
    _frontFill.opacity = opacity;
    _crestFade.startPoint = CGPointMake(0.5, (baseline - screen * kFadeTop) / bounds.size.height);
    _crestFade.endPoint = CGPointMake(0.5, (baseline - screen * kFadeFoot) / bounds.size.height);
    [CATransaction commit];
}

#pragma mark - Mosaic

- (void)setMosaic:(BOOL)mosaic {
    if (mosaic == _mosaic) return;
    _mosaic = mosaic;
    _content.hidden = mosaic;
    if (mosaic) {
        _wall = [[UIView alloc] initWithFrame:self.bounds];
        _wall.backgroundColor = [UIColor colorWithWhite:0 alpha:kWallDark];
        _wall.alpha = _content.alpha;
        _dots = [CALayer layer];
        _dots.actions = noActions();
        _dots.magnificationFilter = kCAFilterNearest;
        _holes = [CALayer layer];
        _holes.actions = noActions();
        _dots.mask = _holes;
        [_wall.layer addSublayer:_dots];
        _clipStill = [CALayer layer];
        _clipStill.actions = noActions();
        _clipStill.contentsGravity = kCAGravityResizeAspectFill;
        _clipStill.masksToBounds = YES;
        _clipStill.cornerCurve = kCACornerCurveContinuous;
        _clipStill.hidden = YES;
        _clipLayer = [AVPlayerLayer layer];
        _clipLayer.actions = noActions();
        _clipLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [_clipStill addSublayer:_clipLayer];
        [_wall.layer addSublayer:_clipStill];
        [self insertSubview:_wall belowSubview:_lyricsBlur];
        _columns = _rows = 0;
        _pitch = _light = 0;
        memset(&_lit, 0, sizeof _lit);
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(wallSettingsChanged) name:NSUserDefaultsDidChangeNotification object:nil];
    } else {
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSUserDefaultsDidChangeNotification object:nil];
        [self playClip:nil poster:nil];
        [_wall removeFromSuperview];
        _wall = nil;
        _dots = _holes = _clipStill = nil;
        _clipLayer = nil;
        memset(&_drawn, 0, sizeof _drawn);
    }
    [self setNeedsLayout];
}

// The defaults change on any thread; the dots are laid out again on main when theirs did.
- (void)wallSettingsChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_mosaic) return;
        CGFloat pitch = [self wantedPitch], light = SGRMosaicSize() / 100.0;
        if (pitch != self->_pitch || light != self->_light) [self setNeedsLayout];
    });
}

// Whole points, so the mask's pattern and the dots' pixels stay in step across the wall.
- (CGFloat)wantedPitch {
    CGFloat width = self.window.bounds.size.width ?: self.bounds.size.width;
    return MAX(4, floor(width / SGRMosaicDots()));
}

// One dot of the wall's mask: a round light, `light` of its cell of `pitch` points.
static UIImage *lightImage(CGFloat pitch, CGFloat light) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(pitch, pitch)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat inset = pitch * (1 - light) / 2;
        [UIColor.whiteColor setFill];
        if (light >= 1) UIRectFill(CGRectMake(0, 0, pitch, pitch));
        else [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(inset, inset, pitch - 2 * inset, pitch - 2 * inset)] fill];
    }];
}

#pragma mark - the animated cover

// Plays `file` in the cover's square, looping and muted, its poster there until the video draws; nil takes it off.
- (void)playClip:(NSURL *)file poster:(UIImage *)poster {
    if ((file == _clipFile || [file isEqual:_clipFile]) && (file || !_clipPlayer)) return;
    [_clipPlayer pause];
    _clipLayer.player = nil;
    _clipPlayer = nil;
    _clipLooper = nil;
    _clipFile = file;
    _frames = nil;
    _frameBusy = NO;
    if (!file || !_clipStill) {
        _clipStill.hidden = YES;
        _clipStill.contents = nil;
        if (_clipFrame) {
            _clipFrame = nil;
            [self sampleArtwork];   // back to the cover's colors
        }
        return;
    }
    _clipStill.contents = (__bridge id)poster.CGImage;
    // The dots take the clip's colors: its poster at once, then its frames as it plays.
    _clipFrame = poster;
    _frames = [AVAssetImageGenerator assetImageGeneratorWithAsset:[AVURLAsset URLAssetWithURL:file options:nil]];
    _frames.maximumSize = CGSizeMake(96, 96);
    _frames.appliesPreferredTrackTransform = YES;
    _frames.requestedTimeToleranceBefore = _frames.requestedTimeToleranceAfter = CMTimeMakeWithSeconds(0.1, 600);
    if (poster) [self sampleArtwork];
    _clipPlayer = [AVQueuePlayer new];
    _clipPlayer.muted = YES;
    _clipPlayer.preventsDisplaySleepDuringVideoPlayback = NO;
    _clipLooper = [AVPlayerLooper playerLooperWithPlayer:_clipPlayer templateItem:[AVPlayerItem playerItemWithURL:file]];
    _clipLayer.player = _clipPlayer;
    _clipStill.hidden = NO;
    [self placeClip];
    [self updateMotion];
}

// The clip's frame now, read off its file away from the main thread, for the dots' colors. One at a time.
- (void)readClipFrame {
    if (!_frames || _frameBusy || !_clipPlayer || _clipStill.hidden) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _frameAt < kFrameEvery) return;
    _frameAt = now;
    _frameBusy = YES;
    AVAssetImageGenerator *frames = _frames;
    __weak SGRVisualiserView *weakSelf = self;
    [frames generateCGImageAsynchronouslyForTime:_clipPlayer.currentTime completionHandler:^(CGImageRef image, CMTime actual, NSError *error) {
        UIImage *frame = image ? [UIImage imageWithCGImage:image] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            SGRVisualiserView *view = weakSelf;
            if (!view || view->_frames != frames) return;
            view->_frameBusy = NO;
            if (!frame) return;
            view->_clipFrame = frame;
            view->_blendNext = YES;
            [view sampleArtwork];
        });
    }];
}

// Over the cover's square, as large and as round as it is drawn now.
- (void)placeClip {
    if (!_clipStill || _clipStill.hidden) return;
    CGRect cover = [self coverRect];
    if (CGRectEqualToRect(cover, _clipStill.frame)) return;
    _clipStill.frame = cover;
    _clipStill.cornerRadius = round(cover.size.width * kClipCorner);
    _clipLayer.frame = _clipStill.bounds;
}

// A dot a cell of the settings' size, as many as cover the bounds, the grid centered across.
- (void)layOutWall {
    CGRect bounds = self.bounds;
    _wall.frame = bounds;
    CGFloat pitch = [self wantedPitch], light = SGRMosaicSize() / 100.0;
    if (pitch != _pitch || light != _light) {
        _pitch = pitch;
        _light = light;
        _holes.backgroundColor = [UIColor colorWithPatternImage:lightImage(pitch, light)].CGColor;
        _columns = _rows = 0;
    }
    int columns = (int)ceil(bounds.size.width / pitch), rows = (int)ceil(bounds.size.height / pitch);
    CGRect frame = CGRectMake(floor((bounds.size.width - columns * pitch) / 2), 0, columns * pitch, rows * pitch);
    _dots.frame = frame;
    _holes.frame = (CGRect){CGPointZero, frame.size};
    [self placeClip];
    if (columns == _columns && rows == _rows) return;
    _columns = columns;
    _rows = rows;
    free(_samples);
    free(_pixels);
    _samples = calloc((size_t)MAX(columns * rows, 1) * 3, sizeof(float));
    _pixels = calloc((size_t)MAX(columns * rows, 1) * 4, 1);
    memset(&_lit, 0, sizeof _lit);
    [self sampleArtwork];
}

// The cover (or the frame of its animated cover playing) stretched over the grid, a pixel a dot, in the cover's
// color and brightness: a dark part of the cover lights dim, a bright part bright, gray as gray.
- (void)sampleArtwork {
    CGImageRef source = (_clipFrame ?: _artwork).CGImage;
    BOOL blend = _blendNext;
    _blendNext = NO;
    if (!_samples || !source) return;
    int columns = _columns, rows = _rows;
    uint8_t *rgba = calloc((size_t)columns * rows * 4, 1);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(rgba, columns, rows, 8, columns * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(space);
    if (context) {
        CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
        CGContextDrawImage(context, CGRectMake(0, 0, columns, rows), source);
        CGContextRelease(context);
    }
    for (int i = 0; i < columns * rows; i++) {
        float r = rgba[i * 4] / 255.0f, g = rgba[i * 4 + 1] / 255.0f, b = rgba[i * 4 + 2] / 255.0f;
        float most = fmaxf(r, fmaxf(g, b)), least = fminf(r, fminf(g, b));
        // The cover's own brightness, so a dark part of it lights dim and a bright part bright.
        float value = kValueFloor + (1 - kValueFloor) * most;
        if (most < 0.06f || most - least < 0.04f) {
            r = g = b = value;
        } else {
            // The saturation lifted a little so a pale cover's lights still have a hue, then the cover's brightness.
            r /= most; g /= most; b /= most;
            float low = fminf(r, fminf(g, b)), lift = fminf(1, 1.25f * (1 - low)) / fmaxf(1 - low, 0.001f);
            r = (1 - (1 - r) * lift) * value; g = (1 - (1 - g) * lift) * value; b = (1 - (1 - b) * lift) * value;
        }
        float keep = blend ? kFrameKeep : 0;
        _samples[i * 3] = keep * _samples[i * 3] + (1 - keep) * r;
        _samples[i * 3 + 1] = keep * _samples[i * 3 + 1] + (1 - keep) * g;
        _samples[i * 3 + 2] = keep * _samples[i * 3 + 2] + (1 - keep) * b;
    }
    free(rgba);
    memset(&_lit, 0, sizeof _lit);
    [self draw];
}

// Where the bars stand out of, in the view's coordinates.
- (CGRect)coverRect {
    CGRect bounds = self.bounds;
    if (_followsCover) {
        CGRect cover = SGRPlayerCoverFrameIn(self);
        if (!CGRectIsNull(cover) && cover.size.width > 0) return cover;
    }
    CGFloat side = round(MIN(bounds.size.width, bounds.size.height) * 0.42);
    return CGRectMake(round((bounds.size.width - side) / 2), round((bounds.size.height - side) / 2.6), side, side);
}

// Each dot outside the cover belongs to a band by its direction from the cover's middle, the bass straight out
// of the sides and the treble out of the top and foot, mirrored all four ways, and lights while the band's bar
// reaches it: how far it stands from the cover's nearest edge, in dots. The slower `back` levels leave a dimmer
// trail behind a falling bar. Unlit, a dot glows faintly in its color; the kick lifts the whole wall a little.
// Only the part of a band's level over the threshold reaches out. A ring of dark dots kBorder wide stands around
// the cover.
- (void)drawWall {
    CGRect bounds = self.bounds, cover = [self coverRect];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self placeClip];
    [CATransaction commit];
    if (!_pixels || !_columns) return;
    [self readClipFrame];
    float threshold = SGRMosaicThreshold() / 100.0f;
    if (CGRectEqualToRect(bounds, _lit.bounds) && CGRectEqualToRect(cover, _lit.cover) && _pulse == _lit.pulse && threshold == _lit.threshold
        && !memcmp(_front, _lit.front, sizeof _front) && !memcmp(_back, _lit.back, sizeof _back)) return;
    _lit.threshold = threshold;
    _lit.bounds = bounds;
    _lit.cover = cover;
    _lit.pulse = _pulse;
    memcpy(_lit.front, _front, sizeof _front);
    memcpy(_lit.back, _back, sizeof _back);

    CGFloat originX = _dots.frame.origin.x, reach = MAX(bounds.size.width, bounds.size.height) * kReach / _pitch;
    CGFloat midX = CGRectGetMidX(cover), midY = CGRectGetMidY(cover);
    CGFloat halfW = MAX(cover.size.width / 2, 1), halfH = MAX(cover.size.height / 2, 1);
    float glow = kUnlit + kUnlitPulse * _pulse;
    CGFloat border = MAX(kBorder, _pitch);
    for (int row = 0; row < _rows; row++) {
        CGFloat y = (row + 0.5) * _pitch;
        for (int column = 0; column < _columns; column++) {
            CGFloat x = originX + (column + 0.5) * _pitch;
            CGFloat outX = MAX(MAX(CGRectGetMinX(cover) - x, x - CGRectGetMaxX(cover)), 0);
            CGFloat outY = MAX(MAX(CGRectGetMinY(cover) - y, y - CGRectGetMaxY(cover)), 0);
            int i = row * _columns + column;
            float level = 0;
            CGFloat out = MAX(outX, outY);
            if (out > 0 && out < border) {
                memset(_pixels + i * 4, 0, 3);
                _pixels[i * 4 + 3] = 255;
                continue;
            }
            if (out > 0) {
                double angle = atan2(fabs(y - midY) / halfH, fabs(x - midX) / halfW) / M_PI_2;
                int band = kFirst + (int)lround(angle * (kShown - 1));
                float distance = (float)((out - border) / _pitch);
                float frontLevel = fmaxf(0, (_front[band] - threshold) / (1 - threshold));
                float backLevel = fmaxf(0, (_back[band] - threshold) / (1 - threshold));
                float front = powf(frontLevel, 1.2f) * (float)reach, back = powf(backLevel, 1.2f) * (float)reach;
                float lit = fminf(1, fmaxf(0, front - distance + 0.5f));
                float trail = kTrail * fminf(1, fmaxf(0, back - distance + 0.5f));
                level = fmaxf(lit, trail);
            }
            float brightness = glow + (1 - glow) * level;
            const float *color = _samples + i * 3;
            uint8_t *pixel = _pixels + i * 4;
            pixel[0] = (uint8_t)lroundf(255 * color[0] * brightness);
            pixel[1] = (uint8_t)lroundf(255 * color[1] * brightness);
            pixel[2] = (uint8_t)lroundf(255 * color[2] * brightness);
            pixel[3] = 255;
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(_pixels, _columns, _rows, 8, _columns * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(space);
    if (!context) return;
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _dots.contents = (__bridge id)image;
    [CATransaction commit];
    CGImageRelease(image);
}

@end

#pragma mark - in the player

static SGRVisualiserView *sg_view;

BOOL SGRPlayerVisualiserShowing(void) {
    SGRPlayerBackgroundKind kind = SGRPlayerBackground();
    return kind == SGRPlayerBackgroundVisualiser || kind == SGRPlayerBackgroundMosaic;
}

UIView *SGRPlayerVisualiserPreview(void) {
    SGRVisualiserView *preview = [[SGRVisualiserView alloc] initWithFrame:CGRectZero];
    preview.mosaic = SGRPlayerBackground() == SGRPlayerBackgroundMosaic;
    return preview;
}

void SGRPlayerMosaicSetClip(NSURL *file, UIImage *poster) {
    sg_clipFile = file;
    sg_clipPoster = poster;
    [sg_view playClip:file poster:poster];
}

BOOL SGRPlayerMosaicClipShowing(void) {
    return sg_clipFile != nil && sg_view.mosaic;
}

void SGRPlayerMosaicCoverMoved(void) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [sg_view placeClip];
    [CATransaction commit];
}

// The hills from the top of the field to the foot of its bleed, standing on the screen's foot.
static void layOut(SGRArtworkField *field) {
    if (sg_view.superview != field) [field addSubview:sg_view];
    else if (field.subviews.lastObject != sg_view) [field bringSubviewToFront:sg_view];
    CGSize size = field.bounds.size;
    CGFloat screen = field.window.bounds.size.height ?: size.height;
    CGRect frame = CGRectMake(0, 0, size.width, MAX(size.height, screen) + field.bleed.bottom);
    if (!CGRectEqualToRect(sg_view.frame, frame)) sg_view.frame = frame;
    sg_view.baseline = screen;
    sg_view.screenHeight = screen;
}

void SGRPlayerVisualiserUpdate(void) {
    SGRArtworkField *field = SGRPlayerField();
    // Not over an Animated artwork clip still playing: the Player page can change the choice under it, which the
    // player takes up when it next starts.
    BOOL wanted = SGRPlayerVisualiserShowing() && field && !SGRPlayerMotionShowing();
    if (!wanted) {
        SGRVisualiserView *old = sg_view;
        sg_view = nil;
        if (old.mosaic) SGRPlayerTextShadowsChanged();
        if (old.window) [old disappear:^{ [old removeFromSuperview]; }];
        else [old removeFromSuperview];
        return;
    }
    BOOL made = !sg_view;
    if (made) {
        sg_view = [[SGRVisualiserView alloc] initWithFrame:CGRectZero];
        sg_view.followsCover = YES;
    }
    BOOL mosaic = SGRPlayerBackground() == SGRPlayerBackgroundMosaic;
    if (sg_view.mosaic != mosaic) {
        sg_view.mosaic = mosaic;
        if (mosaic) [sg_view playClip:sg_clipFile poster:sg_clipPoster];
        SGRPlayerTextShadowsChanged();
    }
    layOut(field);
    if (made) {
        [sg_view setBlurred:SGRPlayerLyricsOpen() animated:NO];
        [sg_view appear:field.window != nil];
        SGLog(@"redesign player: visualizer on the field");
    } else {
        BOOL open = SGRPlayerLyricsOpen();
        if (open != sg_view.blurred) [sg_view setBlurred:open animated:sg_view.window != nil];
    }
}

#pragma mark - the ⋯ menu's switch

void SGRPlayerMenuSetBackground(SGRPlayerBackgroundKind kind) {
    SGRPlayerBackgroundKind current = SGRPlayerBackground();
    if (!SGPlayerMenuOffersAnimatedArtwork() || kind < SGRPlayerBackgroundFluid || kind == current) return;
    // Animated's own switch lets the clip go or looks it up, and calls back here.
    if (kind == SGRPlayerBackgroundAnimated || current == SGRPlayerBackgroundAnimated) SGPlayerMenuSetAnimatedArtwork(kind == SGRPlayerBackgroundAnimated);
    if (kind != SGRPlayerBackgroundAnimated) SGSetInt(SGRKeyPlayerBackground, kind);
    SGLog(@"redesign player: background switched to %@ from the menu", SGRPlayerBackgroundNames()[(NSUInteger)kind]);
    SGRPlayerHoldField();
    SGRPlayerVisualiserUpdate();
    // Mosaic plays the animated cover in the square: the track is looked up again for it, or let go.
    if (kind == SGRPlayerBackgroundMosaic || current == SGRPlayerBackgroundMosaic) SGRPlayerMotionRestart();
}
