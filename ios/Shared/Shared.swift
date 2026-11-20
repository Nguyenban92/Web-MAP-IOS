import Foundation

struct Crop: Codable, Equatable {
    var x: Double = 0.055
    var y: Double = 0.002
    var width: Double = 0.144
    var height: Double = 0.311
    var referenceAspect: Double = 2.165
    // Some landscape games expose ReplayKit frames in the opposite physical
    // device orientation from the screenshot used by the crop editor.
    // Optional keeps configurations made by older app versions compatible.
    var rotate180: Bool? = true
    var version: Int? = 3
    var valid: Bool {
        [x, y, width, height, referenceAspect].allSatisfy { $0.isFinite } &&
        x >= 0 && y >= 0 && width >= 0.02 && height >= 0.02 &&
        x + width <= 1.001 && y + height <= 1.001 && referenceAspect > 0
    }
}
struct Room: Codable {
    let id: String
    let publishToken: String
    let viewerURL: String
}
struct BroadcastConfig: Codable {
    var server: String
    var room: Room
    var crop: Crop
    var fps: Double
    var quality: Double
    var enabled: Bool
}
enum SharedStore {
    static let appGroupID = "group.vn.nguyenban.nbwebmap"
    static var directory: URL? {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    static func save(_ config: BroadcastConfig) throws {
        guard let dir = directory else { return }
        try JSONEncoder().encode(config).write(to: dir.appendingPathComponent("config.json"), options: [.atomic, .completeFileProtection])
    }
    static func read() -> BroadcastConfig? {
        guard let dir = directory, let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")) else { return nil }
        return try? JSONDecoder().decode(BroadcastConfig.self, from: data)
    }
    static func status(_ value: String) {}
    static func readStatus() -> String { "" }
}
