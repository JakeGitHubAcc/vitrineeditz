// Records: the albums of the library, the ones saved on Spotify and the local ones (LocalAlbumsPage.m), as a crate
// of records flipped through. Opened from a tab of its own, vitrine:records (Shared/Navigation/Links.h), which the
// bar gets once (Navbar.h, SGRNavbarAddTabOnce) and the Add a Tab presets offer after that.
//
// The crate, as the prototype that matched the video had it: every record is its cover with a label strip along its
// bottom edge, the title and the artist, and leans back about that edge. The ones by the focus lie almost flat, so
// their labels are what is read; the further one is from it the more it stands up and shows its cover. From one
// record's bottom edge to the next is the first one's label and the next one's cover as the perspective shows them,
// so the crate packs itself as the tilt changes. Scrolling moves the focus a record per kStep points and settles on
// one; a tap on the focused record opens its album, a tap on another brings it to the focus. Behind the crate is
// the focused cover, blurred and darkened.
//
// Spotify's albums are the Web API's saved albums (GET /v1/me/albums, Shared/Navigation/WebAPI.h), every page of
// them, kept for the next open; the local ones come from Shared/LocalFiles/LocalAlbums.h. Both are listed newest
// first by when they were added, or by title or artist.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Redesigned/Navbar/Navbar.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/LocalFiles/LocalAlbums.h"
#import "Shared/Navigation/AddTabSheet.h"
#import "Shared/Navigation/Links.h"
#import "Shared/Navigation/TabIcons.h"
#import "Shared/Navigation/WebAPI.h"
#import "Library.h"

static NSString *const kRecordsURI = @"vitrine:records";
#define SGKeyRecordsSort @"spotifyglass.records.sort"
#define SGKeyRecordsShow @"spotifyglass.records.show"
#define SGKeyRecordsTabAdded @"spotifyglass.records.tabAdded"

// The crate's tuning, the prototype's: where the focus sits down the page, the tilt by it and far from it (degrees
// back from upright), how many records the tilt takes to open up, the room between records, the label's depth, the
// perspective's distance, the widest cover, and how far a scroll goes for each record.
static const CGFloat kFocusY = 0.42, kFlat = 88, kOpen = 58, kReach = 4, kGap = 6, kSpine = 18;
static const CGFloat kPerspective = 2400, kMaxWidth = 340, kStep = 64;
// Records further than this from the focus let their pictures go.
static const NSInteger kKeepPictures = 30;

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

static NSArray<SGRRecord *> *localRecords(void) {
    NSMutableArray<SGRRecord *> *records = [NSMutableArray array];
    for (SGLocalAlbum *album in SGLocalAlbums()) {
        if (!album.tracks.count) continue;
        SGRRecord *record = [SGRRecord new];
        record.title = album.title;
        record.artist = album.artist;
        record.local = album;
        record.added = album.added ?: NSDate.distantPast;
        [records addObject:record];
    }
    return records;
}

#pragma mark - the crate's geometry

static CGFloat radians(CGFloat degrees) {
    return degrees * M_PI / 180;
}

// How far back a record `distance` records from the focus leans.
static CGFloat tiltAt(CGFloat distance) {
    CGFloat x = MIN(fabs(distance) / kReach, 1);
    return kFlat + (kOpen - kFlat) * (x * x * (3 - 2 * x));
}

// The record leaned back `tilt` degrees about its bottom edge, in perspective from the focus `depth` points above
// that edge. The layer's anchor is the middle of the bottom edge.
static CATransform3D recordTransform(CGFloat tilt, CGFloat depth) {
    CATransform3D perspective = CATransform3DIdentity;
    perspective.m34 = -1 / kPerspective;
    CATransform3D t = CATransform3DMakeRotation(radians(tilt), 1, 0, 0);
    t = CATransform3DConcat(t, CATransform3DMakeTranslation(0, depth, 0));
    t = CATransform3DConcat(t, perspective);
    return CATransform3DConcat(t, CATransform3DMakeTranslation(0, -depth, 0));
}

