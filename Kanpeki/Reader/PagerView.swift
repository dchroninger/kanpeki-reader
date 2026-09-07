#if os(iOS)
import SwiftUI
import UIKit
import KanpekiCore

/// The pager: `UIPageViewController` with the page-curl transition. The
/// curl follows the finger, snaps back if released early, and completes
/// with momentum. Spine on the right for RTL so pages lift from the left.
///
/// This is the one deliberate UIKit exception in an otherwise SwiftUI app.
struct PagerView: UIViewControllerRepresentable {
    let provider: PageProvider
    let rightToLeft: Bool
    let twoUp: Bool
    @Binding var page: Int
    @Binding var visiblePages: [Int]
    var onUserTurn: () -> Void
    var onMiddleTap: () -> Void

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                       options: [.spineLocation: NSNumber(value: (rightToLeft ? UIPageViewController.SpineLocation.max : .min).rawValue)])
        pvc.view.backgroundColor = .black
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        // Edge taps are ours (RTL-aware zones + a middle tap for chrome).
        pvc.gestureRecognizers.compactMap { $0 as? UITapGestureRecognizer }.forEach { $0.isEnabled = false }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        pvc.view.addGestureRecognizer(tap)
        context.coordinator.pvc = pvc
        context.coordinator.show(startingAt: page, direction: .forward, animated: false)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.twoUp != twoUp {
            c.twoUp = twoUp
            c.show(startingAt: c.currentPages.first ?? page, direction: .forward, animated: false)
        } else if !c.currentPages.contains(page) {
            // Slider or a remote position moved us.
            let forward = page > (c.currentPages.first ?? 0)
            c.show(startingAt: page, direction: forward ? .forward : .reverse, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PagerView
        weak var pvc: UIPageViewController?
        var twoUp: Bool
        var currentPages: [Int] = []

        init(_ parent: PagerView) { self.parent = parent; self.twoUp = parent.twoUp }

        private var provider: PageProvider { parent.provider }

        func controller(for pages: [Int]) -> SpreadViewController {
            SpreadViewController(pages: pages, rightToLeft: parent.rightToLeft, provider: provider)
        }

        /// UIKit's "forward" always curls the right edge over, whatever the
        /// spine. In an RTL book the next page lives under the left edge, so
        /// reading-forward maps to UIKit-reverse.
        private func uiDirection(readingForward: Bool) -> UIPageViewController.NavigationDirection {
            (readingForward != parent.rightToLeft) ? .forward : .reverse
        }

        func show(startingAt p: Int, direction: UIPageViewController.NavigationDirection, animated: Bool) {
            show(startingAt: p, readingForward: direction == .forward, animated: animated)
        }

        func show(startingAt p: Int, readingForward: Bool, animated: Bool) {
            let pages = provider.spread(startingAt: p, twoUp: twoUp)
            guard !pages.isEmpty, let pvc else { return }
            let vc = controller(for: pages)
            currentPages = pages
            pvc.setViewControllers([vc], direction: uiDirection(readingForward: readingForward), animated: animated) { [weak self] _ in
                self?.commit(pages, userDriven: false)
            }
            if !animated { commit(pages, userDriven: false) }
        }

        // Reading order, independent of UIKit's notion of before/after.
        private func nextSpread(after vc: UIViewController) -> SpreadViewController? {
            guard let last = (vc as? SpreadViewController)?.pages.last else { return nil }
            let n = provider.spread(startingAt: last + 1, twoUp: twoUp)
            return n.isEmpty ? nil : controller(for: n)
        }
        private func previousSpread(before vc: UIViewController) -> SpreadViewController? {
            guard let first = (vc as? SpreadViewController)?.pages.first else { return nil }
            let p = provider.spread(endingAt: first - 1, twoUp: twoUp)
            return p.isEmpty ? nil : controller(for: p)
        }

        private func commit(_ pages: [Int], userDriven: Bool) {
            currentPages = pages
            parent.visiblePages = pages
            if let f = pages.first, parent.page != f { parent.page = f }
            provider.prefetch(around: pages.last ?? 0)
            if userDriven { parent.onUserTurn() }
        }

        // MARK: Data source — UIKit "after" sits under the right edge. For an
        // RTL book that is the *previous* page in reading order.

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            parent.rightToLeft ? previousSpread(before: vc) : nextSpread(after: vc)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            parent.rightToLeft ? nextSpread(after: vc) : previousSpread(before: vc)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let vc = pvc.viewControllers?.first as? SpreadViewController else { return }
            commit(vc.pages, userDriven: true)
        }

        // MARK: Taps — outer thirds turn (direction follows the book), middle toggles chrome.

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let view = g.view else { return }
            let x = g.location(in: view).x, w = view.bounds.width
            if x > w / 3 && x < w * 2 / 3 { parent.onMiddleTap(); return }
            let leading = x < w / 3
            let forward = parent.rightToLeft ? leading : !leading
            turn(forward: forward)
        }

        func turn(forward: Bool) {
            guard let pvc, let cur = pvc.viewControllers?.first else { return }
            guard let target = forward ? nextSpread(after: cur) : previousSpread(before: cur) else { return }
            pvc.setViewControllers([target], direction: uiDirection(readingForward: forward), animated: true) { [weak self] done in
                if done { self?.commit(target.pages, userDriven: true) }
            }
        }
    }
}

/// One sheet of the book: a single page, or two pages edge to edge sharing
/// one height so a spread split across files reads as one image.
final class SpreadViewController: UIViewController {
    let pages: [Int]
    let rightToLeft: Bool
    let provider: PageProvider
    private var imageViews: [UIImageView] = []

    init(pages: [Int], rightToLeft: Bool, provider: PageProvider) {
        self.pages = pages; self.rightToLeft = rightToLeft; self.provider = provider
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let ordered = rightToLeft ? pages.reversed() : pages
        for p in ordered {
            let iv = UIImageView()
            iv.contentMode = .scaleToFill
            iv.backgroundColor = .black
            view.addSubview(iv)
            imageViews.append(iv)
            if let img = provider.cached(p) { iv.image = UIImage(cgImage: img) }
            else { Task { [weak iv] in if let img = await provider.image(p) { iv?.image = UIImage(cgImage: img) } } }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let ordered = rightToLeft ? pages.reversed() : pages
        let sizes = ordered.map { provider.sizes.indices.contains($0) ? provider.sizes[$0] : CGSize(width: 2, height: 3) }
        let aspects = sizes.map { $0.width / max($0.height, 1) }
        let b = view.bounds
        let h = min(b.height, b.width / max(aspects.reduce(0, +), 0.01))
        let total = aspects.reduce(0, +) * h
        var x = (b.width - total) / 2
        let y = (b.height - h) / 2
        for (iv, a) in zip(imageViews, aspects) {
            iv.frame = CGRect(x: x, y: y, width: a * h, height: h)
            x += a * h
        }
    }
}
#endif
