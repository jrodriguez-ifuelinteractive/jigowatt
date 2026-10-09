import Foundation
import SwiftUI
import JigowattCore

/// Observable wrapper around `HostStore` for the UI.
@MainActor
final class HostLibrary: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []
    @Published var lastError: String?

    private let store = HostStore()

    init() {
        reload()
    }

    func reload() {
        do {
            hosts = try store.load()
        } catch {
            lastError = "Could not read \(store.url.path): \(error.localizedDescription)"
        }
    }

    func host(_ id: SSHHost.ID?) -> SSHHost? {
        guard let id else { return nil }
        return hosts.first { $0.id == id }
    }

    func upsert(_ host: SSHHost) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
        } else {
            hosts.append(host)
        }
        save()
    }

    func delete(_ ids: Set<SSHHost.ID>) {
        hosts.removeAll { ids.contains($0.id) }
        for id in ids { KeychainStore.deletePassword(for: id) }
        save()
    }

    func duplicate(_ id: SSHHost.ID) -> SSHHost? {
        guard var copy = host(id) else { return nil }
        copy.id = UUID()
        copy.name = copy.displayName + " copy"
        copy.agentAllowed = false
        upsert(copy)
        return copy
    }

    func setAgentAllowed(_ ids: Set<SSHHost.ID>, _ allowed: Bool) {
        for i in hosts.indices where ids.contains(hosts[i].id) {
            hosts[i].agentAllowed = allowed
        }
        save()
    }

    /// Existing group names, for the editor's suggestions.
    var groups: [String] {
        Array(Set(hosts.map(\.group).filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Hosts matching the search text, grouped by folder (ungrouped last).
    func grouped(matching query: String) -> [(group: String, hosts: [SSHHost])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? hosts : hosts.filter { h in
            [h.displayName, h.hostname, h.username, h.group, h.tags.joined(separator: " ")]
                .contains { $0.lowercased().contains(q) }
        }
        let byGroup = Dictionary(grouping: filtered, by: \.group)
        return byGroup.keys
            .sorted { a, b in
                if a.isEmpty != b.isEmpty { return !a.isEmpty }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map { key in
                (key, byGroup[key]!.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
            }
    }

    private func save() {
        do {
            try store.save(hosts)
        } catch {
            lastError = "Could not save hosts: \(error.localizedDescription)"
        }
    }
}
