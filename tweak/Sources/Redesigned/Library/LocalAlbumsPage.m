// Library redesign: Local Albums, the local files gathered into albums (Shared/LocalFiles/LocalAlbums.h), the
// way the Music app shows a library's albums. A grid of covers two to a row, sorted by title, artist or when
// they were added (the ⋯ at the top), and each album's own page, laid out as the redesign lays out Spotify's
// album page: a tap on a track plays from it, and its ⋯ or a hold offers Edit Info.
//
// Opened from the button in Your Library's header (LibraryHeader.x) and from Go to Album in the player's ⋯
// while a local file plays (Redesigned/Player/PlayerMenu.m). Pages of the mod's (Settings/SGPage.h), so they
// go on Spotify's own stack.
//
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/LocalFiles/LocalAlbums.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Shared/Player/PlayerState.h"
#import "Redesigned/Album/Album.h"
#import "Library.h"

static const CGFloat kCardGap = 16;

static void tell(UIViewController *owner, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}

static NSString *minutesText(NSInteger seconds) {
    NSInteger minutes = (seconds + 30) / 60;
    if (minutes < 60) return [NSString stringWithFormat:@"%ld min", (long)minutes];
    return [NSString stringWithFormat:@"%ld hr %ld min", (long)(minutes / 60), (long)(minutes % 60)];
}

static UILabel *label(UIFont *font, UIColor *color) {
    UILabel *label = [UILabel new];
    label.font = font;
    label.textColor = color;
    return label;
}

#pragma mark - a cover

// The album's cover, a placeholder until it loads; the same view asked again for another album drops the
// first's answer.
static void showCover(UIImageView *view, SGLocalAlbum *album, CGFloat side) {
    static char kFor;
    objc_setAssociatedObject(view, &kFor, album, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.image = [UIImage systemImageNamed:@"music.note" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:side / 4]];
    view.contentMode = UIViewContentModeCenter;
    view.tintColor = SGRTertiary();
    __weak UIImageView *weakView = view;
    SGLocalAlbumCover(album, side, ^(UIImage *cover) {
        UIImageView *view = weakView;
        if (!cover || !view || objc_getAssociatedObject(view, &kFor) != album) return;
        view.contentMode = UIViewContentModeScaleAspectFill;
        view.image = cover;
    });
}

static UIImageView *coverView(CGFloat radius) {
    UIImageView *view = [UIImageView new];
    view.backgroundColor = SGRElevated(SGRNeutralField());
    view.clipsToBounds = YES;
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    return view;
}

#pragma mark - the albums

@interface SGRLocalAlbumCard : UIControl
@property (nonatomic, strong) SGLocalAlbum *album;
@property (nonatomic, strong, readonly) UIImageView *cover;
@property (nonatomic, strong, readonly) UILabel *title, *artist;
@end

@implementation SGRLocalAlbumCard
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _cover = coverView(SGRRadiusCover);
    _cover.userInteractionEnabled = NO;
    _title = label(SGRFont(UIFontTextStyleSubheadline, UIFontWeightMedium, UIContentSizeCategoryExtraExtraLarge), SGRPrimary());
    _artist = label(SGRFont(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryExtraExtraLarge), SGRSecondary());
    for (UIView *view in @[_cover, _title, _artist]) [self addSubview:view];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    return self;
}

- (void)setAlbum:(SGLocalAlbum *)album {
    _album = album;
    self.hidden = !album;
    if (!album) return;
    _title.text = album.title;
    _artist.text = album.artist;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", album.title, album.artist];
    showCover(_cover, album, self.bounds.size.width ?: 180);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.6 : 1;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    _cover.frame = CGRectMake(0, 0, width, width);
    CGFloat titleHeight = ceil(_title.font.lineHeight), artistHeight = ceil(_artist.font.lineHeight);
    _title.frame = CGRectMake(0, width + 6, width, titleHeight);
    _artist.frame = CGRectMake(0, CGRectGetMaxY(_title.frame), width, artistHeight);
}

+ (CGFloat)heightForWidth:(CGFloat)width {
    UIFont *title = SGRFont(UIFontTextStyleSubheadline, UIFontWeightMedium, UIContentSizeCategoryExtraExtraLarge);
    UIFont *artist = SGRFont(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryExtraExtraLarge);
    return width + 6 + ceil(title.lineHeight) + ceil(artist.lineHeight);
}
@end

