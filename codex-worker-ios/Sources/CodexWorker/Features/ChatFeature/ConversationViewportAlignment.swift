import SwiftUI
import UIKit

/// Exyte's conversation table is inverted. Give short transcripts the unused
/// viewport as a top inset so their visual position starts below the header.
/// Message order, scrolling, the composer and the table's delegate stay intact.
struct ConversationViewportAlignment: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.scheduleUpdate() }
    static func dismantleUIView(_ uiView: Probe, coordinator: ()) { uiView.detach() }

    final class Probe: UIView {
        private weak var table: UITableView?
        private weak var host: UIView?
        private var observations: [NSKeyValueObservation] = []
        private var baselineTop: CGFloat = 0
        private var extraTop: CGFloat = 0
        private var updateQueued = false
        private var deferredUpdateQueued = false
        private var generation: UInt64 = 0
        private var isActive = false

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() }
            else { isActive = true; scheduleUpdate() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleUpdate()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            scheduleUpdate()
        }

        func scheduleUpdate() {
            guard isActive, !updateQueued else { return }
            updateQueued = true
            let expectedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.generation == expectedGeneration else { return }
                self.updateQueued = false
                self.updateAlignment()
            }
        }

        func detach() {
            isActive = false
            generation &+= 1
            updateQueued = false
            deferredUpdateQueued = false
            unbindTable()
        }

        private func unbindTable() {
            observations.removeAll()
            if let table, extraTop > 0,
               abs(table.contentInset.top - baselineTop - extraTop) <= 0.5 {
                let oldOffset = table.contentOffset
                var inset = table.contentInset
                inset.top = baselineTop
                table.contentInset = inset
                let minimumY = -table.adjustedContentInset.top
                let maximumY = max(minimumY, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
                table.setContentOffset(CGPoint(x: oldOffset.x,
                    y: min(maximumY, max(minimumY, oldOffset.y + extraTop))), animated: false)
            }
            table = nil
            host = nil
            extraTop = 0
        }

        private func updateAlignment() {
            guard isActive, let window, bounds.width > 0, bounds.height > 0 else { return }
            if let table {
                let matches = host.flatMap { isDescendant(of: $0) ? invertedTables(in: $0, window: window) : nil } ?? []
                if matches.count != 1 || matches.first !== table { unbindTable() }
            }
            if table == nil {
                var ancestor = superview
                while let container = ancestor {
                    let matches = invertedTables(in: container, window: window)
                    // Fail closed if another conversation is also in this subtree.
                    if matches.count > 1 { return }
                    if let match = matches.first {
                        table = match
                        host = container
                        baselineTop = match.contentInset.top
                        observations = [
                            match.observe(\.contentSize) { [weak self] _, _ in self?.scheduleUpdate() },
                            match.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                                if change.oldValue?.size != change.newValue?.size { self?.scheduleUpdate() }
                            },
                            match.observe(\.contentInset) { [weak self] table, _ in
                                guard let self else { return }
                                // A different owner explicitly changed the raw top inset.
                                // Keep its value and stop adapting this view rather than
                                // guessing how much of that new value belongs to us.
                                if abs(table.contentInset.top - self.baselineTop - self.extraTop) > 0.5 {
                                    self.detach()
                                } else { self.scheduleUpdate() }
                            }
                        ]
                        break
                    }
                    ancestor = container.superview
                }
            }
            guard let table, table.bounds.height > 0, table.contentSize.height > 0 else { return }
            if table.isDragging || table.isDecelerating {
                // A layout change during a pan must be applied once interaction settles.
                guard !deferredUpdateQueued else { return }
                deferredUpdateQueued = true
                let expectedGeneration = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.isActive, self.generation == expectedGeneration else { return }
                    self.deferredUpdateQueued = false
                    self.scheduleUpdate()
                }
                return
            }
            let adjusted = table.adjustedContentInset
            let systemTop = adjusted.top - table.contentInset.top
            let usableHeight = table.bounds.height - baselineTop - systemTop - adjusted.bottom
            let nextExtra = max(0, usableHeight - table.contentSize.height)
            let oldExtra = extraTop
            let oldOffset = table.contentOffset
            extraTop = nextExtra
            let desiredTop = baselineTop + nextExtra
            if abs(table.contentInset.top - desiredTop) > 0.5 {
                var inset = table.contentInset
                inset.top = desiredTop
                table.contentInset = inset
            }
            if nextExtra > 0.5 {
                let targetY = -table.adjustedContentInset.top
                if abs(table.contentOffset.y - targetY) > 0.5 {
                    table.setContentOffset(CGPoint(x: oldOffset.x, y: targetY), animated: false)
                }
            } else if oldExtra > 0.5 {
                let minimumY = -table.adjustedContentInset.top
                let maximumY = max(minimumY, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
                let targetY = min(maximumY, max(minimumY, oldOffset.y + oldExtra))
                table.setContentOffset(CGPoint(x: oldOffset.x, y: targetY), animated: false)
            }
        }

        private func invertedTables(in view: UIView, window: UIWindow) -> [UITableView] {
            guard !view.isHidden, view.alpha > 0.01 else { return [] }
            if let table = view as? UITableView,
               table.window === window,
               abs(table.transform.a + 1) < 0.01, abs(table.transform.d + 1) < 0.01,
               abs(table.transform.b) < 0.01, abs(table.transform.c) < 0.01,
               table.convert(table.bounds, to: self).intersects(bounds) {
                return [table]
            }
            return view.subviews.flatMap { invertedTables(in: $0, window: window) }
        }
    }
}
