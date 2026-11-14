import Foundation

public enum Embeddings {
    /// Cosine similarity in [-1, 1]. Returns nil for empty, mismatched or zero vectors.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return nil }
        let c = dot / (na.squareRoot() * nb.squareRoot())
        return min(1, max(-1, c))
    }

    /// Scales a vector to unit length. Returns nil for an empty or zero vector.
    public static func normalized(_ v: [Float]) -> [Float]? {
        let n = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard !v.isEmpty, n > 0 else { return nil }
        return v.map { Float(Double($0) / n) }
    }

    /// L2-normalized mean of L2-normalized vectors. Nil if empty or dimensions differ.
    public static func normalizedMean(_ vectors: [[Float]]) -> [Float]? {
        guard let dim = vectors.first?.count, dim > 0,
              vectors.allSatisfy({ $0.count == dim }) else { return nil }
        var sum = [Double](repeating: 0, count: dim)
        for v in vectors {
            guard let u = normalized(v) else { return nil }
            for i in 0..<dim { sum[i] += Double(u[i]) }
        }
        return normalized(sum.map { Float($0) })
    }
}