@interface SGRLocalAlbumPairCell : UITableViewCell
@property (nonatomic, strong, readonly) SGRLocalAlbumCard *left, *right;
@end

@implementation SGRLocalAlbumPairCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:identifier])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _left = [SGRLocalAlbumCard new];
    _right = [SGRLocalAlbumCard new];
    [self.contentView addSubview:_left];
    [self.contentView addSubview:_right];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = (self.contentView.bounds.size.width - 2 * SGRSideMargin - kCardGap) / 2;
    CGFloat height = [SGRLocalAlbumCard heightForWidth:width];
    _left.frame = CGRectMake(SGRSideMargin, 0, width, height);
    _right.frame = CGRectMake(SGRSideMargin + width + kCardGap, 0, width, height);
}
@end

@interface SGRLocalAlbumsPage : SGPage
@end

@interface SGRLocalAlbumPage : SGPage
- (instancetype)initWithAlbum:(SGLocalAlbum *)album;
@end

@implementation SGRLocalAlbumsPage {
    NSArray<SGLocalAlbum *> *_albums;
    UIView *_empty;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStylePlain])) return nil;
    self.title = @"Local Albums";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = UIColor.blackColor;
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(rescan:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;
    [self updateSortButton];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(albumsChanged) name:SGLocalAlbumsDidChangeNotification object:nil];
    [self albumsChanged];
    SGLocalAlbumsRefresh(nil);
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
    if (_empty) SGFitNote(self.tableView, _empty, 24, 24);
}

- (SGLocalAlbumSort)sort {
    return (SGLocalAlbumSort)MIN(MAX(SGInt(SGKeyLocalAlbumsSort, SGLocalAlbumSortTitle), 0), 2);
}

- (void)updateSortButton {
    NSArray<NSString *> *names = @[@"Title", @"Artist", @"Recently Added"];
    NSMutableArray<UIMenuElement *> *choices = [NSMutableArray array];
    SGLocalAlbumSort current = [self sort];
    __weak SGRLocalAlbumsPage *weakSelf = self;
    for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
        UIAction *choice = [UIAction actionWithTitle:names[(NSUInteger)i] image:nil identifier:nil handler:^(UIAction *action) {
            SGSetInt(SGKeyLocalAlbumsSort, i);
            [weakSelf updateSortButton];
            [weakSelf albumsChanged];
        }];
        choice.state = i == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [choices addObject:choice];
    }
    UIMenu *sortBy = [UIMenu menuWithTitle:@"Sort By" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:choices];
    UIBarButtonItem *sort = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                              menu:[UIMenu menuWithChildren:@[sortBy]]];
    sort.accessibilityLabel = @"Sort By";
    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithPrimaryAction:[UIAction actionWithTitle:@"Add from Google Drive"
        image:[UIImage systemImageNamed:@"plus"] identifier:nil handler:^(UIAction *action) {
            SGRLocalAlbumsPage *page = weakSelf;
            if (page) SGRAskDriveImport(page);
        }]];
    self.navigationItem.rightBarButtonItems = @[sort, add];
}

- (void)rescan:(UIRefreshControl *)refresh {
    SGLocalAlbumsRefresh(^{ [refresh endRefreshing]; });
}

