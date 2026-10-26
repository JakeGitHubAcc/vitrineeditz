// Player redesign: Share as Instagram Note, from the player's ⋯ (PlayerMenu.m). A sheet that writes the playing
// song up as a note and shows it as Instagram's notes tray would, over a round copy of the cover where the
// profile picture goes.
//
// Instagram takes a note from no other app (no URL scheme, no share extension, no public API writes one), so
// the note is copied and Instagram opened on the messages, whose top row is the notes tray: the user taps their
// own note there, pastes and shares. Only what a note carries reaches the people who see it, which is its text,
// at most 60 characters; the bubble, its color and its font are Instagram's. So everything here is text:
//
//     Template     the song written up a few ways, or the user's own words (Custom, from typing in the field)
//     Letters      Unicode's styled letters (bold, script, double-struck, small caps and so on), which show as
//                  such anywhere; on the whole note or on the song's name only
//     Case         as it is, lowercase, UPPERCASE
//     Emoji        one at the front
//     Match album colors
//                  the cover's main colors as colored emoji (hearts, circles, squares or things in nature) before
//                  the note, after it or on both sides, and this sheet tinted with the cover
//
// A template too long for 60 cuts the song's name, artist or album with an ellipsis, the longest first. The
// count is of characters as Instagram's field counts them, one an emoji or a styled letter.
//
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Redesigned/Kit/SGRBridges.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "Redesigned/Kit/SGRPalette.h"
#import "Shared/Player/PlayerState.h"
#import "Player.h"

static const NSUInteger kNoteLimit = 60;
static const CGFloat kSide = 20, kRowHeight = 48, kGap = 10;

#pragma mark - the text

static NSUInteger characterCount(NSString *text) {
    __block NSUInteger count = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(NSString *part, NSRange range, NSRange enclosing, BOOL *stop) { count++; }];
    return count;
}

// `text` to its first `keep` characters and an ellipsis, or as it is when it is no longer.
static NSString *shortened(NSString *text, NSUInteger keep) {
    __block NSUInteger seen = 0, end = text.length;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(NSString *part, NSRange range, NSRange enclosing, BOOL *stop) {
        if (seen++ == keep) { end = range.location; *stop = YES; }
    }];
    if (end >= text.length) return text;
    NSString *head = [[text substringToIndex:end] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return [head stringByAppendingString:@"…"];
}

// {t} the song's name, {a} its artist, {l} its album.
static NSArray<NSString *> *templates(void) {
    return @[@"{t} — {a}", @"{t} · {a}", @"listening to {t} by {a}", @"now playing: {t}", @"on repeat: {t}",
             @"{a} – {t}", @"{t}", @"{t}, from {l}", @"can't stop playing {t}"];
}

typedef NS_ENUM(NSInteger, SGRNoteLetters) {
    SGRNoteLettersPlain, SGRNoteLettersBold, SGRNoteLettersSansBold, SGRNoteLettersItalic, SGRNoteLettersBoldItalic,
    SGRNoteLettersScript, SGRNoteLettersGothic, SGRNoteLettersDouble, SGRNoteLettersMono, SGRNoteLettersSmallCaps,
    SGRNoteLettersCircled, SGRNoteLettersWide, SGRNoteLettersCount
};

static NSString *lettersName(SGRNoteLetters letters) {
    switch (letters) {
        case SGRNoteLettersPlain: return @"Plain";
        case SGRNoteLettersBold: return @"Bold";
        case SGRNoteLettersSansBold: return @"Sans Bold";
        case SGRNoteLettersItalic: return @"Italic";
        case SGRNoteLettersBoldItalic: return @"Bold Italic";
        case SGRNoteLettersScript: return @"Script";
        case SGRNoteLettersGothic: return @"Gothic";
        case SGRNoteLettersDouble: return @"Outline";
        case SGRNoteLettersMono: return @"Typewriter";
        case SGRNoteLettersSmallCaps: return @"Small Caps";
        case SGRNoteLettersCircled: return @"Bubbles";
        case SGRNoteLettersWide: return @"Wide";
        default: return @"";
    }
}

static void appendScalar(NSMutableString *out, UTF32Char scalar) {
    if (scalar > 0xFFFF) {
        unichar pair[2] = {(unichar)(0xD800 + ((scalar - 0x10000) >> 10)), (unichar)(0xDC00 + ((scalar - 0x10000) & 0x3FF))};
        [out appendString:[NSString stringWithCharacters:pair length:2]];
    } else {
        unichar single = (unichar)scalar;
        [out appendString:[NSString stringWithCharacters:&single length:1]];
    }
}

