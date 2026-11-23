public enum CursorRest {
    public enum Phase: Equatable { case wait, check, undelivered }

    public static func phase(requested: Double, delivered: Double?, now: Double) -> Phase {
        if let delivered, delivered >= requested, delivered <= requested+2 {
            return now >= delivered+0.15 ? .check : .wait
        }
        return now >= requested+2 ? .undelivered : .wait
    }
}
