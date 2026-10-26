// Records: the albums of the library, the ones saved on Spotify and the local ones (LocalAlbumsPage.m), as a crate
// of records flipped through. Opened from a tab of its own, vitrine:records (Shared/Navigation/Links.h), which the
// bar gets once (Navbar.h, SGRNavbarAddTabOnce) and the Add a Tab presets offer after that.
//
// The crate: every record is its cover with a label strip along its bottom edge, the title and the artist, leaning
// back about that edge, all of them alike, so a little of each cover shows over its label. Scrolling moves the
// crate along and settles with a record at the focus, whose cover is behind the crate, blurred and darkened.
//
// A tap on a record pulls it out: it lifts out and stands up in the middle, over the crate dimmed, its title and
// artist under it, as a sleeve: its front, its back, and its edges. Dragging across it turns it over; a gatefold
// sleeve has Open Gatefold under it, which swings the front open on its left edge to show the inside. A tap on it
// opens its album, pushed onto the tab's stack over the crate (the record still out on the way back); a tap anywhere
// else puts it back.
//
// A local album wears the pictures that came with its songs when it was imported from a link (DriveImport.h): its
// front, back, spine, sticker and inside, as a scanned sleeve is worn. Else, with Vinyl Scans on (the menu), a record
// wears its sleeve as a vinyl pressing of it was scanned (its cover staying the streaming one, unless the user
// picks their own), front, back,
// spine, hype sticker and gatefold, when the Cover Art Archive has them (RecordScans.h); a sticker scanned on its own
// goes on the front's top right corner, where one usually is. A record with no scanned back has one drawn, its
// tracks listed in the cover's colors, and a label strip with no spine scan is drawn in them too: the cover's most
// common color behind, and the one of its colors that reads best on that for the text.
//
// Light: in the crate each cover is shaded where the record above meets it and toward its own bottom edge, and the
// records further from the focus sit in the dark; a record out of the crate casts a shadow behind it, catches a
// sheen that slides across it as it turns, and goes dark on the side turned from the light. A hype sticker is a
// layer of its own over the cover, glossier than the cover: a band of light crosses it, clear from corner to corner,
// as the crate scrolls past and as its record is turned, and stays put while nothing moves.
//
// Customize, under a record out of the crate, picks a picture of the user's own for any part of its sleeve, from
// Photos or Files, in place of the one found (RecordCustom.h); takes its hype sticker off, or moves it, dragged on
// the front where it should sit.
//
// Spotify's albums are the Web API's saved albums (GET /v1/me/albums, Shared/Navigation/WebAPI.h), every page of
// them, kept for the next open; the local ones come from Shared/LocalFiles/LocalAlbums.h. Both are listed newest
// first by when they were added, or by title or artist.
//
// Threading: main thread only.
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Core/SGCore.h"
#import "Redesigned/Navbar/Navbar.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/LocalFiles/DriveImport.h"
#import "Shared/LocalFiles/LocalAlbums.h"
#import "Shared/Navigation/AddTabSheet.h"
#import "Shared/Navigation/Links.h"
#import "Shared/Navigation/TabIcons.h"
#import "Shared/Navigation/WebAPI.h"
#import "Library.h"
#import "RecordCustom.h"
#import "RecordScans.h"

static NSString *const kRecordsURI = @"vitrine:records";
#define SGKeyRecordsSort @"spotifyglass.records.sort"
#define SGKeyRecordsShow @"spotifyglass.records.show"
#define SGKeyRecordsTabAdded @"spotifyglass.records.tabAdded"
// The sleeves' scans; on unless switched off.
#define SGKeyRecordsScans @"spotifyglass.records.scans"

// The crate: where the focus sits down the page, how far every record leans back from upright (degrees), the room
// between records, the label's depth, the perspective's distance and the widest cover.
static const CGFloat kFocusY = 0.42, kTilt = 78, kGap = 6, kSpine = 18, kPerspective = 2400, kMaxWidth = 340;
// Records further than this from the focus let their pictures go; the sleeves are looked for this close to it.
static const NSInteger kKeepPictures = 30, kScanReach = 6;
// A record out of the crate: how far it still leans back, its perspective, how dark the crate goes behind it, the
// room under it for its title, artist and the gatefold's button, the sleeve's thickness, and a hype sticker's width
// as a share of the cover's.
// The light: how dark the records furthest from the focus get, how dark a cover turned away from the light gets, the
// shadow behind a record out of the crate.
static const CGFloat kFarDark = 0.55, kTurnedDark = 0.6, kFloorShadow = 0.75;
// A picture picked from Photos or Files is made no larger than this on its longer side before it is kept.
static const CGFloat kPickedLongest = 1600;
// The sleeve out of the crate is as thick as the label strip along its bottom edge, as in the crate.
static const CGFloat kPulledTilt = 4, kPulledPerspective = 1400, kPulledDim = 0.55, kCaption = 110, kSticker = 0.26;
// The Customize button's size and its room from the corner.
static const CGFloat kCornerButton = 40, kCornerRoom = 16;

typedef NS_ENUM(NSInteger, SGRRecordsSort) {
    SGRRecordsSortAdded,
    SGRRecordsSortTitle,
    SGRRecordsSortArtist,
};

typedef NS_ENUM(NSInteger, SGRRecordsShow) {
    SGRRecordsShowAll,
    SGRRecordsShowSpotify,
    SGRRecordsShowLocal,
};

#pragma mark - a record

@interface SGRRecord : NSObject
@property (nonatomic, copy) NSString *title, *artist;
// spotify:album:<id>, or nil for a local album.
@property (nonatomic, copy) NSString *uri;
// The cover's address, Spotify's only.
@property (nonatomic, copy) NSString *picture;
// Spotify's album_type: album, single, ep or compilation.
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, strong) SGLocalAlbum *local;
@property (nonatomic, strong) NSDate *added;
// What tells it apart from every other record: its URI, or a local album's names.
- (NSString *)key;
@end

@implementation SGRRecord

- (NSString *)key {
    return self.uri ?: [NSString stringWithFormat:@"local:%@:%@", self.title, self.artist];
}

@end

// Spotify's saved albums as last read, for the next open to show at once.
static NSArray<SGRRecord *> *sg_savedAlbums;

static NSDate *dateOf(NSString *text) {
    static NSISO8601DateFormatter *format;
    if (!format) format = [NSISO8601DateFormatter new];
    return [text isKindOfClass:NSString.class] ? [format dateFromString:text] : nil;
}