- (void)albumsChanged {
    _albums = SGLocalAlbumsSorted(SGLocalAlbums(), [self sort]);
    if (!_albums.count && !_empty) {
        _empty = SGNote(@"No local files yet. Put songs in the Spotify folder in the Files app (On My iPhone ▸ Spotify) and "
                         "turn on Show audio files from this device in Spotify's settings. Pull down to look again.");
        self.tableView.tableFooterView = _empty;
    } else if (_albums.count && _empty) {
        _empty = nil;
        self.tableView.tableFooterView = [UIView new];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)(_albums.count + 1) / 2;
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    CGFloat width = (table.bounds.size.width - 2 * SGRSideMargin - kCardGap) / 2;
    return [SGRLocalAlbumCard heightForWidth:width] + 2 * SGRGrid + 4;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    SGRLocalAlbumPairCell *cell = [table dequeueReusableCellWithIdentifier:@"pair"];
    if (!cell) {
        cell = [[SGRLocalAlbumPairCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"pair"];
        [cell.left addTarget:self action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
        [cell.right addTarget:self action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
    }
    [cell setNeedsLayout];
    [cell layoutIfNeeded];
    NSUInteger first = (NSUInteger)path.row * 2;
    cell.left.album = first < _albums.count ? _albums[first] : nil;
    cell.right.album = first + 1 < _albums.count ? _albums[first + 1] : nil;
    return cell;
}

- (void)open:(SGRLocalAlbumCard *)card {
    if (card.album) SGShowPage(self, [[SGRLocalAlbumPage alloc] initWithAlbum:card.album]);
}
@end

#pragma mark - an album

// The page Spotify's own album page is under the redesign (Redesigned/Album/), built from the same Kit: the
// cover full bleed across the top dissolving into a field of its main color, the title, the artist and the
// kind and year centered on the bottom of the dissolve, shuffle, a white Play capsule and ⋯ under them, the
// tracks on the field with a hairline under each, and the year and the length under the last.

// The album's numbers (AlbumHeader.x): how much of the hero the dissolve covers, and the scrim over the top
// that keeps the status bar and the back button legible on a bright cover.
static const CGFloat kDissolve = 0.46, kTopScrim = 140, kTopScrimAlpha = 0.28;
// The hero runs a little taller than the cover is wide, as the Music app's album page does.
static const CGFloat kHeroAspect = 1.1;
static const CGFloat kTrackRow = 56, kRowMore = 44;

@interface SGRLocalAlbumHero : UIView
@property (nonatomic, readonly) UIImageView *picture;
@property (nonatomic, copy) UIColor *fieldColor;
@end

@implementation SGRLocalAlbumHero {
    CAGradientLayer *_scrim, *_dissolve;
    UIView *_extension;   // iOS 26's UIBackgroundExtensionView around the picture, nil before it
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.clipsToBounds = YES;
    _picture = [[UIImageView alloc] initWithFrame:self.bounds];
    _picture.contentMode = UIViewContentModeScaleAspectFill;
    _picture.clipsToBounds = YES;
    // The cover stays whole at the top and the system carries its bottom edge down the rest, as the album's
    // hero does; before iOS 26 it fills.
    Class extension = NSClassFromString(@"UIBackgroundExtensionView");
    if (extension) {
        _extension = [[extension alloc] initWithFrame:self.bounds];
        [_extension setValue:@NO forKey:@"automaticallyPlacesContentView"];
        [_extension setValue:_picture forKey:@"contentView"];
        [self addSubview:_extension];
    } else {
        _picture.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_picture];
    }
    _scrim = [CAGradientLayer layer];
    _scrim.zPosition = 1;
    _scrim.colors = @[(id)[UIColor colorWithWhite:0 alpha:kTopScrimAlpha].CGColor, (id)UIColor.clearColor.CGColor];
    [self.layer addSublayer:_scrim];
    _dissolve = [CAGradientLayer layer];
    _dissolve.zPosition = 2;
    _dissolve.locations = @[@0, @0.62, @1];
    [self.layer addSublayer:_dissolve];
    self.fieldColor = SGRNeutralField();
    return self;
}

- (void)setFieldColor:(UIColor *)color {
    if (!color || [_fieldColor isEqual:color]) return;
    _fieldColor = [color copy];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _dissolve.colors = @[(id)[color colorWithAlphaComponent:0].CGColor, (id)[color colorWithAlphaComponent:0.72].CGColor, (id)color.CGColor];
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (_extension) {
        _extension.frame = bounds;
        _picture.frame = CGRectMake(0, 0, bounds.size.width, MIN(bounds.size.width, bounds.size.height));
    }
    _scrim.frame = CGRectMake(0, 0, bounds.size.width, MIN(kTopScrim, bounds.size.height));
    CGFloat fade = round(bounds.size.height * kDissolve);
    _dissolve.frame = CGRectMake(0, bounds.size.height - fade, bounds.size.width, fade);
    [CATransaction commit];
}
@end

// A button for the header's row to draw and fire (SGRActionRow.h reads a glyph and a word off a control of
// Spotify's): a control the size of its glyph, never on screen, whose action is the page's.
static UIControl *rowSource(NSString *symbol, NSString *word, void (^tapped)(void)) {
    UIControl *control = [[UIControl alloc] initWithFrame:CGRectMake(0, 0, SGRActionHeight, SGRActionHeight)];
    UIImageView *glyph = [[UIImageView alloc] initWithFrame:control.bounds];
    glyph.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]];
    glyph.contentMode = UIViewContentModeCenter;
    glyph.tintColor = SGRPrimary();
    [control addSubview:glyph];
    control.accessibilityLabel = word;
    [control addAction:[UIAction actionWithHandler:^(UIAction *action) { tapped(); }] forControlEvents:UIControlEventPrimaryActionTriggered];
    return control;
}

