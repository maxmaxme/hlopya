import Foundation
import CoreAudio

/// Detects when another app starts using the microphone (Zoom, Meet, FaceTime, …)
/// by observing `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device.
///
/// Calls `onCallDetected` when the mic has been in use for `activationDelay` seconds by
/// something other than Hlopya. Applies a `cooldown` after we stop recording to avoid
/// immediately re-arming on our own mic release.
@MainActor
final class CallDetectionService {
    var isEnabled: Bool = false {
        didSet { isEnabled ? start() : stop() }
    }

    /// Fired on the main actor when a call is detected and we should begin recording.
    var onCallDetected: (() -> Void)?

    /// How long the mic must be in use before we trigger (README promises 2 s).
    let activationDelay: TimeInterval = 2.0

    /// How long to ignore mic activity after we stop recording (README promises 5 s).
    let cooldown: TimeInterval = 5.0

    /// Set by AppViewModel whenever Hlopya is recording. While true, detection is suppressed —
    /// we're the one holding the mic.
    var isOwnRecording: Bool = false {
        didSet {
            if isOwnRecording {
                pendingTrigger?.cancel()
                pendingTrigger = nil
            } else if oldValue && !isOwnRecording {
                cooldownUntil = Date().addingTimeInterval(cooldown)
            }
        }
    }

    private var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var inUseListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var pendingTrigger: Task<Void, Never>?
    private var cooldownUntil: Date?

    deinit {
        // Can't call @MainActor stop() from deinit — clean up listeners directly.
        if let listener = inUseListener, inputDeviceID != kAudioObjectUnknown {
            var addr = Self.isRunningSomewhereAddress
            AudioObjectRemovePropertyListenerBlock(inputDeviceID, &addr, nil, listener)
        }
        if let listener = defaultDeviceListener {
            var addr = Self.defaultInputDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, nil, listener)
        }
    }

    private func start() {
        attachDefaultDeviceListener()
        rebindToCurrentInputDevice()
    }

    private func stop() {
        pendingTrigger?.cancel()
        pendingTrigger = nil
        detachInUseListener()
        detachDefaultDeviceListener()
    }

    // MARK: - Device binding

    private func rebindToCurrentInputDevice() {
        detachInUseListener()
        guard let newID = Self.currentDefaultInputDevice(), newID != kAudioObjectUnknown else {
            NSLog("[CallDetection] No default input device")
            return
        }
        inputDeviceID = newID

        var addr = Self.isRunningSomewhereAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleInUseChange() }
        }
        let err = AudioObjectAddPropertyListenerBlock(newID, &addr, nil, listener)
        if err == noErr {
            inUseListener = listener
            NSLog("[CallDetection] Bound to input device #%d", newID)
            // Prime state: if mic is already hot right now, start the trigger countdown.
            handleInUseChange()
        } else {
            NSLog("[CallDetection] Failed to add listener (error %d)", err)
        }
    }

    private func detachInUseListener() {
        guard let listener = inUseListener, inputDeviceID != kAudioObjectUnknown else { return }
        var addr = Self.isRunningSomewhereAddress
        AudioObjectRemovePropertyListenerBlock(inputDeviceID, &addr, nil, listener)
        inUseListener = nil
        inputDeviceID = kAudioObjectUnknown
    }

    private func attachDefaultDeviceListener() {
        guard defaultDeviceListener == nil else { return }
        var addr = Self.defaultInputDeviceAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.rebindToCurrentInputDevice() }
        }
        let err = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, nil, listener)
        if err == noErr {
            defaultDeviceListener = listener
        } else {
            NSLog("[CallDetection] Failed to watch default input device (error %d)", err)
        }
    }

    private func detachDefaultDeviceListener() {
        guard let listener = defaultDeviceListener else { return }
        var addr = Self.defaultInputDeviceAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, nil, listener)
        defaultDeviceListener = nil
    }

    // MARK: - State machine

    private func handleInUseChange() {
        guard isEnabled else { return }
        let inUse = Self.readIsRunningSomewhere(inputDeviceID)

        if !inUse {
            pendingTrigger?.cancel()
            pendingTrigger = nil
            return
        }

        // Mic is hot. Suppress if we're the one using it, or we're in cooldown.
        if isOwnRecording { return }
        if let until = cooldownUntil, Date() < until { return }
        if pendingTrigger != nil { return }

        let delay = activationDelay
        pendingTrigger = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            // Re-check conditions after the delay.
            guard self.isEnabled, !self.isOwnRecording else {
                self.pendingTrigger = nil
                return
            }
            if let until = self.cooldownUntil, Date() < until {
                self.pendingTrigger = nil
                return
            }
            guard Self.readIsRunningSomewhere(self.inputDeviceID) else {
                self.pendingTrigger = nil
                return
            }
            NSLog("[CallDetection] Mic hot for %.0fs — triggering auto-record", delay)
            self.pendingTrigger = nil
            self.onCallDetected?()
        }
    }

    // MARK: - Core Audio helpers

    nonisolated(unsafe) private static var isRunningSomewhereAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    nonisolated(unsafe) private static var defaultInputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func currentDefaultInputDevice() -> AudioDeviceID? {
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = defaultInputDeviceAddress
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr ? id : nil
    }

    private static func readIsRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = isRunningSomewhereAddress
        let err = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        return err == noErr && value != 0
    }
}
