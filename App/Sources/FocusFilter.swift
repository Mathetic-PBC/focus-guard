import AppIntents
import FocusGuardCore

/// A profile, as System Settings shows it when a filter is being set up.
struct ProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Profile" }
    static var defaultQuery = ProfileQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ProfileQuery: EntityQuery {
    private func all() -> [ProfileEntity] {
        ConfigStore.load(from: Paths.config).profiles.map { ProfileEntity(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [ProfileEntity] {
        let profiles = all()
        return identifiers.compactMap { id in profiles.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [ProfileEntity] {
        all()
    }
}

/// The link between a Focus and a profile. Adding this filter to a Focus in
/// System Settings is what "connecting" means: from then on macOS runs
/// `perform()` each time that Focus goes on or off, however it was switched.
struct BlockingFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Block Distractions"
    static var description: IntentDescription? = IntentDescription(
        "Blocks the websites and apps in a Focus Guard profile while this Focus is on.")

    @Parameter(title: "Profile")
    var profile: ProfileEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Block Distractions",
            subtitle: "\(profile?.name ?? "No profile chosen")")
    }

    func perform() async throws -> some IntentResult {
        let id = profile?.id
        await MainActor.run {
            SessionController.shared.focusFilterPerformed(profileID: id)
        }
        return .result()
    }
}
