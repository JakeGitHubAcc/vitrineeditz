// DriveImport.h says what is imported, how and where.
#import <AVFoundation/AVFoundation.h>
#import <zlib.h>
#import "Core/SGCore.h"
#import "DriveImport.h"
#import "LocalAlbums.h"

NSNotificationName const SGDriveJobDidChangeNotification = @"spotifyglass.driveImport.jobDidChange";

// AAC's bit rate for two channels; one gets half.
static const NSInteger kBitRate = 256000;
// How deep a folder's folders are followed.
static const NSUInteger kFolderDepth = 3;

static NSSet<NSString *> *lossless(void) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSSet setWithArray:@[@"flac", @"wav", @"wave", @"aif", @"aiff"]]; });
    return set;
}

static NSSet<NSString *> *lossy(void) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSSet setWithArray:@[@"mp3", @"m4a", @"aac", @"mp4"]]; });
    return set;
}

static BOOL isCoverName(NSString *name) {
    NSString *base = name.lastPathComponent.stringByDeletingPathExtension.lowercaseString;
    NSString *extension = name.pathExtension.lowercaseString;
    return [@[@"jpg", @"jpeg", @"png"] containsObject:extension] && [@[@"cover", @"folder", @"front", @"album", @"artwork"] containsObject:base];
}

NSString *SGDriveImportFolder(void) {
    // Documents itself: Spotify reads local files from it, and may not look into folders inside it.
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

#pragma mark - items and jobs

@interface SGDriveItem ()
@property (nonatomic, copy, readwrite) NSString *name, *detail;
@property (nonatomic, readwrite) SGDriveItemState state;
@property (nonatomic, readwrite) double progress;
// Drive's id, or for a file out of a .zip where it was unpacked.
@property (nonatomic, copy) NSString *fileID, *unpacked;
@end
@implementation SGDriveItem
@end

@interface SGDriveJob () <NSURLSessionDownloadDelegate>
@property (nonatomic, copy, readwrite) NSString *link, *error;
@property (nonatomic, copy, readwrite) NSArray<SGDriveItem *> *items;
@property (nonatomic, readwrite, getter=isFinished) BOOL finished;
@end

static NSMutableArray<SGDriveJob *> *sg_jobs;

static dispatch_queue_t workQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.driveImport", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

#pragma mark - links

static NSString *match(NSString *text, NSString *pattern) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *found = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return found && found.numberOfRanges > 1 ? [text substringWithRange:[found rangeAtIndex:1]] : nil;
}

// Drive's id in a share link, and whether it is a folder's.
static NSString *idIn(NSString *link, BOOL *folder) {
    if (![link containsString:@"google.com"]) return nil;
    NSString *found = match(link, @"/folders/([A-Za-z0-9_-]{10,})");
    if (!found) found = match(link, @"folderview\\?(?:.*&)?id=([A-Za-z0-9_-]{10,})");
    *folder = found != nil;
    if (found) return found;
    found = match(link, @"/file/d/([A-Za-z0-9_-]{10,})");
    return found ?: match(link, @"[?&]id=([A-Za-z0-9_-]{10,})");
}

static NSString *unescapedHTML(NSString *text) {
    NSMutableString *out = [text mutableCopy];
    for (NSArray<NSString *> *pair in @[@[@"&quot;", @"\""], @[@"&#39;", @"'"], @[@"&lt;", @"<"], @[@"&gt;", @">"], @[@"&amp;", @"&"]]) {
        [out replaceOccurrencesOfString:pair[0] withString:pair[1] options:0 range:NSMakeRange(0, out.length)];
    }
    NSRegularExpression *number = [NSRegularExpression regularExpressionWithPattern:@"&#(\\d+);" options:0 error:nil];
    for (NSTextCheckingResult *found in [number matchesInString:out options:0 range:NSMakeRange(0, out.length)].reverseObjectEnumerator) {
        unichar code = (unichar)[[out substringWithRange:[found rangeAtIndex:1]] integerValue];
        [out replaceCharactersInRange:found.range withString:[NSString stringWithCharacters:&code length:1]];
    }
    return out;
}

