import CoreLocation
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Low-latency single-finger stroke recognizer that cannot be prevented or stolen by
/// map subviews, double-tap zoom, POI tap handlers, or container gestures, while still
/// yielding cleanly when a second finger lands early for 2-finger pinch/pan.
final class FreehandStrokeRecognizer: UIGestureRecognizer {
    var onStrokeBegan: ((CGPoint) -> Void)?
    var onStrokeMoved: (([CGPoint]) -> Void)?
    var onStrokeEnded: ((CGPoint?, CGFloat) -> Void)?
    var onStrokeCancelled: (() -> Void)?

    /// Optional guard (e.g. post-2-finger cooldown) preventing accidental single-finger strokes
    /// when one finger lifts slightly before the other after 2-finger pinch/pan.
    var shouldIgnoreNewTouches: (() -> Bool)?

    /// Two-finger navigation gestures on the same overlay that are allowed to win when 2 fingers touch.
    weak var twoFingerPan: UIGestureRecognizer?
    weak var twoFingerPinch: UIGestureRecognizer?

    private weak var trackedTouch: UITouch?
    private var initialPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var maxDisplacementPt: CGFloat = 0
    private var totalPathLengthPt: CGFloat = 0
    private var hasCommittedStroke = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        if preventingGestureRecognizer === twoFingerPan || preventingGestureRecognizer === twoFingerPinch {
            return !hasCommittedStroke
        }
        return false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        if preventedGestureRecognizer === twoFingerPan || preventedGestureRecognizer === twoFingerPinch {
            return hasCommittedStroke
        }
        return true
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        initialPoint = .zero
        lastPoint = .zero
        maxDisplacementPt = 0
        totalPathLengthPt = 0
        hasCommittedStroke = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if !hasCommittedStroke && shouldIgnoreNewTouches?() == true {
            state = .failed
            return
        }
        let allActive = (event.allTouches ?? touches).filter {
            $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
        }
        if allActive.count > 1 {
            // If the user puts 2 fingers down before actually drawing (>14pt path), yield to pinch/pan.
            if !hasCommittedStroke || totalPathLengthPt < 14.0 {
                if hasCommittedStroke {
                    onStrokeCancelled?()
                }
                state = .failed
            } else {
                // Ignore accidental second-finger palm/edge graze mid-stroke.
                for t in touches where t !== trackedTouch {
                    ignore(t, for: event)
                }
            }
            return
        }
        guard trackedTouch == nil, let touch = touches.first, let view else { return }
        trackedTouch = touch
        let pt = touch.location(in: view)
        initialPoint = pt
        lastPoint = pt
        maxDisplacementPt = 0
        totalPathLengthPt = 0
        hasCommittedStroke = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch), let view else { return }

        let allActive = (event.allTouches ?? touches).filter {
            $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
        }
        if allActive.count > 1 && (!hasCommittedStroke || totalPathLengthPt < 14.0) {
            if hasCommittedStroke {
                onStrokeCancelled?()
            }
            state = .failed
            return
        }

        let coalesced = event.coalescedTouches(for: touch) ?? [touch]
        let pts = coalesced.map { $0.location(in: view) }
        guard !pts.isEmpty else { return }

        for pt in pts {
            let step = hypot(pt.x - lastPoint.x, pt.y - lastPoint.y)
            totalPathLengthPt += step
            lastPoint = pt
            let distFromStart = hypot(pt.x - initialPoint.x, pt.y - initialPoint.y)
            if distFromStart > maxDisplacementPt {
                maxDisplacementPt = distFromStart
            }
        }

        if !hasCommittedStroke {
            // Commit immediately at 3pt (vs UIPanGestureRecognizer's ~10pt delay).
            guard maxDisplacementPt >= 3.0 || totalPathLengthPt >= 4.0 else { return }
            hasCommittedStroke = true
            state = .began
            onStrokeBegan?(initialPoint)
            onStrokeMoved?(pts)
        } else {
            state = .changed
            onStrokeMoved?(pts)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        if hasCommittedStroke {
            let endPt = view.map { touch.location(in: $0) }
            onStrokeEnded?(endPt, totalPathLengthPt)
            state = .ended
        } else {
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        if hasCommittedStroke {
            // Preserve substantial strokes (using total drawn path length, so small closed circles
            // whose finger finishes near the start dot are never discarded on late edge interrupts).
            if totalPathLengthPt >= 45.0 {
                let endPt = view.map { touch.location(in: $0) }
                onStrokeEnded?(endPt, totalPathLengthPt)
                state = .ended
            } else {
                onStrokeCancelled?()
                state = .cancelled
            }
        } else {
            state = .failed
        }
    }
}

/// Dedicated topmost touch-isolating canvas for freehand trajectory drawing.
/// When active (`isDrawingEnabled = true`), intercepts all single-finger strokes directly so
/// underlying map subviews (`MKMapView`, POIs, annotations, double-tap zoom) can never steal
/// or cancel touches, while forwarding 2-finger pinch & pan cleanly to the underlying map.
final class FreehandDrawingOverlayView: UIView, UIGestureRecognizerDelegate {
    var convertPointToCoordinate: ((CGPoint) -> CLLocationCoordinate2D)?
    var onFinishStroke: (([CLLocationCoordinate2D]) -> Void)?
    var onTwoFingerPan: ((UIPanGestureRecognizer) -> Void)?
    var onTwoFingerPinch: ((UIPinchGestureRecognizer) -> Void)?

