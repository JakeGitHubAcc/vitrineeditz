// LocalFiles.h says what a tap on a local file's artist in the player offers.
//
// The sheet is the one Spotify opens for a tap on a track's artist, rebuilt (device, 9.1.94): a short sheet with a
// grabber, a row per artist -- the picture round, the name, "Artist" under it and Follow or Following at the
// trailing edge -- and a row for the album, its cover square, its name and its type. A row opens what it names.
//
// An artist is found by name with the Web API's search (GET api.spotify.com/v1/search, type artist), asked as the
// signed-in app (Shared/Navigation/WebAPI.h): the artist named exactly, else the first one found, which
// gives the row its picture. Whether the user follows them is asked the same way (GET /v1/me/following/contains)
// and Follow changes it (PUT or DELETE /v1/me/following); the button shows only once that has answered. An artist
// that cannot be found opens Spotify's search for the name instead.
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Navigation/Links.h"
#import "Shared/Navigation/WebAPI.h"
#import "Shared/Player/PlayerState.h"
#import "LocalAlbums.h"
#import "LocalFiles.h"

// The sheet's measures, read off Spotify's: the row, its picture, the side margin and the gap after the picture,
// the room above the first row for the grabber and under the last, and the corner.
static const CGFloat kRow = 76, kPicture = 56, kSide = 24, kGap = 16, kTop = 28, kBottom = 20, kCorner = 38;
static const CGFloat kFollowHeight = 34, kFollowPad = 16;

static BOOL (*sg_albumOpener)(UIViewController *owner, NSString *uri);

void SGLocalFilesSetAlbumOpener(BOOL (*open)(UIViewController *owner, NSString *uri)) {
    sg_albumOpener = open;
}

#pragma mark - the Web API

// Everything but letters and digits escaped, so an "&" or a "+" in a name stays part of it.
static NSString *escaped(NSString *text) {
    return [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet] ?: @"";
}

// The artist named `name`: {uri, id, image (an address, may be missing)}, nil when none was found.
static void findArtist(NSString *name, void (^done)(NSDictionary *artist)) {
    SGWebAPI(@"GET", [NSString stringWithFormat:@"search?type=artist&limit=10&q=%@", escaped(name)], ^(NSInteger status, id answer) {
        id items = status == 200 && [answer isKindOfClass:NSDictionary.class] ? answer[@"artists"][@"items"] : nil;
        NSDictionary *found = nil;
        for (id item in [items isKindOfClass:NSArray.class] ? items : @[]) {
            if (![item isKindOfClass:NSDictionary.class] || ![item[@"uri"] isKindOfClass:NSString.class] || ![item[@"id"] isKindOfClass:NSString.class]) continue;
            BOOL same = [item[@"name"] isKindOfClass:NSString.class] && [item[@"name"] caseInsensitiveCompare:name] == NSOrderedSame;
            if (same || !found) found = item;
            if (same) break;
        }
        if (!found) {
            SGLog(@"local files: no artist found for a local file's artist (search status %ld)", (long)status);
            done(nil);
            return;
        }
        NSMutableDictionary *artist = [@{@"uri": found[@"uri"], @"id": found[@"id"]} mutableCopy];
        id images = found[@"images"];
        // The smallest picture at least the row's size, as the list gives them largest first.
        for (id image in [images isKindOfClass:NSArray.class] ? images : @[]) {
            if (![image isKindOfClass:NSDictionary.class] || ![image[@"url"] isKindOfClass:NSString.class]) continue;
            if (!artist[@"image"] || [image[@"width"] doubleValue] >= kPicture * 3) artist[@"image"] = image[@"url"];
        }
        done(artist);
    });
}

static void openSearch(NSString *name) {
    SGOpenSpotifyURI([NSURL URLWithString:[@"spotify:search:" stringByAppendingString:escaped(name)]]);
}

#pragma mark - a row

@interface SGLocalLinkRow : UIControl
@property (nonatomic, readonly) UIImageView *picture;
@property (nonatomic, readonly) UILabel *title, *subtitle;
@property (nonatomic, readonly) UIButton *follow;
@property (nonatomic) BOOL round;
@end

