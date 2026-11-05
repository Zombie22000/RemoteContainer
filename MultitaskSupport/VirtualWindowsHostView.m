//
//  VirtualWindowsHostView.m
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"

@interface VirtualWindowsHostView ()
@property(nonatomic, weak) UIView *activeGuestView;
- (void)configureHostView;
@end

@implementation VirtualWindowsHostView {
    BOOL _didCompleteInitialLayout;
    int32_t _activeGuestProcessID;
}

+ (UIWindow *)activeWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.keyWindow) {
            return windowScene.keyWindow;
        }
        for (UIWindow *window in windowScene.windows) {
            if (!window.isHidden && window.rootViewController) {
                return window;
            }
        }
    }
    return nil;
}

- (instancetype)init {
    UIWindow *window = [VirtualWindowsHostView activeWindow];
    return [self initWithFrame:window ? window.bounds : CGRectZero];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self configureHostView];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self configureHostView];
    }
    return self;
}

- (void)configureHostView {
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.shouldForwardTapAction = YES;
    _didCompleteInitialLayout = NO;
}

- (BOOL)readyForStreaming {
    UIWindow *window = self.window;
    return _didCompleteInitialLayout &&
        !CGRectIsEmpty(self.bounds) &&
        !self.hidden &&
        self.alpha > 0 &&
        window &&
        window.windowScene.activationState == UISceneActivationStateForegroundActive &&
        !window.isHidden;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    _didCompleteInitialLayout = NO;
    if (self.window && CGRectIsEmpty(self.bounds)) {
        self.frame = (CGRect){CGPointZero, self.window.bounds.size};
    }
    [self setNeedsLayout];
    NSLog(@"[RemoteContainer] Virtual window host attached=%d sceneActive=%d bounds=%@",
          self.window != nil,
          self.window.windowScene.activationState == UISceneActivationStateForegroundActive,
          NSStringFromCGRect(self.bounds));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _didCompleteInitialLayout = YES;
}

- (void)activateGuestView:(UIView *)view {
    if (view && view.superview != self) {
        NSLog(@"[RemoteContainer] Ignored guest view activation outside the virtual window host");
        return;
    }

    UIView *previousView = self.activeGuestView;
    if (view) {
        [self bringSubviewToFront:view];
    }

    DecoratedAppSceneViewController *decoratedVC = (id)view._viewDelegate;
    DecoratedAppSceneViewController *previousVC = (id)previousView._viewDelegate;
    int32_t processID = decoratedVC.appSceneVC.pid;
    if (previousView == view && _activeGuestProcessID == processID) {
        return;
    }
    self.activeGuestView = view;
    _activeGuestProcessID = processID;
    NSLog(@"[RemoteContainer] Virtual window guest switched from PID %d to PID %d",
          previousVC.appSceneVC.pid, processID);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RemoteActiveGuestChanged"
                                                        object:self
                                                      userInfo:@{@"processID": @(processID > 0 ? processID : 0)}];
}

- (void)activateFrontmostVisibleGuestView {
    UIView *frontmostView = nil;
    for (UIView *view in self.subviews.reverseObjectEnumerator) {
        if (!view.hidden && view.alpha > 0.1) {
            frontmostView = view;
            break;
        }
    }
    [self activateGuestView:frontmostView];
}

- (BOOL)handleStatusBarTapAction:(UIAction *)action {
    if(!self.shouldForwardTapAction) return NO;
    // grab the frontmost app window, if it's visible pass this event to it
    UIView *frontmostView = self.subviews.lastObject;
    if(!frontmostView.hidden) {
        DecoratedAppSceneViewController *decoratedVC = (id)frontmostView._viewDelegate;
        [decoratedVC.appSceneVC handleStatusBarTapAction:action];
    }
    return !frontmostView.hidden;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView* hitView = [super hitTest:point withEvent:event];
    if(hitView == self) {
        self.shouldForwardTapAction = NO;
        return nil;
    } else {
        self.shouldForwardTapAction = YES;
        return hitView;
    }
}
@end