// The styled scalar for an ASCII letter or digit, 0 for one the style has none of.
static UTF32Char styledScalar(SGRNoteLetters letters, unichar c) {
    BOOL upper = c >= 'A' && c <= 'Z', lower = c >= 'a' && c <= 'z', digit = c >= '0' && c <= '9';
    if (!upper && !lower && !digit) return 0;
    // Mathematical Alphanumeric Symbols, U+1D400 on: where each style's capitals, small letters and digits begin.
    UTF32Char capitals = 0, smalls = 0, digits = 0;
    switch (letters) {
        case SGRNoteLettersBold: capitals = 0x1D400; smalls = 0x1D41A; digits = 0x1D7CE; break;
        case SGRNoteLettersSansBold: capitals = 0x1D5D4; smalls = 0x1D5EE; digits = 0x1D7EC; break;
        case SGRNoteLettersItalic:
            if (c == 'h') return 0x210E;   // the one italic letter Unicode had already
            capitals = 0x1D434; smalls = 0x1D44E; break;
        case SGRNoteLettersBoldItalic: capitals = 0x1D468; smalls = 0x1D482; break;
        case SGRNoteLettersScript: capitals = 0x1D4D0; smalls = 0x1D4EA; break;   // bold script, which has no gaps
        case SGRNoteLettersGothic: capitals = 0x1D56C; smalls = 0x1D586; break;   // bold fraktur, likewise
        case SGRNoteLettersDouble: {
            static const struct { unichar letter; UTF32Char scalar; } older[] = {
                {'C', 0x2102}, {'H', 0x210D}, {'N', 0x2115}, {'P', 0x2119}, {'Q', 0x211A}, {'R', 0x211D}, {'Z', 0x2124}};
            for (size_t i = 0; i < sizeof older / sizeof *older; i++) if (older[i].letter == c) return older[i].scalar;
            capitals = 0x1D538; smalls = 0x1D552; digits = 0x1D7D8; break;
        }
        case SGRNoteLettersMono: capitals = 0x1D670; smalls = 0x1D68A; digits = 0x1D7F6; break;
        case SGRNoteLettersSmallCaps: {
            if (digit) return 0;
            static NSString *caps = @"ᴀʙᴄᴅᴇꜰɢʜɪᴊᴋʟᴍɴᴏᴘǫʀꜱᴛᴜᴠᴡxʏᴢ";
            return [caps characterAtIndex:(NSUInteger)((upper ? c - 'A' : c - 'a'))];
        }
        case SGRNoteLettersCircled:
            if (digit) return c == '0' ? 0x24EA : 0x2460 + (UTF32Char)(c - '1');
            capitals = 0x24B6; smalls = 0x24D0; break;
        case SGRNoteLettersWide: capitals = 0xFF21; smalls = 0xFF41; digits = 0xFF10; break;
        default: return 0;
    }
    if (upper) return capitals ? capitals + (UTF32Char)(c - 'A') : 0;
    if (lower) return smalls ? smalls + (UTF32Char)(c - 'a') : 0;
    return digits ? digits + (UTF32Char)(c - '0') : 0;
}

static NSString *styled(NSString *text, SGRNoteLetters letters) {
    if (letters == SGRNoteLettersPlain || !text.length) return text;
    NSMutableString *out = [NSMutableString stringWithCapacity:text.length * 2];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        UTF32Char scalar = styledScalar(letters, c);
        if (scalar) appendScalar(out, scalar);
        else if (letters == SGRNoteLettersWide && c == ' ') appendScalar(out, 0x3000);
        else [out appendString:[NSString stringWithCharacters:&c length:1]];
    }
    return out;
}

typedef NS_ENUM(NSInteger, SGRNoteCase) { SGRNoteCaseAsIs, SGRNoteCaseLower, SGRNoteCaseUpper };

static NSString *cased(NSString *text, SGRNoteCase textCase) {
    switch (textCase) {
        case SGRNoteCaseLower: return text.lowercaseString;
        case SGRNoteCaseUpper: return text.uppercaseString;
        default: return text;
    }
}

static NSArray<NSString *> *leadEmoji(void) {
    return @[@"", @"🎧", @"🎶", @"🎵", @"💿", @"📻", @"🔁", @"🔥", @"✨", @"🌙", @"💭", @"🫶"];
}

#pragma mark - the cover's colors

typedef NS_ENUM(NSInteger, SGRNoteHue) {
    SGRNoteHueRed, SGRNoteHueOrange, SGRNoteHueYellow, SGRNoteHueGreen, SGRNoteHueBlue, SGRNoteHuePurple,
    SGRNoteHuePink, SGRNoteHueBrown, SGRNoteHueBlack, SGRNoteHueWhite, SGRNoteHueGray, SGRNoteHueCount
};

typedef NS_ENUM(NSInteger, SGRNoteShape) { SGRNoteShapeHearts, SGRNoteShapeCircles, SGRNoteShapeSquares, SGRNoteShapeNature, SGRNoteShapeCount };

static NSString *shapeName(SGRNoteShape shape) {
    return @[@"Hearts", @"Circles", @"Squares", @"Nature"][shape];
}

// Each shape's emoji, in SGRNoteHue's order. Circles and squares have no pink and no gray.
static NSArray<NSString *> *shapeEmoji(SGRNoteShape shape) {
    switch (shape) {
        case SGRNoteShapeCircles: return @[@"🔴", @"🟠", @"🟡", @"🟢", @"🔵", @"🟣", @"🟣", @"🟤", @"⚫", @"⚪", @"⚪"];
        case SGRNoteShapeSquares: return @[@"🟥", @"🟧", @"🟨", @"🟩", @"🟦", @"🟪", @"🟪", @"🟫", @"⬛", @"⬜", @"⬜"];
        case SGRNoteShapeNature: return @[@"🍒", @"🍊", @"🌼", @"🍀", @"🫐", @"🍇", @"🌸", @"🍂", @"🌑", @"☁️", @"🪨"];
        default: return @[@"❤️", @"🧡", @"💛", @"💚", @"💙", @"💜", @"🩷", @"🤎", @"🖤", @"🤍", @"🩶"];
    }
}

