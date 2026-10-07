import Foundation

struct Crop: Codable, Equatable {
    var x: Double = 0.01
    var y: Double = 0.02
    var width: Double = 0.23
    var height: Double = 0.40
    var referenceAspect: Double = 2.16
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
// App-private storage only. Broadcast receives configuration through one-time HTTPS pairing.
enum SharedStore {
    static var directory: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }
    static func save(_ config: BroadcastConfig) throws {
        try JSONEncoder().encode(config).write(to: directory!.appendingPathComponent("config.json"), options: [.atomic, .completeFileProtection])
    }
    static func read() -> BroadcastConfig? {
        guard let data = try? Data(contentsOf: directory!.appendingPathComponent("config.json")) else { return nil }
        return try? JSONDecoder().decode(BroadcastConfig.self, from: data)
    }
    static func status(_ value: String) {}
    static func readStatus() -> String { "" }
}