// A shared folder's files, read from Drive's public view of it, its folders' too; `done` on main with the
// (name, id) of each, or nil when the folder could not be read.
static void listFolder(NSString *folderID, NSString *prefix, NSUInteger depth, void (^done)(NSArray<NSArray<NSString *> *> *files)) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://drive.google.com/embeddedfolderview?id=%@", folderID]];
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (status != 200 || ![html containsString:@"flip-entry"]) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(status == 200 && html ? @[] : nil); });
            return;
        }
        NSMutableArray<NSArray<NSString *> *> *files = [NSMutableArray array];
        NSMutableArray<NSArray<NSString *> *> *folders = [NSMutableArray array];
        NSArray<NSString *> *chunks = [html componentsSeparatedByString:@"class=\"flip-entry\""];
        for (NSUInteger i = 1; i < chunks.count; i++) {
            NSString *chunk = chunks[i];
            NSString *entry = match(chunk, @"id=\"entry-([A-Za-z0-9_-]+)\"");
            NSString *title = match(chunk, @"flip-entry-title\">([^<]*)<");
            if (!entry || !title.length) continue;
            title = unescapedHTML(title);
            if ([chunk containsString:@"/drive/folders/"]) [folders addObject:@[title, entry]];
            else [files addObject:@[[prefix stringByAppendingString:title], entry]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!folders.count || depth >= kFolderDepth) { done(files); return; }
            // The folders one after another, their files after the folder's own.
            __block NSUInteger next = 0;
            __block void (^listNext)(void);
            void (^step)(void) = ^{
                if (next >= folders.count) { listNext = nil; done(files); return; }
                NSArray<NSString *> *folder = folders[next++];
                listFolder(folder[1], [NSString stringWithFormat:@"%@%@/", prefix, folder[0]], depth + 1, ^(NSArray *more) {
                    if (more) [files addObjectsFromArray:more];
                    listNext();
                });
            };
            listNext = step;
            step();
        });
    }] resume];
}

#pragma mark - tags

@interface SGSongTags : NSObject
@property (nonatomic, copy) NSString *title, *artist, *album, *albumArtist, *date;
@property (nonatomic) NSInteger track, tracks, disc, discs;
@property (nonatomic, strong) NSData *cover;
@end
@implementation SGSongTags
@end

static uint32_t bigEndian(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint32_t littleEndian(const uint8_t *p) { return (uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0]; }

// "3/12" into 3 and 12.
static void numberPair(NSString *text, NSInteger *number, NSInteger *total) {
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@"/"];
    *number = parts.firstObject.integerValue;
    if (parts.count > 1 && total) *total = parts[1].integerValue;
}