    var isDrawingEnabled: Bool = false {
        didSet {
            guard oldValue != isDrawingEnabled else { return }
            isUserInteractionEnabled = isDrawingEnabled
            strokeRecognizer.isEnabled = isDrawingEnabled
            twoFingerPanRecognizer.isEnabled = isDrawingEnabled
            twoFingerPinchRecognizer.isEnabled = isDrawingEnabled
            if !isDrawingEnabled {
                clearDraftStroke()
            }
        }
    }

    private let casingLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let startHaloLayer = CAShapeLayer()
    private let startDotLayer = CAShapeLayer()

    private var screenPoints: [CGPoint] = []
    private var coordinates: [CLLocationCoordinate2D] = []
    private var screenLengthPt: CGFloat = 0
    private var lastTwoFingerInteractionAt: CFTimeInterval = 0

    private lazy var strokeRecognizer = FreehandStrokeRecognizer(target: self, action: #selector(handleStrokeState(_:)))
    private lazy var twoFingerPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
    private lazy var twoFingerPinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handleTwoFingerPinch(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = false

        casingLayer.fillColor = UIColor.clear.cgColor
        casingLayer.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        casingLayer.lineWidth = 9.0
        casingLayer.lineCap = .round
        casingLayer.lineJoin = .round
        layer.addSublayer(casingLayer)

        strokeLayer.fillColor = UIColor.clear.cgColor
        strokeLayer.strokeColor = UIColor(RelocTheme.accent).cgColor
        strokeLayer.lineWidth = 5.5
        strokeLayer.lineCap = .round
        strokeLayer.lineJoin = .round
        layer.addSublayer(strokeLayer)

        startHaloLayer.fillColor = UIColor(RelocTheme.emerald).withAlphaComponent(0.24).cgColor
        startHaloLayer.strokeColor = UIColor.clear.cgColor
        startHaloLayer.isHidden = true
        layer.addSublayer(startHaloLayer)

        startDotLayer.fillColor = UIColor(RelocTheme.emerald).cgColor
        startDotLayer.strokeColor = UIColor.white.cgColor
        startDotLayer.lineWidth = 2.5
        startDotLayer.isHidden = true
        layer.addSublayer(startDotLayer)

        twoFingerPanRecognizer.minimumNumberOfTouches = 2
        twoFingerPanRecognizer.maximumNumberOfTouches = 2
        twoFingerPanRecognizer.delegate = self
        twoFingerPanRecognizer.isEnabled = false
        addGestureRecognizer(twoFingerPanRecognizer)

        twoFingerPinchRecognizer.delegate = self
        twoFingerPinchRecognizer.isEnabled = false
        addGestureRecognizer(twoFingerPinchRecognizer)

        strokeRecognizer.twoFingerPan = twoFingerPanRecognizer
        strokeRecognizer.twoFingerPinch = twoFingerPinchRecognizer
        strokeRecognizer.delegate = self
        strokeRecognizer.isEnabled = false
        strokeRecognizer.shouldIgnoreNewTouches = { [weak self] in
            guard let self else { return false }
            let isTwoFingerLive = self.twoFingerPanRecognizer.state == .began
                || self.twoFingerPanRecognizer.state == .changed
                || self.twoFingerPinchRecognizer.state == .began
                || self.twoFingerPinchRecognizer.state == .changed
            if isTwoFingerLive { return true }
            return (CACurrentMediaTime() - self.lastTwoFingerInteractionAt) < 0.18
        }
        strokeRecognizer.onStrokeBegan = { [weak self] pt in
            self?.beginStroke(at: pt)
        }
        strokeRecognizer.onStrokeMoved = { [weak self] pts in
            self?.appendStrokePoints(pts)
        }
        strokeRecognizer.onStrokeEnded = { [weak self] endPt, totalLen in
            self?.finishStroke(endPoint: endPt, totalPathLengthPt: totalLen)
        }
        strokeRecognizer.onStrokeCancelled = { [weak self] in
            self?.clearDraftStroke()
        }
        addGestureRecognizer(strokeRecognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        casingLayer.frame = bounds
        strokeLayer.frame = bounds
        startHaloLayer.frame = bounds
        startDotLayer.frame = bounds
        CATransaction.commit()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer === twoFingerPanRecognizer && otherGestureRecognizer === twoFingerPinchRecognizer)
            || (gestureRecognizer === twoFingerPinchRecognizer && otherGestureRecognizer === twoFingerPanRecognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === strokeRecognizer else { return false }
        if otherGestureRecognizer === twoFingerPanRecognizer || otherGestureRecognizer === twoFingerPinchRecognizer {
            return false
        }
        // Prevent any ancestor scroll/tab/map gesture from stealing an active freehand stroke.
        return isDrawingEnabled
    }

    @objc private func handleStrokeState(_ gesture: FreehandStrokeRecognizer) {
        // State callbacks are dispatched directly with coalesced points from FreehandStrokeRecognizer.
    }

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        lastTwoFingerInteractionAt = CACurrentMediaTime()
        clearDraftStroke()
        onTwoFingerPan?(gesture)
    }

    @objc private func handleTwoFingerPinch(_ gesture: UIPinchGestureRecognizer) {
        lastTwoFingerInteractionAt = CACurrentMediaTime()
        clearDraftStroke()
        onTwoFingerPinch?(gesture)
    }

    private func beginStroke(at pt: CGPoint) {
        guard let coord = convertPointToCoordinate?(pt),
              coord.latitude.isFinite, coord.longitude.isFinite else { return }
        screenPoints = [pt]
        coordinates = [coord]
        screenLengthPt = 0
        renderDraftStroke(snappedToStart: false)
    }

    private func appendStrokePoints(_ pts: [CGPoint]) {
        guard let convert = convertPointToCoordinate else { return }
        for pt in pts {
            if let last = screenPoints.last {
                let step = hypot(pt.x - last.x, pt.y - last.y)
                if step >= 3.5 {
                    let coord = convert(pt)
                    guard coord.latitude.isFinite, coord.longitude.isFinite else { continue }
                    screenPoints.append(pt)
                    coordinates.append(coord)
                    screenLengthPt += step
                }
            } else {
                let coord = convert(pt)
                guard coord.latitude.isFinite, coord.longitude.isFinite else { continue }
                screenPoints = [pt]
                coordinates = [coord]
            }
        }
        let nearStart: Bool = {
            guard let first = screenPoints.first, let latest = pts.last, screenLengthPt >= 60.0 else { return false }
            return hypot(latest.x - first.x, latest.y - first.y) <= 32.0
        }()
        renderDraftStroke(snappedToStart: nearStart)
    }

    private func finishStroke(endPoint: CGPoint?, totalPathLengthPt: CGFloat) {
        if let pt = endPoint,
           let convert = convertPointToCoordinate,
           let last = screenPoints.last {
            let step = hypot(pt.x - last.x, pt.y - last.y)
            if step >= 1.5 {
                let coord = convert(pt)
                if coord.latitude.isFinite && coord.longitude.isFinite {
                    screenPoints.append(pt)
                    coordinates.append(coord)
                    screenLengthPt += step
                }
            }
        }
        let effectiveLengthPt = max(screenLengthPt, totalPathLengthPt)
        let finished = coordinates
        clearDraftStroke()
        // Ignore accidental brief taps/brushes (< 26pt) so the user stays cleanly in draw mode
        // without clobbering an existing route.
        guard effectiveLengthPt >= 26.0, finished.count >= 2 else { return }
        onFinishStroke?(finished)
    }

    func clearDraftStroke() {
        screenPoints.removeAll(keepingCapacity: true)
        coordinates.removeAll(keepingCapacity: true)
        screenLengthPt = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        casingLayer.path = nil
        strokeLayer.path = nil
        startHaloLayer.path = nil
        startHaloLayer.isHidden = true
        startDotLayer.path = nil
        startDotLayer.isHidden = true
        CATransaction.commit()
    }

    private func renderDraftStroke(snappedToStart: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if screenPoints.count >= 2 {
            let path = CGMutablePath()
            path.move(to: screenPoints[0])
            if screenPoints.count == 2 {
                path.addLine(to: screenPoints[1])
            } else {
                // Smooth quadratic midpoint interpolation for crisp live finger preview.
                for i in 1..<(screenPoints.count - 1) {
                    let prev = screenPoints[i]
                    let next = screenPoints[i + 1]
                    let mid = CGPoint(x: (prev.x + next.x) * 0.5, y: (prev.y + next.y) * 0.5)
                    path.addQuadCurve(to: mid, control: prev)
                }
                path.addLine(to: screenPoints[screenPoints.count - 1])
            }
            if snappedToStart {
                path.addLine(to: screenPoints[0])
            }
            casingLayer.path = path
            strokeLayer.path = path
            strokeLayer.strokeColor = (snappedToStart ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)).cgColor
        } else {
            casingLayer.path = nil
            strokeLayer.path = nil
        }
        if let first = screenPoints.first {
            let radius: CGFloat = snappedToStart ? 9.5 : 6.5
            let dotRect = CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)
            startDotLayer.path = UIBezierPath(ovalIn: dotRect).cgPath
            startDotLayer.isHidden = false

            if snappedToStart {
                let haloR: CGFloat = 19.0
                let haloRect = CGRect(x: first.x - haloR, y: first.y - haloR, width: haloR * 2, height: haloR * 2)
                startHaloLayer.path = UIBezierPath(ovalIn: haloRect).cgPath
                startHaloLayer.isHidden = false
            } else {
                startHaloLayer.isHidden = true
            }
        } else {
            startDotLayer.isHidden = true
            startHaloLayer.isHidden = true
        }
        CATransaction.commit()
    }
}