static SGRNoteHue hueOf(CGFloat r, CGFloat g, CGFloat b, CGFloat *weight) {
    CGFloat high = MAX(r, MAX(g, b)), low = MIN(r, MIN(g, b));
    CGFloat saturation = high > 0 ? (high - low) / high : 0;
    *weight = 1 + saturation * 2;   // a colored pixel says more about a cover than a gray one
    if (high < 0.2) return SGRNoteHueBlack;
    if (saturation < 0.2) return high > 0.78 ? SGRNoteHueWhite : high < 0.4 ? SGRNoteHueBlack : SGRNoteHueGray;
    CGFloat hue;
    if (high == r) hue = fmod((g - b) / (high - low), 6);
    else if (high == g) hue = (b - r) / (high - low) + 2;
    else hue = (r - g) / (high - low) + 4;
    hue *= 60;
    if (hue < 0) hue += 360;
    if (hue < 45 && high < 0.55) return SGRNoteHueBrown;
    if (hue < 14 || hue >= 340) return SGRNoteHueRed;
    if (hue < 42) return SGRNoteHueOrange;
    if (hue < 70) return SGRNoteHueYellow;
    if (hue < 165) return SGRNoteHueGreen;
    if (hue < 255) return SGRNoteHueBlue;
    if (hue < 290) return SGRNoteHuePurple;
    return SGRNoteHuePink;
}

// The cover's main hues, most first: up to three, each at least an eighth of the picture, and the mean color
// of the first, through `main`.
static NSArray<NSNumber *> *coverHues(UIImage *image, UIColor **main) {
    CGImageRef picture = image.CGImage;
    if (!picture) return @[];
    enum { kGrid = 24 };
    uint8_t pixels[kGrid * kGrid * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, kGrid, kGrid, 8, kGrid * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return @[];
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, kGrid, kGrid), picture);
    CGContextRelease(context);
    CGFloat weights[SGRNoteHueCount] = {0}, sums[SGRNoteHueCount][3] = {{0}}, total = 0;
    for (int i = 0; i < kGrid * kGrid; i++) {
        CGFloat r = pixels[i * 4] / 255.0, g = pixels[i * 4 + 1] / 255.0, b = pixels[i * 4 + 2] / 255.0, weight;
        SGRNoteHue hue = hueOf(r, g, b, &weight);
        weights[hue] += weight;
        sums[hue][0] += r * weight; sums[hue][1] += g * weight; sums[hue][2] += b * weight;
        total += weight;
    }
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (NSInteger hue = 0; hue < SGRNoteHueCount; hue++) if (weights[hue] > 0) [order addObject:@(hue)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        CGFloat x = weights[a.integerValue], y = weights[b.integerValue];
        return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray<NSNumber *> *picked = [NSMutableArray array];
    for (NSNumber *hue in order) {
        if (picked.count == 3 || (picked.count && weights[hue.integerValue] < total / 8)) break;
        [picked addObject:hue];
    }
    if (picked.count && main) {
        NSInteger first = picked[0].integerValue;
        CGFloat weight = weights[first];
        *main = [UIColor colorWithRed:sums[first][0] / weight green:sums[first][1] / weight blue:sums[first][2] / weight alpha:1];
    }
    return picked;
}

// A color bright enough to fill a button with, keeping the hue: a dark cover's color lifted.
static UIColor *buttonColor(UIColor *color) {
    CGFloat hue, saturation, brightness, alpha;
    if (![color getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha]) return SGRAccent();
    return [UIColor colorWithHue:hue saturation:MIN(saturation, 0.8) brightness:MAX(brightness, 0.8) alpha:1];
}

static BOOL light(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.55;
}

#pragma mark - the rows

// A row that opens a menu: its name on the left, the choice on the right.
@interface SGRNoteRow : UIButton
@property (nonatomic, readonly) UILabel *name, *value;
@end

@implementation SGRNoteRow

- (instancetype)initWithName:(NSString *)name {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    self.layer.cornerRadius = 12;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.showsMenuAsPrimaryAction = YES;
    _name = [UILabel new];
    _name.text = name;
    _name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _name.textColor = SGRPrimary();
    _value = [UILabel new];
    _value.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _value.textColor = SGRSecondary();
    _value.textAlignment = NSTextAlignmentRight;
    for (UILabel *label in @[_name, _value]) {
        label.userInteractionEnabled = NO;
        [self addSubview:label];
    }
    UIImageView *chevrons = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.up.chevron.down"
                                                                         withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]]];
    chevrons.tintColor = SGRTertiary();
    chevrons.tag = 1;
    [self addSubview:chevrons];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    UIView *chevrons = [self viewWithTag:1];
    CGSize mark = chevrons.intrinsicContentSize;
    chevrons.frame = CGRectMake(size.width - 14 - mark.width, (size.height - mark.height) / 2, mark.width, mark.height);
    CGFloat nameWidth = MIN([_name sizeThatFits:size].width, size.width * 0.45);
    _name.frame = CGRectMake(14, 0, nameWidth, size.height);
    CGFloat valueLeft = CGRectGetMaxX(_name.frame) + 10;
    _value.frame = CGRectMake(valueLeft, 0, CGRectGetMinX(chevrons.frame) - 8 - valueLeft, size.height);
}

- (NSString *)accessibilityLabel {
    return _name.text;
}

