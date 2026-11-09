/// Where a resolve was requested. Built from compile-time literals (no allocation), or from
/// runtime strings by the positional `(file, fileId, function, line)` overloads kept for source compatibility.
enum Site: CustomStringConvertible {
    case literal(file: StaticString, fileID: StaticString, function: StaticString, line: UInt)
    case dynamic(file: String, fileID: String, function: String, line: UInt)

    var description: String {
        switch self {
        case let .literal(_, fileID, function, line): "\(fileID)#\(function):\(line)"
        case let .dynamic(_, fileID, function, line): "\(fileID)#\(function):\(line)"
        }
    }

    func trap(_ message: String) -> Never {
        switch self {
        case let .literal(file, _, _, line): fatalError(message, file: file, line: line)
        case let .dynamic(file, _, _, line): fatalError("\(message) (\(file):\(line))")
        }
    }
}
