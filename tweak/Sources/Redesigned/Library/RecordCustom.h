// What the user picked for a record's sleeve on the Records page (RecordsPage.m), its Customize menu: a picture of
// their own for any part of it, in place of the one found or drawn, and where its hype sticker sits, or none at all.
// Kept by record (RecordsPage's record key) in Application Support, the pictures beside the list as JPEGs (a sticker
// as a PNG, which keeps its cut-out edge).
//
// Threading: main thread.
#import <UIKit/UIKit.h>

// The parts.
extern NSString *const SGRPartFront, *const SGRPartBack, *const SGRPartSpine, *const SGRPartInsideLeft,
                *const SGRPartInsideRight, *const SGRPartSticker;

// The picture picked for `part` of `record`, nil for none.
UIImage *SGRCustomPicture(NSString *record, NSString *part);
// Keeps `picture` for the part; nil forgets the one picked.
void SGRSetCustomPicture(NSString *record, NSString *part, UIImage *picture);
// Whether anything is picked for the record.
BOOL SGRHasCustom(NSString *record);
// Where the sticker's middle sits on the front, in shares of its side; NO when not moved.
BOOL SGRCustomStickerCenter(NSString *record, CGPoint *center);
void SGRSetCustomStickerCenter(NSString *record, CGPoint center);
// The sticker taken off, whatever the sleeve has.
BOOL SGRCustomStickerHidden(NSString *record);
void SGRSetCustomStickerHidden(NSString *record, BOOL hidden);
// The color the record itself is pressed in: "black", "cover" (the album's most vivid color), or "#RRGGBB"; nil for
// the page's default.
NSString *SGRCustomVinyl(NSString *record);
void SGRSetCustomVinyl(NSString *record, NSString *vinyl);
// Everything picked for the record forgotten.
void SGRForgetCustom(NSString *record);
