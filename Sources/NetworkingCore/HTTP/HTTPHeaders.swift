import Foundation

/// Sendable-обёртка над словарём заголовков. Hashable для удобного сравнения в тестах.
public struct HTTPHeaders: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    public private(set) var storage: [String: String]

    public init(_ storage: [String: String] = [:]) { self.storage = storage }
    public init(dictionaryLiteral elements: (String, String)...) {
        self.storage = Dictionary(uniqueKeysWithValues: elements)
    }

    public subscript(name: String) -> String? {
        get { storage[name] }
        set { storage[name] = newValue }
    }

    /// Перезаписывает значение.
    public mutating func set(_ name: String, _ value: String) {
        storage[name] = value
    }

    /// Дополняет существующее значение через запятую (для Cookie/Set-Cookie семантики).
    public mutating func append(_ name: String, _ value: String) {
        if let existing = storage[name] {
            storage[name] = existing + ", " + value
        } else {
            storage[name] = value
        }
    }

    /// Удаляет заголовок.
    public mutating func remove(_ name: String) { storage.removeValue(forKey: name) }

    /// Сливает поверх — `other` побеждает при коллизии.
    public func merging(_ other: HTTPHeaders) -> HTTPHeaders {
        HTTPHeaders(storage.merging(other.storage) { _, new in new })
    }

    public var isEmpty: Bool { storage.isEmpty }
    public var dictionary: [String: String] { storage }
}
