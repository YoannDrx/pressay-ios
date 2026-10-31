import Foundation

/// One finished dictation, handed from the app to the keyboard.
public struct DictationResult: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let engine: String
    public let createdAt: Date
    public let audioSeconds: Double
    public let transcriptionSeconds: Double

    public init(
        id: UUID = UUID(),
        text: String,
        engine: String,
        createdAt: Date = Date(),
        audioSeconds: Double,
        transcriptionSeconds: Double
    ) {
        self.id = id
        self.text = text
        self.engine = engine
        self.createdAt = createdAt
        self.audioSeconds = audioSeconds
        self.transcriptionSeconds = transcriptionSeconds
    }
}