@implementation SGLocalLinkRow

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _picture = [UIImageView new];
    _picture.contentMode = UIViewContentModeScaleAspectFill;
    _picture.clipsToBounds = YES;
    _picture.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _title = [UILabel new];
    _title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    _title.textColor = UIColor.whiteColor;
    _subtitle = [UILabel new];
    _subtitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    _follow = [UIButton buttonWithType:UIButtonTypeCustom];
    _follow.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [_follow setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _follow.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
    _follow.layer.borderWidth = 1;
    _follow.hidden = YES;
    for (UIView *view in @[_picture, _title, _subtitle]) {
        view.userInteractionEnabled = NO;
        [self addSubview:view];
    }
    [self addSubview:_follow];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? [UIColor colorWithWhite:1 alpha:0.06] : UIColor.clearColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    _picture.frame = CGRectMake(kSide, round((height - kPicture) / 2), kPicture, kPicture);
    _picture.layer.cornerRadius = self.round ? kPicture / 2 : 4;
    CGFloat trailing = width - kSide;
    if (!_follow.hidden) {
        NSString *word = [_follow titleForState:UIControlStateNormal] ?: @"";
        CGFloat wide = ceil([word sizeWithAttributes:@{NSFontAttributeName: _follow.titleLabel.font}].width) + 2 * kFollowPad;
        _follow.frame = CGRectMake(trailing - wide, round((height - kFollowHeight) / 2), wide, kFollowHeight);
        _follow.layer.cornerRadius = kFollowHeight / 2;
        trailing = CGRectGetMinX(_follow.frame) - kGap;
    }
    CGFloat x = CGRectGetMaxX(_picture.frame) + kGap, text = MAX(0, trailing - x);
    CGFloat titleHeight = ceil(_title.font.lineHeight), subtitleHeight = ceil(_subtitle.font.lineHeight);
    CGFloat top = round((height - titleHeight - 4 - subtitleHeight) / 2);
    _title.frame = CGRectMake(x, top, text, titleHeight);
    _subtitle.frame = CGRectMake(x, top + titleHeight + 4, text, subtitleHeight);
}

- (void)showFollowing:(BOOL)following {
    [_follow setTitle:following ? @"Following" : @"Follow" forState:UIControlStateNormal];
    _follow.hidden = NO;
    [self setNeedsLayout];
}

@end

#pragma mark - the sheet

@interface SGLocalLinksSheet : UIViewController
- (instancetype)initWithURI:(NSString *)uri artists:(NSArray<NSString *> *)artists album:(SGLocalAlbum *)album;
@end

@implementation SGLocalLinksSheet {
    NSString *_uri;
    NSArray<NSString *> *_artists;
    SGLocalAlbum *_album;
    NSMutableArray<SGLocalLinkRow *> *_rows;
    NSMutableDictionary<NSString *, NSDictionary *> *_found;   // name -> findArtist's answer
    NSMutableDictionary<NSString *, NSNumber *> *_following;   // artist id -> followed
}

- (instancetype)initWithURI:(NSString *)uri artists:(NSArray<NSString *> *)artists album:(SGLocalAlbum *)album {
    if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
    _uri = uri;
    _artists = artists;
    _album = album;
    _rows = [NSMutableArray array];
    _found = [NSMutableDictionary dictionary];
    _following = [NSMutableDictionary dictionary];
    self.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = self.sheetPresentationController;
    CGFloat height = kTop + kRow * (artists.count + (album ? 1 : 0)) + kBottom;
    sheet.detents = @[[UISheetPresentationControllerDetent customDetentWithIdentifier:@"links" resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
        return height;
    }]];
    sheet.prefersGrabberVisible = YES;
    sheet.preferredCornerRadius = kCorner;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.141 green:0.141 blue:0.141 alpha:1];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    for (NSString *name in _artists) {
        SGLocalLinkRow *row = [SGLocalLinkRow new];
        row.round = YES;
        row.title.text = name;
        row.subtitle.text = @"Artist";
        row.accessibilityLabel = [NSString stringWithFormat:@"%@, Artist", name];
        [row addTarget:self action:@selector(openArtist:) forControlEvents:UIControlEventTouchUpInside];
        [row.follow addTarget:self action:@selector(toggleFollow:) forControlEvents:UIControlEventTouchUpInside];
        [_rows addObject:row];
        [self.view addSubview:row];
        [self lookUp:name row:row];
    }
    if (_album) {
        SGLocalLinkRow *row = [SGLocalLinkRow new];
        row.title.text = _album.title;
        row.subtitle.text = SGLocalAlbumTypeName(SGLocalAlbumShownType(_album));
        row.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", row.title.text, row.subtitle.text];
        [row addTarget:self action:@selector(openAlbum:) forControlEvents:UIControlEventTouchUpInside];
        [_rows addObject:row];
        [self.view addSubview:row];
        __weak SGLocalLinkRow *weakRow = row;
        SGLocalAlbumCover(_album, kPicture, ^(UIImage *cover) {
            weakRow.picture.image = cover;
        });
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    [_rows enumerateObjectsUsingBlock:^(SGLocalLinkRow *row, NSUInteger i, BOOL *stop) {
        row.frame = CGRectMake(0, kTop + kRow * i, width, kRow);
    }];
}