// A FLAC's Vorbis comment and front cover, which AVFoundation does not read.
static void readFLAC(NSString *path, SGSongTags *tags) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length, at = 4;
    if (length < 8 || memcmp(bytes, "fLaC", 4) != 0) return;
    NSData *anyCover = nil;
    for (BOOL last = NO; !last && at + 4 <= length;) {
        last = (bytes[at] & 0x80) != 0;
        uint8_t type = bytes[at] & 0x7F;
        NSUInteger size = (NSUInteger)bytes[at + 1] << 16 | (NSUInteger)bytes[at + 2] << 8 | bytes[at + 3];
        at += 4;
        if (at + size > length) break;
        const uint8_t *block = bytes + at;
        if (type == 4 && size >= 8) {
            NSUInteger p = 4 + littleEndian(block);
            if (p + 4 > size) { at += size; continue; }
            uint32_t count = littleEndian(block + p);
            p += 4;
            for (uint32_t i = 0; i < count && p + 4 <= size; i++) {
                uint32_t entryLength = littleEndian(block + p);
                p += 4;
                if (p + entryLength > size) break;
                NSString *entry = [[NSString alloc] initWithBytes:block + p length:entryLength encoding:NSUTF8StringEncoding];
                p += entryLength;
                NSRange equals = [entry rangeOfString:@"="];
                if (equals.location == NSNotFound) continue;
                NSString *key = [entry substringToIndex:equals.location].uppercaseString;
                NSString *value = [entry substringFromIndex:equals.location + 1];
                if (!value.length) continue;
                if ([key isEqualToString:@"TITLE"]) tags.title = value;
                else if ([key isEqualToString:@"ARTIST"] && !tags.artist) tags.artist = value;
                else if ([key isEqualToString:@"ALBUM"]) tags.album = value;
                else if ([key isEqualToString:@"ALBUMARTIST"] || [key isEqualToString:@"ALBUM ARTIST"]) tags.albumArtist = value;
                else if ([key isEqualToString:@"DATE"] || [key isEqualToString:@"YEAR"]) tags.date = value;
                else if ([key isEqualToString:@"TRACKNUMBER"]) { NSInteger number = 0, total = tags.tracks; numberPair(value, &number, &total); tags.track = number; tags.tracks = total; }
                else if ([key isEqualToString:@"TRACKTOTAL"] || [key isEqualToString:@"TOTALTRACKS"]) tags.tracks = value.integerValue;
                else if ([key isEqualToString:@"DISCNUMBER"]) { NSInteger number = 0, total = tags.discs; numberPair(value, &number, &total); tags.disc = number; tags.discs = total; }
                else if ([key isEqualToString:@"DISCTOTAL"] || [key isEqualToString:@"TOTALDISCS"]) tags.discs = value.integerValue;
            }
        } else if (type == 6 && size >= 32) {
            uint32_t pictureType = bigEndian(block);
            NSUInteger p = 4;
            p += 4 + bigEndian(block + p);          // the MIME type
            if (p + 4 > size) { at += size; continue; }
            p += 4 + bigEndian(block + p);          // the description
            p += 16;                                // width, height, depth, colors
            if (p + 4 > size) { at += size; continue; }
            uint32_t pictureLength = bigEndian(block + p);
            p += 4;
            if (p + pictureLength <= size) {
                NSData *picture = [NSData dataWithBytes:block + p length:pictureLength];
                if (pictureType == 3) tags.cover = picture;
                else if (!anyCover) anyCover = picture;
            }
        }
        at += size;
    }
    if (!tags.cover) tags.cover = anyCover;
}

// What AVFoundation reads of a file's tags, under whatever format it keeps them.
static void readCommon(AVAsset *asset, SGSongTags *tags) {
    for (AVMetadataItem *item in asset.commonMetadata) {
        NSString *key = item.commonKey;
        id value = item.value;
        if ([key isEqualToString:AVMetadataCommonKeyArtwork]) {
            if ([value isKindOfClass:NSData.class] && !tags.cover) tags.cover = value;
            continue;
        }
        NSString *text = [value isKindOfClass:NSString.class] ? value : nil;
        if (!text.length) continue;
        if ([key isEqualToString:AVMetadataCommonKeyTitle] && !tags.title) tags.title = text;
        else if ([key isEqualToString:AVMetadataCommonKeyArtist] && !tags.artist) tags.artist = text;
        else if ([key isEqualToString:AVMetadataCommonKeyAlbumName] && !tags.album) tags.album = text;
        else if ([key isEqualToString:AVMetadataCommonKeyCreationDate] && !tags.date) tags.date = text;
    }
}

static AVMutableMetadataItem *metadata(AVMetadataIdentifier identifier, id value) {
    AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
    item.identifier = identifier;
    item.value = value;
    return item;
}

// iTunes's track and disc numbers: big-endian pairs after two zero bytes.
static NSData *numberData(NSInteger number, NSInteger total, NSUInteger length) {
    uint8_t bytes[8] = {0};
    bytes[2] = (uint8_t)(number >> 8); bytes[3] = (uint8_t)number;
    bytes[4] = (uint8_t)(total >> 8); bytes[5] = (uint8_t)total;
    return [NSData dataWithBytes:bytes length:length];
}

