import AppKit
import DuckpadNativeABI

@_cdecl("duckpad_native_abi_version") public func nativeVersion() -> UInt32 { 1 }
@_cdecl("duckpad_native_create") public func nativeCreate(_ api: UnsafePointer<DuckpadHostV1>?, _ config: UnsafePointer<UInt8>?, _ length: Int) -> UnsafeMutableRawPointer? {
    guard let api, let config, length > 0, length < 65536,
          let values = try? JSONSerialization.jsonObject(with: Data(bytes: config, count: length)) as? [String: String],
          values["resourceDirectory"] != nil, values["storageDirectory"] != nil else { return nil }
    let address = UInt(bitPattern: api)
    let result: UInt = MainActor.assumeIsolated {
        guard let host = DuckpadHost(UnsafePointer<DuckpadHostV1>(bitPattern: address)!) else { return 0 }
        return UInt(bitPattern: Unmanaged.passRetained(ClipboardPlugin(host: host, config: values)).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: result)
}
@_cdecl("duckpad_native_view") public func nativeView(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let pointer else { return nil }; let address = UInt(bitPattern: pointer)
    let view: UInt = MainActor.assumeIsolated {
        let plugin = Unmanaged<ClipboardPlugin>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
        return UInt(bitPattern: Unmanaged.passUnretained(plugin.show()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: view)
}
@_cdecl("duckpad_native_set_language") public func nativeLanguage(_ pointer: UnsafeMutableRawPointer?, _ language: UnsafePointer<CChar>?) {
    guard let pointer, let language else { return }; let address = UInt(bitPattern: pointer); let code = String(cString: language)
    MainActor.assumeIsolated { Unmanaged<ClipboardPlugin>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue().setLanguage(code) }
}
@_cdecl("duckpad_native_deactivate") public func nativeDeactivate(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }; let address = UInt(bitPattern: pointer)
    MainActor.assumeIsolated { Unmanaged<ClipboardPlugin>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue().stop() }
}
@_cdecl("duckpad_native_destroy") public func nativeDestroy(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }; let address = UInt(bitPattern: pointer)
    MainActor.assumeIsolated {
        let plugin = Unmanaged<ClipboardPlugin>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeRetainedValue()
        plugin.stop()
    }
}
