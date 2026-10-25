// Library redesign: Add from Google Drive (Shared/LocalFiles/DriveImport.h), from the + at the top of Local
// Albums (LocalAlbumsPage.m). Asks for a share link, then shows the import: each file, what is being done to
// it and what came of it, with Stop while it runs.
//
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/LocalFiles/DriveImport.h"
#import "Library.h"

static NSString *stateText(SGDriveItem *item) {
    switch (item.state) {
        case SGDriveItemWaiting: return @"Waiting";
        case SGDriveItemDownloading: return [NSString stringWithFormat:@"Downloading %.0f%%", item.progress * 100];
        case SGDriveItemConverting: return item.detail ?: @"Converting";
        case SGDriveItemSaved:
        case SGDriveItemSkipped:
        case SGDriveItemFailed: return item.detail ?: @"";
    }
    return @"";
}

static NSString *stateSymbol(SGDriveItemState state) {
    switch (state) {
        case SGDriveItemWaiting: return @"clock";
        case SGDriveItemDownloading: return @"arrow.down.circle";
        case SGDriveItemConverting: return @"waveform";
        case SGDriveItemSaved: return @"checkmark.circle.fill";
        case SGDriveItemSkipped: return @"minus.circle";
        case SGDriveItemFailed: return @"exclamationmark.triangle.fill";
    }
    return @"circle";
}

@interface SGRDriveImportPage : SGPage
- (instancetype)initWithJob:(SGDriveJob *)job;
@end

@implementation SGRDriveImportPage {
    SGDriveJob *_job;
    UIView *_note;
}

- (instancetype)initWithJob:(SGDriveJob *)job {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _job = job;
    self.title = @"Google Drive";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _note = SGNote(@"Lossless songs (FLAC, WAV, AIFF) are converted to AAC at 256 kbps, which sounds the same at about a fifth "
                    "of the size; MP3 and M4A files are kept as they are. Songs are saved in the Spotify folder in Files. If "
                    "Spotify's Local Files does not show them yet, close Spotify and open it again.");
    self.tableView.tableFooterView = _note;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(jobChanged:) name:SGDriveJobDidChangeNotification object:_job];
    [self updateStop];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _note, 16, 24);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (void)updateStop {
    if (_job.finished) {
        self.navigationItem.rightBarButtonItem = nil;
        return;
    }
    __weak SGDriveJob *job = _job;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Stop" style:UIBarButtonItemStylePlain target:nil action:nil];
    self.navigationItem.rightBarButtonItem.primaryAction = [UIAction actionWithTitle:@"Stop" image:nil identifier:nil handler:^(UIAction *action) { [job cancel]; }];
}

- (void)jobChanged:(NSNotification *)note {
    [self updateStop];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return 2;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : (NSInteger)_job.items.count;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    return section == 1 && _job.items.count ? SGSectionHeader(table, @"Files") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"item");
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (path.section == 0) {
        NSUInteger saved = 0, failed = 0;
        for (SGDriveItem *item in _job.items) {
            saved += item.state == SGDriveItemSaved;
            failed += item.state == SGDriveItemFailed;
        }
        NSString *title = _job.error ? @"Not imported" : _job.finished ? [NSString stringWithFormat:@"%lu %@ saved", (unsigned long)saved, saved == 1 ? @"song" : @"songs"]
                        : _job.items.count ? @"Importing" : @"Reading the link";
        NSString *subtitle = _job.error ?: failed ? [NSString stringWithFormat:@"%lu could not be imported", (unsigned long)failed] : _job.link;
        SGFillCell(cell, title, subtitle, _job.error ? SGRed() : SGGreen(), _job.finished ? (_job.error ? @"xmark" : @"checkmark") : @"icloud.and.arrow.down");
        return cell;
    }
    SGDriveItem *item = _job.items[(NSUInteger)path.row];
    UIColor *color = item.state == SGDriveItemFailed ? SGRed() : item.state == SGDriveItemSaved ? SGGreen() : SGGrey();
    SGFillCell(cell, item.name, stateText(item), color, stateSymbol(item.state));
    return cell;
}
@end

void SGRAskDriveImport(UIViewController *owner) {
    UIAlertController *ask = [UIAlertController alertControllerWithTitle:@"Add from Google Drive"
                                                                 message:@"Paste a link to a song, a folder or a .zip shared with anyone who has the link."
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [ask addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://drive.google.com/…";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIViewController *weakOwner = owner;
    __weak UIAlertController *weakAsk = ask;
    [ask addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIViewController *owner = weakOwner;
        NSString *link = weakAsk.textFields.firstObject.text ?: @"";
        if (!owner) return;
        SGDriveJob *job = SGDriveImportStart(link);
        if (!job) {
            UIAlertController *wrong = [UIAlertController alertControllerWithTitle:@"Not a Google Drive link"
                                                                           message:@"Copy the link from Share ▸ Copy link in Google Drive."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [wrong addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [owner presentViewController:wrong animated:YES completion:nil];
            return;
        }
        SGShowPage(owner, [[SGRDriveImportPage alloc] initWithJob:job]);
    }]];
    [owner presentViewController:ask animated:YES completion:nil];
}
