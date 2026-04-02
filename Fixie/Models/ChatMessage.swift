// Models/ChatMessage.swift
import Foundation

// MARK: – Chat message

struct ChatMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String
    let imageData: Data?       // user messages may attach a re-scan photo
    let timestamp: Date
    var isDone: Bool           // for AssistantCard step cards — user taps "Done"
    var isStepPrompt: Bool     // true → shows Done/Completed row; false for context/info messages

    init(role: Role, text: String, imageData: Data? = nil, isStepPrompt: Bool = true) {
        self.role         = role
        self.text         = text
        self.imageData    = imageData
        self.timestamp    = Date()
        self.isDone       = false
        self.isStepPrompt = isStepPrompt
    }

    static func user(_ text: String, imageData: Data? = nil) -> ChatMessage {
        ChatMessage(role: .user, text: text, imageData: imageData)
    }

    /// Standard AI step message — shows Done button so user can advance the step.
    static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, isStepPrompt: true)
    }

    /// Context/info message — no Done button (intro plan, tools list, welcome back, etc.)
    static func contextMessage(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, isStepPrompt: false)
    }
}
