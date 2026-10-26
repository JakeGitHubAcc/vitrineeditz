// The dispatcher is a singleton the app builds at startup; -setMainUILoaded: is the last call of its
// setup (objc-methods.txt:38809).
#import "Core/SGCore.h"
#import "Headers/SPTLinkDispatcherImplementation.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Links.h"
#import <objc/message.h>

static __weak SPTLinkDispatcherImplementation *sg_linkDispatcher;
static NSMutableDictionary<NSString *, UIViewController *(^)(void)> *sg_modPages;

void SGRegisterModPage(NSString *uri, UIViewController *(^make)(void)) {
    if (!sg_modPages) sg_modPages = [NSMutableDictionary dictionary];
    sg_modPages[uri.lowercaseString] = [make copy];
}

// The navigation stack on screen inside `page`, the deepest: the selected tab's, whose view is in the window. The
// window's root holds no stack itself, and a page shown from it is presented over everything, the pages it opens
// going under it.
static UINavigationController *shownNavigation(UIViewController *page) {
    for (UIViewController *child in page.childViewControllers) {
        if (!child.viewIfLoaded.window) continue;
        UINavigationController *found = shownNavigation(child);
        if (found) return found;
    }
    return [page isKindOfClass:UINavigationController.class] && page.viewIfLoaded.window ? (UINavigationController *)page : nil;
}

static UIViewController *(^modPageFor(NSURL *uri))(void) {
    if (![uri.scheme.lowercaseString isEqualToString:@"vitrine"]) return nil;
    return sg_modPages[uri.absoluteString.lowercaseString];
}

id SGLinkDispatcher(void) {
    return sg_linkDispatcher;
}

// 9.1.88 dropped -navigateToURI:options:interactionID:. In 9.1.78 it only wraps
// -navigateToURI:options:reason:completionHandler:resultHandler:, which every version has, with the reason
// [[SPTUBINavigationReason alloc] initWithSourceApplication:nil interactionID:<its interactionID>] and no handlers
// (read off the 9.1.78 binary), so later versions get the same. A nil reason crashes: Swift reads it as an enum.
BOOL SGOpenSpotifyURI(NSURL *uri) {
    UIViewController *(^make)(void) = modPageFor(uri);
    if (make) {
        UIViewController *top = SGTopController();
        if (!top) return NO;
        UINavigationController *nav = top.navigationController ?: shownNavigation(top);
        SGShowPage(nav.topViewController ?: top, make());
        return YES;
    }
    SPTLinkDispatcherImplementation *dispatcher = sg_linkDispatcher;
    if (!uri || !dispatcher) return NO;
    if ([dispatcher respondsToSelector:@selector(navigateToURI:options:interactionID:)]) {
        [dispatcher navigateToURI:uri options:0 interactionID:nil];
        return YES;
    }
    SEL full = NSSelectorFromString(@"navigateToURI:options:reason:completionHandler:resultHandler:");
    // alloc and init by hand, outside ARC: init consumes what alloc made and returns its own +1.
    Class reasonClass = NSClassFromString(@"SPTUBINavigationReason");
    SEL init = NSSelectorFromString(@"initWithSourceApplication:interactionID:");
    id reason = nil;
    if ([reasonClass instancesRespondToSelector:init]) {
        void *raw = ((void *(*)(Class, SEL))objc_msgSend)(reasonClass, @selector(alloc));
        reason = CFBridgingRelease(((void *(*)(void *, SEL, id, id))objc_msgSend)(raw, init, nil, nil));
    }
    if (![dispatcher respondsToSelector:full] || !reason) return NO;
    ((void (*)(id, SEL, NSURL *, long long, id, id, id))objc_msgSend)(dispatcher, full, uri, 0, reason, nil, nil);
    return YES;
}

#pragma mark - asking before opening

