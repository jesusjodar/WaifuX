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
        return result(elements, accepting: accepting)
    }

    static func read<Record: Decodable>(
        _ type: Record.Type, from decoder: Decoder,
        accepting: (Record) -> Bool = { _ in true }
    ) throws -> Result<Record> {
        try result(Elements<Record>(from: decoder), accepting: accepting)
    }

    private static func result<Record>(
        _ elements: Elements<Record>, accepting: (Record) -> Bool
    ) -> Result<Record> {
        let accepted = elements.records.filter(accepting)
        return Result(records: accepted, rejectedCount: elements.totalCount - accepted.count)
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func readDictionary<Record: Decodable>(_ type: Record.Type, from decoder: Decoder) throws -> [String: Record] {
        let container = try decoder.container(keyedBy: Key.self)
        var records: [String: Record] = [:]
        for key in container.allKeys {
            if let record = try? container.decode(type, forKey: key) { records[key.stringValue] = record }
        }
        return records
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
