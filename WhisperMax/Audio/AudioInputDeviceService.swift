import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let audioObjectID: AudioObjectID
    let name: String

    var id: AudioObjectID { audioObjectID }
}

struct AudioInputDeviceSnapshot {
    let devices: [AudioInputDevice]
    let defaultDeviceID: AudioObjectID
}

enum AudioInputDeviceServiceError: LocalizedError {
    case unavailable
    case unableToReadDevices
    case unableToReadDefaultInput
    case unableToReadDeviceName
    case unableToSwitchDefaultInput

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "No input devices are available."
        case .unableToReadDevices:
            return "Could not read the available input devices."
        case .unableToReadDefaultInput:
            return "Could not read the default input device."
        case .unableToReadDeviceName:
            return "Could not read the selected input device name."
        case .unableToSwitchDefaultInput:
            return "Could not switch the default input device."
        }
    }
}

final class AudioInputDeviceService {
    private let listenerQueue = DispatchQueue(label: "com.whispermax.audio-input-listener")
    private var propertyListener: AudioObjectPropertyListenerBlock?

    deinit {
        stopObserving()
    }

    func snapshot() throws -> AudioInputDeviceSnapshot {
        let defaultDeviceID = try defaultInputDeviceID()
        var devices = try allDeviceIDs().compactMap { deviceID -> AudioInputDevice? in
            guard hasInputChannels(deviceID: deviceID) else {
                return nil
            }

            guard let name = try? deviceName(for: deviceID) else {
                return nil
            }

            return AudioInputDevice(audioObjectID: deviceID, name: name)
        }

        guard !devices.isEmpty else {
            throw AudioInputDeviceServiceError.unavailable
        }

        devices.sort { lhs, rhs in
            if lhs.audioObjectID == defaultDeviceID {
                return true
            }

            if rhs.audioObjectID == defaultDeviceID {
                return false
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return AudioInputDeviceSnapshot(devices: devices, defaultDeviceID: defaultDeviceID)
    }

    func startObserving(onChange: @escaping @Sendable () -> Void) {
        guard propertyListener == nil else {
            return
        }

        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }

        let defaultInputAddress = makePropertyAddress(selector: kAudioHardwarePropertyDefaultInputDevice)
        let devicesAddress = makePropertyAddress(selector: kAudioHardwarePropertyDevices)

        let defaultStatus = withUnsafePointer(to: defaultInputAddress) { addressPointer in
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                addressPointer,
                listenerQueue,
                listener
            )
        }

        guard defaultStatus == noErr else {
            return
        }

        let devicesStatus = withUnsafePointer(to: devicesAddress) { addressPointer in
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                addressPointer,
                listenerQueue,
                listener
            )
        }

        guard devicesStatus == noErr else {
            _ = withUnsafePointer(to: defaultInputAddress) { addressPointer in
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    addressPointer,
                    listenerQueue,
                    listener
                )
            }
            return
        }

        propertyListener = listener
    }

    func stopObserving() {
        guard let propertyListener else {
            return
        }

        let defaultInputAddress = makePropertyAddress(selector: kAudioHardwarePropertyDefaultInputDevice)
        let devicesAddress = makePropertyAddress(selector: kAudioHardwarePropertyDevices)

        _ = withUnsafePointer(to: defaultInputAddress) { addressPointer in
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                addressPointer,
                listenerQueue,
                propertyListener
            )
        }

        _ = withUnsafePointer(to: devicesAddress) { addressPointer in
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                addressPointer,
                listenerQueue,
                propertyListener
            )
        }

        self.propertyListener = nil
    }

    func setDefaultInputDevice(_ deviceID: AudioObjectID) throws {
        var mutableDeviceID = deviceID
        var propertyAddress = makePropertyAddress(selector: kAudioHardwarePropertyDefaultInputDevice)

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableDeviceID
        )

        guard status == noErr else {
            throw AudioInputDeviceServiceError.unableToSwitchDefaultInput
        }
    }

    private func makePropertyAddress(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func allDeviceIDs() throws -> [AudioObjectID] {
        var propertyAddress = makePropertyAddress(selector: kAudioHardwarePropertyDevices)

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard sizeStatus == noErr else {
            throw AudioInputDeviceServiceError.unableToReadDevices
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = Array(repeating: AudioObjectID(), count: count)

        let readStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard readStatus == noErr else {
            throw AudioInputDeviceServiceError.unableToReadDevices
        }

        return deviceIDs
    }

    private func defaultInputDeviceID() throws -> AudioObjectID {
        var propertyAddress = makePropertyAddress(selector: kAudioHardwarePropertyDefaultInputDevice)

        var deviceID = AudioObjectID()
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioInputDeviceServiceError.unableToReadDefaultInput
        }

        return deviceID
    }

    private func deviceName(for deviceID: AudioObjectID) throws -> String {
        var propertyAddress = makePropertyAddress(selector: kAudioObjectPropertyName)

        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &dataSize,
                pointer
            )
        }

        guard status == noErr, let name else {
            throw AudioInputDeviceServiceError.unableToReadDeviceName
        }

        return name as String
    }

    private func hasInputChannels(deviceID: AudioObjectID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard sizeStatus == noErr, dataSize > 0 else {
            return false
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )

        defer {
            bufferListPointer.deallocate()
        }

        let readStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            bufferListPointer
        )

        guard readStatus == noErr else {
            return false
        }

        let audioBufferList = bufferListPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }
}