@interface SGRLocalTrackCell : UITableViewCell
@property (nonatomic, strong, readonly) UILabel *title, *artist;
@property (nonatomic, strong, readonly) UIButton *more;
@property (nonatomic) BOOL credited;
@end

@implementation SGRLocalTrackCell {
    UIView *_hairline;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:identifier])) return nil;
    self.backgroundColor = UIColor.clearColor;
    UIView *selected = [UIView new];
    selected.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    self.selectedBackgroundView = selected;
    _title = label(SGRFont(UIFontTextStyleCallout, UIFontWeightRegular, UIContentSizeCategoryLarge), SGRPrimary());
    _artist = label(SGRFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryLarge), SGRSecondary());
    _more = [UIButton buttonWithType:UIButtonTypeSystem];
    [_more setImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold]]
           forState:UIControlStateNormal];
    _more.tintColor = SGRSecondary();
    _more.showsMenuAsPrimaryAction = YES;
    _more.accessibilityLabel = @"More";
    _hairline = [UIView new];
    _hairline.backgroundColor = SGRHairline();
    for (UIView *view in @[_title, _artist, _more, _hairline]) [self.contentView addSubview:view];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width, height = self.contentView.bounds.size.height;
    _more.frame = CGRectMake(width - SGRSideMargin - kRowMore + 12, round((height - kRowMore) / 2), kRowMore, kRowMore);
    CGFloat text = CGRectGetMinX(_more.frame) - SGRGrid - SGRSideMargin;
    CGFloat titleHeight = ceil(_title.font.lineHeight), artistHeight = ceil(_artist.font.lineHeight);
    _artist.hidden = !self.credited;
    if (self.credited) {
        CGFloat top = round((height - titleHeight - 2 - artistHeight) / 2);
        _title.frame = CGRectMake(SGRSideMargin, top, text, titleHeight);
        _artist.frame = CGRectMake(SGRSideMargin, top + titleHeight + 2, text, artistHeight);
    } else {
        _title.frame = CGRectMake(SGRSideMargin, round((height - titleHeight) / 2), text, titleHeight);
    }
    CGFloat line = 1 / (self.window.screen.scale ?: UIScreen.mainScreen.scale);
    _hairline.frame = CGRectMake(SGRSideMargin, height - line, width - 2 * SGRSideMargin, line);
}
@end

@interface SGRLocalAlbumPage () <SGPlayerStateObserver>
@end

@implementation SGRLocalAlbumPage {
    SGLocalAlbum *_album;
    SGRArtworkField *_field;
    SGRLocalAlbumHero *_hero;
    SGRHeaderInfo *_info;
    UIView *_header;
    UIControl *_playSource, *_shuffleSource, *_moreSource;
    CGFloat _laidOutWidth;
    NSString *_playing;
}

- (instancetype)initWithAlbum:(SGLocalAlbum *)album {
    if (!(self = [super initWithStyle:UITableViewStylePlain])) return nil;
    _album = album;
    self.title = album.title;
    // The title shows in the bar only once the header has scrolled away, as on Spotify's album page.
    self.navigationItem.title = @"";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UITableView *table = self.tableView;
    table.backgroundColor = UIColor.clearColor;
    table.separatorStyle = UITableViewCellSeparatorStyleNone;
    table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _field = [SGRArtworkField new];
    _field.mainColor = YES;
    _field.bleed = UIEdgeInsetsMake(600, 0, 600, 0);
    table.backgroundView = _field;

    __weak SGRLocalAlbumPage *weakSelf = self;
    _playSource = rowSource(@"play.fill", @"Play", ^{ [weakSelf playFrom:0 shuffle:NO]; });
    _shuffleSource = rowSource(@"shuffle", @"Shuffle", ^{ [weakSelf playFrom:0 shuffle:YES]; });
    _moreSource = rowSource(@"ellipsis", @"More", ^{ [weakSelf showAlbumMenu]; });
    _hero = [SGRLocalAlbumHero new];
    _info = [SGRHeaderInfo new];
    _header = [UIView new];
    [_header addSubview:_hero];
    [_header addSubview:_info];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(albumsChanged) name:SGLocalAlbumsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fieldColorChanged:) name:SGRFieldColorDidChangeNotification object:_field];
    SGAddPlayerStateObserver(self);
    _playing = SGURIString(SGPlayerState().track.URI);
    [self showAlbum];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
    CGFloat width = self.tableView.bounds.size.width;
    if (width > 0 && fabs(width - _laidOutWidth) > 0.5) [self layoutHeader];
}

