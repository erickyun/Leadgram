#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#include <math.h>

/// PrivacyControls is additive: it never modifies the Lead/TGExtra/iQTele binaries.
/// Dynamic class/identifier matching is intentionally conservative. Telegram forks
/// change their internal node names; see README for the known coverage limitations.
static NSString *const PGPrefix = @"LeadgramPrivacy.";
static NSString *const PGKeys[] = {
    @"hideAvatars", @"hideSenderNames", @"hideUsernames", @"hideNames", @"hideReactions", @"hideComments"
};
static NSString *const PGTitles[] = {
    @"Hide Avatars", @"Hide Sender Names", @"Hide Usernames", @"Hide Names", @"Hide Reactions", @"Hide Comments"
};
static BOOL PGEnabled[6];
static char PGHiddenMarker;
static char PGGestureMarker;

static BOOL PGContains(NSString *haystack, NSString *needle) {
    return [haystack rangeOfString:needle].location != NSNotFound;
}

static NSString *PGClass(id object) {
    return object ? NSStringFromClass([object class]).lowercaseString : @"";
}

static id PGInvokeObject(id object, SEL selector) {
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

// AsyncDisplayKit-backed Telegram views expose their owning ASDisplayNode.
static id PGNode(UIView *view) {
    return PGInvokeObject(view, NSSelectorFromString(@"asyncdisplaykit_node"));
}

static NSString *PGDirectHint(UIView *view, id node) {
    NSMutableString *hint = [NSMutableString stringWithString:PGClass(view)];
    if (node) [hint appendFormat:@" %@", PGClass(node)];
    NSString *identifier = view.accessibilityIdentifier;
    if (identifier.length) [hint appendFormat:@" %@", identifier.lowercaseString];
    return hint;
}

static NSString *PGContextHint(UIView *view, id node) {
    NSMutableString *result = [NSMutableString string];
    UIView *parent = view.superview;
    for (NSUInteger i = 0; parent && i < 8; i++, parent = parent.superview) {
        [result appendFormat:@" %@ ", PGClass(parent)];
        id parentNode = PGNode(parent);
        if (parentNode) [result appendFormat:@" %@ ", PGClass(parentNode)];
    }
    // Include the logical node tree: many Telegram child nodes have generic views.
    id ancestor = PGInvokeObject(node, NSSelectorFromString(@"supernode"));
    for (NSUInteger i = 0; ancestor && i < 7; i++) {
        [result appendFormat:@" %@ ", PGClass(ancestor)];
        ancestor = PGInvokeObject(ancestor, NSSelectorFromString(@"supernode"));
    }
    return result;
}

static BOOL PGHasAny(NSString *value, NSArray<NSString *> *words) {
    for (NSString *word in words) if (PGContains(value, word)) return YES;
    return NO;
}

static BOOL PGIsTextView(UIView *view, id node) {
    if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UITextView class]]) return YES;
    NSString *name = PGClass(node);
    return PGContains(name, @"textnode") || PGContains(name, @"textview");
}

static NSString *PGText(UIView *view, id node) {
    if ([view isKindOfClass:[UILabel class]]) return ((UILabel *)view).text;
    if ([view isKindOfClass:[UITextView class]]) return ((UITextView *)view).text;
    id value = PGInvokeObject(node, NSSelectorFromString(@"attributedText"));
    return [value isKindOfClass:[NSAttributedString class]] ? [value string] : nil;
}

// Optional runtime metadata matching: Obj-C-visible stored node references such as
// authorNameNode/titleNode may identify the exact text node without reading its text.
// Never read non-object ivars; never hide a chat message's generic text node.
static NSString *PGIvarRole(id node) {
    if (!node) return @"";
    id parent = PGInvokeObject(node, NSSelectorFromString(@"supernode"));
    for (NSUInteger depth = 0; parent && depth < 5; depth++) {
        for (Class cls = object_getClass(parent); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                Ivar var = ivars[i];
                const char *type = ivar_getTypeEncoding(var);
                if (!type || type[0] != '@') continue;
                NSString *ivarName = [NSString stringWithUTF8String:ivar_getName(var)].lowercaseString;
                BOOL candidate = PGHasAny(ivarName, @[@"authorname", @"sendername", @"username",
                                                       @"displayname", @"peername", @"titlenode", @"namenode"]);
                if (candidate && object_getIvar(parent, var) == node) {
                    free(ivars);
                    if (PGHasAny(ivarName, @[@"authorname", @"sendername"])) return @"sender";
                    if (PGContains(ivarName, @"username")) return @"username";
                    return @"name";
                }
            }
            free(ivars);
        }
        parent = PGInvokeObject(parent, NSSelectorFromString(@"supernode"));
    }
    return @"";
}