static SGRRecord *recordOfSaved(id item) {
    if (![item isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *album = item[@"album"];
    if (![album isKindOfClass:NSDictionary.class] || ![album[@"uri"] isKindOfClass:NSString.class]) return nil;
    SGRRecord *record = [SGRRecord new];
    record.uri = album[@"uri"];
    record.title = [album[@"name"] isKindOfClass:NSString.class] ? album[@"name"] : @"";
    record.kind = [album[@"album_type"] isKindOfClass:NSString.class] ? album[@"album_type"] : @"album";
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id artist in [album[@"artists"] isKindOfClass:NSArray.class] ? album[@"artists"] : @[]) {
        if ([artist isKindOfClass:NSDictionary.class] && [artist[@"name"] isKindOfClass:NSString.class]) [names addObject:artist[@"name"]];
    }
    record.artist = [names componentsJoinedByString:@", "];
    // The largest picture, which the list gives first.
    id images = album[@"images"];
    id first = [images isKindOfClass:NSArray.class] ? [images firstObject] : nil;
    if ([first isKindOfClass:NSDictionary.class] && [first[@"url"] isKindOfClass:NSString.class]) record.picture = first[@"url"];
    record.added = dateOf(item[@"added_at"]) ?: NSDate.distantPast;
    return record;
}

// Every page of the saved albums, `done` once with all of them, or nil when the first page could not be read.
static void readSavedAlbums(NSMutableArray<SGRRecord *> *sofar, NSString *path, void (^done)(NSArray<SGRRecord *> *albums)) {
    SGWebAPI(@"GET", path, ^(NSInteger status, id answer) {
        if (status != 200 || ![answer isKindOfClass:NSDictionary.class]) {
            SGLog(@"records: saved albums answered %ld after %lu", (long)status, (unsigned long)sofar.count);
            done(sofar.count ? sofar : nil);
            return;
        }
        for (id item in [answer[@"items"] isKindOfClass:NSArray.class] ? answer[@"items"] : @[]) {
            SGRRecord *record = recordOfSaved(item);
            if (record) [sofar addObject:record];
        }
        NSString *next = answer[@"next"];
        NSString *base = @"https://api.spotify.com/v1/";
        if ([next isKindOfClass:NSString.class] && [next hasPrefix:base]) readSavedAlbums(sofar, [next substringFromIndex:base.length], done);
        else done(sofar);
    });
}

static NSString *localKind(SGLocalAlbum *album) {
    switch (SGLocalAlbumShownType(album)) {
        case SGLocalAlbumTypeSingle: return @"single";
        case SGLocalAlbumTypeEP: return @"ep";
        case SGLocalAlbumTypeCompilation: return @"compilation";
        default: return @"album";
    }
}

static NSArray<SGRRecord *> *localRecords(void) {
    NSMutableArray<SGRRecord *> *records = [NSMutableArray array];
    for (SGLocalAlbum *album in SGLocalAlbums()) {
        if (!album.tracks.count) continue;
        SGRRecord *record = [SGRRecord new];
        record.title = album.title;
        record.artist = album.artist;
        record.kind = localKind(album);
        record.local = album;
        record.added = album.added ?: NSDate.distantPast;
        [records addObject:record];
    }
    return records;
}

#pragma mark - geometry

static CGFloat radians(CGFloat degrees) {
    return degrees * M_PI / 180;
}

// A record turned `turn` radians about its upright middle, then `between` (an open gatefold's move), leaned back
// `tilt` degrees about its bottom edge, and seen in perspective from `distance` away, from in front of its own
// middle, so every record in the crate looks alike. The layer's anchor is the middle of the bottom edge; `width` is
// the cover's.
static CATransform3D recordPose(CGFloat turn, CATransform3D between, CGFloat tilt, CGFloat distance, CGFloat width) {
    CATransform3D perspective = CATransform3DIdentity;
    perspective.m34 = -1 / distance;
    CATransform3D t = CATransform3DMakeRotation(turn, 0, 1, 0);
    t = CATransform3DConcat(t, between);
    t = CATransform3DConcat(t, CATransform3DMakeRotation(radians(tilt), 1, 0, 0));
    t = CATransform3DConcat(t, CATransform3DMakeTranslation(0, width / 2, 0));
    t = CATransform3DConcat(t, perspective);
    return CATransform3DConcat(t, CATransform3DMakeTranslation(0, -width / 2, 0));
}

static CGPoint project(CATransform3D t, CGFloat x, CGFloat y, CGFloat z) {
    CGFloat w = x * t.m14 + y * t.m24 + z * t.m34 + t.m44;
    if (w <= 0.001) w = 0.001;
    return CGPointMake((x * t.m11 + y * t.m21 + z * t.m31 + t.m41) / w, (x * t.m12 + y * t.m22 + z * t.m32 + t.m42) / w);
}

static CALayer *panel(CGRect frame, UIImage *picture, UIColor *color) {
    CALayer *layer = [CALayer layer];
    layer.frame = frame;
    layer.contents = (id)picture.CGImage;
    layer.contentsGravity = kCAGravityResizeAspectFill;
    layer.masksToBounds = YES;
    layer.backgroundColor = color.CGColor;
    layer.contentsScale = UIScreen.mainScreen.scale;
    return layer;
}

// Where a sticker's middle sits on the front by default, in shares of its side: where one usually is, on the top
// right corner.
static CGPoint defaultStickerCenter(UIImage *sticker) {
    CGFloat height = sticker.size.width > 0 ? kSticker * sticker.size.height / sticker.size.width : kSticker;
    return CGPointMake(1 - 0.04 - kSticker / 2, 0.04 + height / 2);
}

// A hype sticker as its own layer, `width` the cover's: the sticker, its shadow on the cover, and a band of light
// (cut to the sticker's shape) that is moved across it (shine()).
static CALayer *stickerLayer(UIImage *sticker, CGFloat width) {
    CALayer *layer = [CALayer layer];
    CGFloat w = width * kSticker, h = w * sticker.size.height / MAX(sticker.size.width, 1);
    layer.bounds = CGRectMake(0, 0, w, h);
    layer.contents = (id)sticker.CGImage;
    layer.contentsGravity = kCAGravityResize;
    layer.contentsScale = UIScreen.mainScreen.scale;
    layer.shadowOpacity = 0.4;
    layer.shadowRadius = 1.5;
    layer.shadowOffset = CGSizeMake(0, 1);
    // The light, cut to the sticker's shape: a sheen all over, and a band on a layer three times the sticker's size,
    // moved across it so it comes in past one corner and goes out past the other.
    CALayer *clip = [CALayer layer];
    clip.frame = layer.bounds;
    CALayer *shape = [CALayer layer];
    shape.frame = clip.bounds;
    shape.contents = (id)sticker.CGImage;
    shape.contentsGravity = kCAGravityResize;
    clip.mask = shape;
    clip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    CAGradientLayer *band = [CAGradientLayer layer];
    band.bounds = CGRectMake(0, 0, w * 3, h * 3);
    band.startPoint = CGPointMake(0, 0);
    band.endPoint = CGPointMake(1, 1);
    UIColor *none = [UIColor colorWithWhite:1 alpha:0], *light = [UIColor colorWithWhite:1 alpha:0.85];
    band.colors = @[(id)none.CGColor, (id)light.CGColor, (id)none.CGColor];
    band.locations = @[@0.44, @0.5, @0.56];
    [clip addSublayer:band];
    [layer addSublayer:clip];
    return layer;
}

static NSArray<NSNumber *> *bandAt(CGFloat place) {
    CGFloat p = MIN(MAX(place, 0.13), 0.87);
    return @[@0, @(p - 0.12), @(p), @(p + 0.12), @1];
}

// The band of light across a sticker at `place`: 0 and below clear of its top left corner, 1 and above clear of its
// bottom right, in between across it. Never animated: it moves only as the record does.
static void shine(CALayer *sticker, CGFloat place) {
    CALayer *band = sticker.sublayers.firstObject.sublayers.firstObject;
    CGSize size = sticker.bounds.size;
    CGFloat along = (MIN(MAX(place, -0.2), 1.2) - 0.5) * 2;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    band.position = CGPointMake(size.width / 2 + along * size.width, size.height / 2 + along * size.height);
    [CATransaction commit];
}

// A picture picked by the user no larger than kPickedLongest on its longer side, its orientation drawn in.
static UIImage *fitted(UIImage *picture) {
    CGFloat longest = MAX(picture.size.width, picture.size.height);
    CGFloat scale = longest > kPickedLongest ? kPickedLongest / longest : 1;
    CGSize size = CGSizeMake(round(picture.size.width * scale), round(picture.size.height * scale));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [picture drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

#pragma mark - the page

@interface SGRRecordsPage : SGPage <UIGestureRecognizerDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@end

@implementation SGRRecordsPage {
    NSArray<SGRRecord *> *_records;
    NSArray<CATransformLayer *> *_layers;
    NSArray<CALayer *> *_faces, *_spines;
    // The covers, the fronts to show (a scan with its sticker on), the drawn backs, the sleeves found, the label
    // colors taken from the covers and the track names, by record key.
    NSCache<NSString *, UIImage *> *_pictures, *_fronts, *_backs;
    NSMutableDictionary<NSString *, SGRSleeve *> *_sleeves;
    NSMutableDictionary<NSString *, NSArray<UIColor *> *> *_colors;
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *_tracks;
    NSMutableSet<NSString *> *_asked, *_sleevesAsked, *_tracksAsked;
    // The records wearing their own pictures from an import, whatever Vinyl Scans is.
    NSMutableSet<NSString *> *_ownSleeves;
    // The records looked for again on being pulled out, this visit.
    NSMutableSet<NSString *> *_lookedAgain;
    UIImageView *_backdrop;
    UIView *_stage;
    CALayer *_dim;
    UILabel *_note, *_pulledTitle, *_pulledArtist;
    UIButton *_gateButton, *_customButton;
    // The light on each record in the crate: the shading on its cover, and the dark over its cover and its label.
    NSArray<CAGradientLayer *> *_shades;
    NSArray<CALayer *> *_veils, *_spineVeils;
    // The stickers to wear, by record key ([picture, middle]), and the sticker layer on each record that wears one.
    NSMutableDictionary<NSString *, NSArray *> *_stickers;
    NSMutableDictionary<NSNumber *, CALayer *> *_stickerLayers;
    // The light on the record out of the crate: the shadow behind it, the sheen on its cover, the dark on its cover
    // and its back as they turn from the light.
    CALayer *_floor;
    CAGradientLayer *_gloss;
    CALayer *_frontShade, *_backShade;
    // The part a picture is being picked for, of which record; and the sticker being moved on the front.
    NSString *_pickingPart, *_pickingKey;
    BOOL _placing;
    CALayer *_placedSticker;
    CGPoint _stickerCenter;
    UIView *_spacer;
    CGFloat _width;
    NSInteger _focused;
    // The record pulled out of the crate, and the one going back into it; -1 for none.
    NSInteger _pulled, _returning;
    // The record out of the crate: its flap and other extra layers, how far it is turned (radians), and whether its
    // gatefold is open.
    CATransformLayer *_flap;
    NSArray<CALayer *> *_extras;
    CGFloat _turn, _turnStart;
    BOOL _opened;
    UIPanGestureRecognizer *_turner;
    BOOL _loading;
    UISelectionFeedbackGenerator *_tick;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStylePlain])) return nil;
    self.title = @"Records";
    _pictures = [NSCache new];
    _fronts = [NSCache new];
    _backs = [NSCache new];
    _sleeves = [NSMutableDictionary dictionary];
    _colors = [NSMutableDictionary dictionary];
    _tracks = [NSMutableDictionary dictionary];
    _asked = [NSMutableSet set];
    _sleevesAsked = [NSMutableSet set];
    _tracksAsked = [NSMutableSet set];
    _ownSleeves = [NSMutableSet set];
    _lookedAgain = [NSMutableSet set];
    _stickers = [NSMutableDictionary dictionary];
    _stickerLayers = [NSMutableDictionary dictionary];
    _focused = _pulled = _returning = -1;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UITableView *table = self.tableView;
    table.separatorStyle = UITableViewCellSeparatorStyleNone;
    table.backgroundColor = UIColor.blackColor;
    table.showsVerticalScrollIndicator = NO;

    UIView *back = [[UIView alloc] initWithFrame:table.bounds];
    back.backgroundColor = UIColor.blackColor;
    back.clipsToBounds = YES;
    _backdrop = [[UIImageView alloc] initWithFrame:CGRectInset(back.bounds, -60, -60)];
    _backdrop.contentMode = UIViewContentModeScaleAspectFill;
    _backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [back addSubview:_backdrop];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    blur.frame = back.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [back addSubview:blur];
    UIView *dim = [[UIView alloc] initWithFrame:back.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [back addSubview:dim];
    _stage = [[UIView alloc] initWithFrame:back.bounds];
    _stage.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [back addSubview:_stage];
    // Over the crate while a record is out of it, under that record.
    _dim = [CALayer layer];
    _dim.backgroundColor = UIColor.blackColor.CGColor;
    _dim.opacity = 0;
    _dim.zPosition = 999;
    [_stage.layer addSublayer:_dim];
    // Behind the record out of the crate, over the dim.
    _floor = [CALayer layer];
    _floor.zPosition = 999.5;
    _floor.shadowColor = UIColor.blackColor.CGColor;
    _floor.shadowOpacity = 0;
    _floor.shadowRadius = 22;
    _floor.shadowOffset = CGSizeMake(0, 18);
    [_stage.layer addSublayer:_floor];
    _note = [UILabel new];
    _note.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    _note.font = [UIFont systemFontOfSize:15];
    _note.numberOfLines = 0;
    _note.textAlignment = NSTextAlignmentCenter;
    [back addSubview:_note];
    _pulledTitle = [UILabel new];
    _pulledTitle.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _pulledTitle.textColor = UIColor.whiteColor;
    _pulledTitle.textAlignment = NSTextAlignmentCenter;
    _pulledTitle.alpha = 0;
    [back addSubview:_pulledTitle];
    _pulledArtist = [UILabel new];
    _pulledArtist.font = [UIFont systemFontOfSize:15];
    _pulledArtist.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    _pulledArtist.textAlignment = NSTextAlignmentCenter;
    _pulledArtist.alpha = 0;
    [back addSubview:_pulledArtist];
    // Its taps are the table's (-tapped:), which knows where it is.
    UIButtonConfiguration *gate = [UIButtonConfiguration grayButtonConfiguration];
    gate.image = [UIImage systemImageNamed:@"book"];
    gate.imagePadding = 6;
    gate.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    gate.baseForegroundColor = UIColor.whiteColor;
    _gateButton = [UIButton buttonWithConfiguration:gate primaryAction:nil];
    _gateButton.userInteractionEnabled = NO;
    _gateButton.hidden = YES;
    [back addSubview:_gateButton];
    // Small, in the bottom right corner.
    UIButtonConfiguration *custom = [UIButtonConfiguration grayButtonConfiguration];
    custom.image = [UIImage systemImageNamed:@"paintbrush" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium]];
    custom.imagePadding = 6;
    custom.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    custom.baseForegroundColor = [UIColor colorWithWhite:1 alpha:0.85];
    custom.background.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    _customButton = [UIButton buttonWithConfiguration:custom primaryAction:nil];
    _customButton.userInteractionEnabled = NO;
    _customButton.hidden = YES;
    [back addSubview:_customButton];
    table.backgroundView = back;

    _spacer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    table.tableFooterView = _spacer;
    [table addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];
    _turner = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(turned:)];
    _turner.delegate = self;
    [table addGestureRecognizer:_turner];
    _tick = [UISelectionFeedbackGenerator new];

    [self updateMenu];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(rebuild) name:SGLocalAlbumsDidChangeNotification object:nil];
    [self rebuild];
    [self readSaved];
    SGLocalAlbumsRefresh(nil);
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// The crate is not drawn while the album page opened from it covers it; back from there, it is as it was left.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.tableView.backgroundView.hidden = NO;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    self.tableView.backgroundView.hidden = YES;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return 0;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
    UIView *back = self.tableView.backgroundView;
    _note.frame = CGRectInset(back.bounds, 32, 0);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _dim.frame = _stage.bounds;
    _floor.frame = _stage.bounds;
    [CATransaction commit];
    if (_width != [self recordWidth]) {
        [self dropPulled];
        [self makeLayers];
    }
    [self fitSpacer];
    [self render];
}

