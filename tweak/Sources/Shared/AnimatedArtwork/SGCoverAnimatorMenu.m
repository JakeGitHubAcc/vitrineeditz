// SGAnimatedCoverMenu (SGCoverAnimator.h): an album's animated cover in a ⋯ menu, the player's and an album
// page's. One submenu, Animated Cover, which says what there is of it: what can be done with it first, then
// Animated Cover Settings, which opens the page of the settings that go with the next cover sent.
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
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

    // The settings for the next cover made are a page of their own (SGAnimatedCoversPage), opened from here.
    UIAction *open = [UIAction actionWithTitle:@"Animated Cover Settings" image:symbol(@"slider.horizontal.3") identifier:nil
                                       handler:^(UIAction *action) {
        UIViewController *top = SGTopController();
        if (top) SGShowPage(top, SGAnimatedCoversPage());
    }];
    open.subtitle = @"Text, camera sway, line boil and what moves";
    UIMenu *settings = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[open]];

    UIMenu *menu = [UIMenu menuWithTitle:@"Animated Cover" image:symbol(@"sparkles.rectangle.stack") identifier:nil options:0
                                children:@[[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:actions], settings]];
    menu.subtitle = SGAnimatedCoverStatus(picture) ?: @"Not animated";
    return @[menu];
}
