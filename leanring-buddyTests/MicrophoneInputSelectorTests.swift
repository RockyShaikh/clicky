//
//  MicrophoneInputSelectorTests.swift
//  leanring-buddyTests
//

import CoreAudio
import Testing
@testable import leanring_buddy

struct MicrophoneInputSelectorTests {
    private let builtIn: AudioDeviceID = 10
    private let bluetoothDefault: AudioDeviceID = 20

    private func choose(_ source: ClickyMicrophoneSource, transport: UInt32?, builtIn builtInID: AudioDeviceID?) -> AudioDeviceID? {
        ClickyMicrophoneInputSelector.chooseDeviceID(
            source: source, defaultInputDeviceID: bluetoothDefault,
            defaultInputTransportType: transport, builtInInputDeviceID: builtInID)
    }

    @Test func automaticPicksBuiltInWhenDefaultIsBluetooth() {
        #expect(choose(.automatic, transport: kAudioDeviceTransportTypeBluetooth, builtIn: builtIn) == builtIn)
        #expect(choose(.automatic, transport: kAudioDeviceTransportTypeBluetoothLE, builtIn: builtIn) == builtIn)
    }

    @Test func automaticKeepsDefaultWhenNotBluetooth() {
        #expect(choose(.automatic, transport: kAudioDeviceTransportTypeUSB, builtIn: builtIn) == nil)
        #expect(choose(.automatic, transport: kAudioDeviceTransportTypeBuiltIn, builtIn: builtIn) == nil)
    }

    @Test func noBuiltInMicFallsBackToDefault() {
        #expect(choose(.automatic, transport: kAudioDeviceTransportTypeBluetooth, builtIn: nil) == nil)
        #expect(choose(.builtIn, transport: kAudioDeviceTransportTypeBluetooth, builtIn: nil) == nil)
    }

    @Test func explicitSourcesAreHonored() {
        #expect(choose(.builtIn, transport: kAudioDeviceTransportTypeUSB, builtIn: builtIn) == builtIn)
        #expect(choose(.systemDefault, transport: kAudioDeviceTransportTypeBluetooth, builtIn: builtIn) == nil)
    }
}