// The chain a spotify: link takes in 9.1.78, read off the binary: -[SPTLinkDispatcherImplementation
// navigateToURI:…] hands it to the URI scheme dispatcher, whose "spotify" handler is the dispatcher's
// -spotifyLinkHandler (SPTSpotifyLinkHandler). That one passes the cleaned URI to its
// -URISubtypeRegistry (SPTURISubtypeRegistryImplementation), which keeps the handlers of its -handlers
// hash table that answer -URISubtypeHandlerCanHandleURI: YES and opens with the first by priority;
// pages go through Navigation's PageResolverURISubtypeHandler. With no taker, -handleSpotifyURL:
// tries again once with -remapURI: (its fallback resolver's URI), and only then shows the alert.
static id sg_send(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static id sg_send1(id target, NSString *selector, id arg) {
    SEL sel = NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
}

// The class of the first handler that takes `uri`, nil for none. A handler whose name says it only
// listens (Jam's SGSNavigationURIHandledEventSource) is not asked, so a question is not taken for a
// navigation.
static NSString *takerFor(id<NSFastEnumeration> handlers, NSURL *uri, NSUInteger *asked) {
    SEL canHandle = NSSelectorFromString(@"URISubtypeHandlerCanHandleURI:");
    for (id handler in handlers) {
        NSString *name = NSStringFromClass([handler class]);
        if ([name containsString:@"EventSource"] || ![handler respondsToSelector:canHandle]) continue;
        (*asked)++;
        if (((BOOL (*)(id, SEL, id))objc_msgSend)(handler, canHandle, uri)) return name;
    }
    return nil;
}

SGLinkRoute SGSpotifyURIRoute(NSURL *uri, NSString **via) {
    if (via) *via = nil;
    if (!uri) return SGLinkRouteNone;
    if ([uri.scheme.lowercaseString isEqualToString:@"vitrine"]) {
        if (!modPageFor(uri)) return SGLinkRouteNone;
        if (via) *via = @"the mod's own page";
        return SGLinkRouteOpens;
    }
    id linkHandler = sg_send(sg_linkDispatcher, @"spotifyLinkHandler");
    id handlers = sg_send(sg_send(linkHandler, @"URISubtypeRegistry"), @"handlers");
    if (![handlers conformsToProtocol:@protocol(NSFastEnumeration)]) return SGLinkRouteUnknown;
    @try {
        NSURL *clean = sg_send(uri, @"spt_normalizedSpotifyURI");
        if (![clean isKindOfClass:NSURL.class]) clean = uri;
        NSUInteger asked = 0;
        NSString *taker = takerFor(handlers, clean, &asked);
        if (!taker) {
            NSURL *remapped = sg_send1(linkHandler, @"remapURI:", clean);
            if ([remapped isKindOfClass:NSURL.class] && ![remapped isEqual:clean]) {
                taker = takerFor(handlers, remapped, &asked);
                if (taker) taker = [NSString stringWithFormat:@"remap %@ %@", remapped.absoluteString, taker];
            }
        }
        if (!asked) return SGLinkRouteUnknown;
        if (via) *via = taker;
        return taker ? SGLinkRouteOpens : SGLinkRouteNone;
    } @catch (NSException *e) {
        SGLog(@"links: asking about %@ threw %@", uri, e.reason);
        return SGLinkRouteUnknown;
    }
}

NSURL *SGSpotifyURIFromText(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:trimmed];
    NSString *host = parts.host.lowercaseString;
    if ([parts.scheme.lowercaseString hasPrefix:@"http"] && [host isEqualToString:@"open.spotify.com"]) {
        NSMutableArray<NSString *> *path = [NSMutableArray array];
        for (NSString *piece in [parts.path componentsSeparatedByString:@"/"]) {
            if (piece.length) [path addObject:piece];
        }
        if (path.count && [path.firstObject hasPrefix:@"intl-"]) [path removeObjectAtIndex:0];
        if (path.count >= 2) return [NSURL URLWithString:[@"spotify:" stringByAppendingString:[path componentsJoinedByString:@":"]]];
    }
    return [NSURL URLWithString:trimmed];
}

%hook SPTLinkDispatcherImplementation
- (void)setMainUILoaded:(BOOL)loaded {
    %orig;
    sg_linkDispatcher = (SPTLinkDispatcherImplementation *)self;
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"SPTLinkDispatcherImplementation"]);
}