- (void)showAlbum {
    NSMutableArray<NSString *> *kind = [NSMutableArray arrayWithObject:@"Album"];
    if (_album.year > 0) [kind addObject:[NSString stringWithFormat:@"%ld", (long)_album.year]];
    [_info showTitle:_album.title creator:_album.artist length:[kind componentsJoinedByString:@" · "] about:nil];
    [_info showShuffle:_shuffleSource play:_playSource trailing:_moreSource trailingFallback:[UIImage systemImageNamed:@"ellipsis"]
             playColor:_field.fieldColor];
    CGFloat side = UIScreen.mainScreen.bounds.size.width * kHeroAspect;
    __weak SGRLocalAlbumPage *weakSelf = self;
    SGLocalAlbumCover(_album, side, ^(UIImage *cover) {
        SGRLocalAlbumPage *page = weakSelf;
        if (!page || !cover) return;
        page->_hero.picture.image = cover;
        [page->_field setArtwork:cover identity:page->_album.title animated:page.viewIfLoaded.window != nil];
    });
    self.tableView.tableFooterView = [self footer];
    _laidOutWidth = 0;
    [self.view setNeedsLayout];
    [self.tableView reloadData];
}

// The hero reaches to the top of the title plus SGRHeaderInfoTitleRise, so the title and the artist sit on the
// bottom of its dissolve, and the row stands SGRHeaderInfoBottom over the first track (SGRHeaderInfo.h).
- (void)layoutHeader {
    CGFloat width = self.tableView.bounds.size.width;
    _laidOutWidth = width;
    CGFloat heroHeight = round(width * kHeroAspect);
    CGFloat content = [_info contentHeightForWidth:width];
    CGFloat height = heroHeight - SGRHeaderInfoTitleRise + content + SGRHeaderInfoBottom;
    _header.frame = CGRectMake(0, 0, width, height);
    _hero.frame = CGRectMake(0, 0, width, heroHeight);
    _info.frame = _header.bounds;
    self.tableView.tableHeaderView = _header;
}

- (void)fieldColorChanged:(NSNotification *)note {
    _hero.fieldColor = _field.fieldColor;
    [_info showShuffle:_shuffleSource play:_playSource trailing:_moreSource trailingFallback:[UIImage systemImageNamed:@"ellipsis"]
             playColor:_field.fieldColor];
}

- (void)scrollViewDidScroll:(UIScrollView *)scroll {
    BOOL past = scroll.contentOffset.y > _hero.bounds.size.height - 120;
    NSString *title = past ? _album.title : @"";
    if (![self.navigationItem.title isEqualToString:title]) self.navigationItem.title = title;
}

// The same album after a scan (a rename in Edit Info), found by one of its tracks.
- (void)albumsChanged {
    SGLocalAlbum *now = nil;
    for (SGLocalTrack *track in _album.tracks) {
        now = SGLocalAlbumOfTrack(track.uri);
        if (now) break;
    }
    if (!now) return;
    _album = now;
    self.title = now.title;
    [self showAlbum];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *playing = SGURIString(state.track.URI);
    if ((playing || _playing) && ![playing isEqualToString:_playing]) {
        _playing = playing;
        [self.tableView reloadData];
    }
}

