// Library redesign: Local Albums, the local files gathered into albums (Shared/LocalFiles/LocalAlbums.h), the
// way the Music app shows a library's albums. A grid of covers two to a row, sorted by title, artist or when
// they were added (the ⋯ at the top), and each album's own page: its cover, title, artist and year, Play
// and Shuffle, and its tracks, a tap playing from that track and a hold offering Edit Info.
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
#import "Library.h"

static const CGFloat kCardGap = 16;
static const CGFloat kHeroSide = 240;

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

static NSString *clockText(NSInteger seconds) {
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                                               menu:[UIMenu menuWithChildren:@[sortBy]]];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"Sort By";
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

@implementation SGRLocalAlbumPage {
    SGLocalAlbum *_album;
    BOOL _various;
}

- (instancetype)initWithAlbum:(SGLocalAlbum *)album {
    if (!(self = [super initWithStyle:UITableViewStylePlain])) return nil;
    _album = album;
    _various = [album.artist isEqualToString:@"Various Artists"];
    self.title = album.title;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.separatorColor = SGRHairline();
    self.tableView.separatorInset = UIEdgeInsetsMake(0, SGRSideMargin + 36, 0, 0);
    self.tableView.tableHeaderView = [self hero];
    self.tableView.tableFooterView = [self footer];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(albumsChanged) name:SGLocalAlbumsDidChangeNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
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
    self.tableView.tableHeaderView = [self hero];
    self.tableView.tableFooterView = [self footer];
    [self.tableView reloadData];
}

- (UIView *)hero {
    CGFloat width = UIScreen.mainScreen.bounds.size.width;
    UIView *hero = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 0)];
    UIImageView *cover = coverView(SGRRadiusArtwork);
    cover.frame = CGRectMake(round((width - kHeroSide) / 2), SGRGrid * 2, kHeroSide, kHeroSide);
    showCover(cover, _album, kHeroSide);
    [hero addSubview:cover];

    UILabel *title = label(SGRFont(UIFontTextStyleTitle2, UIFontWeightBold, UIContentSizeCategoryExtraExtraLarge), SGRPrimary());
    UILabel *artist = label(SGRFont(UIFontTextStyleTitle2, UIFontWeightRegular, UIContentSizeCategoryExtraExtraLarge), SGRAccent());
    UILabel *about = label(SGRFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryExtraExtraLarge), SGRSecondary());
    title.text = _album.title;
    artist.text = _album.artist;
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:@"Local Files"];
    if (_album.year > 0) [parts addObject:[NSString stringWithFormat:@"%ld", (long)_album.year]];
    about.text = [parts componentsJoinedByString:@" · "];
    CGFloat y = CGRectGetMaxY(cover.frame) + SGRGrid * 2;
    for (UILabel *line in @[title, artist, about]) {
        line.textAlignment = NSTextAlignmentCenter;
        line.numberOfLines = line == title ? 2 : 1;
        CGSize fit = [line sizeThatFits:CGSizeMake(width - 2 * SGRSideMargin, CGFLOAT_MAX)];
        line.frame = CGRectMake(SGRSideMargin, y, width - 2 * SGRSideMargin, ceil(fit.height));
        y = CGRectGetMaxY(line.frame) + 2;
        [hero addSubview:line];
    }
    y += SGRGrid * 2;
    CGFloat buttonWidth = (width - 2 * SGRSideMargin - SGRActionSpacing) / 2;
    NSArray *buttons = @[@[@"Play", @"play.fill", @NO], @[@"Shuffle", @"shuffle", @YES]];
    for (NSUInteger i = 0; i < buttons.count; i++) {
        UIButtonConfiguration *look = [UIButtonConfiguration filledButtonConfiguration];
        look.title = buttons[i][0];
        look.image = [UIImage systemImageNamed:buttons[i][1]];
        look.imagePadding = SGRGrid;
        look.baseBackgroundColor = SGRElevated(SGRNeutralField());
        look.baseForegroundColor = SGRAccent();
        look.cornerStyle = UIButtonConfigurationCornerStyleLarge;
        BOOL shuffle = [buttons[i][2] boolValue];
        __weak SGRLocalAlbumPage *weakSelf = self;
        UIButton *button = [UIButton buttonWithConfiguration:look primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
            [weakSelf playFrom:0 shuffle:shuffle];
        }]];
        button.frame = CGRectMake(SGRSideMargin + (CGFloat)i * (buttonWidth + SGRActionSpacing), y, buttonWidth, SGRActionHeight);
        [hero addSubview:button];
    }
    hero.frame = CGRectMake(0, 0, width, y + SGRActionHeight + SGRGrid * 2);
    return hero;
}

