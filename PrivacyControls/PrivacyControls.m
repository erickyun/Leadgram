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
    // ChatMessageBubbleItemNode.swift: nameNode is a TextNode directly attached
    // to ChatMessageBubbleClippingNode. TextNode does not necessarily expose
    // -attributedText in all Telegram builds, so never require text inspection.
    id parent = PGInvokeObject(node, NSSelectorFromString(@"supernode"));
    if (!PGContains(PGClass(parent), @"chatmessagebubbleclippingnode")) return NO;
    UIView *label = PGInvokeObject(node, NSSelectorFromString(@"view"));
    UIView *container = PGInvokeObject(parent, NSSelectorFromString(@"view"));
    if (![label isKindOfClass:[UIView class]] || ![container isKindOfClass:[UIView class]]) return NO;
    CGRect rect = label.frame;
    CGFloat width = container.bounds.size.width;
    CGFloat height = container.bounds.size.height;
    // Names, including one-character sender names, are single-line text.
    // Chat message bodies are housed in separate BubbleContentNode descendants.
    if (rect.size.width < 4.0 || rect.size.height < 8.0 || rect.size.height > 38.0) return NO;
    if (width > 0 && (rect.origin.x < -8.0 || rect.origin.x > width * 0.85)) return NO;
    if (height > 0 && (rect.origin.y < -4.0 || rect.origin.y > MIN(100.0, height * 0.55))) return NO;
    return YES;
}