- (NSString *)accessibilityValue {
    return _value.text;
}

@end

#pragma mark - the sheet

@interface SGRNoteSheet : UIViewController <UITextFieldDelegate>
@end

@implementation SGRNoteSheet {
    NSString *_title, *_artist, *_album;
    UIImage *_cover;
    NSArray<NSNumber *> *_hues;
    UIColor *_coverColor;

    NSInteger _template;        // into templates(), or -1 for the user's own words in _custom
    NSString *_custom;
    SGRNoteLetters _letters;
    BOOL _lettersOnName;
    SGRNoteCase _case;
    NSInteger _lead;
    BOOL _match;
    SGRNoteShape _shape;
    NSInteger _colorsAt;        // 0 before, 1 after, 2 both sides

    UIScrollView *_scroll;
    UILabel *_heading;
    UIView *_stage, *_bubble, *_tailBig, *_tailSmall;
    UILabel *_bubbleText, *_caption;
    UIImageView *_avatar;
    UIView *_fieldBox;
    UITextField *_field;
    UILabel *_counter;
    SGRNoteRow *_templateRow, *_lettersRow, *_lettersOnRow, *_caseRow, *_leadRow, *_shapeRow, *_colorsAtRow;
    UIView *_matchRow;
    UISwitch *_matchSwitch;
    UIButton *_share, *_copy;
    UILabel *_footnote;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    SPTPlayerTrack *track = SGPlayerState().track;
    NSDictionary *metadata = [track.metadata isKindOfClass:NSDictionary.class] ? track.metadata : nil;
    _title = track.trackTitle.length ? track.trackTitle : @"";
    _artist = track.artistName ?: @"";
    _album = [metadata[@"album_title"] isKindOfClass:NSString.class] ? metadata[@"album_title"] : @"";
    _cover = SGRNowPlayingArtwork(NULL, NULL);
    UIColor *main = nil;
    _hues = _cover ? coverHues(_cover, &main) : @[];
    _coverColor = main;

    _template = MIN(MAX(SGInt(SGRKeyNoteTemplate, 0), 0), (NSInteger)templates().count - 1);
    _letters = MIN(MAX(SGInt(SGRKeyNoteLetters, SGRNoteLettersPlain), 0), SGRNoteLettersCount - 1);
    _lettersOnName = SGInt(SGRKeyNoteLettersOn, 0) == 1;
    _case = MIN(MAX(SGInt(SGRKeyNoteCase, SGRNoteCaseAsIs), 0), SGRNoteCaseUpper);
    _lead = MIN(MAX(SGInt(SGRKeyNoteEmoji, 1), 0), (NSInteger)leadEmoji().count - 1);
    _match = SGEnabled(SGRKeyNoteMatchCover) && _hues.count;
    _shape = MIN(MAX(SGInt(SGRKeyNoteShape, SGRNoteShapeHearts), 0), SGRNoteShapeCount - 1);
    _colorsAt = MIN(MAX(SGInt(SGRKeyNoteColorsAt, 1), 0), 2);

    self.modalPresentationStyle = UIModalPresentationPageSheet;
    SGPresentDark(self);
    UISheetPresentationController *sheet = self.sheetPresentationController;
    sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
    sheet.prefersGrabberVisible = YES;
    sheet.prefersEdgeAttachedInCompactHeight = YES;
    return self;
}

#pragma mark the note

- (NSString *)filled:(NSString *)template title:(NSString *)title artist:(NSString *)artist album:(NSString *)album {
    NSString *out = [template stringByReplacingOccurrencesOfString:@"{t}" withString:@"\x01"];
    out = [out stringByReplacingOccurrencesOfString:@"{a}" withString:@"\x02"];
    out = [out stringByReplacingOccurrencesOfString:@"{l}" withString:@"\x03"];
    out = cased(out, _case);
    BOOL nameOnly = _lettersOnName && _letters != SGRNoteLettersPlain;
    NSString *name = cased(title, _case);
    if (nameOnly) name = styled(name, _letters);
    out = [out stringByReplacingOccurrencesOfString:@"\x01" withString:name];
    out = [out stringByReplacingOccurrencesOfString:@"\x02" withString:cased(artist, _case)];
    out = [out stringByReplacingOccurrencesOfString:@"\x03" withString:cased(album, _case)];
    return nameOnly ? out : styled(out, _letters);
}

- (NSString *)plainFilled:(NSString *)template title:(NSString *)title artist:(NSString *)artist album:(NSString *)album {
    NSString *out = [template stringByReplacingOccurrencesOfString:@"{t}" withString:title];
    out = [out stringByReplacingOccurrencesOfString:@"{a}" withString:artist];
    return [out stringByReplacingOccurrencesOfString:@"{l}" withString:album];
}

- (NSArray<NSString *> *)colorEmoji {
    if (!_match) return @[];
    NSArray<NSString *> *table = shapeEmoji(_shape);
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSNumber *hue in _hues) {
        NSString *emoji = table[hue.integerValue];
        if (![out containsObject:emoji]) [out addObject:emoji];
    }
    return out;
}

