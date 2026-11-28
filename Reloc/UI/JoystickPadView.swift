import SwiftUI

/// Ergonomic 360° glassmorphic thumb joystick overlay for real-time free-roam GPS movement.
struct JoystickPadView: View {
    let headingDegrees: Double
    let isMoving: Bool
    let isCruiseLocked: Bool
    let isWaitingForLock: Bool
    let onVectorChange: (_ magnitude: Double, _ headingDegrees: Double?) -> Void
    let onToggleCruise: () -> Void

    @State private var knobOffset: CGSize = .zero
    @State private var isDragging = false

    private let outerDiameter: CGFloat = 134
    private let knobDiameter: CGFloat = 48
    private var maxRadius: CGFloat { (outerDiameter - knobDiameter) * 0.5 }

    var body: some View {
        ZStack {
            // Base translucent pad
            Circle()
                .fill(.regularMaterial)
                .frame(width: outerDiameter, height: outerDiameter)
                .overlay(
                    Circle()
                        .strokeBorder(
                            isCruiseLocked
                                ? RelocTheme.emerald.opacity(0.8)
                                : (isDragging ? RelocTheme.accent.opacity(0.65) : Color.white.opacity(0.28)),
                            lineWidth: isCruiseLocked || isDragging ? 2.0 : 0.9
                        )
                )
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)

            // Inner concentric guide ring
            Circle()
                .strokeBorder(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: outerDiameter * 0.56, height: outerDiameter * 0.56)

            // Outer directional caret along active heading (clears cardinal labels completely)
            if isDragging || isCruiseLocked || isMoving {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isCruiseLocked ? RelocTheme.emerald : RelocTheme.accent)
                    .offset(y: -(outerDiameter * 0.5 - 8))
                    .rotationEffect(.degrees(headingDegrees))
            }

            // Cardinal labels tucked cleanly inside the rim
            Text("N")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.secondary.opacity(0.8))
                .offset(y: -(outerDiameter * 0.36))
            Text("S")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.secondary.opacity(0.65))
                .offset(y: outerDiameter * 0.36)
            Text("W")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.secondary.opacity(0.65))
                .offset(x: -(outerDiameter * 0.36))
            Text("E")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.secondary.opacity(0.65))
                .offset(x: outerDiameter * 0.36)

            // Thumb knob
            Circle()
                .fill(
                    LinearGradient(
                        colors: isCruiseLocked
                            ? [RelocTheme.emerald, Color(red: 0.08, green: 0.62, blue: 0.42)]
                            : [RelocTheme.accent, Color(red: 0.04, green: 0.38, blue: 0.86)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: knobDiameter, height: knobDiameter)
                .overlay(
                    Image(systemName: isCruiseLocked ? "location.north.fill" : "safari.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(isCruiseLocked ? headingDegrees : 0))
                )
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1.2)
                )
                .shadow(color: (isCruiseLocked ? RelocTheme.emerald : RelocTheme.accent).opacity(0.35), radius: 8, y: 3)
                .offset(knobOffset)
                .opacity(isWaitingForLock ? 0.55 : 1.0)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        RelocTheme.hapticLight()
                    }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let dist = hypot(dx, dy)
                    let clampedDist = min(maxRadius, dist)
                    let angleRad = atan2(dx, -dy) // 0 = North (-y), +90° = East (+x)
                    let clampedX = sin(angleRad) * clampedDist
                    let clampedY = -cos(angleRad) * clampedDist
                    knobOffset = CGSize(width: clampedX, height: clampedY)

                    let magnitude = Double(clampedDist / max(1, maxRadius))
                    let headingDeg = ((angleRad * 180.0 / .pi) + 360.0).truncatingRemainder(dividingBy: 360.0)
                    onVectorChange(magnitude, magnitude > 0.04 ? headingDeg : nil)
                }
                .onEnded { _ in
                    isDragging = false
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                        knobOffset = .zero
                    }
                    onVectorChange(0.0, nil)
                }
        )
    }
}
