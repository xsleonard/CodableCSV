import Foundation

/// Sequentially writes string values and/or array of strings into a CSV file format.
public final class CSVWriter {
    /// Recipe detailing how to write the CSV information (i.e. delimiters, date strategy, etc.).
    public let configuration: Configuration
    /// Internal writer settings extracted from the public `configuration` and other values inferred during initialization.
    internal let settings: Settings
    /// The output stream gathering the processed data.
    private let stream: OutputStream
    /// Encoder used to transform unicode scalars into a bunch of bytes and store them in the result
    private let encoder: ScalarEncoder
    /// Check whether the following scalars are part of the field delimiter sequence.
    private let isFieldDelimiter: DelimiterChecker
    /// Check whether the following scalar are par of the row delimiter sequence.
    private let isRowDelimiter: DelimiterChecker
    /// The row being writen.
    ///
    /// The header row is not accounted on the `row` index.
    /// - note: If the `CSVWriter` is appending rows to a previously writen file/socket, those rows are not accounted for.
    public private(set) var rowIndex: Int
    /// The field to write next.
    public private(set) var fieldIndex: Int
    /// The number of fields per row that are expected.
    private var expectedFields: Int

    /// Designated initializer for the CSV writer.
    /// - parameter configuration: Recipe detailing how to parse the CSV data (i.e. encoding, delimiters, etc.).
    /// - parameter stream: An output stream that is already open.
    /// - parameter encoder: The function transforming unicode scalars into the desired binary representation and storing the bytes in their final location.
    /// - throws: `CSVError<CSVWriter>` exclusively.
    internal init(configuration: Configuration, settings: Settings, stream: OutputStream, encoder: @escaping ScalarEncoder) throws {
        precondition(stream.streamStatus != .notOpen)
        self.configuration = configuration
        self.settings = settings
        (self.stream, self.encoder) = (stream, encoder)
        self.isFieldDelimiter = CSVWriter.makeMatcher(delimiter: self.settings.delimiters.field)
        self.isRowDelimiter = CSVWriter.makeMatcher(delimiter: self.settings.delimiters.row)
        (self.rowIndex, self.fieldIndex, self.expectedFields) = (0, 0, 0)
        
        if !self.settings.headers.isEmpty {
            try self.write(row: self.settings.headers)
            self.rowIndex = 0
        }
    }

    deinit {
        try? self.endFile()
    }
    
    /// Returns the generated blob of data if the writer was initialized with a memory position (i.e. a `String` or `Data`, but not a file nor a network socket).
    /// - remark: Please notice that the `endFile()` function must be called before this function is used.
    public func data() throws -> Data {
        guard case .closed = self.stream.streamStatus else {
            throw Error.invalidDataAccess(status: self.stream.streamStatus, error: self.stream.streamError)
        }
    
        guard let data = stream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data else {
            throw Error.dataFailed(error: self.stream.streamError)
        }
        
        return data
    }
}

extension CSVWriter {
    /// Finishes the file and closes the output stream (if not indicated otherwise in the initializer).
    /// - throws: `CSVError<CSVWriter>` exclusively.
    public func endFile() throws {
        guard self.stream.streamStatus != .closed else { return }
        
        if self.fieldIndex > 0 {
            try self.endRow()
        }
        
        self.stream.close()
    }
}

extension CSVWriter {
    /// Writes a `String` field into a CSV row.
    /// - parameter field: The `String` to concatenate to the current CSV row.
    /// - throws: `CSVError<CSVWriter>` exclusively.
    public func write(field: String) throws {
        guard self.expectedFields <= 0 || self.fieldIndex <= self.expectedFields else {
            throw Error.fieldOverflow(expectedFields: self.expectedFields)
        }

        if self.fieldIndex > 0 {
            try self.lowlevelWrite(delimiter: self.settings.delimiters.field)
        }

        try self.lowlevelWrite(field: field)
        self.fieldIndex += 1
    }

    /// Appends a collection of `String`s as the fields for the current CSV row.
    ///
    /// This function can be called to add several fields at the same time. The row is not completed at the end of this function; therefore subsequent calls to this function or `write(field:)` can be made. An explicit call to `endRow()` must be made to write the row delimiter.
    /// - parameter fields: A collection representing several fields (usually `[String]`).
    /// - throws: `CSVError<CSVWriter>` exclusively.
    public func write<C:Collection>(fields: C) throws where C.Element == String {
        guard self.expectedFields <= 0 || (self.fieldIndex + fields.count) <= self.expectedFields else {
            throw Error.fieldOverflow(expectedFields: self.expectedFields)
        }

        for field in fields {
            if self.fieldIndex > 0 {
                try self.lowlevelWrite(delimiter: self.settings.delimiters.field)
            }
            try self.lowlevelWrite(field: field)
            self.fieldIndex += 1
        }
    }

    /// Finishes a row adding empty fields if fewer fields than expected have been writen.
    ///
    /// It is perfectly fine to call this method when only some fields (but not all) have been writen. This function will complete the row writing row delimiters.
    /// - throws: `CSVError<CSVWriter>` exclusively.
    public func endRow() throws {
        guard self.fieldIndex > 0 else {
            return try self.writeEmptyRow()
        }
        
        if self.expectedFields > 0 {
            try stride(from: self.fieldIndex, to: self.expectedFields, by: 1).forEach { [f = self.settings.delimiters.field] _ in
                try self.lowlevelWrite(delimiter: f)
                try self.lowlevelWrite(field: "")
            }
        } else {
            self.expectedFields = self.fieldIndex
        }
        
        try self.lowlevelWrite(delimiter: self.settings.delimiters.row)
        self.rowIndex += 1
        self.fieldIndex = 0
    }
}

