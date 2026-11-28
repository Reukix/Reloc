import CoreLocation
import Foundation

// MARK: - Joystick Progress & Thread-Safe Kinematic Driver

public struct JoystickProgress: Equatable, Sendable {
    public var currentLocation: TargetLocation
    public var traveledMeters: Double
    public var currentSpeedMps: Double
    public var headingDegrees: Double
    public var isMoving: Bool
    public var isCruiseLocked: Bool
    public var isWaitingForStartLock: Bool

    public init(
        currentLocation: TargetLocation,
        traveledMeters: Double = 0,
        currentSpeedMps: Double = 0,
        headingDegrees: Double = 0,
        isMoving: Bool = false,
        isCruiseLocked: Bool = false,
        isWaitingForStartLock: Bool = true
    ) {
        self.currentLocation = currentLocation
        self.traveledMeters = traveledMeters
        self.currentSpeedMps = currentSpeedMps
        self.headingDegrees = headingDegrees
        self.isMoving = isMoving
        self.isCruiseLocked = isCruiseLocked
        self.isWaitingForStartLock = isWaitingForStartLock
    }
}

/// Thread-safe manual 360° joystick kinematic driver evaluated directly on `AccessoryLocationSession`'s
/// background NMEA tick loop using monotonic time. Supports live thumb deflection as well as
/// background-safe heading cruise lock with zero main-thread timers.
public final class JoystickDriver: @unchecked Sendable {
    private let lock = NSLock()

    private var currentLat: Double
    private var currentLon: Double
    private var currentAlt: Double
    private var maxSpeedMps: Double
    private var realisticMotionEnabled: Bool

    private var stickMagnitude: Double = 0.0
    private var headingDegrees: Double = 0.0
    private var cruiseLocked: Bool = false
    private var isWaitingForStartLock: Bool

    private var currentSpeedMps: Double = 0.0
    private var traveledMeters: Double = 0.0
    private var lastAdvanceTime: TimeInterval?
    private var elapsedMovingTime: TimeInterval = 0.0
    private var altitudeNoiseMeters: Double = 0.0
    private var lastEmittedLocation: TargetLocation

    public init(
        initialLocation: TargetLocation,
        maxSpeedMps: Double,
        realisticMotionEnabled: Bool = true,
        waitForStartLock: Bool = true
    ) {
        self.currentLat = initialLocation.latitude
        self.currentLon = initialLocation.longitude
        self.currentAlt = initialLocation.altitude
        self.maxSpeedMps = max(0.3, min(50.0, maxSpeedMps))
        self.realisticMotionEnabled = realisticMotionEnabled
        self.isWaitingForStartLock = waitForStartLock
        self.lastEmittedLocation = TargetLocation(
            latitude: initialLocation.latitude,
            longitude: initialLocation.longitude,
            altitude: initialLocation.altitude,
            speedKnots: 0.0,
            courseDegrees: 0.0
        )
    }

    public func currentTargetLocation() -> TargetLocation {
        lock.lock()
        defer { lock.unlock() }
        return lastEmittedLocation
    }

    public func initialProgress() -> JoystickProgress {
        lock.lock()
        defer { lock.unlock() }
        return makeProgressLocked(location: lastEmittedLocation)
    }

