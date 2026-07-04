import Foundation
import Observation

/// The live set of cue instances: feeds the Active Cues panel AND is the
/// resolution table fade/stop cues use to find their running targets.
@MainActor
@Observable
public final class ActiveCuesRegistry {
    public private(set) var instances: [CueInstance] = []

    public var isEmpty: Bool { instances.isEmpty }

    func add(_ instance: CueInstance) {
        instances.append(instance)
    }

    func remove(_ instance: CueInstance) {
        instances.removeAll { $0.id == instance.id }
    }

    public func instances(ofCue cueID: UUID) -> [CueInstance] {
        instances.filter { $0.cue.id == cueID }
    }
}
