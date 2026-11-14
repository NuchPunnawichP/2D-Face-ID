import Foundation

/// The threshold decision for a face match.
public enum MatchDecision {
    public struct Scores: Equatable, Sendable {
        /// cosine(mean of probe embeddings, enrolled mean)
        public var meanScore: Double
        /// max cosine(mean of probe embeddings, each enrolled embedding)
        public var bestIndividualScore: Double
    }

    public static func scores(probe: [[Float]], enrollment: Enrollment) -> Scores? {
        guard let mean = Embeddings.normalizedMean(probe),
              let m = Embeddings.cosine(mean, enrollment.mean) else { return nil }
        let individual = enrollment.embeddings.compactMap { Embeddings.cosine(mean, $0) }
        guard let best = individual.max() else { return nil }
        return Scores(meanScore: m, bestIndividualScore: best)
    }

    /// True only if both scores reach the threshold (inclusive).
    public static func isMatch(_ s: Scores, threshold: Double) -> Bool {
        s.meanScore >= threshold && s.bestIndividualScore >= threshold
    }
}