static NSArray<AVMetadataItem *> *itunesTags(SGSongTags *tags) {
    NSMutableArray<AVMetadataItem *> *items = [NSMutableArray array];
    if (tags.title) [items addObject:metadata(AVMetadataIdentifieriTunesMetadataSongName, tags.title)];
    if (tags.artist) [items addObject:metadata(AVMetadataIdentifieriTunesMetadataArtist, tags.artist)];
    if (tags.album) [items addObject:metadata(AVMetadataIdentifieriTunesMetadataAlbum, tags.album)];
    if (tags.albumArtist) [items addObject:metadata(AVMetadataIdentifieriTunesMetadataAlbumArtist, tags.albumArtist)];
    if (tags.date) [items addObject:metadata(AVMetadataIdentifieriTunesMetadataReleaseDate, tags.date)];
    if (tags.track > 0) [items addObject:metadata(AVMetadataIdentifieriTunesMetadataTrackNumber, numberData(tags.track, tags.tracks, 8))];
    if (tags.disc > 0) [items addObject:metadata(AVMetadataIdentifieriTunesMetadataDiscNumber, numberData(tags.disc, tags.discs, 6))];
    if (tags.cover.length > 8) {
        AVMutableMetadataItem *cover = metadata(AVMetadataIdentifieriTunesMetadataCoverArt, tags.cover);
        const uint8_t *head = tags.cover.bytes;
        cover.dataType = head[0] == 0x89 && head[1] == 'P' ? (__bridge NSString *)kCMMetadataBaseDataType_PNG : (__bridge NSString *)kCMMetadataBaseDataType_JPEG;
        [items addObject:cover];
    }
    return items;
}

#pragma mark - converting

// `source` as AAC 256 kbps in an .m4a at `target`, with `tags` and, for a file with no cover of its own,
// `fallbackCover` (its folder's cover.jpg); nil, or what went wrong. On the work queue.
static NSString *convert(NSURL *source, NSURL *target, SGSongTags *tags, NSData *fallbackCover, BOOL (^cancelled)(void)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"commonMetadata"] completionHandler:^{ dispatch_semaphore_signal(loaded); }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    readCommon(asset, tags);
    if (!tags.cover) tags.cover = fallbackCover;
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) return @"iOS cannot read this file.";
    const AudioStreamBasicDescription *format = NULL;
    for (id description in track.formatDescriptions) {
        format = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)description);
        if (format) break;
    }
    double sourceRate = format && format->mSampleRate > 0 ? format->mSampleRate : 44100;
    // AAC takes 48 kHz at most: a 96 or 192 kHz file goes down to 48, an 88.2 kHz one to 44.1.
    double rate = sourceRate <= 48000 ? sourceRate : fmod(sourceRate, 48000) == 0 ? 48000 : 44100;
    if (rate != 44100 && rate != 48000 && rate != 32000) rate = 44100;
    NSInteger channels = format ? MIN(MAX((NSInteger)format->mChannelsPerFrame, 1), 2) : 2;

    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (!reader) return @"iOS cannot read this file.";
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
        AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO, AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @(channels),
    }];
    if (![reader canAddOutput:output]) return @"iOS cannot read this file.";
    [reader addOutput:output];

    [NSFileManager.defaultManager removeItemAtURL:target error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:target fileType:AVFileTypeAppleM4A error:&error];
    if (!writer) return @"The converted file could not be written.";
    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono;
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @(channels),
        AVEncoderBitRateKey: @(kBitRate * channels / 2), AVChannelLayoutKey: [NSData dataWithBytes:&layout length:sizeof(layout)],
    }];
    input.expectsMediaDataInRealTime = NO;
    if (![writer canAddInput:input]) return @"The converted file could not be written.";
    [writer addInput:input];
    writer.metadata = itunesTags(tags);

    if (![reader startReading] || ![writer startWriting]) return @"The file could not be converted.";
    [writer startSessionAtSourceTime:kCMTimeZero];
    BOOL stopped = NO;
    while (reader.status == AVAssetReaderStatusReading) {
        if (cancelled()) { stopped = YES; break; }
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) usleep(2000);
        if (writer.status != AVAssetWriterStatusWriting) break;
        CMSampleBufferRef buffer = [output copyNextSampleBuffer];
        if (!buffer) break;
        BOOL appended = [input appendSampleBuffer:buffer];
        CFRelease(buffer);
        if (!appended) break;
    }
    if (stopped || reader.status == AVAssetReaderStatusFailed || writer.status != AVAssetWriterStatusWriting) {
        [reader cancelReading];
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:target error:nil];
        if (!stopped) SGLog(@"drive import: converting %@ failed: %@ %@", source.lastPathComponent, reader.error, writer.error);
        return stopped ? @"Stopped." : @"The file could not be converted.";
    }
    [input markAsFinished];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    return writer.status == AVAssetWriterStatusCompleted ? nil : @"The converted file could not be finished.";
}

