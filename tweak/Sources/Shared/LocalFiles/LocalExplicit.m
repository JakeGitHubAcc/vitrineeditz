// LocalFiles.h says what is marked explicit and how a file's lyrics mark it. A file's lyrics are fetched the way its
// lyrics page fetches them (Shared/LyricsSources, by the file's lyrics key), so the sources the Lyrics page has on
// are the ones asked, and read for explicit words. A file whose lyrics none of them has stays as it was, and is
// asked about again on a later launch.
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "LocalFiles.h"

// Words that make a song explicit on their own, and ones that do when there are two of them. Censored spellings
// ("f*ck", "sh!t") count as the word.
static NSString *const kStrong = @"\\b(?:motherf\\w*|f+u+c+k\\w*|fuk\\w*|f[*#@!]+c?k\\w*|sh[i1!*]+t\\w*|bullsh\\w*|b[i1!*]+tch\\w*|cunt\\w*|"
                                  "nigg\\w*|n[i*]gg?[a*]s?\\b|pussy|pussies|cocksuck\\w*|asshole\\w*|whore\\w*|slut\\w*|fagg?ot\\w*|twat\\w*)\\b";
static NSString *const kMild = @"\\b(?:ass|asses|dick|dicks|hoe|hoes|cock|cocks|wank\\w*|damn)\\b";

static NSUInteger hits(NSString *text, NSString *pattern, NSUInteger enough) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    __block NSUInteger count = 0;
    [expression enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                              usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        if (++count >= enough) *stop = YES;
    }];
    return count;
}

BOOL SGLyricsAreExplicit(NSArray<NSString *> *lines) {
    NSString *text = [lines componentsJoinedByString:@"\n"];
    if (!text.length) return NO;
    return hits(text, kStrong, 1) >= 1 || hits(text, kMild, 2) >= 2;
}

static NSArray<NSString *> *textsOf(NSArray<SGKaraokeLine *> *lines) {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (SGKaraokeLine *line in lines) {
        NSString *text = SGKaraokeLineText(line);
        if (text.length) [texts addObject:text];
    }
    return texts;
}

static NSString *plainURI(NSString *key) {
    NSRange mark = [key rangeOfString:@"#" options:NSBackwardsSearch];
    return mark.location == NSNotFound ? key : [key substringToIndex:mark.location];
}

static NSMutableArray<NSString *> *sg_waiting;
static NSMutableSet<NSString *> *sg_askedThisLaunch;
static BOOL sg_reading;

static void readNext(void) {
    if (sg_reading || !sg_waiting.count) return;
    NSString *uri = sg_waiting.firstObject;
    [sg_waiting removeObjectAtIndex:0];
    NSString *key = SGLocalFileLyricsKey(uri);
    if (!key || !SGLyricsEnabled()) {
        readNext();
        return;
    }
    sg_reading = YES;
    SGLyricsFetch(key, ^(SGLyricsResult *result) {
        sg_reading = NO;
        SGLocalFileLyricsVerdict verdict = !result ? SGLocalFileLyricsNone
                                         : result.instrumental ? SGLocalFileLyricsClean
                                         : SGLyricsAreExplicit(result.texts ?: textsOf(result.karaokeLines)) ? SGLocalFileLyricsExplicit
                                         : SGLocalFileLyricsClean;
        SGLog(@"local files: lyrics read for explicit words, %ld", (long)verdict);
        SGLocalFileSetLyricsVerdict(uri, verdict);
        readNext();
    });
}

void SGLocalFilesCheckLyrics(NSArray<NSString *> *uris) {
    if (!sg_waiting) {
        sg_waiting = [NSMutableArray array];
        sg_askedThisLaunch = [NSMutableSet set];
    }
    for (NSString *uri in uris) {
        NSString *plain = plainURI(uri);
        SGLocalFileLyricsVerdict verdict = SGLocalFileLyricsVerdictOf(plain);
        // Read once; one with none found is asked again on a later launch.
        if (verdict == SGLocalFileLyricsClean || verdict == SGLocalFileLyricsExplicit || [sg_askedThisLaunch containsObject:plain]) continue;
        [sg_askedThisLaunch addObject:plain];
        [sg_waiting addObject:plain];
    }
    readNext();
}

// The lyrics of a local file that came in as it played, read at once.
__attribute__((constructor)) static void readPlayedLyrics(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:SGKaraokeLinesKeptNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        NSString *key = [note.object isKindOfClass:NSString.class] ? note.object : nil;
        if (!SGLocalFileIs(key)) return;
        NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(key);
        if (!lines.count) return;
        SGLocalFileSetLyricsVerdict(plainURI(key), SGLyricsAreExplicit(textsOf(lines)) ? SGLocalFileLyricsExplicit : SGLocalFileLyricsClean);
    }];
}