// Chat-message author labels are TextNodes directly underneath the bubble
// clipping node. Message body text is nested in a BubbleContentNode.
// Recognize that structure instead of matching arbitrary displayed strings.
static BOOL PGBubbleAuthorHeader(id node) {
    if (!node || !PGContains(PGClass(node), @"textnode")) return NO;
    id parent = PGInvokeObject(node, NSSelectorFromString(@"supernode"));
    for (NSUInteger depth = 0; parent && depth < 4; depth++) {
        NSString *name = PGClass(parent);
        if (PGHasAny(name, @[@"contentnode", @"replyinfonode", @"forwardinfonode",
                             @"statusnode", @"threadinfonode", @"quotenode", @"dateandstatus"])) return NO;
        if (PGContains(name, @"chatmessagebubbleitemnode")) return depth <= 1;
        parent = PGInvokeObject(parent, NSSelectorFromString(@"supernode"));
    }
    return NO;
}

static BOOL PGShouldHide(UIView *view) {
    if (!(PGEnabled[0] || PGEnabled[1] || PGEnabled[2] || PGEnabled[3] || PGEnabled[4] || PGEnabled[5])) return NO;
    if (!view.window && ![view isKindOfClass:[UIWindow class]]) return NO;

    id node = PGNode(view);
    NSString *direct = PGDirectHint(view, node);

    // Telegram uses AvatarNode, AnimatedAvatarSetNode and newer AvatarComponent
    // variants. Never blanket-hide UIImageView: that would erase media/stickers.
    if (PGEnabled[0] && PGHasAny(direct, @[@"avatarnode", @"avatarview",
                @"avatarimageview", @"avatarcontrol", @"peeravatar", @"profileavatar",
                @"peerphoto", @"profilephoto", @"participantavatar", @"animatedavatarset",
                @"avatarcomponent", @"avatarstack", @"memberavatar", @"storyavatar",
                @"chatavatar", @"useravatar", @"peerphotoimage"])) return YES;

    // Some forked chat/contact lists use a plain circular UIImageView rather
    // than AvatarNode. Only use geometry inside clearly identified identity rows.
    if (PGEnabled[0] && [view isKindOfClass:[UIImageView class]]) {
        CGRect bounds = view.bounds;
        CGFloat edge = MIN(bounds.size.width, bounds.size.height);
        BOOL smallSquare = edge >= 24.0 && edge <= 110.0 &&
            fabs(bounds.size.width - bounds.size.height) <= edge * 0.13;
        BOOL circle = view.layer.cornerRadius >= edge * 0.35 || view.layer.mask != nil;
        if (smallSquare && circle) {
            NSString *ctx = PGContextHint(view, node);
            if (PGHasAny(ctx, @[@"chatlistitemnode", @"contactlist", @"peerlistitem",
                                @"searchresult", @"memberlist", @"participantlist"])) {
                return YES;
            }
        }
    }

    // Telegram has standalone reaction buttons and footer nodes; do not hide
    // the enclosing message, status/date node, or unrelated emoji in its text.
    if (PGEnabled[4] && PGContains(direct, @"reaction") &&
        PGHasAny(direct, @[@"button", @"footer", @"container", @"list", @"counter",
                          @"panel", @"badge", @"node", @"view", @"item", @"component"])) return YES;

    // Channel post comment/footer links are separate from reaction controls.
    // ChatMessageThreadInfoNode is the message reply/thread entry button.
    if (PGEnabled[5] && PGHasAny(direct, @[@"chatmessagecommentfooter",
               @"chatmessagethreadinfonode", @"messagecommentbutton", @"postcommentbutton",
               @"commentfooter", @"discussionbutton", @"viewcommentsbutton"])) return YES;

    if (!(PGEnabled[1] || PGEnabled[2] || PGEnabled[3])) return NO;
    if (!PGIsTextView(view, node)) return NO;

    NSString *context = PGContextHint(view, node);
    NSString *role = PGIvarRole(node);
    BOOL identityContext = PGHasAny(context, @[@"chatlistitem", @"contactlist",
        @"peerinfo", @"userinfo", @"chatinfo", @"memberlist", @"searchresult",
        @"chatlistsearch", @"peerlist", @"gallerytitle", @"chatmessage"]);
    BOOL isMessage = PGContains(context, @"chatmessage");

    // The author label in ChatMessageBubbleItemNode is actually stored as
    // 'nameNode' (not 'senderNameNode'). Both Hide Names and Hide Sender Names
    // must be able to conceal it, without touching actual message text.
    BOOL bubbleHeader = isMessage && PGBubbleAuthorHeader(node);
    BOOL senderHint = [role isEqualToString:@"sender"] ||
        (isMessage && [role isEqualToString:@"name"]) || bubbleHeader ||
        PGHasAny(direct, @[@"sendername", @"authorname", @"forwardedfrom", @"messageauthor"]);
    if ((PGEnabled[1] || PGEnabled[3]) && senderHint &&
        (isMessage || PGContains(context, @"gallery") || PGContains(context, @"message"))) return YES;

    BOOL userHint = [role isEqualToString:@"username"] ||
        PGHasAny(direct, @[@"username", @"userhandle", @"peerhandle"]);
    if (PGEnabled[2] && userHint) return YES;

    // A standalone @handle in a profile/contact/search identity header can be
    // hidden. Do NOT search message bodies for @mentions.
    if (PGEnabled[2] && identityContext && !isMessage) {
        NSString *text = [PGText(view, node) stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([text hasPrefix:@"@"] && text.length > 1 &&
            [text rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location == NSNotFound) {
            return YES;
        }
    }

    BOOL nameHint = [role isEqualToString:@"name"] ||
        PGHasAny(direct, @[@"displayname", @"peername", @"contactname", @"profilename"]);
    // Avoid hiding arbitrary titles/captions and message text.
    if (PGEnabled[3] && nameHint && identityContext && !isMessage) return YES;

    // The chat-list title is often an unnamed ASTextNode. Restrict this
    // fallback to the top-left title region; never hide the message preview
    // or the timestamp on the right side of the row.
    if (PGEnabled[3] && !isMessage && PGContains(context, @"chatlistitem")) {
        UIView *row = view.superview;
        for (NSUInteger level = 0; row && level < 8; level++, row = row.superview) {
            NSString *rowName = [NSString stringWithFormat:@"%@ %@",
                                 PGClass(row), PGClass(PGNode(row))];
            if (!PGContains(rowName, @"chatlistitemnode")) continue;
            CGRect box = [view convertRect:view.bounds toView:row];
            CGFloat width = CGRectGetWidth(row.bounds);
            CGFloat height = CGRectGetHeight(row.bounds);
            if (width > 0 && height > 0 && box.size.height > 5 && box.size.height < 36 &&
                CGRectGetMidY(box) < height * 0.56 &&
                CGRectGetMinX(box) > width * 0.12 &&
                CGRectGetMinX(box) < width * 0.75) return YES;
            break;
        }
    }

    return NO;
}

static void PGApply(UIView *view) {
    BOOL marked = [objc_getAssociatedObject(view, &PGHiddenMarker) boolValue];
    BOOL hide = PGShouldHide(view);
    if (hide) {
        if (!marked && !view.hidden) {
            objc_setAssociatedObject(view, &PGHiddenMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            marked = YES;
        }
        if (marked && !view.hidden) view.hidden = YES;
    } else if (marked) {
        objc_setAssociatedObject(view, &PGHiddenMarker, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.hidden = NO;
    }
}

static void PGRefreshView(UIView *view) {
    PGApply(view);
    for (UIView *child in view.subviews) PGRefreshView(child);
}

static void PGReload(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (int i = 0; i < 6; i++) PGEnabled[i] = [defaults boolForKey:[PGPrefix stringByAppendingString:PGKeys[i]]];
    for (UIWindow *window in [UIApplication sharedApplication].windows) PGRefreshView(window);
}

static UIViewController *PGTopController(UIViewController *controller) {
    if (!controller) return nil;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    if ([controller isKindOfClass:[UINavigationController class]]) {
        return PGTopController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:[UITabBarController class]]) {
        return PGTopController(((UITabBarController *)controller).selectedViewController);
    }
    return controller;
}

static void PGShowMenu(UIWindow *window) {
    UIViewController *root = PGTopController(window.rootViewController);
    if (!root || [root isKindOfClass:[UIAlertController class]]) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Privacy Controls"
        message:@"Toggle visibility. Open this menu with a three-finger long press."
        preferredStyle:UIAlertControllerStyleAlert];
    for (int i = 0; i < 6; i++) {
        NSString *title = [NSString stringWithFormat:@"%@ %@",
                           PGEnabled[i] ? @"✓" : @"○", PGTitles[i]];
        NSInteger index = i;
        [alert addAction:[UIAlertAction actionWithTitle:title
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                NSString *key = [PGPrefix stringByAppendingString:PGKeys[index]];
                [[NSUserDefaults standardUserDefaults] setBool:!PGEnabled[index] forKey:key];
                PGReload();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ PGShowMenu(window); });
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Done"
                         style:UIAlertActionStyleCancel handler:nil]];
    [root presentViewController:alert animated:YES completion:nil];
}

@interface PGGestureTarget : NSObject
+ (instancetype)shared;
- (void)open:(UILongPressGestureRecognizer *)recognizer;
@end

@implementation PGGestureTarget
+ (instancetype)shared {
    static PGGestureTarget *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [PGGestureTarget new]; });
    return target;
}
- (void)open:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        UIWindow *window = (UIWindow *)recognizer.view;
        PGShowMenu(window);
    }
}
@end