static CGPoint project(CATransform3D t, CGFloat x, CGFloat y, CGFloat z) {
    CGFloat w = x * t.m14 + y * t.m24 + z * t.m34 + t.m44;
    if (w <= 0.001) w = 0.001;
    return CGPointMake((x * t.m11 + y * t.m21 + z * t.m31 + t.m41) / w, (x * t.m12 + y * t.m22 + z * t.m32 + t.m42) / w);
}

#pragma mark - the page

@interface SGRRecordsPage : SGPage
@end

@implementation SGRRecordsPage {
    NSArray<SGRRecord *> *_records;
    NSArray<CATransformLayer *> *_layers;
    NSArray<CALayer *> *_faces, *_spines;
    NSCache<NSString *, UIImage *> *_pictures;
    NSMutableSet<NSString *> *_asked;
    UIImageView *_backdrop;
    UIView *_stage;
    UILabel *_note;
    UIView *_spacer;
    CGFloat _width;
    NSInteger _focused;
    BOOL _loading;
    UISelectionFeedbackGenerator *_tick;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStylePlain])) return nil;
    self.title = @"Records";
    _pictures = [NSCache new];
    _asked = [NSMutableSet set];
    _focused = -1;
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
    _note = [UILabel new];
    _note.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    _note.font = [UIFont systemFontOfSize:15];
    _note.numberOfLines = 0;
    _note.textAlignment = NSTextAlignmentCenter;
    [back addSubview:_note];
    table.backgroundView = back;

    _spacer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    table.tableFooterView = _spacer;
    [table addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];
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

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return 0;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
    UIView *back = self.tableView.backgroundView;
    _note.frame = CGRectInset(back.bounds, 32, 0);
    [self fitSpacer];
    if (_width != [self recordWidth]) [self makeLayers];
    [self render];
}

#pragma mark the list

- (SGRRecordsSort)sort {
    return (SGRRecordsSort)MIN(MAX(SGInt(SGKeyRecordsSort, SGRRecordsSortAdded), 0), 2);
}

- (SGRRecordsShow)show {
    return (SGRRecordsShow)MIN(MAX(SGInt(SGKeyRecordsShow, SGRRecordsShowAll), 0), 2);
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
    UIMenu *menu = [UIMenu menuWithChildren:@[
        choices(@"Sort By", SGKeyRecordsSort, @[@"Recently Added", @"Title", @"Artist"], [self sort]),
        choices(@"Show", SGKeyRecordsShow, @[@"All Albums", @"Spotify", @"Local Albums"], [self show]),
    ]];
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease"] menu:menu];
    item.accessibilityLabel = @"Sort and Filter";
    self.navigationItem.rightBarButtonItem = item;
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
    [table setContentOffset:CGPointMake(0, (keep == NSNotFound ? 0 : (CGFloat)keep) * kStep - top) animated:NO];
    [self updateNote];
    [self render];
}

- (void)updateNote {
    if (_records.count) _note.text = nil;
    else if (_loading) _note.text = @"Loading your albums…";
    else _note.text = [self show] == SGRRecordsShowLocal ? @"No local albums yet." : @"No albums yet. Albums you save on Spotify and your local albums show here.";
    _note.hidden = !_note.text;
}

// The table scrolls a record per kStep: one screen past the last record's place.
- (void)fitSpacer {
    UITableView *table = self.tableView;
    UIEdgeInsets inset = table.adjustedContentInset;
    CGFloat visible = MAX(0, table.bounds.size.height - inset.top - inset.bottom);
    CGFloat height = visible + (CGFloat)(_records.count ? _records.count - 1 : 0) * kStep;
    if (fabs(_spacer.frame.size.height - height) < 0.5) return;
    _spacer.frame = CGRectMake(0, 0, table.bounds.size.width, height);
    table.tableFooterView = _spacer;
}

#pragma mark the records

- (CGFloat)recordWidth {
    return floor(MIN(kMaxWidth, self.tableView.bounds.size.width * 0.8));
}

