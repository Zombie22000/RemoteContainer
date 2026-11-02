import UIKit

extension UIView {
    /// Programmatically synthesize and dispatch touch events to this view hierarchy.
    /// - Parameters:
    ///   - normalizedX: X coordinate normalized to the view's bounds (0.0 = left, 1.0 = right)
    ///   - normalizedY: Y coordinate normalized to the view's bounds (0.0 = top, 1.0 = bottom)
    ///   - phases: Sequence of touch phases to dispatch (e.g., [.began, .ended] or [.began, .moved, .ended])
    func synthesizeTouch(normalizedX: CGFloat, normalizedY: CGFloat,
                        phases: [UITouch.Phase] = [.began, .ended]) {
        guard let window = self.window ?? (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first) else { return }
        let point = CGPoint(x: bounds.width * normalizedX, y: bounds.height * normalizedY)
        let locationInWindow = self.convert(point, to: window)
        let locationInView = point

        var touches: [UITouch] = []
        let timestamp = ProcessInfo.processInfo.systemUptime

        for phase in phases {
            let touch = UITouch()
            // Use private APIs where necessary for synthesis
            if let setPhase = class_getInstanceMethod(UITouch.self, Selector(("_setPhase:"))) {
                typealias SetPhase = @convention(c) (UITouch, Selector, UITouch.Phase) -> Void
                let imp = method_getImplementation(setPhase)
                let fn = unsafeBitCast(imp, to: SetPhase.self)
                fn(touch, Selector(("_setPhase:")), phase)
            }
            if let setLocation = class_getInstanceMethod(UITouch.self, Selector(("_setLocationInWindow:"))) {
                typealias SetLoc = @convention(c) (UITouch, Selector, CGPoint) -> Void
                let imp = method_getImplementation(setLocation)
                let fn = unsafeBitCast(imp, to: SetLoc.self)
                fn(touch, Selector(("_setLocationInWindow:")), locationInWindow)
            }
            if let setPrevLocation = class_getInstanceMethod(UITouch.self, Selector(("_setPreviousLocationInWindow:"))) {
                typealias SetPrevLoc = @convention(c) (UITouch, Selector, CGPoint) -> Void
                let imp = method_getImplementation(setPrevLocation)
                let fn = unsafeBitCast(imp, to: SetPrevLoc.self)
                fn(touch, Selector(("_setPreviousLocationInWindow:")), locationInWindow)
            }
            if let setView = class_getInstanceMethod(UITouch.self, Selector(("_setView:"))) {
                typealias SetView = @convention(c) (UITouch, Selector, UIView?) -> Void
                let imp = method_getImplementation(setView)
                let fn = unsafeBitCast(imp, to: SetView.self)
                fn(touch, Selector(("_setView:")), self.hitTest(locationInView, with: nil))
            }
            if let setWindow = class_getInstanceMethod(UITouch.self, Selector(("_setWindow:"))) {
                typealias SetWindow = @convention(c) (UITouch, Selector, UIWindow?) -> Void
                let imp = method_getImplementation(setWindow)
                let fn = unsafeBitCast(imp, to: SetWindow.self)
                fn(touch, Selector(("_setWindow:")), window)
            }
            if let setTimestamp = class_getInstanceMethod(UITouch.self, Selector(("_setTimestamp:"))) {
                typealias SetTs = @convention(c) (UITouch, Selector, TimeInterval) -> Void
                let imp = method_getImplementation(setTimestamp)
                let fn = unsafeBitCast(imp, to: SetTs.self)
                fn(touch, Selector(("_setTimestamp:")), timestamp)
            }
            touches.append(touch)
        }

        // Create UIEvent via private API if available
        if let eventWithTouches = class_getClassMethod(UIEvent.self, Selector(("_eventWithTouches:"))) {
            typealias EventWithTouches = @convention(c) (AnyClass, Selector, NSSet) -> UIEvent?
            let imp = method_getImplementation(eventWithTouches)
            let fn = unsafeBitCast(imp, to: EventWithTouches.self)
            if let event = fn(UIEvent.self, Selector(("_eventWithTouches:")), NSSet(array: touches)) {
                window.sendEvent(event)
                return
            }
        }

        // Fallback: try to send via UIApplication
        let event = UIEvent()
        UIApplication.shared.sendEvent(event)
    }

    /// Convenience for single tap
    func synthesizeTap(normalizedX: CGFloat = 0.5, normalizedY: CGFloat = 0.5) {
        synthesizeTouch(normalizedX: normalizedX, normalizedY: normalizedY, phases: [.began, .ended])
    }
}