#pragma mark - .zip

// Unpacks the files of a .zip (stored or deflated, no ZIP64) into `folder`, flat, leaving out macOS's
// resource forks; answers the paths written.
static NSArray<NSString *> *unzip(NSString *path, NSString *folder) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    if (length < 22) return @[];
    // The end of central directory record, in the last 64 KB.
    NSInteger end = -1;
    for (NSInteger i = (NSInteger)length - 22; i >= 0 && i >= (NSInteger)length - 65557; i--) {
        if (littleEndian(bytes + i) == 0x06054b50) { end = i; break; }
    }
    if (end < 0) return @[];
    uint16_t count = (uint16_t)(bytes[end + 10] | bytes[end + 11] << 8);
    NSUInteger at = littleEndian(bytes + end + 16);
    NSMutableArray<NSString *> *written = [NSMutableArray array];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    for (uint16_t i = 0; i < count && at + 46 <= length; i++) {
        if (littleEndian(bytes + at) != 0x02014b50) break;
        uint16_t method = (uint16_t)(bytes[at + 10] | bytes[at + 11] << 8);
        uint32_t packed = littleEndian(bytes + at + 20), size = littleEndian(bytes + at + 24);
        uint16_t nameLength = (uint16_t)(bytes[at + 28] | bytes[at + 29] << 8);
        uint16_t extraLength = (uint16_t)(bytes[at + 30] | bytes[at + 31] << 8);
        uint16_t commentLength = (uint16_t)(bytes[at + 32] | bytes[at + 33] << 8);
        uint32_t local = littleEndian(bytes + at + 42);
        if (at + 46 + nameLength > length) break;
        NSString *name = [[NSString alloc] initWithBytes:bytes + at + 46 length:nameLength encoding:NSUTF8StringEncoding];
        at += 46 + nameLength + extraLength + commentLength;
        if (!name || [name hasSuffix:@"/"] || [name containsString:@"__MACOSX"] || [name.lastPathComponent hasPrefix:@"._"]) continue;
        if (local + 30 > length || littleEndian(bytes + local) != 0x04034b50) continue;
        NSUInteger dataAt = local + 30 + (NSUInteger)(bytes[local + 26] | bytes[local + 27] << 8) + (NSUInteger)(bytes[local + 28] | bytes[local + 29] << 8);
        if (dataAt + packed > length) continue;
        NSData *contents = nil;
        if (method == 0) {
            contents = [NSData dataWithBytes:bytes + dataAt length:packed];
        } else if (method == 8) {
            NSMutableData *out = [NSMutableData dataWithLength:size];
            z_stream stream = {0};
            stream.next_in = (Bytef *)(bytes + dataAt);
            stream.avail_in = packed;
            stream.next_out = out.mutableBytes;
            stream.avail_out = size;
            if (inflateInit2(&stream, -MAX_WBITS) == Z_OK) {
                int result = inflate(&stream, Z_FINISH);
                inflateEnd(&stream);
                if (result == Z_STREAM_END && stream.total_out == size) contents = out;
            }
        }
        if (!contents) continue;
        NSString *target = [folder stringByAppendingPathComponent:name.lastPathComponent];
        if ([contents writeToFile:target atomically:NO]) [written addObject:target];
    }
    return written;
}

