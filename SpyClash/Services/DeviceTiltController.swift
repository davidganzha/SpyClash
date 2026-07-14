import CoreMotion
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class DeviceTiltController {
    private let motionManager = CMMotionManager()
    @ObservationIgnored private var timer: Timer?

    var x: Double = 0
    var y: Double = 0

    func start() {
        guard motionManager.isDeviceMotionAvailable || motionManager.isAccelerometerAvailable else {
            return
        }

        if motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive {
            motionManager.deviceMotionUpdateInterval = 1 / 30
            motionManager.startDeviceMotionUpdates()
        }

        if motionManager.isAccelerometerAvailable, !motionManager.isAccelerometerActive {
            motionManager.accelerometerUpdateInterval = 1 / 30
            motionManager.startAccelerometerUpdates()
        }

        timer?.invalidate()
        let nextTimer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleMotion()
            }
        }
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopAccelerometerUpdates()
        x = 0
        y = 0
    }

    func offset(multiplier: CGFloat) -> CGSize {
        CGSize(width: x * multiplier, height: y * multiplier)
    }

    func rotation(multiplier: Double) -> Angle {
        .degrees(x * multiplier)
    }

    func pitch(multiplier: Double) -> Angle {
        .degrees(y * multiplier)
    }

    func yaw(multiplier: Double) -> Angle {
        .degrees(-x * multiplier)
    }

    private func sampleMotion() {
        let sourceX = motionManager.deviceMotion?.gravity.x ?? motionManager.accelerometerData?.acceleration.x
        let sourceY = motionManager.deviceMotion?.gravity.y ?? motionManager.accelerometerData?.acceleration.y
        guard let sourceX, let sourceY else { return }

        let nextX = Self.clamped(sourceX / 0.34)
        let nextY = Self.clamped(-sourceY / 0.34)

        x = (x * 0.84) + (nextX * 0.16)
        y = (y * 0.84) + (nextY * 0.16)
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }
}