// Distinguish the reply author heading from the quoted message's actual
// preview text. In Telegram-iOS, ChatMessageReplyInfoNode.contentNode has
// separate TextNodes for 'titleNode' (author) and 'textNode' (message preview).
// The composer uses ReplyAccessoryPanelNode.titleNode (CompositeTextNode).
static BOOL PGReplyAuthorTitle(id node) {
    if (!node) return NO;
    NSString *name = PGClass(node);
    if (!PGContains(name, @"textnode")) return NO;

    id parent = PGInvokeObject(node, NSSelectorFromString(@"supernode"));
    NSString *parentName = PGClass(parent);
    // The reply bar above the keyboard stores its title as a direct child.
    if (PGContains(parentName, @"replyaccessorypanelnode")) {
        return PGContains(name, @"compositetextnode");
    }

    // Message quote: title and message text sit under a shared contentNode,
    // which is in turn owned by ChatMessageReplyInfoNode.
    if (!parent || !PGContains(parentName, @"asdisplaynode")) return NO;
    id grandparent = PGInvokeObject(parent, NSSelectorFromString(@"supernode"));
    if (!PGContains(PGClass(grandparent), @"chatmessagereplyinfonode")) return NO;

    // First choice: identify the title via a stored Swift/ObjC ivar, if this
    // Telegram build exposes one. Never hide the 'textNode' body.
    id storedTitle = nil;
    for (Class cls = object_getClass(grandparent); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            Ivar var = ivars[i];
            const char *encoding = ivar_getTypeEncoding(var);
            if (!encoding || encoding[0] != '@') continue;
            NSString *ivarName = [NSString stringWithUTF8String:ivar_getName(var)].lowercaseString;
            if (PGContains(ivarName, @"titlenode")) {
                storedTitle = object_getIvar(grandparent, var);
                break;
            }
        }
        free(ivars);
        if (storedTitle) break;
    }
    if (storedTitle) return storedTitle == node;

    // Fallback for Swift-opaque storage: title is the upper, single-line
    // TextNode and a distinct TextNode below it displays the message preview.
    UIView *titleView = PGInvokeObject(node, NSSelectorFromString(@"view"));
    if (![titleView isKindOfClass:[UIView class]]) return NO;
    CGRect titleFrame = titleView.frame;
    if (titleFrame.size.height < 6.0 || titleFrame.size.height > 45.0) return NO;
    id children = PGInvokeObject(parent, NSSelectorFromString(@"subnodes"));
    if (![children isKindOfClass:[NSArray class]]) return NO;
    for (id sibling in (NSArray *)children) {
        if (sibling == node || !PGContains(PGClass(sibling), @"textnode")) continue;
        UIView *siblingView = PGInvokeObject(sibling, NSSelectorFromString(@"view"));
        if (![siblingView isKindOfClass:[UIView class]]) continue;
        CGRect otherFrame = siblingView.frame;
        if (otherFrame.size.height >= 5.0 &&
            otherFrame.origin.y > titleFrame.origin.y + 4.0) return YES;
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

    // Hide reply-to person names with the existing sender/name toggles.
    // The quoted message's body and its media remain visible.
    if ((PGEnabled[1] || PGEnabled[3]) && PGReplyAuthorTitle(node)) return YES;

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
    BOOL bubbleHeader = PGBubbleAuthorHeader(node);
    BOOL senderHint = [role isEqualToString:@"sender"] ||
        (isMessage && [role isEqualToString:@"name"]) || bubbleHeader ||
        PGHasAny(direct, @[@"sendername", @"authorname", @"forwardedfrom", @"messageauthor"]);
    if ((PGEnabled[1] || PGEnabled[3]) && senderHint &&
        (bubbleHeader || isMessage || PGContains(context, @"gallery") ||
         PGContains(context, @"message"))) return YES;

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
- (void)pg_privacyDidMoveToSuperview;
- (void)pg_privacyDidAddSubview:(UIView *)subview;
- (void)pg_privacySetHidden:(BOOL)hidden;
@end
@implementation UIView (PGPrivacyLayout)
- (void)pg_privacyLayoutSubviews {
    [self pg_privacyLayoutSubviews];
    PGApply(self);
}
- (void)pg_privacyDidMoveToWindow {
    [self pg_privacyDidMoveToWindow];
    PGApply(self);
}
- (void)pg_privacyDidMoveToSuperview {
    [self pg_privacyDidMoveToSuperview];
    PGApply(self);
}
- (void)pg_privacyDidAddSubview:(UIView *)subview {
    [self pg_privacyDidAddSubview:subview];
    // Chat list / profile components can be attached *after* their layout
    // finished. Re-evaluate at insertion time instead of waiting for relayout.
    if (subview.window) PGApply(subview);
}
- (void)pg_privacySetHidden:(BOOL)hidden {
    // Telegram often explicitly unhides/recycles the same AvatarNode when a
    // conversation is reopened. Do not allow a marked, still-targeted view
    // to become visible. No recursion: the swapped selector below calls
    // UIKit's original implementation directly.
    if (!hidden && objc_getAssociatedObject(self, &PGHiddenMarker) &&
        [NSThread isMainThread] && PGShouldHide(self)) {
        [self pg_privacySetHidden:YES];
        return;
    }
    [self pg_privacySetHidden:hidden];
}
@end

@interface UIViewController (PGPrivacyNavigation)
- (void)pg_privacyViewDidAppear:(BOOL)animated;
@end
@implementation UIViewController (PGPrivacyNavigation)
- (void)pg_privacyViewDidAppear:(BOOL)animated {
    [self pg_privacyViewDidAppear:animated];
    // Navigation can recycle Telegram's cached avatar views without adding
    // new subviews or running layout on the avatar itself. Re-apply the
    // independent switches at the end of each completed presentation.
    if ([NSThread isMainThread]) {
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (!window.hidden) PGRefreshView(window);
        }
    }
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
    PGSwizzle([UIView class], @selector(didMoveToSuperview), @selector(pg_privacyDidMoveToSuperview));
    PGSwizzle([UIView class], @selector(didAddSubview:), @selector(pg_privacyDidAddSubview:));
    PGSwizzle([UIView class], @selector(setHidden:), @selector(pg_privacySetHidden:));
    PGSwizzle([UIViewController class], @selector(viewDidAppear:), @selector(pg_privacyViewDidAppear:));
    PGSwizzle([UIWindow class], @selector(makeKeyAndVisible), @selector(pg_privacyMakeKeyAndVisible));
    dispatch_async(dispatch_get_main_queue(), ^{
        PGReload();
        for (UIWindow *window in [UIApplication sharedApplication].windows) PGAttachGesture(window);
    });
}