#pragma mark - saving

static NSString *safeName(NSString *name) {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
    NSString *clean = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"-"];
    clean = [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return clean.length ? [clean substringToIndex:MIN(clean.length, (NSUInteger)120)] : @"Song";
}

// A name in the folder no file has yet: "Name.m4a", else "Name 2.m4a" and on.
static NSString *freePath(NSString *base, NSString *extension) {
    NSString *folder = SGDriveImportFolder();
    NSString *path = [folder stringByAppendingPathComponent:[base stringByAppendingPathExtension:extension]];
    for (NSUInteger n = 2; [NSFileManager.defaultManager fileExistsAtPath:path]; n++) {
        path = [folder stringByAppendingPathComponent:[[NSString stringWithFormat:@"%@ %lu", base, (unsigned long)n] stringByAppendingPathExtension:extension]];
    }
    return path;
}

static NSString *sizeText(NSString *path) {
    unsigned long long bytes = [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize];
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

#pragma mark - the job

@implementation SGDriveJob {
    NSURLSession *_session;
    NSURLSessionDownloadTask *_task;
    NSUInteger _next;
    NSString *_scratch;
    NSData *_folderCover;
    BOOL _cancelled;
    NSUInteger _saved;
}

- (void)changed {
    [NSNotificationCenter.defaultCenter postNotificationName:SGDriveJobDidChangeNotification object:self];
}

- (void)cancel {
    if (self.finished) return;
    _cancelled = YES;
    [_task cancel];
}

- (void)fail:(NSString *)error {
    self.error = error;
    [self finish];
}

- (void)finish {
    if (self.finished) return;
    self.finished = YES;
    [_session finishTasksAndInvalidate];
    _session = nil;
    if (_scratch) [NSFileManager.defaultManager removeItemAtPath:_scratch error:nil];
    SGLog(@"drive import: %lu songs saved from %lu files%@", (unsigned long)_saved, (unsigned long)self.items.count,
          self.error ? [@", " stringByAppendingString:self.error] : @"");
    [self changed];
    if (_saved) SGLocalAlbumsRefresh(nil);
}

- (void)startWithID:(NSString *)fileID folder:(BOOL)folder {
    _scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"drive-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:_scratch withIntermediateDirectories:YES attributes:nil error:nil];
    _session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration delegate:self
                                        delegateQueue:NSOperationQueue.mainQueue];
    if (!folder) {
        SGDriveItem *item = [SGDriveItem new];
        item.name = @"Shared file";
        item.fileID = fileID;
        self.items = @[item];
        [self changed];
        [self next];
        return;
    }
    __weak SGDriveJob *weakSelf = self;
    listFolder(fileID, @"", 0, ^(NSArray<NSArray<NSString *> *> *files) {
        SGDriveJob *job = weakSelf;
        if (!job || job.finished) return;
        if (!files) { [job fail:@"The folder could not be read. Check that it is shared with anyone who has the link."]; return; }
        if (!files.count) { [job fail:@"The folder is empty."]; return; }
        NSMutableArray<SGDriveItem *> *items = [NSMutableArray array];
        for (NSArray<NSString *> *file in files) {
            SGDriveItem *item = [SGDriveItem new];
            item.name = file[0];
            item.fileID = file[1];
            [items addObject:item];
        }
        // A cover image first, for the songs whose files have none.
        [items sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(SGDriveItem *a, SGDriveItem *b) {
            BOOL ca = isCoverName(a.name), cb = isCoverName(b.name);
            return ca == cb ? NSOrderedSame : ca ? NSOrderedAscending : NSOrderedDescending;
        }];
        job.items = items;
        [job changed];
        [job next];
    });
}

- (SGDriveItem *)nextWaiting {
    for (; _next < self.items.count; _next++) {
        if (self.items[_next].state == SGDriveItemWaiting) return self.items[_next];
    }
    return nil;
}