- (void)makeLayers {
    for (CALayer *layer in _layers) [layer removeFromSuperlayer];
    _width = [self recordWidth];
    NSMutableArray<CATransformLayer *> *layers = [NSMutableArray array];
    NSMutableArray<CALayer *> *faces = [NSMutableArray array], *spines = [NSMutableArray array];
    CGFloat side = _width;
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
        // The label strip stands out behind the cover's bottom edge, so it hangs below the edge once leaned back.
        CALayer *spine = [CALayer layer];
        spine.bounds = CGRectMake(0, 0, side, kSpine);
        spine.anchorPoint = CGPointMake(0.5, 0);
        spine.position = CGPointMake(side / 2, side);
        spine.transform = CATransform3DMakeRotation(-M_PI_2, 1, 0, 0);
        spine.backgroundColor = [UIColor colorWithWhite:0.106 alpha:1].CGColor;
        spine.contentsScale = UIScreen.mainScreen.scale;
        [record addSublayer:spine];
        [_stage.layer addSublayer:record];
        [layers addObject:record];
        [faces addObject:face];
        [spines addObject:spine];
    }
    _layers = layers;
    _faces = faces;
    _spines = spines;
}

- (UIImage *)labelFor:(SGRRecord *)record {
    CGSize size = CGSizeMake(_width, kSpine);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor colorWithWhite:0.106 alpha:1] setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.alignment = NSTextAlignmentCenter;
        paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:record.title ?: @""
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightBold], NSForegroundColorAttributeName: UIColor.whiteColor}];
        if (record.artist.length) {
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:record.artist]
                attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:10], NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.75]}]];
        }
        [text addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0, text.length)];
        CGFloat height = ceil([UIFont systemFontOfSize:10].lineHeight);
        [text drawWithRect:CGRectMake(10, (size.height - height) / 2, size.width - 20, height)
                   options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine context:nil];
    }];
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
        [page render];
        if ((NSInteger)index == page->_focused) [page showBackdrop:picture];
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

- (void)showBackdrop:(UIImage *)picture {
    if (_backdrop.image == picture) return;
    [UIView transitionWithView:_backdrop duration:0.35 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:^{ self->_backdrop.image = picture; } completion:nil];
}

- (CGFloat)focus {
    UITableView *table = self.tableView;
    CGFloat focus = (table.contentOffset.y + table.adjustedContentInset.top) / kStep;
    return MIN(MAX(focus, 0), (CGFloat)(_records.count ? _records.count - 1 : 0));
}

// Where the focus sits, in the stage's coordinates.
- (CGFloat)focusLine {
    UITableView *table = self.tableView;
    UIEdgeInsets inset = table.adjustedContentInset;
    return inset.top + kFocusY * MAX(0, _stage.bounds.size.height - inset.top - inset.bottom);
}

- (CATransform3D)transformOf:(NSUInteger)index bottoms:(const CGFloat *)bottoms focus:(CGFloat)focus line:(CGFloat)line {
    return recordTransform(tiltAt((CGFloat)index - focus), bottoms[index] - line);
}

// Each record's bottom edge down the stage: from one to the next is the first one's label and the next one's
// cover, as their tilts show them. Placed so the focus, between two records, falls on the focus line.
- (void)bottoms:(CGFloat *)bottoms focus:(CGFloat)focus line:(CGFloat)line {
    NSUInteger count = _records.count;
    bottoms[0] = 0;
    for (NSUInteger i = 1; i < count; i++) {
        CGFloat above = tiltAt((CGFloat)(i - 1) - focus), here = tiltAt((CGFloat)i - focus);
        bottoms[i] = bottoms[i - 1] + kSpine * sin(radians(above)) + _width * cos(radians(here)) + kGap;
    }
    NSUInteger at = (NSUInteger)floor(focus);
    CGFloat part = focus - (CGFloat)at;
    CGFloat there = at + 1 < count ? bottoms[at] + part * (bottoms[at + 1] - bottoms[at]) : bottoms[at];
    for (NSUInteger i = 0; i < count; i++) bottoms[i] += line - there;
}