// The artist's page and picture, then whether they are followed.
- (void)lookUp:(NSString *)name row:(SGLocalLinkRow *)row {
    __weak SGLocalLinksSheet *weakSelf = self;
    __weak SGLocalLinkRow *weakRow = row;
    findArtist(name, ^(NSDictionary *artist) {
        SGLocalLinksSheet *sheet = weakSelf;
        if (!sheet || !artist) return;
        sheet->_found[name] = artist;
        NSString *image = artist[@"image"];
        if (image) {
            [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:image] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                UIImage *picture = data ? [UIImage imageWithData:data] : nil;
                if (picture) dispatch_async(dispatch_get_main_queue(), ^{ weakRow.picture.image = picture; });
            }] resume];
        }
        SGWebAPI(@"GET", [@"me/following/contains?type=artist&ids=" stringByAppendingString:artist[@"id"]], ^(NSInteger status, id answer) {
            SGLocalLinksSheet *sheet = weakSelf;
            if (!sheet || status != 200 || ![answer isKindOfClass:NSArray.class] || ![answer count]) return;
            BOOL following = [[answer firstObject] boolValue];
            sheet->_following[artist[@"id"]] = @(following);
            [weakRow showFollowing:following];
        });
    });
}

- (NSString *)nameOf:(SGLocalLinkRow *)row {
    NSUInteger index = [_rows indexOfObject:row];
    return index < _artists.count ? _artists[index] : nil;
}

- (void)openArtist:(SGLocalLinkRow *)row {
    NSString *name = [self nameOf:row];
    if (!name) return;
    NSDictionary *artist = _found[name];
    [self dismissViewControllerAnimated:YES completion:^{
        if (artist && SGOpenSpotifyURI([NSURL URLWithString:artist[@"uri"]])) return;
        // Not found yet, or not at all: asked again, and Spotify's search for the name when there is no one.
        if (artist) {
            openSearch(name);
            return;
        }
        findArtist(name, ^(NSDictionary *found) {
            if (!found || !SGOpenSpotifyURI([NSURL URLWithString:found[@"uri"]])) openSearch(name);
        });
    }];
}

- (void)openAlbum:(SGLocalLinkRow *)row {
    NSString *uri = _uri;
    BOOL (*opener)(UIViewController *, NSString *) = sg_albumOpener;
    [self dismissViewControllerAnimated:YES completion:^{
        UIViewController *owner = SGTopController();
        if (owner && opener && !opener(owner, uri)) SGLog(@"local files: no local album for %@", uri);
    }];
}

// Followed at once on screen; put back if Spotify says no.
- (void)toggleFollow:(UIButton *)button {
    SGLocalLinkRow *row = (SGLocalLinkRow *)button.superview;
    NSDictionary *artist = _found[[self nameOf:row] ?: @""];
    NSNumber *was = artist ? _following[artist[@"id"]] : nil;
    if (!was) return;
    BOOL now = !was.boolValue;
    _following[artist[@"id"]] = @(now);
    [row showFollowing:now];
    __weak SGLocalLinksSheet *weakSelf = self;
    __weak SGLocalLinkRow *weakRow = row;
    SGWebAPI(now ? @"PUT" : @"DELETE", [@"me/following?type=artist&ids=" stringByAppendingString:artist[@"id"]], ^(NSInteger status, id answer) {
        if (status >= 200 && status < 300) return;
        SGLog(@"local files: following an artist failed (status %ld)", (long)status);
        SGLocalLinksSheet *sheet = weakSelf;
        if (!sheet) return;
        sheet->_following[artist[@"id"]] = was;
        [weakRow showFollowing:was.boolValue];
    });
}

@end

#pragma mark - opening it

// The names of the artists, as the player shows them ("C, A, B").
static NSArray<NSString *> *artistsOf(NSString *line) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *part in [line componentsSeparatedByString:@","]) {
        NSString *name = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length && ![names containsObject:name]) [names addObject:name];
    }
    return names;
}

void SGLocalFileShowLinks(NSString *uri, UIView *source) {
    NSDictionary *shown = SGLocalFileShown(uri);
    UIViewController *top = SGTopController();
    if (!shown || !top) return;
    NSArray<NSString *> *artists = artistsOf(shown[@"artist"] ?: @"");
    // The albums are scanned on first use, so the album's row shows from the next tap on.
    SGLocalAlbum *album = sg_albumOpener && SGLocalAlbums() ? SGLocalAlbumOfTrack(uri) : nil;
    if (!artists.count && !album) return;
    [top presentViewController:[[SGLocalLinksSheet alloc] initWithURI:uri artists:artists album:album] animated:YES completion:nil];
}