#pragma mark the list

- (SGRRecordsSort)sort {
    return (SGRRecordsSort)MIN(MAX(SGInt(SGKeyRecordsSort, SGRRecordsSortAdded), 0), 2);
}

- (SGRRecordsShow)show {
    return (SGRRecordsShow)MIN(MAX(SGInt(SGKeyRecordsShow, SGRRecordsShowAll), 0), 2);
}

- (BOOL)scans {
    return SGEnabled(SGKeyRecordsScans);
}

- (void)updateMenu {
    __weak SGRRecordsPage *weakSelf = self;
    UIMenu *(^choices)(NSString *, NSString *, NSArray<NSString *> *, NSInteger) = ^UIMenu *(NSString *title, NSString *key, NSArray<NSString *> *names, NSInteger current) {
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
            UIAction *choice = [UIAction actionWithTitle:names[(NSUInteger)i] image:nil identifier:nil handler:^(UIAction *action) {
                SGSetInt(key, i);
                [weakSelf updateMenu];
                [weakSelf rebuild];
            }];
            choice.state = i == current ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:choice];
        }
        return [UIMenu menuWithTitle:title image:nil identifier:nil options:UIMenuOptionsDisplayInline children:actions];
    };
    UIAction *scans = [UIAction actionWithTitle:@"Vinyl Scans" image:[UIImage systemImageNamed:@"opticaldisc"] identifier:nil handler:^(UIAction *action) {
        SGSetEnabled(SGKeyRecordsScans, !SGEnabled(SGKeyRecordsScans));
        [weakSelf updateMenu];
        [weakSelf redrawSleeves];
    }];
    scans.subtitle = @"The real sleeves, from the Cover Art Archive and Discogs";
    scans.state = [self scans] ? UIMenuElementStateOn : UIMenuElementStateOff;
    BOOL hasToken = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyDiscogsToken].length > 0;
    UIAction *discogs = [UIAction actionWithTitle:@"Discogs Token" image:[UIImage systemImageNamed:@"key"] identifier:nil handler:^(UIAction *action) {
        [weakSelf askDiscogsToken];
    }];
    discogs.subtitle = hasToken ? @"Set: Discogs is asked too" : @"Add yours to look on Discogs too";
    UIMenu *menu = [UIMenu menuWithChildren:@[
        choices(@"Sort By", SGKeyRecordsSort, @[@"Recently Added", @"Title", @"Artist"], [self sort]),
        choices(@"Show", SGKeyRecordsShow, @[@"All Albums", @"Spotify", @"Local Albums"], [self show]),
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[scans, discogs]],
    ]];
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease"] menu:menu];
    item.accessibilityLabel = @"Sort and Filter";
    self.navigationItem.rightBarButtonItem = item;
}

// The user's Discogs token, which Discogs's database asks of any program: made at discogs.com > Settings >
// Developers > Generate new token. Kept on the phone only. Setting it looks again for every sleeve not found.
- (void)askDiscogsToken {
    UIAlertController *ask = [UIAlertController alertControllerWithTitle:@"Discogs Token"
        message:@"Discogs answers only signed-in apps. Make a personal access token at discogs.com, Settings, Developers, Generate new token, and paste it here. It stays on this phone."
        preferredStyle:UIAlertControllerStyleAlert];
    NSString *now = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyDiscogsToken];
    [ask addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Token";
        field.text = now;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.secureTextEntry = YES;
    }];
    __weak SGRRecordsPage *weakSelf = self;
    __weak UIAlertController *weakAsk = ask;
    void (^keep)(NSString *) = ^(NSString *token) {
        token = [token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (token.length) [NSUserDefaults.standardUserDefaults setObject:token forKey:SGKeyDiscogsToken];
        else [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyDiscogsToken];
        SGRRecordScansForgetMissing();
        SGRRecordsPage *page = weakSelf;
        if (!page) return;
        [page->_lookedAgain removeAllObjects];
        [page updateMenu];
        [page redrawSleeves];
    };
    [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (now.length) {
        [ask addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { keep(nil); }]];
    }
    [ask addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        keep(weakAsk.textFields.firstObject.text ?: @"");
    }]];
    [self presentViewController:ask animated:YES completion:nil];
}

- (void)readSaved {
    _loading = !sg_savedAlbums;
    [self updateNote];
    __weak SGRRecordsPage *weakSelf = self;
    readSavedAlbums([NSMutableArray array], @"me/albums?limit=50", ^(NSArray<SGRRecord *> *albums) {
        SGRRecordsPage *page = weakSelf;
        if (albums) {
            NSArray<NSString *> *(^keys)(NSArray<SGRRecord *> *) = ^NSArray<NSString *> *(NSArray<SGRRecord *> *list) {
                NSMutableArray<NSString *> *all = [NSMutableArray array];
                for (SGRRecord *record in list) [all addObject:[record key]];
                return all;
            };
            BOOL same = sg_savedAlbums && [keys(sg_savedAlbums) isEqualToArray:keys(albums)];
            sg_savedAlbums = albums;
            if (page && !same) [page rebuild];
        }
        if (page) {
            page->_loading = NO;
            [page updateNote];
        }
    });
}

- (void)rebuild {
    NSMutableArray<SGRRecord *> *records = [NSMutableArray array];
    SGRRecordsShow show = [self show];
    if (show != SGRRecordsShowLocal) [records addObjectsFromArray:sg_savedAlbums ?: @[]];
    if (show != SGRRecordsShowSpotify) [records addObjectsFromArray:localRecords()];
    SGRRecordsSort sort = [self sort];
    [records sortUsingComparator:^NSComparisonResult(SGRRecord *a, SGRRecord *b) {
        if (sort == SGRRecordsSortAdded) return [b.added compare:a.added];
        NSComparisonResult order = sort == SGRRecordsSortArtist ? [a.artist localizedStandardCompare:b.artist] : NSOrderedSame;
        return order != NSOrderedSame ? order : [a.title localizedStandardCompare:b.title];
    }];

    // The focused record stays focused when it is still there.
    SGRRecord *was = _focused >= 0 && _focused < (NSInteger)_records.count ? _records[(NSUInteger)_focused] : nil;
    [self dropPulled];
    _records = records;
    NSUInteger keep = NSNotFound;
    for (NSUInteger i = 0; was && i < records.count && keep == NSNotFound; i++) {
        if ([[records[i] key] isEqualToString:[was key]]) keep = i;
    }
    _focused = -1;
    [self makeLayers];
    [self fitSpacer];
    UITableView *table = self.tableView;
    CGFloat top = table.adjustedContentInset.top;
    [table setContentOffset:CGPointMake(0, (keep == NSNotFound ? 0 : (CGFloat)keep) * [self step] - top) animated:NO];
    [self updateNote];
    [self render];
}

- (void)updateNote {
    if (_records.count) _note.text = nil;
    else if (_loading) _note.text = @"Loading your albums…";
    else _note.text = [self show] == SGRRecordsShowLocal ? @"No local albums yet." : @"No albums yet. Albums you save on Spotify and your local albums show here.";
    _note.hidden = !_note.text;
}

// The table scrolls a record per step, the room one record takes in the crate: one screen past the last's place.
- (void)fitSpacer {
    UITableView *table = self.tableView;
    UIEdgeInsets inset = table.adjustedContentInset;
    CGFloat visible = MAX(0, table.bounds.size.height - inset.top - inset.bottom);
    CGFloat height = visible + (CGFloat)(_records.count ? _records.count - 1 : 0) * [self step];
    if (fabs(_spacer.frame.size.height - height) < 0.5) return;
    _spacer.frame = CGRectMake(0, 0, table.bounds.size.width, height);
    table.tableFooterView = _spacer;
}

#pragma mark the records

- (CGFloat)recordWidth {
    return floor(MIN(kMaxWidth, self.tableView.bounds.size.width * 0.8));
}

// From one record's bottom edge to the next's: the first one's label and the next one's cover, leaned back.
- (CGFloat)step {
    CGFloat width = _width > 0 ? _width : [self recordWidth];
    return MAX(1, kSpine * sin(radians(kTilt)) + width * cos(radians(kTilt)) + kGap);
}