// The year and how long it runs, under the last track, as Spotify's album page closes.
- (UIView *)footer {
    CGFloat width = UIScreen.mainScreen.bounds.size.width;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 0)];
    CGFloat y = SGRGrid * 3;
    if (_album.year > 0) {
        UILabel *year = label(SGRFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, UIContentSizeCategoryExtraLarge), SGRPrimary());
        year.text = [NSString stringWithFormat:@"%ld", (long)_album.year];
        year.frame = CGRectMake(SGRSideMargin, y, width - 2 * SGRSideMargin, ceil(year.font.lineHeight));
        [footer addSubview:year];
        y = CGRectGetMaxY(year.frame) + 2;
    }
    UILabel *summary = label(SGRFont(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryExtraLarge), SGRSecondary());
    NSUInteger count = _album.tracks.count;
    summary.text = [NSString stringWithFormat:@"%lu %@ • %@", (unsigned long)count, count == 1 ? @"song" : @"songs", minutesText(_album.seconds)];
    summary.frame = CGRectMake(SGRSideMargin, y, width - 2 * SGRSideMargin, ceil(summary.font.lineHeight));
    [footer addSubview:summary];
    footer.frame = CGRectMake(0, 0, width, CGRectGetMaxY(summary.frame) + SGRGrid * 4);
    return footer;
}

- (void)playFrom:(NSUInteger)index shuffle:(BOOL)shuffle {
    __weak SGRLocalAlbumPage *weakSelf = self;
    SGLocalAlbumPlay(_album, index, shuffle, ^(NSString *error) {
        if (error && weakSelf) tell(weakSelf, @"Not played", error);
    });
}

- (void)showAlbumMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:_album.title message:_album.artist preferredStyle:UIAlertControllerStyleActionSheet];
    __weak SGRLocalAlbumPage *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Play" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf playFrom:0 shuffle:NO];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Shuffle" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf playFrom:0 shuffle:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UIMenu *)menuForTrack:(NSUInteger)row {
    SGLocalTrack *track = _album.tracks[row];
    __weak SGRLocalAlbumPage *weakSelf = self;
    UIAction *play = [UIAction actionWithTitle:@"Play" image:[UIImage systemImageNamed:@"play"] identifier:nil handler:^(UIAction *action) {
        [weakSelf playFrom:row shuffle:NO];
    }];
    UIAction *edit = [UIAction actionWithTitle:@"Edit Info" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *action) {
        SGRLocalAlbumPage *page = weakSelf;
        if (page) SGLocalFilePresentEditor(page, track.uri);
    }];
    return [UIMenu menuWithChildren:@[play, edit]];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_album.tracks.count;
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    return kTrackRow;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    SGRLocalTrackCell *cell = [table dequeueReusableCellWithIdentifier:@"track"];
    if (!cell) cell = [[SGRLocalTrackCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"track"];
    SGLocalTrack *track = _album.tracks[(NSUInteger)path.row];
    cell.title.text = track.title;
    // The playing track's title in the accent, as Spotify marks it.
    cell.title.textColor = _playing && [_playing isEqualToString:track.uri] ? SGRAccent() : SGRPrimary();
    // The artist line only where it says something the header does not (Redesigned/Album/AlbumCredits.m).
    cell.credited = track.artist.length && !SGRCreditRepeatsAlbum(_album.artist, track.artist, track.title);
    cell.artist.text = track.artist;
    cell.more.menu = [self menuForTrack:(NSUInteger)path.row];
    cell.accessibilityLabel = cell.credited ? [NSString stringWithFormat:@"%@, %@", track.title, track.artist] : track.title;
    [cell setNeedsLayout];
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    [self playFrom:(NSUInteger)path.row shuffle:NO];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)table contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point {
    __weak SGRLocalAlbumPage *weakSelf = self;
    NSUInteger row = (NSUInteger)path.row;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        return [weakSelf menuForTrack:row];
    }];
}
@end

void SGRShowLocalAlbums(UIViewController *owner) {
    SGShowPage(owner, [SGRLocalAlbumsPage new]);
}

UIViewController *SGRLocalAlbumsPageNew(void) {
    return [SGRLocalAlbumsPage new];
}

BOOL SGRShowLocalAlbumOf(UIViewController *owner, NSString *uri) {
    SGLocalAlbum *album = SGLocalAlbumOfTrack(uri);
    if (!album) return NO;
    SGShowPage(owner, [[SGRLocalAlbumPage alloc] initWithAlbum:album]);
    return YES;
}
