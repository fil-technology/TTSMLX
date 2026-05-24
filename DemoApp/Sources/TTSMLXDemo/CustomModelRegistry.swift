import Foundation
import Observation
import TTSMLX

@MainActor
@Observable
final class CustomModelRegistry {
    private let userDefaults = UserDefaults.standard
    private let storageKey = "com.filtechnology.ttsmlx.demo.customModels"

    private(set) var descriptors: [TTSModelDescriptor] = []

    init() {
        load()
    }

    func add(_ descriptor: TTSModelDescriptor) {
        descriptors.removeAll { $0.id == descriptor.id }
        descriptors.append(descriptor)
        persist()
    }

    func remove(id: String) {
        descriptors.removeAll { $0.id == id }
        persist()
    }

    func contains(id: String) -> Bool {
        descriptors.contains { $0.id == id }
    }

    private func load() {
        guard
            let data = userDefaults.data(forKey: storageKey),
            let stored = try? JSONDecoder().decode([TTSModelDescriptor].self, from: data)
        else { return }
        descriptors = stored
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(descriptors) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}