- (void)makeLayers {
    for (CALayer *layer in _layers) [layer removeFromSuperlayer];
    _width = [self recordWidth];
    NSMutableArray<CATransformLayer *> *layers = [NSMutableArray array];
    NSMutableArray<CALayer *> *faces = [NSMutableArray array], *spines = [NSMutableArray array];
    NSMutableArray<CAGradientLayer *> *shades = [NSMutableArray array];
    NSMutableArray<CALayer *> *veils = [NSMutableArray array], *spineVeils = [NSMutableArray array];
    [_stickerLayers removeAllObjects];
    CGFloat side = _width;
    CGColorRef black = UIColor.blackColor.CGColor;
    UIColor *clear = [UIColor colorWithWhite:0 alpha:0];
    for (NSUInteger i = 0; i < _records.count; i++) {
        CATransformLayer *record = [CATransformLayer layer];
        record.bounds = CGRectMake(0, 0, side, side);
        record.anchorPoint = CGPointMake(0.5, 1);
        record.hidden = YES;
        CALayer *face = [CALayer layer];
        face.frame = record.bounds;
        face.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1].CGColor;
        face.contentsGravity = kCAGravityResizeAspectFill;
        face.masksToBounds = YES;
        face.borderWidth = 0.5;
        face.borderColor = [UIColor colorWithWhite:0 alpha:0.4].CGColor;
        face.contentsScale = UIScreen.mainScreen.scale;
        [record addSublayer:face];
        // The record above's edge darkens the top of the cover, and the cover darkens toward its own bottom edge,
        // where it meets the next.
        CAGradientLayer *shade = [CAGradientLayer layer];
        shade.frame = face.bounds;
        shade.colors = @[(__bridge id)[UIColor colorWithWhite:0 alpha:0.45].CGColor, (__bridge id)clear.CGColor, (__bridge id)clear.CGColor,
                         (__bridge id)[UIColor colorWithWhite:0 alpha:0.4].CGColor];
        shade.locations = @[@0, @0.2, @0.62, @1];
        [face addSublayer:shade];
        CALayer *veil = [CALayer layer];
        veil.frame = face.bounds;
        veil.backgroundColor = black;
        veil.opacity = 0;
        [face addSublayer:veil];
        // The label strip stands out behind the cover's bottom edge, so it hangs below the edge once leaned back.
        CALayer *spine = [CALayer layer];
        spine.bounds = CGRectMake(0, 0, side, kSpine);
        spine.anchorPoint = CGPointMake(0.5, 0);
        spine.position = CGPointMake(side / 2, side);
        spine.transform = CATransform3DMakeRotation(-M_PI_2, 1, 0, 0);
        spine.backgroundColor = [UIColor colorWithWhite:0.106 alpha:1].CGColor;
        spine.contentsScale = UIScreen.mainScreen.scale;
        // The label's edge catches the light along its top and falls into shadow along its bottom.
        CAGradientLayer *edge = [CAGradientLayer layer];
        edge.frame = spine.bounds;
        edge.colors = @[(__bridge id)[UIColor colorWithWhite:1 alpha:0.16].CGColor, (__bridge id)clear.CGColor,
                        (__bridge id)[UIColor colorWithWhite:0 alpha:0.35].CGColor];
        edge.locations = @[@0, @0.35, @1];
        [spine addSublayer:edge];
        CALayer *spineVeil = [CALayer layer];
        spineVeil.frame = spine.bounds;
        spineVeil.backgroundColor = black;
        spineVeil.opacity = 0;
        [spine addSublayer:spineVeil];
        [record addSublayer:spine];
        [_stage.layer addSublayer:record];
        [layers addObject:record];
        [faces addObject:face];
        [spines addObject:spine];
        [shades addObject:shade];
        [veils addObject:veil];
        [spineVeils addObject:spineVeil];
    }
    _layers = layers;
    _faces = faces;
    _spines = spines;
    _shades = shades;
    _veils = veils;
    _spineVeils = spineVeils;
}

- (SGRSleeve *)sleeveOf:(SGRRecord *)record {
    return [self sleeveWithKey:[record key]];
}

// The sleeve a record wears: the one found (scanned, or its import's pictures), with what the user picked over it.
- (SGRSleeve *)sleeveWithKey:(NSString *)key {
    SGRSleeve *found = [self scans] || [_ownSleeves containsObject:key] ? _sleeves[key] : nil;
    if (!SGRHasCustom(key)) return found;
    SGRSleeve *worn = [SGRSleeve new];
    worn.front = SGRCustomPicture(key, SGRPartFront) ?: found.front;
    worn.back = SGRCustomPicture(key, SGRPartBack) ?: found.back;
    UIImage *spine = SGRCustomPicture(key, SGRPartSpine);
    worn.spine = spine ? SGRLyingSpine(spine) : found.spine;
    worn.sticker = SGRCustomStickerHidden(key) ? nil : SGRCustomPicture(key, SGRPartSticker) ?: found.sticker;
    UIImage *left = SGRCustomPicture(key, SGRPartInsideLeft) ?: found.gatefold.firstObject;
    UIImage *right = SGRCustomPicture(key, SGRPartInsideRight) ?: (found.gatefold.count == 2 ? found.gatefold[1] : nil);
    if (left && right) worn.gatefold = @[left, right];
    return worn;
}

// The record's front as shown, with its sticker on where it sits, made again off main; just the cover when its
// sleeve has neither a front nor a sticker.
- (void)composeFrontOf:(NSString *)key {
    SGRSleeve *sleeve = [self sleeveWithKey:key];
    // The streaming cover, unless the user picked their own: a scan's front only tells the pressing apart.
    UIImage *front = SGRCustomPicture(key, SGRPartFront);
    if (front) [_fronts setObject:front forKey:key];
    else [_fronts removeObjectForKey:key];
    if (sleeve.sticker) {
        CGPoint center = defaultStickerCenter(sleeve.sticker);
        SGRCustomStickerCenter(key, &center);
        _stickers[key] = @[sleeve.sticker, [NSValue valueWithCGPoint:center]];
    } else {
        [_stickers removeObjectForKey:key];
    }
    [self redrawRecordWithKey:key];
}

// Record `index` wearing its sticker, or none, where it sits; its band of light at `place` unless it is out of the
// crate, where it is moved by its own animation. Answers the sticker layer.
- (CALayer *)dressSticker:(NSUInteger)index place:(CGFloat)place {
    NSArray *sticker = _stickers[[_records[index] key]];
    CALayer *layer = _stickerLayers[@(index)];
    UIImage *picture = sticker.firstObject;
    if (layer && (!picture || (__bridge CGImageRef)layer.contents != picture.CGImage)) {
        [layer removeFromSuperlayer];
        [_stickerLayers removeObjectForKey:@(index)];
        layer = nil;
    }
    if (!picture) return nil;
    if (!layer) {
        layer = stickerLayer(picture, _width);
        // Over the cover, under its shading.
        [_faces[index] insertSublayer:layer below:_shades[index]];
        _stickerLayers[@(index)] = layer;
    }
    CGPoint center = [sticker[1] CGPointValue];
    if (!(_placing && (NSInteger)index == _pulled)) layer.position = CGPointMake(center.x * _width, center.y * _width);
    shine(layer, (NSInteger)index == _pulled ? [self pulledShine] : place);
    return layer;
}

- (NSArray<UIColor *> *)colorsOf:(SGRRecord *)record {
    return _colors[[record key]] ?: @[[UIColor colorWithWhite:0.106 alpha:1], UIColor.whiteColor];
}

// The strip along the record's bottom edge: the sleeve's own spine when one was found, else the title and the
// artist in the cover's colors, white on dark gray until the cover is in.
- (UIImage *)labelFor:(SGRRecord *)record {
    NSArray<UIColor *> *colors = [self colorsOf:record];
    UIColor *back = colors.firstObject, *ink = colors.lastObject;
    UIImage *scan = [self sleeveOf:record].spine;
    CGSize size = CGSizeMake(_width, kSpine);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [back setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        if (scan && scan.size.width > 0) {
            // Across the strip's width; a spine thinner than the strip is stretched up to 2.5 times, then centered.
            CGFloat natural = size.width * scan.size.height / scan.size.width;
            CGFloat height = MIN(size.height, natural * 2.5);
            [scan drawInRect:CGRectMake(0, (size.height - height) / 2, size.width, height)];
            return;
        }
        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.alignment = NSTextAlignmentCenter;
        paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:record.title ?: @""
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightBold], NSForegroundColorAttributeName: ink}];
        if (record.artist.length) {
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:record.artist]
                attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:10], NSForegroundColorAttributeName: [ink colorWithAlphaComponent:0.8]}]];
        }
        [text addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, text.length)];
        CGFloat height = ceil([UIFont systemFontOfSize:10].lineHeight);
        [text drawWithRect:CGRectMake(10, (size.height - height) / 2, size.width - 20, height)
                   options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine context:nil];
    }];
}

// What the record's cover shows: the sleeve's scanned front, its sticker on, when there is one, else the album's cover.
- (UIImage *)faceOf:(SGRRecord *)record {
    NSString *key = [record key];
    return [_fronts objectForKey:key] ?: [_pictures objectForKey:key];
}

// The sleeve's back: its scan, else drawn in the cover's colors with the album's name and its tracks.
- (UIImage *)backOf:(SGRRecord *)record {
    SGRSleeve *sleeve = [self sleeveOf:record];
    if (sleeve.back) return sleeve.back;
    NSString *key = [record key];
    UIImage *drawn = [_backs objectForKey:key];
    if (drawn) return drawn;
    NSArray<NSString *> *tracks = _tracks[key];
    if (!tracks) [self askTracksOf:record];
    tracks = _tracks[key];
    NSArray<UIColor *> *colors = [self colorsOf:record];
    UIColor *paper = colors.firstObject, *ink = colors.lastObject;
    CGSize size = CGSizeMake(_width, _width);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    drawn = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [paper setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        CGFloat pad = round(size.width * 0.08), y = pad, inner = size.width - 2 * pad;
        NSDictionary *heading = @{NSFontAttributeName: [UIFont systemFontOfSize:18 weight:UIFontWeightHeavy], NSForegroundColorAttributeName: ink};
        NSDictionary *byline = @{NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightMedium], NSForegroundColorAttributeName: [ink colorWithAlphaComponent:0.75]};
        NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine;
        [record.title.uppercaseString ?: @"" drawWithRect:CGRectMake(pad, y, inner, 24) options:options attributes:heading context:nil];
        y += 26;
        [record.artist ?: @"" drawWithRect:CGRectMake(pad, y, inner, 16) options:options attributes:byline context:nil];
        y += 30;
        // The tracks, in two columns when one would run off the bottom.
        UIFont *font = [UIFont systemFontOfSize:10];
        CGFloat line = ceil(font.lineHeight) + 3, room = size.height - pad - y;
        NSUInteger rows = MAX((NSUInteger)1, (NSUInteger)floor(room / line));
        BOOL two = tracks.count > rows;
        CGFloat column = two ? (inner - pad / 2) / 2 : inner;
        NSDictionary *listed = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [ink colorWithAlphaComponent:0.9]};
        for (NSUInteger i = 0; i < tracks.count && i < (two ? rows * 2 : rows); i++) {
            NSUInteger row = i % rows;
            CGFloat x = pad + (i >= rows ? column + pad / 2 : 0);
            NSString *text = [NSString stringWithFormat:@"%lu. %@", (unsigned long)(i + 1), tracks[i]];
            [text drawWithRect:CGRectMake(x, y + row * line, column, line) options:options attributes:listed context:nil];
        }
    }];
    if (tracks) [_backs setObject:drawn forKey:key];
    return drawn;
}