// The note around `body`: the emoji at the front, and the cover's colors where they go.
- (NSString *)decorated:(NSString *)body {
    NSArray<NSString *> *colors = self.colorEmoji;
    NSString *before = @"", *after = @"";
    if (colors.count) {
        NSString *run = [colors componentsJoinedByString:@""];
        if (_colorsAt != 1) before = [run stringByAppendingString:@" "];
        if (_colorsAt != 0) {
            NSString *back = _colorsAt == 2 ? [colors.reverseObjectEnumerator.allObjects componentsJoinedByString:@""] : run;
            after = [@" " stringByAppendingString:back];
        }
    }
    NSString *lead = leadEmoji()[_lead];
    if (lead.length) lead = [lead stringByAppendingString:@" "];
    return [NSString stringWithFormat:@"%@%@%@%@", before, lead, body, after];
}

// The note, and the template's plain words for the field. A template's song name, artist and album are cut,
// the longest first, until the note fits.
- (NSString *)noteWithPlain:(NSString **)plain {
    if (_template < 0) {
        if (plain) *plain = _custom;
        return [self decorated:styled(cased(_custom ?: @"", _case), _letters)];
    }
    NSString *template = templates()[_template];
    NSUInteger keep[3] = {characterCount(_title), characterCount(_artist), characterCount(_album)};
    NSString *originals[3] = {_title, _artist, _album};
    BOOL used[3] = {[template containsString:@"{t}"], [template containsString:@"{a}"], [template containsString:@"{l}"]};
    NSString *parts[3], *note = nil;
    for (int round = 0; round < 400; round++) {
        for (int i = 0; i < 3; i++) parts[i] = shortened(originals[i], keep[i]);
        note = [self decorated:[self filled:template title:parts[0] artist:parts[1] album:parts[2]]];
        if (characterCount(note) <= kNoteLimit) break;
        int longest = -1;
        for (int i = 0; i < 3; i++) if (used[i] && keep[i] > 3 && (longest < 0 || keep[i] > keep[longest])) longest = i;
        if (longest < 0) break;
        keep[longest] -= 1;
    }
    if (plain) *plain = [self plainFilled:template title:parts[0] artist:parts[1] album:parts[2]];
    return note;
}

- (NSString *)note {
    return [self noteWithPlain:NULL];
}

#pragma mark views

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    [_scroll addSubview:label];
    return label;
}

- (SGRNoteRow *)rowNamed:(NSString *)name {
    SGRNoteRow *row = [[SGRNoteRow alloc] initWithName:name];
    [_scroll addSubview:row];
    return row;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (@available(iOS 26.0, *)) {
    } else {
        self.view.backgroundColor = UIColor.systemBackgroundColor;
    }
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:_scroll];

    _heading = [self labelWithFont:[UIFont systemFontOfSize:22 weight:UIFontWeightBold] color:SGRPrimary()];
    _heading.text = @"Instagram Note";
    _heading.accessibilityTraits = UIAccessibilityTraitHeader;

    // The preview: the notes tray's own look, a bubble over the picture with two dots of tail, "Your note" under.
    _stage = [UIView new];
    _stage.layer.cornerRadius = 22;
    _stage.layer.cornerCurve = kCACornerCurveContinuous;
    _stage.clipsToBounds = YES;
    [_scroll addSubview:_stage];
    _avatar = [UIImageView new];
    _avatar.contentMode = UIViewContentModeScaleAspectFill;
    _avatar.clipsToBounds = YES;
    _avatar.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    _avatar.image = _cover;
    [_stage addSubview:_avatar];
    UIColor *bubbleColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.16 alpha:1];
    _tailBig = [UIView new];
    _tailSmall = [UIView new];
    _bubble = [UIView new];
    for (UIView *piece in @[_tailBig, _tailSmall, _bubble]) {
        piece.backgroundColor = bubbleColor;
        [_stage addSubview:piece];
    }
    _bubble.layer.cornerCurve = kCACornerCurveContinuous;
    _bubble.layer.shadowColor = UIColor.blackColor.CGColor;
    _bubble.layer.shadowOpacity = 0.25;
    _bubble.layer.shadowRadius = 8;
    _bubble.layer.shadowOffset = CGSizeMake(0, 2);
    _bubbleText = [UILabel new];
    _bubbleText.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _bubbleText.textColor = UIColor.whiteColor;
    _bubbleText.textAlignment = NSTextAlignmentCenter;
    _bubbleText.numberOfLines = 3;
    _bubbleText.lineBreakMode = NSLineBreakByTruncatingTail;
    [_bubble addSubview:_bubbleText];
    _caption = [UILabel new];
    _caption.text = @"Your note";
    _caption.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _caption.textAlignment = NSTextAlignmentCenter;
    [_stage addSubview:_caption];

    _fieldBox = [UIView new];
    _fieldBox.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _fieldBox.layer.cornerRadius = 12;
    _fieldBox.layer.cornerCurve = kCACornerCurveContinuous;
    [_scroll addSubview:_fieldBox];
    _field = [UITextField new];
    _field.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    _field.textColor = SGRPrimary();
    _field.tintColor = SGRAccent();
    _field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Write a note"
                                                                   attributes:@{NSForegroundColorAttributeName: SGRTertiary()}];
    _field.returnKeyType = UIReturnKeyDone;
    _field.clearButtonMode = UITextFieldViewModeWhileEditing;
    _field.delegate = self;
    _field.accessibilityLabel = @"Note";
    [_field addTarget:self action:@selector(typed) forControlEvents:UIControlEventEditingChanged];
    [_fieldBox addSubview:_field];
    _counter = [UILabel new];
    _counter.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    _counter.textAlignment = NSTextAlignmentRight;
    [_fieldBox addSubview:_counter];

    _templateRow = [self rowNamed:@"Template"];
    _lettersRow = [self rowNamed:@"Letters"];
    _lettersOnRow = [self rowNamed:@"Letters On"];
    _caseRow = [self rowNamed:@"Case"];
    _leadRow = [self rowNamed:@"Emoji"];

    _matchRow = [UIView new];
    _matchRow.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _matchRow.layer.cornerRadius = 12;
    _matchRow.layer.cornerCurve = kCACornerCurveContinuous;
    UILabel *matchName = [UILabel new];
    matchName.text = @"Match Album Colors";
    matchName.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    matchName.textColor = SGRPrimary();
    matchName.tag = 1;
    [_matchRow addSubview:matchName];
    _matchSwitch = [UISwitch new];
    _matchSwitch.on = _match;
    _matchSwitch.enabled = _hues.count > 0;
    _matchSwitch.accessibilityLabel = @"Match Album Colors";
    [_matchSwitch addTarget:self action:@selector(matchChanged) forControlEvents:UIControlEventValueChanged];
    [_matchRow addSubview:_matchSwitch];
    [_scroll addSubview:_matchRow];
    _shapeRow = [self rowNamed:@"Color Emoji"];
    _colorsAtRow = [self rowNamed:@"Colors Go"];

    UIButtonConfiguration *share = [UIButtonConfiguration filledButtonConfiguration];
    share.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    share.title = @"Copy & Open Instagram";
    share.image = [UIImage systemImageNamed:@"arrow.up.forward.app"];
    share.imagePadding = 8;
    share.buttonSize = UIButtonConfigurationSizeLarge;
    _share = [UIButton buttonWithConfiguration:share primaryAction:nil];
    [_share addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_share];
    UIButtonConfiguration *copy = [UIButtonConfiguration plainButtonConfiguration];
    copy.title = @"Copy Note Only";
    _copy = [UIButton buttonWithConfiguration:copy primaryAction:nil];
    [_copy addTarget:self action:@selector(copyTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_copy];

    _footnote = [self labelWithFont:[UIFont systemFontOfSize:12 weight:UIFontWeightRegular] color:SGRTertiary()];
    _footnote.text = @"Instagram takes notes from no other app, so this copies the note and opens Instagram on your messages: "
                     @"tap your note at the top, paste, and share. People see the text and emoji just as above; the bubble is "
                     @"Instagram's own. To attach the song itself, use the music button in Instagram's note editor.\n\n"
                     @"Styled letters are Unicode characters, so they show for everyone, but screen readers may spell them out.";

    [self refresh];
}

