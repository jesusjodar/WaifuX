import Foundation

/// Decode records independently so one retired enum case or damaged record
/// cannot hide the rest of a legacy library. Callers retain the original data
/// until migration and backup have both succeeded.
enum LegacyRecordReader {
    struct Result<Record> {
        let records: [Record]
        let rejectedCount: Int
    }

    static func read<Record: Decodable>(
        _ type: Record.Type,
        from data: Data,
        accepting: (Record) -> Bool = { _ in true }
    ) throws -> Result<Record> {
        let elements = try JSONDecoder().decode(Elements<Record>.self, from: data)
        let accepted = elements.records.filter(accepting)
        return Result(records: accepted, rejectedCount: elements.totalCount - accepted.count)
    }

    private struct Elements<Record: Decodable>: Decodable {
        var records: [Record] = []
        var totalCount = 0

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            while !container.isAtEnd {
                // Advance the outer container before decoding this record.
                // A thrown record decoder must never leave the loop at one index.
                let recordDecoder = try container.superDecoder()
                totalCount += 1
                if let record = try? Record(from: recordDecoder) {
                    records.append(record)
                }
            }
        }
    }
}