- (void)askTracksOf:(SGRRecord *)record {
    NSString *key = [record key];
    if (_tracks[key] || [_tracksAsked containsObject:key]) return;
    [_tracksAsked addObject:key];
    if (record.local) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (SGLocalTrack *track in record.local.tracks) [names addObject:track.title ?: @""];
        _tracks[key] = names;
        return;
    }
    NSString *album = [record.uri componentsSeparatedByString:@":"].lastObject;
    if (!album.length) return;
    __weak SGRRecordsPage *weakSelf = self;
    SGWebAPI(@"GET", [NSString stringWithFormat:@"albums/%@/tracks?limit=50", album], ^(NSInteger status, id answer) {
        SGRRecordsPage *page = weakSelf;
        if (!page || status != 200 || ![answer isKindOfClass:NSDictionary.class]) return;
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (id track in [answer[@"items"] isKindOfClass:NSArray.class] ? answer[@"items"] : @[]) {
            if ([track isKindOfClass:NSDictionary.class] && [track[@"name"] isKindOfClass:NSString.class]) [names addObject:track[@"name"]];
        }
        page->_tracks[key] = names;
        [page->_backs removeObjectForKey:key];
        [page redressPulled];
    });
}

// The record's face and label drawn again, wherever it is in the crate.
- (void)redrawRecordWithKey:(NSString *)key {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < _records.count && i < _layers.count; i++) {
        if (![[_records[i] key] isEqualToString:key]) continue;
        _spines[i].contents = nil;
        UIImage *face = [self faceOf:_records[i]];
        if (face) _faces[i].contents = (id)face.CGImage;
        if (((NSInteger)i == _focused && _pulled < 0) || (NSInteger)i == _pulled) {
            if (face) [self showBackdrop:face];
        }
    }
    [CATransaction commit];
    [_backs removeObjectForKey:key];
    if (_pulled >= 0 && [[_records[(NSUInteger)_pulled] key] isEqualToString:key]) [self redressPulled];
    [self render];
}

- (void)redrawSleeves {
    [_backs removeAllObjects];
    [_sleevesAsked removeAllObjects];
    [_fronts removeAllObjects];
    [_stickers removeAllObjects];
    for (SGRRecord *record in _records) {
        NSString *key = [record key];
        if (_sleeves[key] || SGRHasCustom(key)) [self composeFrontOf:key];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < _layers.count; i++) {
        _spines[i].contents = nil;
        _faces[i].contents = nil;
    }
    [CATransaction commit];
    _focused = -1;
    [self render];
    if (_pulled >= 0) {
        UIImage *face = [self faceOf:_records[(NSUInteger)_pulled]];
        if (face) _faces[(NSUInteger)_pulled].contents = (id)face.CGImage;
        [self redressPulled];
    }
}

- (void)askPictureOf:(NSUInteger)index {
    SGRRecord *record = _records[index];
    NSString *key = [record key];
    if ([_pictures objectForKey:key] || [_asked containsObject:key]) return;
    [_asked addObject:key];
    __weak SGRRecordsPage *weakSelf = self;
    void (^got)(UIImage *) = ^(UIImage *picture) {
        SGRRecordsPage *page = weakSelf;
        if (!page) return;
        [page->_asked removeObject:key];
        if (!picture) return;
        [page->_pictures setObject:picture forKey:key];
        [page redrawRecordWithKey:key];
        if (SGRHasCustom(key)) [page composeFrontOf:key];
        if (page->_colors[key]) return;
        // The label's colors, taken from the cover off main.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            UIColor *back = nil, *ink = nil;
            SGRSpineColors(picture, &back, &ink);
            dispatch_async(dispatch_get_main_queue(), ^{
                SGRRecordsPage *later = weakSelf;
                if (!later || !back || !ink) return;
                later->_colors[key] = @[back, ink];
                [later redrawRecordWithKey:key];
            });
        });
    };
    if (record.local) {
        SGLocalAlbumCover(record.local, _width * UIScreen.mainScreen.scale, got);
        return;
    }
    NSURL *url = record.picture ? [NSURL URLWithString:record.picture] : nil;
    if (!url) return;
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *picture = data ? [UIImage imageWithData:data] : nil;
        // Decoded here rather than on main as the layer first draws it.
        UIImage *ready = [picture imageByPreparingForDisplay] ?: picture;
        dispatch_async(dispatch_get_main_queue(), ^{ got(ready); });
    }] resume];
}

// The sleeve is looked for once the album's cover is in, which its front must match.
- (void)askSleeveOf:(NSUInteger)index {
    SGRRecord *record = _records[index];
    NSString *key = [record key];
    UIImage *cover = [_pictures objectForKey:key];
    if (!cover || [_sleevesAsked containsObject:key]) return;
    [_sleevesAsked addObject:key];
    __weak SGRRecordsPage *weakSelf = self;
    void (^wear)(SGRSleeve *, BOOL) = ^(SGRSleeve *sleeve, BOOL own) { [weakSelf wear:sleeve key:key own:own]; };
    // A local album's own pictures, from its import, before any scan.
    void (^scanned)(void) = ^{
        SGRRecordsPage *page = weakSelf;
        if (!page) return;
        // Asked again when Vinyl Scans is switched on (-redrawSleeves).
        if (![page scans]) return;
        SGRRecordSleeve(record.title, record.artist, record.kind, cover, NO, ^(SGRSleeve *sleeve) { wear(sleeve, NO); });
    };
    NSDictionary<NSString *, NSArray<NSString *> *> *artwork = record.local ? SGLocalAlbumArtwork(record.title, record.artist) : nil;
    if (artwork) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            SGRSleeve *sleeve = SGRSleeveOfArtwork(artwork, cover);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (sleeve) wear(sleeve, YES);
                else scanned();
            });
        });
        return;
    }
    scanned();
}

- (void)wear:(SGRSleeve *)sleeve key:(NSString *)key own:(BOOL)own {
    if (!sleeve.front) return;
    _sleeves[key] = sleeve;
    if (own) [_ownSleeves addObject:key];
    [self composeFrontOf:key];
}

// A record pulled out without a sleeve has one looked for at once, once a visit, even when it was looked for before
// and none was found; it is worn as it comes in.
- (void)lookForSleeveOf:(NSUInteger)index {
    SGRRecord *record = _records[index];
    NSString *key = [record key];
    UIImage *cover = [_pictures objectForKey:key];
    if (![self scans] || _sleeves[key] || !cover || [_lookedAgain containsObject:key]) return;
    if (record.local && SGLocalAlbumArtwork(record.title, record.artist)) return;
    [_lookedAgain addObject:key];
    [_sleevesAsked addObject:key];
    __weak SGRRecordsPage *weakSelf = self;
    SGRRecordSleeve(record.title, record.artist, record.kind, cover, YES, ^(SGRSleeve *sleeve) {
        [weakSelf wear:sleeve key:key own:NO];
    });
}

- (void)showBackdrop:(UIImage *)picture {
    if (_backdrop.image == picture) return;
    [UIView transitionWithView:_backdrop duration:0.35 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:^{ self->_backdrop.image = picture; } completion:nil];
}

- (CGFloat)focus {
    UITableView *table = self.tableView;
    CGFloat focus = (table.contentOffset.y + table.adjustedContentInset.top) / [self step];
    return MIN(MAX(focus, 0), (CGFloat)(_records.count ? _records.count - 1 : 0));
}

// Where the focus sits, in the stage's coordinates.
- (CGFloat)focusLine {
    UITableView *table = self.tableView;
    UIEdgeInsets inset = table.adjustedContentInset;
    return inset.top + kFocusY * MAX(0, _stage.bounds.size.height - inset.top - inset.bottom);
}

// Every record in the crate leans the same.
- (CATransform3D)crateTransform {
    return recordPose(0, CATransform3DIdentity, kTilt, kPerspective, _width);
}

// Record `index`'s bottom edge down the stage, a step from the next, the focus on the focus line.
- (CGFloat)bottomOf:(NSUInteger)index focus:(CGFloat)focus {
    return [self focusLine] + ((CGFloat)index - focus) * [self step];
}