- (void)refresh {
    NSString *plain = nil;
    NSString *note = [self noteWithPlain:&plain];
    if (!_field.isFirstResponder) _field.text = plain;
    _bubbleText.text = note.length ? note : @"Write a note";
    _bubbleText.alpha = note.length ? 1 : 0.5;
    NSUInteger count = characterCount(note);
    _counter.text = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)count, (unsigned long)kNoteLimit];
    BOOL fits = count > 0 && count <= kNoteLimit;
    _counter.textColor = count > kNoteLimit ? UIColor.systemRedColor : SGRTertiary();
    _share.enabled = fits;
    _copy.enabled = count > 0;

    // The colors: the cover's, or the redesign's own.
    UIColor *tint = _match && _coverColor ? buttonColor(_coverColor) : SGRAccent();
    _stage.backgroundColor = _match && _coverColor ? SGRFieldColorFor(_coverColor) : SGRElevated(SGRNeutralField());
    _caption.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    UIButtonConfiguration *share = _share.configuration;
    share.baseBackgroundColor = tint;
    share.baseForegroundColor = light(tint) ? UIColor.blackColor : UIColor.whiteColor;
    _share.configuration = share;
    UIButtonConfiguration *copy = _copy.configuration;
    copy.baseForegroundColor = tint;
    _copy.configuration = copy;
    _matchSwitch.onTintColor = tint;
    _field.tintColor = tint;

    [self rebuildMenus];
    [self.view setNeedsLayout];
}

- (UIAction *)choice:(NSString *)title on:(BOOL)on handler:(void (^)(void))handler {
    UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *a) { handler(); }];
    action.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;
    return action;
}