static void PGAttachGesture(UIWindow *window) {
    if (objc_getAssociatedObject(window, &PGGestureMarker)) return;
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[PGGestureTarget shared] action:@selector(open:)];
    gesture.numberOfTouchesRequired = 3;
    gesture.minimumPressDuration = 0.8;
    gesture.cancelsTouchesInView = NO;
    [window addGestureRecognizer:gesture];
    objc_setAssociatedObject(window, &PGGestureMarker, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface UIView (PGPrivacyLayout)
- (void)pg_privacyLayoutSubviews;
- (void)pg_privacyDidMoveToWindow;
@end
@implementation UIView (PGPrivacyLayout)
- (void)pg_privacyLayoutSubviews {
    [self pg_privacyLayoutSubviews];
    PGApply(self);
}
- (void)pg_privacyDidMoveToWindow {
    [self pg_privacyDidMoveToWindow];
    // A node may finish its initial layout before it is in a UIWindow.
    // Check once attached, not just during the first layout pass.
    PGApply(self);
}
@end

@interface UIWindow (PGPrivacyWindow)
- (void)pg_privacyMakeKeyAndVisible;
@end
@implementation UIWindow (PGPrivacyWindow)
- (void)pg_privacyMakeKeyAndVisible {
    [self pg_privacyMakeKeyAndVisible];
    PGAttachGesture(self);
}
@end

static void PGSwizzle(Class cls, SEL original, SEL replacement) {
    Method methodA = class_getInstanceMethod(cls, original);
    Method methodB = class_getInstanceMethod(cls, replacement);
    if (methodA && methodB) method_exchangeImplementations(methodA, methodB);
}

__attribute__((constructor))
static void PGInstall(void) {
    PGSwizzle([UIView class], @selector(layoutSubviews), @selector(pg_privacyLayoutSubviews));
    PGSwizzle([UIView class], @selector(didMoveToWindow), @selector(pg_privacyDidMoveToWindow));
    PGSwizzle([UIWindow class], @selector(makeKeyAndVisible), @selector(pg_privacyMakeKeyAndVisible));
    dispatch_async(dispatch_get_main_queue(), ^{
        PGReload();
        for (UIWindow *window in [UIApplication sharedApplication].windows) PGAttachGesture(window);
    });
}
