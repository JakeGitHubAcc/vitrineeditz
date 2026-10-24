// SGAnimatedCoverMenu (SGCoverAnimator.h): an album's animated cover in a ⋯ menu, the player's and an album
// page's. One submenu, Animated Cover, which says what there is of it: what can be done with it first, then
// the two settings that go with the next cover sent.
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "SGCoverAnimator.h"

static UIImage *symbol(NSString *name) {
    return [UIImage systemImageNamed:name];
}

// `then` once the computer's address is there: at once, or after it is asked for.
static void withComputer(void (^then)(void)) {
    if (SGAnimatedCoverServer()) then();
    else SGAnimatedCoverAskServer(then);
}

NSArray<UIMenuElement *> *SGAnimatedCoverMenu(NSString *picture, void (^send)(void)) {
    if (!picture.length || !send) return @[];
    BOOL saved = SGAnimatedCoverFile(picture) != nil, waiting = SGAnimatedCoverPending(picture);
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    if (saved) {
        [actions addObject:[UIAction actionWithTitle:@"Animate Again" image:symbol(@"sparkles") identifier:nil handler:^(UIAction *action) {
            withComputer(^{
                SGAnimatedCoverForget(picture);
                send();
            });
        }]];
        UIAction *delete = [UIAction actionWithTitle:@"Delete Animated Cover" image:symbol(@"trash") identifier:nil
                                             handler:^(UIAction *action) { SGAnimatedCoverForget(picture); }];
        delete.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:delete];
    } else if (waiting) {
        UIAction *stop = [UIAction actionWithTitle:@"Stop Animating" image:symbol(@"xmark.circle") identifier:nil
                                           handler:^(UIAction *action) { SGAnimatedCoverForget(picture); }];
        stop.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:stop];
    } else {
        UIAction *make = [UIAction actionWithTitle:@"Animate Album Cover" image:symbol(@"sparkles") identifier:nil
                                           handler:^(UIAction *action) { withComputer(send); }];
        make.subtitle = SGAnimatedCoverServer() ? @"On your computer, with Vitrine Animate" : @"Enter your computer first";
        [actions addObject:make];
    }

    NSArray<NSString *> *wordings = @[@"Keep", @"Fade In and Out", @"Hide"];
    NSInteger chosen = MIN(MAX(SGInt(SGKeyAnimateText, SGAnimateTextKeep), 0), 2);
    NSMutableArray<UIMenuElement *> *picks = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)wordings.count; i++) {
        UIAction *pick = [UIAction actionWithTitle:wordings[(NSUInteger)i] image:nil identifier:nil
                                           handler:^(UIAction *action) { SGSetInt(SGKeyAnimateText, i); }];
        pick.state = i == chosen ? UIMenuElementStateOn : UIMenuElementStateOff;
        [picks addObject:pick];
    }
    UIMenu *text = [UIMenu menuWithTitle:@"Cover Text" image:symbol(@"textformat") identifier:nil options:0 children:picks];
    text.subtitle = wordings[(NSUInteger)chosen];
    BOOL swaying = SGHidden(SGKeyAnimateSway);   // an option: off until switched on
    UIAction *sway = [UIAction actionWithTitle:@"Camera Sway" image:symbol(@"video") identifier:nil
                                       handler:^(UIAction *action) { SGSetEnabled(SGKeyAnimateSway, !swaying); }];
    sway.state = swaying ? UIMenuElementStateOn : UIMenuElementStateOff;
    // Under their own heading, as they go with the next cover made rather than the one there is.
    UIMenu *settings = [UIMenu menuWithTitle:@"For the Next One Made" image:nil identifier:nil
                                     options:UIMenuOptionsDisplayInline children:@[text, sway]];

    UIMenu *menu = [UIMenu menuWithTitle:@"Animated Cover" image:symbol(@"sparkles.rectangle.stack") identifier:nil options:0
                                children:@[[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:actions], settings]];
    menu.subtitle = SGAnimatedCoverStatus(picture) ?: @"Not animated";
    return @[menu];
}
