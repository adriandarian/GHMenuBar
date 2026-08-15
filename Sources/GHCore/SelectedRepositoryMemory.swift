import Foundation

public struct SelectedRepositoryMemory {
    public static let defaultKey = "GHMenuBar.selectedRepository"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = Self.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public var selectedRepository: String? {
        defaults.string(forKey: key)
    }

    public func saveSelectedRepository(_ repository: String?) {
        guard let repository = repository?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repository.isEmpty
        else {
            defaults.removeObject(forKey: key)
            return
        }

        defaults.set(repository, forKey: key)
    }
}