- (void)render {
    NSUInteger count = _records.count;
    if (!count || _layers.count != count || _width <= 0) return;
    CGFloat focus = [self focus];
    CGFloat height = _stage.bounds.size.height, middle = _stage.bounds.size.width / 2, line = [self focusLine];
    CATransform3D crate = [self crateTransform];
    BOOL scans = [self scans];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < count; i++) {
        // The record out of the crate, or on its way back, moves by its own animation.
        BOOL apart = (NSInteger)i == _pulled || (NSInteger)i == _returning;
        CATransformLayer *record = _layers[i];
        CGFloat bottom = [self bottomOf:i focus:focus];
        BOOL near = fabs((CGFloat)i - focus) <= kKeepPictures;
        BOOL shown = apart || (near && bottom > -kSpine && bottom - _width < height + kSpine);
        record.hidden = !shown;
        CALayer *face = _faces[i], *spine = _spines[i];
        if (!near && !apart) {
            face.contents = nil;
            spine.contents = nil;
            continue;
        }
        if (!shown) continue;
        if (!apart) {
            record.position = CGPointMake(middle, bottom);
            record.transform = crate;
            // The further from the focus, the darker.
            float dark = (float)MIN(kFarDark, fabs(bottom - line) / MAX(height, 1) * kFarDark * 1.6);
            _veils[i].opacity = dark;
            _spineVeils[i].opacity = dark;
        }
        [self dressSticker:i place:(bottom - _width * 0.2) / MAX(height, 1) * 1.4 - 0.2];
        SGRRecord *item = _records[i];
        UIImage *picture = [self faceOf:item];
        if (picture) face.contents = (id)picture.CGImage;
        if (![_pictures objectForKey:[item key]]) [self askPictureOf:i];
        else if ((scans || item.local) && fabs((CGFloat)i - focus) <= kScanReach) [self askSleeveOf:i];
        if (!spine.contents) spine.contents = (id)[self labelFor:item].CGImage;
    }
    [CATransaction commit];

    NSInteger focused = (NSInteger)lround(focus);
    if (focused != _focused) {
        if (_focused >= 0 && (self.tableView.isDragging || self.tableView.isDecelerating)) [_tick selectionChanged];
        _focused = focused;
        UIImage *picture = [self faceOf:_records[(NSUInteger)focused]];
        if (picture && _pulled < 0) [self showBackdrop:picture];
    }
}

#pragma mark a record out of the crate

// Where a record out of the crate stands: upright in the middle of what the bars leave, its caption under it.
- (CGFloat)pulledBottom {
    UITableView *table = self.tableView;
    UIEdgeInsets inset = table.adjustedContentInset;
    CGFloat visible = MAX(0, _stage.bounds.size.height - inset.top - inset.bottom);
    return inset.top + (visible + _width) / 2 - kCaption / 2;
}

// How much an open gatefold, twice as wide, is made smaller to fit.
- (CGFloat)openScale {
    return MIN(1, (_stage.bounds.size.width - 24) / (2 * _width));
}

- (CGRect)pulledFrame {
    CGFloat bottom = [self pulledBottom], middle = _stage.bounds.size.width / 2;
    if (!_opened) return CGRectMake(middle - _width / 2, bottom - _width, _width, _width);
    CGFloat side = _width * [self openScale];
    return CGRectMake(middle - side, bottom - (_width + side) / 2, 2 * side, side);
}

// The record out of the crate as it stands now: turned, and opened out and made smaller to fit when its gatefold is
// open (moved right by half a cover, so the spread is in the middle, and kept in the middle down the page).
- (CATransform3D)pulledPose {
    CATransform3D between = CATransform3DIdentity;
    if (_opened) {
        CGFloat scale = [self openScale];
        between = CATransform3DMakeTranslation(_width / 2, 0, 0);
        between = CATransform3DConcat(between, CATransform3DMakeScale(scale, scale, scale));
        between = CATransform3DConcat(between, CATransform3DMakeTranslation(0, -(_width - _width * scale) / 2, 0));
    }
    return recordPose(_turn, between, kPulledTilt, kPulledPerspective, _width);
}

// The record out of the crate made a sleeve: its front on a flap hinged at its left edge (the gatefold's front, or
// the whole front), the inside on the flap's other side and under it, the back facing behind, and the four edges.
- (void)dress:(NSUInteger)index {
    [self undress];
    CATransformLayer *record = _layers[index];
    CALayer *face = _faces[index];
    SGRRecord *item = _records[index];
    SGRSleeve *sleeve = [self sleeveOf:item];
    UIColor *edge = [self colorsOf:item].firstObject;
    CGFloat side = _width;
    CGRect whole = CGRectMake(0, 0, side, side);
    NSMutableArray<CALayer *> *extras = [NSMutableArray array];

    _flap = [CATransformLayer layer];
    _flap.bounds = whole;
    _flap.anchorPoint = CGPointMake(0, 0.5);
    _flap.position = CGPointMake(0, side / 2);
    [face removeFromSuperlayer];
    face.frame = whole;
    face.doubleSided = NO;
    [_flap addSublayer:face];
    if (sleeve.gatefold.count == 2) {
        CALayer *left = panel(whole, sleeve.gatefold[0], edge);
        left.doubleSided = NO;
        left.zPosition = -0.5;
        left.transform = CATransform3DMakeRotation(M_PI, 0, 1, 0);
        [_flap addSublayer:left];
        CALayer *right = panel(whole, sleeve.gatefold[1], edge);
        right.doubleSided = NO;
        right.zPosition = -1;
        [record addSublayer:right];
        [extras addObject:right];
    }
    [record addSublayer:_flap];
    [extras addObject:_flap];

    CALayer *back = panel(whole, [self backOf:item], edge);
    back.doubleSided = NO;
    back.zPosition = -kSpine;
    back.transform = CATransform3DMakeRotation(M_PI, 0, 1, 0);
    [record addSublayer:back];
    [extras addObject:back];
    // Its edges as deep as its label: the label itself along the bottom, as in the crate, plain edges at its left and
    // top, and the opening, darker, at its right, where the record comes out.
    for (int i = 0; i < 3; i++) {
        CALayer *strip = [CALayer layer];
        BOOL upright = i < 2;
        strip.bounds = upright ? CGRectMake(0, 0, kSpine, side) : CGRectMake(0, 0, side, kSpine);
        strip.position = upright ? CGPointMake(i == 0 ? 0 : side, side / 2) : CGPointMake(side / 2, 0);
        strip.zPosition = -kSpine / 2;
        strip.transform = upright ? CATransform3DMakeRotation(M_PI_2, 0, 1, 0) : CATransform3DMakeRotation(M_PI_2, 1, 0, 0);
        strip.backgroundColor = edge.CGColor;
        if (i == 1) {
            CALayer *opening = [CALayer layer];
            opening.frame = strip.bounds;
            opening.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55].CGColor;
            [strip addSublayer:opening];
        }
        [record addSublayer:strip];
        [extras addObject:strip];
    }
    // Standing out of the crate, it is lit as a whole: the crate's shading off it, a sheen and the dark as it turns on.
    _shades[index].hidden = YES;
    _veils[index].opacity = 0;
    _gloss = [CAGradientLayer layer];
    _gloss.frame = whole;
    _gloss.startPoint = CGPointMake(0, 0);
    _gloss.endPoint = CGPointMake(1, 1);
    UIColor *none = [UIColor colorWithWhite:1 alpha:0], *sheen = [UIColor colorWithWhite:1 alpha:0.2];
    _gloss.colors = @[(__bridge id)none.CGColor, (__bridge id)none.CGColor, (__bridge id)sheen.CGColor, (__bridge id)none.CGColor, (__bridge id)none.CGColor];
    [face addSublayer:_gloss];
    _frontShade = [CALayer layer];
    _frontShade.frame = whole;
    _frontShade.backgroundColor = UIColor.blackColor.CGColor;
    [face addSublayer:_frontShade];
    _backShade = [CALayer layer];
    _backShade.frame = whole;
    _backShade.backgroundColor = UIColor.blackColor.CGColor;
    [back addSublayer:_backShade];
    _extras = extras;
    _spineVeils[index].opacity = 0;
    [self light];
}

// The record out of the crate lit as it is turned: the sheen sliding across its cover, the side turned from the light
// darker, and its shadow narrowing as it stands edge on.
- (void)light {
    if (_pulled < 0 || !_gloss) return;
    CGFloat facing = cos(_turn);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _frontShade.opacity = (float)(kTurnedDark * (1 - MAX(facing, 0)));
    _backShade.opacity = (float)(kTurnedDark * (1 - MAX(-facing, 0)));
    _gloss.locations = bandAt(0.5 + 0.45 * sin(_turn));
    CALayer *sticker = _stickerLayers[@(_pulled)];
    if (sticker) shine(sticker, [self pulledShine]);
    CGRect frame = [self pulledFrame];
    CGFloat across = MAX(fabs(facing), 0.06) * frame.size.width;
    _floor.shadowPath = [UIBezierPath bezierPathWithRect:CGRectMake(CGRectGetMidX(frame) - across / 2, frame.origin.y + 10, across, frame.size.height - 10)].CGPath;
    [CATransaction commit];
}

- (void)fadeFloor:(float)opacity {
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    fade.fromValue = @(_floor.presentationLayer.shadowOpacity);
    fade.toValue = @(opacity);
    fade.duration = 0.45;
    _floor.shadowOpacity = opacity;
    [_floor addAnimation:fade forKey:@"fade"];
}

// Where the band of light sits on the sticker of the record out of the crate: across it facing front, clear of it
// a quarter turn either way, so it crosses as the record is turned.
- (CGFloat)pulledShine {
    return 0.5 + 0.75 * sin(_turn);
}

// Back to a record in the crate: its front on it again, the rest gone.
- (void)undress {
    if (!_flap) return;
    for (NSUInteger i = 0; i < _faces.count; i++) {
        CALayer *face = _faces[i];
        if (face.superlayer != _flap) continue;
        [face removeFromSuperlayer];
        face.doubleSided = YES;
        face.frame = CGRectMake(0, 0, _width, _width);
        [_layers[i] insertSublayer:face atIndex:0];
        _spines[i].hidden = NO;
    }
    for (CALayer *layer in _extras) [layer removeFromSuperlayer];
    [_gloss removeFromSuperlayer];
    [_frontShade removeFromSuperlayer];
    for (CAGradientLayer *shade in _shades) shade.hidden = NO;
    _gloss = nil;
    _frontShade = _backShade = nil;
    _extras = nil;
    _flap = nil;
}

// The sleeve made again for what has come in since (a scan, the tracks), as it stands.
- (void)redressPulled {
    if (_pulled < 0) return;
    BOOL opened = _opened;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self dress:(NSUInteger)_pulled];
    if (opened && [self sleeveOf:_records[(NSUInteger)_pulled]].gatefold.count == 2) {
        _flap.transform = CATransform3DMakeRotation(-M_PI, 0, 1, 0);
    } else if (opened) {
        _opened = NO;
        _layers[(NSUInteger)_pulled].transform = [self pulledPose];
    }
    [CATransaction commit];
    [self dressSticker:(NSUInteger)_pulled place:0.5];
    [self light];
    [self placeCaption];
}

