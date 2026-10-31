import Foundation

public struct DownloadSegment: Codable, Equatable {
    public var index: Int
    public var start: Int64
    public var length: Int64

    public init(index: Int, start: Int64, length: Int64) {
        self.index = index
        self.start = start
        self.length = length
    }
}
