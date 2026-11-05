import Foundation
import Testing
@testable import TTSMLX

/// `Docs/compatibility.md` is hand-written; this keeps it honest. Every
/// catalog entry with a descriptor must have a row, and the row's stage, gate
/// and peak memory must match the catalog.
@Suite("Docs/compatibility.md matches the catalog")
struct TTSCompatibilityDocTests {
    static var documentURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Docs/compatibility.md")
    }

    struct Row { let id: String; let stage: String; let gate: String; let peak: Int }

    static func rows() throws -> [Row] {
        let text = try String(contentsOf: documentURL, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("| `") else { return nil }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 6 else { return nil }
            let id = cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            return Row(id: id, stage: cells[2], gate: cells[3], peak: Int(cells[4]) ?? -1)
        }
    }

    static func gateName(_ deviceClass: TTSDeviceClass?) -> String {
        switch deviceClass {
        case .iPhone?: "iPhone"
        case .iPad?: "iPad"
        case .mac?: "Mac"
        case nil: "any"
        }
    }

    @Test("every descriptor-bearing catalog entry has a row with the catalog's stage, gate and peak")
    func rowsMatchCatalog() throws {
        let rows = try Self.rows()
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(rows.count == byID.count, "duplicate rows in Docs/compatibility.md")
        for entry in TTSMLX.modelCatalog {
            guard let descriptor = entry.descriptor else { continue }
            guard let row = byID[entry.id] else {
                Issue.record("Docs/compatibility.md has no row for \(entry.id)")
                continue
            }
            #expect(row.stage == entry.supportStage.rawValue, "\(entry.id): stage \(row.stage) vs catalog \(entry.supportStage.rawValue)")
            #expect(row.gate == Self.gateName(descriptor.capabilities.minimumDeviceClass), "\(entry.id): gate \(row.gate) vs catalog \(Self.gateName(descriptor.capabilities.minimumDeviceClass))")
            #expect(row.peak == (descriptor.capabilities.peakMemoryMB ?? -1), "\(entry.id): peak \(row.peak) vs catalog \(descriptor.capabilities.peakMemoryMB ?? -1)")
        }
        let catalogIDs = Set(TTSMLX.modelCatalog.compactMap { $0.descriptor?.id })
        for row in rows where !catalogIDs.contains(row.id) {
            Issue.record("Docs/compatibility.md row \(row.id) is not a descriptor-bearing catalog entry")
        }
    }
}