// The record moves from `from` through a point `lift` above it to `to`, as one animation of its position and
// transform, the model left at `to`.
- (void)move:(CALayer *)layer from:(CGPoint)from transform:(CATransform3D)fromTransform lift:(CGFloat)lift
          to:(CGPoint)to transform:(CATransform3D)toTransform liftFirst:(BOOL)liftFirst done:(void (^)(void))done {
    CGPoint middle = liftFirst ? CGPointMake(from.x, from.y - lift) : CGPointMake(to.x, to.y - lift);
    CATransform3D middleTransform = liftFirst ? fromTransform : toTransform;
    CAKeyframeAnimation *position = [CAKeyframeAnimation animationWithKeyPath:@"position"];
    position.values = @[[NSValue valueWithCGPoint:from], [NSValue valueWithCGPoint:middle], [NSValue valueWithCGPoint:to]];
    CAKeyframeAnimation *transform = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    transform.values = @[[NSValue valueWithCATransform3D:fromTransform], [NSValue valueWithCATransform3D:middleTransform],
                         [NSValue valueWithCATransform3D:toTransform]];
    CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    for (CAKeyframeAnimation *animation in @[position, transform]) {
        animation.keyTimes = @[@0, @0.4, @1];
        animation.timingFunctions = @[ease, ease];
        animation.duration = 0.55;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [CATransaction setCompletionBlock:done];
    layer.position = to;
    layer.transform = toTransform;
    [layer addAnimation:position forKey:@"move.position"];
    [layer addAnimation:transform forKey:@"move.transform"];
    [CATransaction commit];
}

- (void)fadeDim:(float)opacity {
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(_dim.presentationLayer.opacity);
    fade.toValue = @(opacity);
    fade.duration = 0.4;
    _dim.opacity = opacity;
    [_dim addAnimation:fade forKey:@"fade"];
}

// The title, the artist and the gatefold's button under the record out of the crate.
- (void)placeCaption {
    CGFloat bottom = [self pulledBottom], width = _stage.bounds.size.width - 48;
    _pulledTitle.frame = CGRectMake(24, bottom + 18, width, 26);
    _pulledArtist.frame = CGRectMake(24, bottom + 46, width, 20);
    BOOL gatefold = _pulled >= 0 && !_placing && [self sleeveOf:_records[(NSUInteger)_pulled]].gatefold.count == 2;
    _gateButton.hidden = !gatefold;
    _customButton.hidden = _pulled < 0;
    UIButtonConfiguration *gate = _gateButton.configuration;
    gate.title = _opened ? @"Close Gatefold" : @"Open Gatefold";
    _gateButton.configuration = gate;
    UIButtonConfiguration *custom = _customButton.configuration;
    custom.title = _placing ? @"Done" : nil;
    custom.image = [UIImage systemImageNamed:_placing ? @"checkmark" : @"paintbrush"
                           withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium]];
    _customButton.configuration = custom;
    _customButton.accessibilityLabel = _placing ? @"Done" : @"Customize";
    CGSize gateSize = [_gateButton sizeThatFits:CGSizeMake(width, 36)];
    _gateButton.frame = CGRectMake((_stage.bounds.size.width - gateSize.width) / 2, bottom + 76, gateSize.width, MAX(gateSize.height, 34));
    // The Customize button in the bottom right corner, above the bars.
    CGSize customSize = [_customButton sizeThatFits:CGSizeMake(width, kCornerButton)];
    CGFloat customWidth = MAX(customSize.width, kCornerButton);
    CGFloat floorLine = _stage.bounds.size.height - self.tableView.adjustedContentInset.bottom - kCornerRoom;
    _customButton.frame = CGRectMake(_stage.bounds.size.width - kCornerRoom - customWidth, floorLine - kCornerButton, customWidth, kCornerButton);
}

- (void)pullOut:(NSUInteger)index {
    if (_returning >= 0) [self finishReturn];
    CATransformLayer *layer = _layers[index];
    CGPoint from = CGPointMake(_stage.bounds.size.width / 2, [self bottomOf:index focus:[self focus]]);
    CATransform3D fromTransform = [self crateTransform];
    _pulled = (NSInteger)index;
    _turn = 0;
    _opened = NO;
    self.tableView.scrollEnabled = NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self dress:index];
    layer.zPosition = 1000;
    [CATransaction commit];
    CGPoint to = CGPointMake(_stage.bounds.size.width / 2, [self pulledBottom]);
    [self move:layer from:from transform:fromTransform lift:_width * 0.6 to:to transform:[self pulledPose] liftFirst:YES done:nil];
    [self fadeDim:(float)kPulledDim];
    [self light];
    [self fadeFloor:(float)kFloorShadow];
    [self dressSticker:index place:0.5];
    [self lookForSleeveOf:index];

    SGRRecord *record = _records[index];
    _pulledTitle.text = record.title;
    _pulledArtist.text = record.artist;
    [self placeCaption];
    _gateButton.alpha = 0;
    _customButton.alpha = 0;
    [UIView animateWithDuration:0.3 delay:0.3 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_pulledTitle.alpha = 1;
        self->_pulledArtist.alpha = 1;
        self->_gateButton.alpha = 1;
        self->_customButton.alpha = 1;
    } completion:nil];
    UIImage *face = [self faceOf:record];
    if (face) [self showBackdrop:face];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

- (void)putBack {
    if (_pulled < 0) return;
    if (_placing) [self finishPlacing];
    NSUInteger index = (NSUInteger)_pulled;
    CATransformLayer *layer = _layers[index];
    CALayer *now = layer.presentationLayer ?: layer;
    CGPoint from = now.position;
    CATransform3D fromTransform = now.transform;
    // A gatefold left open closes as the record goes.
    if (_opened && _flap) {
        CABasicAnimation *shut = [CABasicAnimation animationWithKeyPath:@"transform.rotation.y"];
        shut.fromValue = @(-M_PI);
        shut.toValue = @0;
        shut.duration = 0.35;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _flap.transform = CATransform3DIdentity;
        [_flap addAnimation:shut forKey:@"shut"];
        [CATransaction commit];
    }
    _opened = NO;
    _turn = 0;
    _pulled = -1;
    _returning = (NSInteger)index;
    self.tableView.scrollEnabled = YES;
    CGPoint to = CGPointMake(_stage.bounds.size.width / 2, [self bottomOf:index focus:[self focus]]);
    __weak SGRRecordsPage *weakSelf = self;
    [self move:layer from:from transform:fromTransform lift:_width * 0.6 to:to transform:[self crateTransform] liftFirst:NO done:^{
        SGRRecordsPage *page = weakSelf;
        if (page && page->_returning == (NSInteger)index) [page finishReturn];
    }];
    [self fadeDim:0];
    [self fadeFloor:0];
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_pulledTitle.alpha = 0;
        self->_pulledArtist.alpha = 0;
        self->_gateButton.alpha = 0;
        self->_customButton.alpha = 0;
    } completion:nil];
    UIImage *face = _focused >= 0 && _focused < (NSInteger)_records.count ? [self faceOf:_records[(NSUInteger)_focused]] : nil;
    if (face) [self showBackdrop:face];
}

- (void)finishReturn {
    if (_returning < 0) return;
    if (_returning < (NSInteger)_layers.count) {
        CATransformLayer *layer = _layers[(NSUInteger)_returning];
        [layer removeAllAnimations];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [self undress];
        layer.zPosition = 0;
        [CATransaction commit];
    }
    _returning = -1;
    _gateButton.hidden = YES;
    _customButton.hidden = YES;
    [self render];
}

// Back in the crate at once, for a crate that is about to be made again.
- (void)dropPulled {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self undress];
    _dim.opacity = 0;
    [CATransaction commit];
    _pulled = _returning = -1;
    _opened = NO;
    _turn = 0;
    self.tableView.scrollEnabled = YES;
    _pulledTitle.alpha = 0;
    _pulledArtist.alpha = 0;
    _gateButton.hidden = YES;
    _customButton.hidden = YES;
    _placing = NO;
    _placedSticker = nil;
    _floor.shadowOpacity = 0;
}

// The gatefold's front swings open on its left edge, the record moving over and getting smaller so the spread fits;
// or closes again.
- (void)toggleGatefold {
    if (_pulled < 0 || !_flap) return;
    CATransformLayer *layer = _layers[(NSUInteger)_pulled];
    CATransform3D was = (layer.presentationLayer ?: layer).transform;
    BOOL opening = !_opened;
    _opened = opening;
    _turn = 0;
    CABasicAnimation *swing = [CABasicAnimation animationWithKeyPath:@"transform.rotation.y"];
    swing.fromValue = @(opening ? 0 : -M_PI);
    swing.toValue = @(opening ? -M_PI : 0);
    CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"transform"];
    move.fromValue = [NSValue valueWithCATransform3D:was];
    move.toValue = [NSValue valueWithCATransform3D:[self pulledPose]];
    for (CABasicAnimation *animation in @[swing, move]) {
        animation.duration = 0.7;
        animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _flap.transform = opening ? CATransform3DMakeRotation(-M_PI, 0, 1, 0) : CATransform3DIdentity;
    layer.transform = [self pulledPose];
    [_flap addAnimation:swing forKey:@"swing"];
    [layer addAnimation:move forKey:@"open"];
    [CATransaction commit];
    [self light];
    [self placeCaption];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

#pragma mark customizing

- (void)showCustomize {
    if (_pulled < 0) return;
    SGRRecord *record = _records[(NSUInteger)_pulled];
    NSString *key = [record key];
    SGRSleeve *sleeve = [self sleeveWithKey:key];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Customize Record" message:record.title preferredStyle:UIAlertControllerStyleActionSheet];
    __weak SGRRecordsPage *weakSelf = self;
    NSArray<NSArray<NSString *> *> *parts = @[@[SGRPartFront, @"Front Cover"], @[SGRPartBack, @"Back Cover"], @[SGRPartSpine, @"Spine"],
                                              @[SGRPartInsideLeft, @"Gatefold Inside, Left"], @[SGRPartInsideRight, @"Gatefold Inside, Right"],
                                              @[SGRPartSticker, @"Hype Sticker"]];
    for (NSArray<NSString *> *part in parts) {
        NSString *title = SGRCustomPicture(key, part[0]) ? [part[1] stringByAppendingString:@" (Yours)"] : part[1];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf askPart:part[0] named:part[1] key:key];
        }]];
    }
    if (sheet && sleeve.sticker) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Move Hype Sticker" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf startPlacing];
        }]];
    }
    BOOL hidden = SGRCustomStickerHidden(key);
    SGRSleeve *found = _sleeves[key];
    if (sleeve.sticker || hidden) {
        [sheet addAction:[UIAlertAction actionWithTitle:hidden ? @"Put Hype Sticker Back" : @"Take Off Hype Sticker" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            SGRSetCustomStickerHidden(key, !hidden);
            [weakSelf customChanged:key];
        }]];
    }
    if (SGRHasCustom(key)) {
        [sheet addAction:[UIAlertAction actionWithTitle:found ? @"Use the Sleeve Found" : @"Use the Album's Cover" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            SGRForgetCustom(key);
            [weakSelf customChanged:key];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = _customButton;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)askPart:(NSString *)part named:(NSString *)name key:(NSString *)key {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak SGRRecordsPage *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choose from Photos" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        SGRRecordsPage *page = weakSelf;
        if (!page) return;
        page->_pickingPart = part;
        page->_pickingKey = key;
        PHPickerConfiguration *configuration = [PHPickerConfiguration new];
        configuration.filter = PHPickerFilter.imagesFilter;
        configuration.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
        picker.delegate = page;
        [page presentViewController:picker animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choose from Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        SGRRecordsPage *page = weakSelf;
        if (!page) return;
        page->_pickingPart = part;
        page->_pickingKey = key;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
        picker.delegate = page;
        [page presentViewController:picker animated:YES completion:nil];
    }]];
    if (SGRCustomPicture(key, part)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Use the Original" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            SGRSetCustomPicture(key, part, nil);
            [weakSelf customChanged:key];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = _customButton;
    [self presentViewController:sheet animated:YES completion:nil];
}

// A picture picked: kept, made smaller first, for the part it was picked for.
- (void)picked:(UIImage *)picture {
    NSString *part = _pickingPart, *key = _pickingKey;
    _pickingPart = _pickingKey = nil;
    if (!picture || !part || !key) return;
    __weak SGRRecordsPage *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *kept = fitted(picture);
        dispatch_async(dispatch_get_main_queue(), ^{
            SGRSetCustomPicture(key, part, kept);
            [weakSelf customChanged:key];
        });
    });
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (![provider canLoadObjectOfClass:UIImage.class]) return;
    __weak SGRRecordsPage *weakSelf = self;
    [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> image, NSError *error) {
        if (![(id)image isKindOfClass:UIImage.class]) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf picked:(UIImage *)image]; });
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    UIImage *image = urls.firstObject ? [UIImage imageWithContentsOfFile:urls.firstObject.path] : nil;
    [self picked:image];
}

