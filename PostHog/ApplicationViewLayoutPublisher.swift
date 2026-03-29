//
//  ApplicationViewLayoutPublisher.swift
//  PostHog
//
//  Created by Ioannis Josephides on 19/03/2025.
//

#if os(iOS) || os(tvOS)
    import QuartzCore
    import UIKit

    protocol ViewLayoutPublishing: AnyObject {
        /// Callback for getting notified when the screen changes.
        /// Note: callback guaranteed to be called on main thread.
        var onViewLayout: PostHogThrottledMulticastCallback<Void> { get }

        /// Temporarily suppress publishing while executing work that is expected
        /// to trigger lots of internal layer display / draw callbacks.
        func performWithoutPublishing<T>(_ block: () -> T) -> T
    }

    final class ApplicationViewLayoutPublisher: ViewLayoutPublishing {
        static let shared = ApplicationViewLayoutPublisher()

        private let stateLock = NSLock()
        private let minimumDeliveryInterval: CFTimeInterval = 0.1

        private(set) lazy var onViewLayout = PostHogThrottledMulticastCallback<Void> {
            [weak self] subscriberCount in
            if subscriberCount > 0 {
                self?.startMonitoring()
            } else {
                self?.stopMonitoring()
            }
        }

        private var hasSwizzled = false
        private var isRunning = false
        private var isDeliveringChanges = false
        private var hasPendingChanges = false
        private var lastDeliveryTime: CFTimeInterval = 0
        private var scheduledDelivery: DispatchWorkItem?
        private var suppressionCount = 0

        func performWithoutPublishing<T>(_ block: () -> T) -> T {
            stateLock.withLock {
                suppressionCount += 1
            }
            defer {
                stateLock.withLock {
                    suppressionCount = max(0, suppressionCount - 1)
                }
            }
            return block()
        }

        private func startMonitoring() {
            let shouldStart = stateLock.withLock {
                guard !hasSwizzled else { return false }
                hasSwizzled = true
                isRunning = true
                isDeliveringChanges = false
                hasPendingChanges = false
                lastDeliveryTime = CACurrentMediaTime()
                return true
            }

            guard shouldStart else { return }

            swizzle(
                forClass: CALayer.self, original: #selector(CALayer.display),
                new: #selector(CALayer.ph_swizzled_display))
            swizzle(
                forClass: CALayer.self, original: #selector(CALayer.draw(in:)),
                new: #selector(CALayer.ph_swizzled_draw(in:)))
            swizzle(
                forClass: CALayer.self, original: #selector(CALayer.layoutSublayers),
                new: #selector(CALayer.ph_swizzled_layoutSublayers))
        }

        private func stopMonitoring() {
            let shouldStop = stateLock.withLock {
                guard hasSwizzled else { return false }
                hasSwizzled = false
                isRunning = false
                isDeliveringChanges = false
                hasPendingChanges = false
                let scheduled = scheduledDelivery
                scheduledDelivery = nil
                scheduled?.cancel()
                return true
            }

            guard shouldStop else { return }

            // Swizzling twice exchanges the implementations back to the original methods.
            swizzle(
                forClass: CALayer.self, original: #selector(CALayer.display),
                new: #selector(CALayer.ph_swizzled_display))
            swizzle(
                forClass: CALayer.self, original: #selector(CALayer.draw(in:)),
                new: #selector(CALayer.ph_swizzled_draw(in:)))
            swizzle(
                forClass: CALayer.self, original: #selector(CALayer.layoutSublayers),
                new: #selector(CALayer.ph_swizzled_layoutSublayers))
        }

        fileprivate func layerDidChange() {
            guard Thread.isMainThread else { return }

            let scheduling = stateLock.withLock { () -> (DispatchWorkItem?, TimeInterval, Bool)? in
                guard isRunning, suppressionCount == 0, !isDeliveringChanges else {
                    return nil
                }

                hasPendingChanges = true

                let now = CACurrentMediaTime()
                let elapsed = now - lastDeliveryTime

                if elapsed >= minimumDeliveryInterval {
                    scheduledDelivery?.cancel()
                    scheduledDelivery = nil
                    return (nil, 0, true)
                }

                guard scheduledDelivery == nil else {
                    return nil
                }

                let delay = minimumDeliveryInterval - elapsed
                let workItem = DispatchWorkItem { [weak self] in
                    self?.deliverPendingChanges()
                }
                scheduledDelivery = workItem
                return (workItem, delay, false)
            }

            guard let scheduling else { return }

            if scheduling.2 {
                deliverPendingChanges()
            } else if let workItem = scheduling.0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + scheduling.1, execute: workItem)
            }
        }

        private func deliverPendingChanges() {
            let shouldDeliver = stateLock.withLock {
                scheduledDelivery = nil

                guard isRunning, hasPendingChanges, suppressionCount == 0 else {
                    return false
                }

                hasPendingChanges = false
                lastDeliveryTime = CACurrentMediaTime()
                isDeliveringChanges = true
                return true
            }

            guard shouldDeliver else { return }

            onViewLayout.invoke(())

            stateLock.withLock {
                isDeliveringChanges = false
            }
        }

        #if TESTING
            func simulateLayoutSubviews() {
                layerDidChange()
            }
        #endif
    }

    extension CALayer {
        @objc func ph_swizzled_display() {
            ph_swizzled_display()
            ApplicationViewLayoutPublisher.shared.layerDidChange()
        }

        @objc func ph_swizzled_draw(in context: CGContext) {
            ph_swizzled_draw(in: context)
            ApplicationViewLayoutPublisher.shared.layerDidChange()
        }

        @objc func ph_swizzled_layoutSublayers() {
            ph_swizzled_layoutSublayers()
            ApplicationViewLayoutPublisher.shared.layerDidChange()
        }
    }
#endif