- (void)next {
    if (self.finished) return;
    if (_cancelled) {
        for (SGDriveItem *item in self.items) {
            if (item.state == SGDriveItemWaiting) { item.state = SGDriveItemSkipped; item.detail = @"Stopped"; }
        }
        [self finish];
        return;
    }
    SGDriveItem *item = [self nextWaiting];
    if (!item) { [self finish]; return; }
    NSString *extension = item.name.pathExtension.lowercaseString;
    BOOL known = [lossless() containsObject:extension] || [lossy() containsObject:extension] || [extension isEqualToString:@"zip"] || isCoverName(item.name);
    // A folder's other files (a .cue, a .log, booklet scans) are left on Drive; a single shared file's
    // name is not known until it downloads.
    if (item.name.pathExtension.length && !known && !item.unpacked) {
        item.state = SGDriveItemSkipped;
        item.detail = @"Not a song";
        [self changed];
        [self next];
        return;
    }
    if (item.unpacked) { [self process:item at:item.unpacked]; return; }
    item.state = SGDriveItemDownloading;
    item.progress = 0;
    [self changed];
    NSString *address = [NSString stringWithFormat:@"https://drive.usercontent.google.com/download?id=%@&export=download&confirm=t", item.fileID];
    _task = [_session downloadTaskWithURL:[NSURL URLWithString:address]];
    [_task resume];
}

- (SGDriveItem *)downloading {
    return _next < self.items.count ? self.items[_next] : nil;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)written
 totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected {
    SGDriveItem *item = [self downloading];
    if (!item || expected <= 0) return;
    double progress = (double)total / (double)expected;
    if (progress - item.progress < 0.02 && progress < 1) return;
    item.progress = progress;
    [self changed];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    SGDriveItem *item = [self downloading];
    if (!item) return;
    NSHTTPURLResponse *response = [task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil;
    NSString *type = response.MIMEType ?: @"";
    if (response.statusCode != 200 || [type hasPrefix:@"text/html"]) {
        item.state = SGDriveItemFailed;
        item.detail = response.statusCode == 404 ? @"Not found" : @"Drive did not send the file. Check its sharing, or try again later.";
        return;
    }
    // A single shared file's own name, from the answer.
    if (!item.name.pathExtension.length && response.suggestedFilename.length) item.name = response.suggestedFilename;
    NSString *kept = [_scratch stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:item.name.pathExtension]];
    if (![NSFileManager.defaultManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:kept] error:nil]) {
        item.state = SGDriveItemFailed;
        item.detail = @"The download could not be kept.";
        return;
    }
    item.unpacked = kept;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    SGDriveItem *item = [self downloading];
    _task = nil;
    if (!item || self.finished) return;
    if (item.unpacked && !error) { [self process:item at:item.unpacked]; return; }
    if (item.state == SGDriveItemDownloading) {
        item.state = _cancelled ? SGDriveItemSkipped : SGDriveItemFailed;
        item.detail = _cancelled ? @"Stopped" : error.localizedDescription ?: @"The download failed.";
    }
    [self changed];
    _next++;
    [self next];
}