    public func isWaitingForLock() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isWaitingForStartLock
    }

    public func isActivelyMoving() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isWaitingForStartLock && (cruiseLocked || stickMagnitude > 0.04 || currentSpeedMps > 0.05)
    }

    @discardableResult
    public func releaseStartLock(atMonotonicTime now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isWaitingForStartLock {
            isWaitingForStartLock = false
            lastAdvanceTime = now
            return true
        }
        return false
    }

    @discardableResult
    public func holdForRelock() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = !isWaitingForStartLock
        isWaitingForStartLock = true
        currentSpeedMps = 0.0
        return changed
    }

    /// Updates thumb deflection (`0...1`) and true compass heading (`0..<360`, 0 = North, 90 = East).
    /// Returns `true` when transitioning from stationary to active motion so the session can nudge immediately.
    @discardableResult
    public func setInput(magnitude: Double, headingDegrees: Double?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasIdle = !cruiseLocked && stickMagnitude <= 0.04
        let clampedMag = min(1.0, max(0.0, magnitude))
        stickMagnitude = clampedMag
        if let h = headingDegrees, h.isFinite {
            self.headingDegrees = ((h.truncatingRemainder(dividingBy: 360.0)) + 360.0).truncatingRemainder(dividingBy: 360.0)
        }
        let isNowActive = cruiseLocked || clampedMag > 0.04
        return wasIdle && isNowActive
    }

    public func setMaxSpeed(_ mps: Double) {
        lock.lock()
        maxSpeedMps = max(0.3, min(50.0, mps))
        lock.unlock()
    }

    public func setCruiseLocked(_ locked: Bool) {
        lock.lock()
        cruiseLocked = locked
        lock.unlock()
    }

    public func setRealisticMotionEnabled(_ enabled: Bool) {
        lock.lock()
        realisticMotionEnabled = enabled
        if !enabled {
            altitudeNoiseMeters = 0.0
        }
        lock.unlock()
    }

    /// Updates the current terrain elevation asynchronously without altering lat/lon.
    public func updateAltitude(_ altitude: Double) {
        guard altitude.isFinite else { return }
        lock.lock()
        currentAlt = min(50_000.0, max(-500.0, altitude))
        lock.unlock()
    }

    public func advance(toMonotonicTime now: TimeInterval, stationaryJitter: Bool) -> (location: TargetLocation, progress: JoystickProgress) {
        lock.lock()
        defer { lock.unlock() }

        let dt: TimeInterval
        if let prev = lastAdvanceTime {
            dt = min(3.0, max(0.0, now - prev))
        } else {
            dt = 0.0
        }
        lastAdvanceTime = now

        if isWaitingForStartLock {
            currentSpeedMps = 0.0
            var loc = TargetLocation(
                latitude: currentLat,
                longitude: currentLon,
                altitude: currentAlt,
                speedKnots: 0.0,
                courseDegrees: 0.0
            )
            if stationaryJitter {
                loc = CoordinateTransform.applyMicroJitter(to: loc)
            }
            lastEmittedLocation = loc
            return (loc, makeProgressLocked(location: loc))
        }

        let effectiveMagnitude = cruiseLocked ? max(stickMagnitude, 1.0) : (stickMagnitude > 0.04 ? stickMagnitude : 0.0)
        var desiredSpeed = maxSpeedMps * effectiveMagnitude
        if desiredSpeed > 0.05 && realisticMotionEnabled {
            let wave = sin(elapsedMovingTime * 0.27) * 0.045
            desiredSpeed = max(0.25, desiredSpeed * (1.0 + wave))
        }

        if dt > 0 {
            let accel = max(1.8, maxSpeedMps * 0.85)
            let decel = max(3.0, maxSpeedMps * 1.4)
            if desiredSpeed > currentSpeedMps {
                currentSpeedMps = min(desiredSpeed, currentSpeedMps + accel * dt)
            } else {
                currentSpeedMps = max(desiredSpeed, currentSpeedMps - decel * dt)
            }
        } else {
            currentSpeedMps = desiredSpeed
        }

        if currentSpeedMps < 0.04 && effectiveMagnitude <= 0.04 {
            currentSpeedMps = 0.0
        }

        let stepMeters = currentSpeedMps * dt
        var emittedHeading = headingDegrees
        if stepMeters > 0.001 {
            elapsedMovingTime += dt
            var stepHeading = headingDegrees
            if realisticMotionEnabled {
                stepHeading = (stepHeading + Double.random(in: -1.8...1.8) + 360.0).truncatingRemainder(dividingBy: 360.0)
            }
            emittedHeading = stepHeading
            let moved = RouteGeometry.offset(
                latitude: currentLat,
                longitude: currentLon,
                meters: stepMeters,
                bearingDegrees: stepHeading
            )
            currentLat = moved.latitude
            currentLon = moved.longitude
            traveledMeters += stepMeters

            if realisticMotionEnabled {
                let altStep = Double.random(in: -0.08...0.08)
                altitudeNoiseMeters = max(-0.4, min(0.4, altitudeNoiseMeters * 0.85 + altStep))
            }
        }

        let isMoving = currentSpeedMps >= 0.05
        var loc = TargetLocation(
            latitude: currentLat,
            longitude: currentLon,
            altitude: min(50_000.0, max(-500.0, currentAlt + (isMoving && realisticMotionEnabled ? altitudeNoiseMeters : 0.0))),
            speedKnots: isMoving ? (currentSpeedMps * RouteGeometry.mpsToKnots) : 0.0,
            courseDegrees: isMoving ? emittedHeading : 0.0
        )
        if !isMoving && stationaryJitter {
            loc = CoordinateTransform.applyMicroJitter(to: loc)
        }
        lastEmittedLocation = loc
        return (loc, makeProgressLocked(location: loc))
    }

    private func makeProgressLocked(location: TargetLocation) -> JoystickProgress {
        JoystickProgress(
            currentLocation: location,
            traveledMeters: traveledMeters,
            currentSpeedMps: currentSpeedMps,
            headingDegrees: headingDegrees,
            isMoving: currentSpeedMps >= 0.05,
            isCruiseLocked: cruiseLocked,
            isWaitingForStartLock: isWaitingForStartLock
        )
    }
}
