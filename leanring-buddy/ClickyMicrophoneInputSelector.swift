//
//  ClickyMicrophoneInputSelector.swift
//  leanring-buddy
//
//  Chooses which microphone Clicky's AVAudioEngines capture from. When the default input is a
//  Bluetooth headset, opening it makes macOS flip the headset from A2DP to the low-quality HFP
//  profile (bad audio, flickering mic indicator). Capturing from the built-in mic instead leaves
//  the headset in A2DP. The system default device is never changed.
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum ClickyMicrophoneSource: String, CaseIterable {
    /// Built-in mic if the default input is Bluetooth, else the default input.
    case automatic
    case builtIn
    case systemDefault

    static let userDefaultsKey = "clicky.audio.microphoneSource"

    static var current: ClickyMicrophoneSource {
        let storedValue = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        return ClickyMicrophoneSource(rawValue: storedValue) ?? .automatic
    }
}

enum ClickyMicrophoneInputSelector {

    /// Pure choice logic (unit tested). Returns nil to mean "leave the engine on the system default".
    static func chooseDeviceID(
        source: ClickyMicrophoneSource,
        defaultInputDeviceID: AudioDeviceID?,
        defaultInputTransportType: UInt32?,
        builtInInputDeviceID: AudioDeviceID?
    ) -> AudioDeviceID? {
        switch source {
        case .systemDefault:
            return nil
        case .builtIn:
            return builtInInputDeviceID
        case .automatic:
            guard let defaultInputTransportType, isBluetooth(transportType: defaultInputTransportType) else { return nil }
            return builtInInputDeviceID
        }
    }

    static func isBluetooth(transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// True when the device Clicky will actually capture from is Bluetooth (so opening it
    /// switches the headset to HFP and the speaker can leak into the mic).
    static func isCaptureDeviceBluetooth() -> Bool {
        let captureDeviceID = chosenDeviceIDForCurrentSetting() ?? defaultInputDeviceID()
        guard let captureDeviceID, let transportType = transportType(of: captureDeviceID) else { return false }
        return isBluetooth(transportType: transportType)
    }

    static func chosenDeviceIDForCurrentSetting() -> AudioDeviceID? {
        let defaultDeviceID = defaultInputDeviceID()
        return chooseDeviceID(
            source: ClickyMicrophoneSource.current,
            defaultInputDeviceID: defaultDeviceID,
            defaultInputTransportType: defaultDeviceID.flatMap { transportType(of: $0) },
            builtInInputDeviceID: builtInInputDeviceID()
        )
    }

    /// Points the engine's input node at the chosen device. Call before reading the input format,
    /// installing the tap and starting the engine. No-op when the default should be used.
    static func applyPreferredInputDevice(to audioEngine: AVAudioEngine) {
        guard var deviceID = chosenDeviceIDForCurrentSetting(), let inputAudioUnit = audioEngine.inputNode.audioUnit else { return }
        let status = AudioUnitSetProperty(
            inputAudioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            print("🎙️ Clicky mic: capturing from device \(deviceID) (source: \(ClickyMicrophoneSource.current.rawValue))")
        } else {
            print("⚠️ Clicky mic: could not select device \(deviceID), status \(status); using default")
        }
    }

    // MARK: - CoreAudio queries

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType) == noErr else { return nil }
        return transportType
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    /// The first built-in device that can capture audio, or nil on Macs with no built-in mic.
    private static func builtInInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else { return nil }
        return deviceIDs.first { transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn && hasInputChannels($0) }
    }
}
