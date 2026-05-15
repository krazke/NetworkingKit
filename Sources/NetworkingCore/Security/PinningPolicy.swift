import Foundation

/// Политика SSL pinning. Транспорт сам выполняет валидацию по этим данным.
public enum PinningPolicy: Sendable {
    /// Без pinning — стандартная системная цепочка.
    case none
    /// Public-key pinning. Передаётся набор DER-сертификатов; ключи из них извлекаются.
    case publicKeys([Data])
    /// Certificate pinning — побайтовое сравнение DER-сертификатов.
    case certificates([Data])
}
