import SwiftUI

@main
struct DynoLoggerApp: App {
    @StateObject private var ble: BLEManager
    @StateObject private var phoneGPS: PhoneGPS
    @StateObject private var sessions: SessionStore
    @StateObject private var recorder: Recorder

    init() {
        let ble = BLEManager()
        let phoneGPS = PhoneGPS()
        let sessions = SessionStore()
        _ble = StateObject(wrappedValue: ble)
        _phoneGPS = StateObject(wrappedValue: phoneGPS)
        _sessions = StateObject(wrappedValue: sessions)
        _recorder = StateObject(wrappedValue: Recorder(ble: ble, phoneGPS: phoneGPS, sessions: sessions))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .environmentObject(ble.obd)
                .environmentObject(ble.gps)
                .environmentObject(ble.goPro)
                .environmentObject(phoneGPS)
                .environmentObject(sessions)
                .environmentObject(recorder)
        }
    }
}