// What was picked worn at once: the front made again, the label and the sleeve out of the crate too.
- (void)customChanged:(NSString *)key {
    [_backs removeObjectForKey:key];
    [self composeFrontOf:key];
    [self redrawRecordWithKey:key];
}

// Moving the sticker: the record faces front, its front shown without the sticker, and the sticker over it follows
// the finger until Done.
- (void)startPlacing {
    if (_pulled < 0) return;
    NSUInteger index = (NSUInteger)_pulled;
    SGRRecord *record = _records[index];
    NSString *key = [record key];
    SGRSleeve *sleeve = [self sleeveWithKey:key];
    if (!sleeve.sticker) return;
    if (_opened) [self toggleGatefold];
    CATransformLayer *layer = _layers[index];
    CATransform3D was = (layer.presentationLayer ?: layer).transform;
    _turn = 0;
    CABasicAnimation *face = [CABasicAnimation animationWithKeyPath:@"transform"];
    face.fromValue = [NSValue valueWithCATransform3D:was];
    face.toValue = [NSValue valueWithCATransform3D:[self pulledPose]];
    face.duration = 0.3;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.transform = [self pulledPose];
    [layer addAnimation:face forKey:@"face"];
    _stickerCenter = defaultStickerCenter(sleeve.sticker);
    SGRCustomStickerCenter(key, &_stickerCenter);
    _placedSticker = [self dressSticker:index place:0.5];
    [CATransaction commit];
    [self light];
    _placing = YES;
    _pulledArtist.text = @"Drag the sticker where it goes";
    [self placeCaption];
}

- (void)placeStickerAt:(CGPoint)point {
    if (!_placedSticker) return;
    CGRect frame = [self pulledFrame];
    _stickerCenter = CGPointMake(MIN(MAX((point.x - frame.origin.x) / frame.size.width, 0), 1),
                                 MIN(MAX((point.y - frame.origin.y) / frame.size.height, 0), 1));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _placedSticker.position = CGPointMake(_stickerCenter.x * _width, _stickerCenter.y * _width);
    [CATransaction commit];
}

- (void)finishPlacing {
    if (!_placing) return;
    _placing = NO;
    _placedSticker = nil;
    if (_pulled >= 0) {
        SGRRecord *record = _records[(NSUInteger)_pulled];
        SGRSetCustomStickerCenter([record key], _stickerCenter);
        _pulledArtist.text = record.artist;
        [self customChanged:[record key]];
    }
    [self placeCaption];
}

#pragma mark scrolling, taps and turning

- (void)scrollViewDidScroll:(UIScrollView *)scroll {
    [self render];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scroll {
    [_tick prepare];
}

// Every scroll settles with a record on the focus.
- (void)scrollViewWillEndDragging:(UIScrollView *)scroll withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)target {
    if (!_records.count) return;
    CGFloat top = scroll.adjustedContentInset.top, step = [self step];
    CGFloat index = MIN(MAX(round((target->y + top) / step), 0), (CGFloat)(_records.count - 1));
    target->y = index * step - top;
}

// Turning starts only on the record out of the crate, its gatefold shut.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != _turner) return YES;
    if (_pulled < 0 || (_opened && !_placing)) return NO;
    return CGRectContainsPoint(CGRectInset([self pulledFrame], -20, -20), [_turner locationInView:_stage]);
}

// Dragging across the record turns it, half a turn for a cover's width, and lets go on its front or its back.
- (void)turned:(UIPanGestureRecognizer *)pan {
    if (_pulled < 0) return;
    if (_placing) {
        [self placeStickerAt:[pan locationInView:_stage]];
        return;
    }
    CATransformLayer *layer = _layers[(NSUInteger)_pulled];
    CGFloat across = [pan translationInView:_stage].x;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [layer removeAllAnimations];
            _turnStart = _turn;
            break;
        case UIGestureRecognizerStateChanged: {
            _turn = _turnStart + across / _width * M_PI;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            layer.transform = [self pulledPose];
            [CATransaction commit];
            [self light];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat thrown = _turn + [pan velocityInView:_stage].x / _width * M_PI * 0.2;
            CATransform3D was = layer.transform;
            _turn = round(thrown / M_PI) * M_PI;
            CABasicAnimation *settle = [CABasicAnimation animationWithKeyPath:@"transform"];
            settle.fromValue = [NSValue valueWithCATransform3D:was];
            settle.toValue = [NSValue valueWithCATransform3D:[self pulledPose]];
            settle.duration = 0.3;
            settle.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            layer.transform = [self pulledPose];
            [layer addAnimation:settle forKey:@"settle"];
            [CATransaction commit];
            // Kept within one turn, which looks the same.
            _turn = fmod(_turn, 2 * M_PI);
            [self light];
            break;
        }
        default:
            break;
    }
}

// A record in the crate comes out of it; the record out of it opens its album, its button opens or shuts its
// gatefold, and a tap anywhere else puts it back.
- (void)tapped:(UITapGestureRecognizer *)tap {
    NSUInteger count = _records.count;
    if (!count || _layers.count != count) return;
    CGPoint point = [tap locationInView:_stage];
    if (_pulled >= 0) {
        BOOL onRecord = CGRectContainsPoint(CGRectInset([self pulledFrame], -8, -8), point);
        if (!_customButton.hidden && CGRectContainsPoint(CGRectInset(_customButton.frame, -8, -8), point)) {
            if (_placing) [self finishPlacing];
            else [self showCustomize];
        } else if (_placing) {
            if (onRecord) [self placeStickerAt:point];
        } else if (!_gateButton.hidden && CGRectContainsPoint(CGRectInset(_gateButton.frame, -8, -8), point)) [self toggleGatefold];
        else if (CGRectContainsPoint(CGRectInset([self pulledFrame], -8, -8), point)) [self open:_records[(NSUInteger)_pulled]];
        else [self putBack];
        return;
    }
    CGFloat focus = [self focus], half = _width / 2, middle = _stage.bounds.size.width / 2;
    CATransform3D t = [self crateTransform];
    CGPoint corners[] = {project(t, -half, -_width, 0), project(t, half, -_width, 0), project(t, -half, 0, 0),
                         project(t, half, 0, 0), project(t, -half, 0, -kSpine), project(t, half, 0, -kSpine)};
    CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, minY = CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
    for (int c = 0; c < 6; c++) {
        minX = MIN(minX, corners[c].x);
        maxX = MAX(maxX, corners[c].x);
        minY = MIN(minY, corners[c].y);
        maxY = MAX(maxY, corners[c].y);
    }
    // The lower records lie over the ones above them.
    for (NSInteger i = (NSInteger)count - 1; i >= 0; i--) {
        if (_layers[(NSUInteger)i].hidden || i == _returning) continue;
        CGFloat x = point.x - middle, y = point.y - [self bottomOf:(NSUInteger)i focus:focus];
        if (x >= minX && x <= maxX && y >= minY && y <= maxY) {
            [self pullOut:(NSUInteger)i];
            return;
        }
    }
}

// Pushed onto this tab's stack, over the crate; back from it, the record is still out.
- (void)open:(SGRRecord *)record {
    if (record.local) {
        SGRShowLocalAlbumOf(self, record.local.tracks.firstObject.uri);
        return;
    }
    if (!SGOpenSpotifyURI([NSURL URLWithString:record.uri])) SGLog(@"records: cannot open %@", record.uri);
}

@end

UIViewController *SGRRecordsPageNew(void) {
    return [SGRRecordsPage new];
}

// The page is vitrine:records, and the bar gets a tab for it once.
__attribute__((constructor)) static void registerRecords(void) {
    if (!SGRedesignedUI()) return;
    SGRegisterModPage(kRecordsURI, ^UIViewController *{ return [SGRRecordsPage new]; });
    dispatch_async(dispatch_get_main_queue(), ^{
        SGRNavbarAddTabOnce(SGKeyRecordsTabAdded, @{SGTabTitle: @"Records", SGTabURI: kRecordsURI,
                                                    SGTabIcon: @"opticaldisc.fill", SGTabIconSet: SGTabIconSetSymbols});
    });
}