- (void)rebuildMenus {
    __weak SGRNoteSheet *weakSelf = self;
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    NSArray<NSString *> *all = templates();
    for (NSInteger i = 0; i < (NSInteger)all.count; i++) {
        NSString *example = shortened([self plainFilled:all[i] title:_title artist:_artist album:_album], 40);
        [items addObject:[self choice:example on:_template == i handler:^{
            SGRNoteSheet *me = weakSelf;
            if (!me) return;
            me->_template = i;
            SGSetInt(SGRKeyNoteTemplate, i);
            [me->_field resignFirstResponder];
            [me refresh];
        }]];
    }
    if (_template < 0) [items addObject:[self choice:@"Custom" on:YES handler:^{}]];
    _templateRow.menu = [UIMenu menuWithChildren:items];
    _templateRow.value.text = _template < 0 ? @"Custom" : shortened([self plainFilled:all[_template] title:@"Song" artist:@"Artist" album:@"Album"], 30);

    [items removeAllObjects];
    for (NSInteger i = 0; i < SGRNoteLettersCount; i++) {
        NSString *sample = [NSString stringWithFormat:@"%@  %@", styled(@"Abc", (SGRNoteLetters)i), lettersName((SGRNoteLetters)i)];
        [items addObject:[self choice:sample on:_letters == i handler:^{
            SGRNoteSheet *me = weakSelf;
            if (!me) return;
            me->_letters = (SGRNoteLetters)i;
            SGSetInt(SGRKeyNoteLetters, i);
            [me refresh];
        }]];
    }
    _lettersRow.menu = [UIMenu menuWithChildren:items];
    _lettersRow.value.text = [NSString stringWithFormat:@"%@ %@", styled(@"Abc", _letters), lettersName(_letters)];

    _lettersOnRow.menu = [UIMenu menuWithChildren:@[
        [self choice:@"Whole Note" on:!_lettersOnName handler:^{ [weakSelf setLettersOnName:NO]; }],
        [self choice:@"Song Name Only" on:_lettersOnName handler:^{ [weakSelf setLettersOnName:YES]; }],
    ]];
    _lettersOnRow.value.text = _lettersOnName ? @"Song Name Only" : @"Whole Note";

    NSArray<NSString *> *cases = @[@"As It Is", @"lowercase", @"UPPERCASE"];
    [items removeAllObjects];
    for (NSInteger i = 0; i < (NSInteger)cases.count; i++) {
        [items addObject:[self choice:cases[i] on:_case == i handler:^{
            SGRNoteSheet *me = weakSelf;
            if (!me) return;
            me->_case = (SGRNoteCase)i;
            SGSetInt(SGRKeyNoteCase, i);
            [me refresh];
        }]];
    }
    _caseRow.menu = [UIMenu menuWithChildren:items];
    _caseRow.value.text = cases[_case];

    NSArray<NSString *> *leads = leadEmoji();
    [items removeAllObjects];
    for (NSInteger i = 0; i < (NSInteger)leads.count; i++) {
        [items addObject:[self choice:leads[i].length ? leads[i] : @"None" on:_lead == i handler:^{
            SGRNoteSheet *me = weakSelf;
            if (!me) return;
            me->_lead = i;
            SGSetInt(SGRKeyNoteEmoji, i);
            [me refresh];
        }]];
    }
    _leadRow.menu = [UIMenu menuWithChildren:items];
    _leadRow.value.text = leads[_lead].length ? leads[_lead] : @"None";

    [items removeAllObjects];
    for (NSInteger i = 0; i < SGRNoteShapeCount; i++) {
        NSMutableArray<NSString *> *sample = [NSMutableArray array];
        NSArray<NSString *> *table = shapeEmoji((SGRNoteShape)i);
        for (NSNumber *hue in _hues) if (![sample containsObject:table[hue.integerValue]]) [sample addObject:table[hue.integerValue]];
        NSString *title = [NSString stringWithFormat:@"%@  %@", [sample componentsJoinedByString:@""], shapeName((SGRNoteShape)i)];
        [items addObject:[self choice:title on:_shape == i handler:^{
            SGRNoteSheet *me = weakSelf;
            if (!me) return;
            me->_shape = (SGRNoteShape)i;
            SGSetInt(SGRKeyNoteShape, i);
            [me refresh];
        }]];
    }
    _shapeRow.menu = [UIMenu menuWithChildren:items];
    _shapeRow.value.text = [NSString stringWithFormat:@"%@ %@", [self.colorEmoji componentsJoinedByString:@""], shapeName(_shape)];

    NSArray<NSString *> *places = @[@"Before", @"After", @"Both Sides"];
    [items removeAllObjects];
    for (NSInteger i = 0; i < (NSInteger)places.count; i++) {
        [items addObject:[self choice:places[i] on:_colorsAt == i handler:^{
            SGRNoteSheet *me = weakSelf;
            if (!me) return;
            me->_colorsAt = i;
            SGSetInt(SGRKeyNoteColorsAt, i);
            [me refresh];
        }]];
    }
    _colorsAtRow.menu = [UIMenu menuWithChildren:items];
    _colorsAtRow.value.text = places[_colorsAt];
}