- (void)render {
    NSUInteger count = _records.count;
    if (!count || _layers.count != count || _width <= 0) return;
    CGFloat focus = [self focus], line = [self focusLine];
    CGFloat height = _stage.bounds.size.height, middle = _stage.bounds.size.width / 2;
    CGFloat *bottoms = malloc(count * sizeof(CGFloat));
    [self bottoms:bottoms focus:focus line:line];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < count; i++) {
        CATransformLayer *record = _layers[i];
        BOOL near = fabs((CGFloat)i - focus) <= kKeepPictures;
        BOOL shown = near && bottoms[i] > -kSpine && bottoms[i] - _width < height + kSpine;
        record.hidden = !shown;
        CALayer *face = _faces[i], *spine = _spines[i];
        if (!near) {
            face.contents = nil;
            spine.contents = nil;
            continue;
        }
        if (!shown) continue;
        record.position = CGPointMake(middle, bottoms[i]);
        record.transform = [self transformOf:i bottoms:bottoms focus:focus line:line];
        SGRRecord *item = _records[i];
        UIImage *picture = [_pictures objectForKey:[item key]];
        if (picture) face.contents = (id)picture.CGImage;
        else [self askPictureOf:i];
        if (!spine.contents) spine.contents = (id)[self labelFor:item].CGImage;
    }
    [CATransaction commit];
    free(bottoms);

    NSInteger focused = (NSInteger)lround(focus);
    if (focused != _focused) {
        if (_focused >= 0 && (self.tableView.isDragging || self.tableView.isDecelerating)) [_tick selectionChanged];
        _focused = focused;
        UIImage *picture = [_pictures objectForKey:[_records[(NSUInteger)focused] key]];
        if (picture) [self showBackdrop:picture];
    }
}

#pragma mark scrolling and taps

- (void)scrollViewDidScroll:(UIScrollView *)scroll {
    [self render];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scroll {
    [_tick prepare];
}

// Every scroll settles with a record on the focus.
- (void)scrollViewWillEndDragging:(UIScrollView *)scroll withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)target {
    if (!_records.count) return;
    CGFloat top = scroll.adjustedContentInset.top;
    CGFloat index = MIN(MAX(round((target->y + top) / kStep), 0), (CGFloat)(_records.count - 1));
    target->y = index * kStep - top;
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    NSUInteger count = _records.count;
    if (!count || _layers.count != count) return;
    CGPoint point = [tap locationInView:_stage];
    CGFloat focus = [self focus], line = [self focusLine], half = _width / 2;
    CGFloat *bottoms = malloc(count * sizeof(CGFloat));
    [self bottoms:bottoms focus:focus line:line];
    NSInteger hit = -1;
    // The lower records lie over the ones above them.
    for (NSInteger i = (NSInteger)count - 1; i >= 0 && hit < 0; i--) {
        if (_layers[(NSUInteger)i].hidden) continue;
        CATransform3D t = [self transformOf:(NSUInteger)i bottoms:bottoms focus:focus line:line];
        CGPoint corners[] = {project(t, -half, -_width, 0), project(t, half, -_width, 0), project(t, -half, 0, 0),
                             project(t, half, 0, 0), project(t, -half, 0, -kSpine), project(t, half, 0, -kSpine)};
        CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, minY = CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
        for (int c = 0; c < 6; c++) {
            minX = MIN(minX, corners[c].x);
            maxX = MAX(maxX, corners[c].x);
            minY = MIN(minY, corners[c].y);
            maxY = MAX(maxY, corners[c].y);
        }
        CGFloat x = point.x - _stage.bounds.size.width / 2, y = point.y - bottoms[i];
        if (x >= minX && x <= maxX && y >= minY && y <= maxY) hit = i;
    }
    free(bottoms);
    if (hit < 0) return;
    if (hit == lround(focus)) [self open:_records[(NSUInteger)hit]];
    else {
        UITableView *table = self.tableView;
        [table setContentOffset:CGPointMake(0, (CGFloat)hit * kStep - table.adjustedContentInset.top) animated:YES];
    }
}

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
