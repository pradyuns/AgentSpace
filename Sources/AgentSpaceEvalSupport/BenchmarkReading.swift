import Foundation

public enum BenchmarkReading {
    public static func typedValue(_ reading: String) -> String? {
        if let data = reading.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            var candidates = Set<String>()
            func collect(_ value: Any) {
                if let string = value as? String, let typed = rawTypedValue(string) { candidates.insert(typed) }
                else if let array = value as? [Any] { array.forEach(collect) }
                else if let fields = value as? [String: Any] { fields.values.forEach(collect) }
            }
            collect(object)
            return candidates.count == 1 ? candidates.first : nil
        }
        return rawTypedValue(reading)
    }

    private static func rawTypedValue(_ reading: String) -> String? {
        guard let start = reading.range(of: "typed="),
              let end = reading[start.upperBound...].firstIndex(of: ";") else { return nil }
        return String(reading[start.upperBound..<end])
    }
}