- (void)setLettersOnName:(BOOL)onName {
    _lettersOnName = onName;
    SGSetInt(SGRKeyNoteLettersOn, onName ? 1 : 0);
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat left = kSide + safe.left, width = self.view.bounds.size.width - left - kSide - safe.right;
    CGFloat y = 28;
    _heading.frame = CGRectMake(left, y, width, ceil(_heading.font.lineHeight));
    y = CGRectGetMaxY(_heading.frame) + 14;

    // The stage: the bubble sized to its text, at most 220 wide, over a 96pt picture.
    CGFloat avatarSide = 96, bubbleMax = MIN(220, width - 40);
    CGSize text = [_bubbleText sizeThatFits:CGSizeMake(bubbleMax - 28, CGFLOAT_MAX)];
    text.height = MIN(text.height, ceil(_bubbleText.font.lineHeight * 3) + 1);
    CGSize bubble = CGSizeMake(MAX(text.width + 28, 64), text.height + 20);
    CGFloat stageHeight = 24 + bubble.height + 10 + avatarSide + 8 + 18 + 18;
    _stage.frame = CGRectMake(left, y, width, stageHeight);
    CGFloat center = width / 2;
    _bubble.frame = CGRectMake(center - bubble.width / 2, 24, bubble.width, bubble.height);
    _bubble.layer.cornerRadius = MIN(20, bubble.height / 2);
    _bubbleText.frame = CGRectMake(14, 10, bubble.width - 28, text.height);
    CGFloat avatarTop = CGRectGetMaxY(_bubble.frame) + 10;
    _avatar.frame = CGRectMake(center - avatarSide / 2, avatarTop, avatarSide, avatarSide);
    _avatar.layer.cornerRadius = avatarSide / 2;
    _tailBig.frame = CGRectMake(center - 22, CGRectGetMaxY(_bubble.frame) - 4, 12, 12);
    _tailBig.layer.cornerRadius = 6;
    _tailSmall.frame = CGRectMake(center - 30, CGRectGetMaxY(_bubble.frame) + 8, 6, 6);
    _tailSmall.layer.cornerRadius = 3;
    [_stage bringSubviewToFront:_tailSmall];
    _caption.frame = CGRectMake(0, CGRectGetMaxY(_avatar.frame) + 8, width, 18);
    y = CGRectGetMaxY(_stage.frame) + 16;

    _fieldBox.frame = CGRectMake(left, y, width, kRowHeight);
    CGFloat counterWidth = [_counter sizeThatFits:CGSizeMake(80, kRowHeight)].width;
    _counter.frame = CGRectMake(width - 14 - counterWidth, 0, counterWidth, kRowHeight);
    _field.frame = CGRectMake(14, 0, CGRectGetMinX(_counter.frame) - 22, kRowHeight);
    y = CGRectGetMaxY(_fieldBox.frame) + 16;

    BOOL nameOnlyAvailable = _template >= 0 && _letters != SGRNoteLettersPlain;
    _lettersOnRow.hidden = !nameOnlyAvailable;
    _shapeRow.hidden = _colorsAtRow.hidden = !_match;
    for (UIView *row in @[_templateRow, _lettersRow, _lettersOnRow, _caseRow, _leadRow, _matchRow, _shapeRow, _colorsAtRow]) {
        if (row.hidden) continue;
        row.frame = CGRectMake(left, y, width, kRowHeight);
        y += kRowHeight + (row == _leadRow ? 16 : kGap - 4);
    }
    UIView *matchName = [_matchRow viewWithTag:1];
    CGSize switchSize = _matchSwitch.intrinsicContentSize;
    _matchSwitch.frame = CGRectMake(width - 14 - switchSize.width, (kRowHeight - switchSize.height) / 2, switchSize.width, switchSize.height);
    matchName.frame = CGRectMake(14, 0, CGRectGetMinX(_matchSwitch.frame) - 24, kRowHeight);
    y += 14;

    CGFloat shareHeight = MAX(50, [_share sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    _share.frame = CGRectMake(left, y, width, shareHeight);
    y = CGRectGetMaxY(_share.frame) + 6;
    _copy.frame = CGRectMake(left, y, width, 44);
    y = CGRectGetMaxY(_copy.frame) + 12;
    _footnote.frame = CGRectMake(left, y, width, [_footnote sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    _scroll.contentSize = CGSizeMake(self.view.bounds.size.width, CGRectGetMaxY(_footnote.frame) + 28 + safe.bottom);
}

#pragma mark actions

- (void)typed {
    _template = -1;
    _custom = _field.text ?: @"";
    [self refresh];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return NO;
}

- (void)matchChanged {
    _match = _matchSwitch.on && _hues.count;
    SGSetEnabled(SGRKeyNoteMatchCover, _matchSwitch.on);
    [UIView animateWithDuration:0.25 animations:^{
        [self refresh];
        [self.view layoutIfNeeded];
    }];
}

- (void)copyNote {
    UIPasteboard.generalPasteboard.string = self.note;
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (void)copyTapped {
    [self copyNote];
    UIButtonConfiguration *copy = _copy.configuration;
    copy.title = @"Copied";
    _copy.configuration = copy;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIButtonConfiguration *back = self->_copy.configuration;
        back.title = @"Copy Note Only";
        self->_copy.configuration = back;
    });
}

// Instagram's messages, whose top row is the notes tray; its app if that link is gone; its site if the app is.
static void openInstagram(NSUInteger from) {
    NSArray<NSString *> *links = @[@"instagram://direct-inbox", @"instagram://app", @"https://www.instagram.com/direct/inbox/"];
    if (from >= links.count) return;
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:links[from]] options:@{} completionHandler:^(BOOL opened) {
        if (!opened) openInstagram(from + 1);
    }];
}

- (void)shareTapped {
    [self copyNote];
    [self dismissViewControllerAnimated:YES completion:^{ openInstagram(0); }];
}

@end

void SGRPlayerShowNoteComposer(void) {
    if (!SGPlayerState().track) return;
    SGRNoteSheet *sheet = [SGRNoteSheet new];
    // Picked from the ⋯ menu, which is still going away: wait for it, as SGPresentPopover does.
    __block int tries = 0;
    __block void (^present)(void);
    present = ^{
        UIViewController *top = SGTopController();
        if ((top.isBeingDismissed || top.isBeingPresented || top.transitionCoordinator) && ++tries < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), present);
            return;
        }
        present = nil;
        if (top && ![top isKindOfClass:SGRNoteSheet.class]) [top presentViewController:sheet animated:YES completion:nil];
    };
    dispatch_async(dispatch_get_main_queue(), present);
}