extension CSVWriter {
    /// Writes a sequence of `String`s as fields of a brand new row and then ends the row (by writing a delimiter).
    ///
    /// Do not call `endRow()` after this function. It is called internally.
    /// - parameter row: Sequence of strings representing a CSV row.
    /// - throws: `CSError<CSVWriter>` exclusively.
    @inlinable public func write<C:Collection>(row: C) throws where C.Element==String {
        try self.write(fields: row)
        try self.endRow()
    }

    /// Writes an empty CSV row.
    ///
    /// An empty row is just comprise internally of the required field delimiters and a row delimiter.
    /// - remark: An empty row cannot start a CSV file if such file has no headers, since the number of fields wouldn't be known.
    /// - throws: `CSVError<CSVWriter>` exclusively.
    public func writeEmptyRow() throws {
        guard self.expectedFields > 0 else  {
            throw Error.invalidRowCompletionOnEmptyFile()
        }
        
        try self.lowlevelWrite(field: "")
        try stride(from: 1, to: self.expectedFields, by: 1).forEach { [f = self.settings.delimiters.field] _ in
            try self.lowlevelWrite(delimiter: f)
            try self.lowlevelWrite(field: "")
        }
        try self.lowlevelWrite(delimiter: self.settings.delimiters.row)
        
        self.rowIndex += 1
        self.fieldIndex = 0
    }
}

// MARK: -

extension CSVWriter {
    /// Writes the given `String` into the receiving writer's stream.
    /// - parameter field: The field to be checked for characters to escape and subsequently written.
    /// - throws: `CSVError<CSVWriter>` exclusively.
    private func lowlevelWrite(field: String) throws {
        let escapingScalar = self.settings.escapingScalar
        var result: [Unicode.Scalar]
        
        if field.isEmpty {
            if let escapingScalar = escapingScalar {
                result = .init(repeating: escapingScalar, count: 2)
            } else {
                result = []
            }
        } else {
            let input: [Unicode.Scalar] = .init(field.unicodeScalars)
            result = .init()
            result.reserveCapacity(input.count + 2)
            var index = 0
            var needsEscaping: Unicode.Scalar?
            
            while index < input.endIndex {
                let scalar = input[index]
                
                if scalar == escapingScalar {
                    needsEscaping = scalar
                } else if self.isFieldDelimiter(input, &index, &result) || self.isRowDelimiter(input, &index, &result) {
                    needsEscaping = scalar
                    continue
                }
                
                index += 1
                result.append(scalar)
            }
            
            if let needsEscaping = needsEscaping {
                guard let escapingScalar = escapingScalar else {
                    throw Error.unescapedDelimiter(needsEscaping)
                }
                result.insert(escapingScalar, at: result.startIndex)
                result.append(escapingScalar)
            }
        }

        try result.forEach { try self.encoder($0) }
    }
    
    /// Writes the given delimiter using the instance's `encoder`.
    /// - parameter delimiter: The array of `Unicode.Scalar` representing a delimiter.
    /// - throws: `CSVError<CSVWriter>` exclusively.
    @inline(__always) private func lowlevelWrite(delimiter: [Unicode.Scalar]) throws {
        try delimiter.forEach { try self.encoder($0) }
    }
}

fileprivate extension CSVWriter.Error {
    static func unescapedDelimiter(_ delimiter: Unicode.Scalar) -> CSVError<CSVWriter> {
        .init(.invalidInput,
              reason: "A field cannot include a delimiter if escaping strategy is disabled.",
              help: "Remove delimiter from field or set an escaping strategy.",
              userInfo: ["Invalid character": delimiter])

    }
    /// Error raised when the a field is trying to be writen and it overflows the expected number of fields per row.
    static func fieldOverflow(expectedFields: Int) -> CSVError<CSVWriter> {
        .init(.invalidOperation,
              reason: "A field cannot be added to a row that has already the expected amount of fields. All CSV rows must have the same amount of fields.",
              help: "Always write the same amount of fields per row.",
              userInfo: ["Number of expected fields per row": expectedFields])
    }
    
    /// Error raised when a row is ended, but nothing has been written before.
    static func invalidRowCompletionOnEmptyFile() -> CSVError<CSVWriter> {
        .init(.invalidOperation,
              reason: "An empty row cannot be writen if the number of fields hold by the file is unkwnown.",
              help: "Write a headers row or a row with content before writing an empty row.")
    }
    /// Error raised when the data was accessed before the stream was closed.
    static func invalidDataAccess(status: Stream.Status, error: Swift.Error?) -> CSVError<CSVWriter> {
        .init(.invalidOperation, underlying: error,
              reason: "The memory stream must be closed before the data can be accessed.",
              help: "Call endFile() before accessing the data. Also remember, that only Data and String initializers can access memory data.",
              userInfo: ["Stream status": status])
    }
    
    /// Error raised when the memory data tried to be accessed, but `nil` is received from the lower-level APIs.
    static func dataFailed(error: Swift.Error?) -> CSVError<CSVWriter> {
        .init(.streamFailure, underlying: error,
              reason: "The stream failed to returned the encoded data.",
              help: "Call endFile() before accessing the data. Also remember, that only Data and String initializers can access memory data.")
    }
}
