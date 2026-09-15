import SwiftUI

/// One visual contract for full and compact focus timers while the shared
/// expiry alarm is active.
enum ExpiryAlarmShakeEffect {
    static let amplitude: CGFloat = 4

    static func targetOffset(isActive: Bool) -> CGFloat {
        isActive ? amplitude : 0
    }
}

private struct ExpiryAlarmShakeModifier: ViewModifier {
    let isActive: Bool
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onAppear { update(animated: isActive) }
            .onChange(of: isActive) { _, _ in update(animated: true) }
    }

    private func update(animated: Bool) {
        let target = ExpiryAlarmShakeEffect.targetOffset(isActive: isActive)
        guard animated else {
            offset = target
            return
        }
        if isActive {
            withAnimation(.easeInOut(duration: 0.09).repeatForever(autoreverses: true)) {
                offset = target
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { offset = target }
        }
    }
}

extension View {
    func expiryAlarmShake(isActive: Bool) -> some View {
        modifier(ExpiryAlarmShakeModifier(isActive: isActive))
    }
}