- (UIView *)footer {
    UILabel *summary = label(SGRFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryExtraExtraLarge), SGRSecondary());
    NSUInteger count = _album.tracks.count;
    summary.text = [NSString stringWithFormat:@"%lu %@, %@", (unsigned long)count, count == 1 ? @"song" : @"songs", minutesText(_album.seconds)];
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width, 56)];
    summary.frame = CGRectMake(SGRSideMargin, 12, footer.bounds.size.width - 2 * SGRSideMargin, 20);
    [footer addSubview:summary];
    return footer;
}

- (void)playFrom:(NSUInteger)index shuffle:(BOOL)shuffle {
    __weak SGRLocalAlbumPage *weakSelf = self;
    SGLocalAlbumPlay(_album, index, shuffle, ^(NSString *error) {
        if (error && weakSelf) tell(weakSelf, @"Not played", error);
    });
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_album.tracks.count;
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    return _various ? 60 : 48;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"track"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"track"];
        cell.backgroundColor = UIColor.clearColor;
        UIView *selected = [UIView new];
        selected.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        cell.selectedBackgroundView = selected;
    }
    SGLocalTrack *track = _album.tracks[(NSUInteger)path.row];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = track.title;
    content.textProperties.font = SGRFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryExtraExtraLarge);
    content.textProperties.color = SGRPrimary();
    content.textProperties.numberOfLines = 1;
    if (_various && track.artist.length) {
        content.secondaryText = track.artist;
        content.secondaryTextProperties.font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryExtraExtraLarge);
        content.secondaryTextProperties.color = SGRSecondary();
    }
    NSString *number = track.number > 0 ? [NSString stringWithFormat:@"%ld", (long)track.number] : [NSString stringWithFormat:@"%ld", (long)path.row + 1];
    UILabel *index = label(SGRMonospacedDigitsFont(SGRFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryExtraExtraLarge)), SGRSecondary());
    index.text = number;
    index.textAlignment = NSTextAlignmentCenter;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, SGRSideMargin + 36, 0, SGRSideMargin);
    cell.contentConfiguration = content;
    static char kIndex;
    UILabel *old = objc_getAssociatedObject(cell, &kIndex);
    [old removeFromSuperview];
    index.frame = CGRectMake(SGRSideMargin, 0, 28, _various ? 60 : 48);
    [cell.contentView addSubview:index];
    objc_setAssociatedObject(cell, &kIndex, index, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UILabel *length = label(SGRMonospacedDigitsFont(SGRFont(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryExtraExtraLarge)), SGRSecondary());
    length.text = track.seconds > 0 ? clockText(track.seconds) : @"";
    [length sizeToFit];
    cell.accessoryView = length;
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    [self playFrom:(NSUInteger)path.row shuffle:NO];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)table contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point {
    SGLocalTrack *track = _album.tracks[(NSUInteger)path.row];
    __weak SGRLocalAlbumPage *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *play = [UIAction actionWithTitle:@"Play" image:[UIImage systemImageNamed:@"play"] identifier:nil handler:^(UIAction *action) {
            [weakSelf playFrom:(NSUInteger)path.row shuffle:NO];
        }];
        UIAction *edit = [UIAction actionWithTitle:@"Edit Info" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *action) {
            SGRLocalAlbumPage *page = weakSelf;
            if (page) SGLocalFilePresentEditor(page, track.uri);
        }];
        return [UIMenu menuWithChildren:@[play, edit]];
    }];
}
@end

void SGRShowLocalAlbums(UIViewController *owner) {
    SGShowPage(owner, [SGRLocalAlbumsPage new]);
}

BOOL SGRShowLocalAlbumOf(UIViewController *owner, NSString *uri) {
    SGLocalAlbum *album = SGLocalAlbumOfTrack(uri);
    if (!album) return NO;
    SGShowPage(owner, [[SGRLocalAlbumPage alloc] initWithAlbum:album]);
    return YES;
}