// A file downloaded or unpacked: a cover kept for the songs, a .zip unpacked into more items, a song saved.
- (void)process:(SGDriveItem *)item at:(NSString *)path {
    NSString *extension = item.name.pathExtension.lowercaseString;
    __weak SGDriveJob *weakSelf = self;
    void (^advance)(void) = ^{
        SGDriveJob *job = weakSelf;
        if (!job) return;
        [job changed];
        job->_next++;
        [job next];
    };
    if (isCoverName(item.name)) {
        _folderCover = [NSData dataWithContentsOfFile:path];
        item.state = SGDriveItemSkipped;
        item.detail = @"Cover, used for songs without one";
        advance();
        return;
    }
    if ([extension isEqualToString:@"zip"]) {
        item.state = SGDriveItemConverting;
        item.detail = @"Unpacking";
        [self changed];
        NSString *into = [_scratch stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        dispatch_async(workQueue(), ^{
            NSArray<NSString *> *files = unzip(path, into);
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                SGDriveJob *job = weakSelf;
                if (!job) return;
                item.state = files.count ? SGDriveItemSkipped : SGDriveItemFailed;
                item.detail = files.count ? [NSString stringWithFormat:@"Unpacked %lu files", (unsigned long)files.count] : @"The .zip could not be unpacked.";
                NSMutableArray<SGDriveItem *> *items = [job.items mutableCopy];
                NSMutableArray<SGDriveItem *> *more = [NSMutableArray array];
                for (NSString *file in files) {
                    SGDriveItem *inside = [SGDriveItem new];
                    inside.name = file.lastPathComponent;
                    inside.unpacked = file;
                    [more addObject:inside];
                }
                [more sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(SGDriveItem *a, SGDriveItem *b) {
                    BOOL ca = isCoverName(a.name), cb = isCoverName(b.name);
                    if (ca != cb) return ca ? NSOrderedAscending : NSOrderedDescending;
                    return [a.name localizedStandardCompare:b.name];
                }];
                [items insertObjects:more atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(job->_next + 1, more.count)]];
                job.items = items;
                advance();
            });
        });
        return;
    }
    BOOL convertIt = [lossless() containsObject:extension];
    if (!convertIt && ![lossy() containsObject:extension]) {
        item.state = SGDriveItemSkipped;
        item.detail = @"Not a song";
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        advance();
        return;
    }
    item.state = SGDriveItemConverting;
    item.detail = convertIt ? @"Converting to AAC 256 kbps" : @"Saving";
    [self changed];
    NSData *folderCover = _folderCover;
    NSString *scratch = _scratch;
    dispatch_async(workQueue(), ^{
        NSString *saved = nil, *error = nil;
        if (convertIt) {
            SGSongTags *tags = [SGSongTags new];
            if ([extension isEqualToString:@"flac"]) readFLAC(path, tags);
            NSString *temporary = [scratch stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"m4a"]];
            error = convert([NSURL fileURLWithPath:path], [NSURL fileURLWithPath:temporary], tags, folderCover,
                            ^BOOL { SGDriveJob *job = weakSelf; return !job || job->_cancelled; });
            if (!error) {
                NSString *base = tags.artist.length && tags.title.length ? [NSString stringWithFormat:@"%@ - %@", tags.artist, tags.title]
                                                                         : item.name.lastPathComponent.stringByDeletingPathExtension;
                saved = freePath(safeName(base), @"m4a");
                if (![NSFileManager.defaultManager moveItemAtPath:temporary toPath:saved error:nil]) error = @"The song could not be saved.";
            }
        } else {
            saved = freePath(safeName(item.name.lastPathComponent.stringByDeletingPathExtension), extension);
            if (![NSFileManager.defaultManager moveItemAtPath:path toPath:saved error:nil]) error = @"The song could not be saved.";
        }
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            SGDriveJob *job = weakSelf;
            if (!job) return;
            if (error) {
                item.state = SGDriveItemFailed;
                item.detail = error;
            } else {
                job->_saved++;
                item.state = SGDriveItemSaved;
                item.detail = [NSString stringWithFormat:@"%@, %@", convertIt ? @"Converted to AAC 256 kbps" : @"Saved as it was", sizeText(saved)];
            }
            advance();
        });
    });
}
@end

SGDriveJob *SGDriveImportStart(NSString *link) {
    NSCAssert(NSThread.isMainThread, @"drive import starts on main");
    BOOL folder = NO;
    NSString *fileID = idIn([link stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet], &folder);
    if (!fileID) return nil;
    SGDriveJob *job = [SGDriveJob new];
    job.link = link;
    job.items = @[];
    if (!sg_jobs) sg_jobs = [NSMutableArray array];
    [sg_jobs insertObject:job atIndex:0];
    SGLog(@"drive import: %@ %@", folder ? @"folder" : @"file", fileID);
    [job startWithID:fileID folder:folder];
    return job;
}

NSArray<SGDriveJob *> *SGDriveImportJobs(void) {
    return sg_jobs ?: @[];
}
