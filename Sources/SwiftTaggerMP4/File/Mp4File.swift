/*
 Mp4File.swift
 SwiftTaggerMP4
 
 Created by Nolaine Crusher on 4/21/20.
 Copyright © 2020 Nolaine Crusher. All rights reserved.
 */

import Foundation
import SwiftLanguageAndLocaleCodes

/// A type representing an audio file stored locally
public class Mp4File {
    
    var rootAtoms: [Atom]
    var data: Data
    static var use64BitOffset: Bool = false
    var chunkSizes: [Int] = []
    var location: URL
    
    /// Initialize an Mp4File from a local file
    /// - Parameter location: the `url` of the mp4 file
    /// - Throws: `InvalidFileFormat` if the file is not a valid mp4 file
    public init(location: URL) throws {
        self.location = location
        
        let validExtensions: [String] = ["aax", "aac", "mp4", "m4a", "m4b"]
        
        guard validExtensions.contains(location.pathExtension.lowercased()) else {
            throw Mp4FileError.InvalidFileFormat
        }
        
        self.data = try Data(contentsOf: location, options: .alwaysMapped)
        var fileData = self.data
        var atoms = [Atom]()
        while !fileData.isEmpty {
            if let atom = try fileData.extractAndParseToAtom() {
                atoms.append(atom)
            } else {
                throw Mp4FileError.UnableToInitializeAtomsFromFileData
            }
        }
        self.rootAtoms = atoms
        
        if self.moov.soundTrack.mdia.minf.stbl.chunkOffsetAtom.identifier == "co64" {
            Mp4File.use64BitOffset = true
        }
        
        self.chunkSizes = try self.chunkSizes(stbl: self.moov.soundTrack.mdia.minf.stbl)
    }
    
    public func tag() throws -> Tag {
        return try Tag(mp4File: self)
    }
    
    public func write(tag: Tag, to outputLocation: URL) throws {
        try setMetadataAtoms(tag: tag)
        setLanguage(tag: tag)

        // Compute mdat layout before chapter track offset calculation
        let titles = tag.chapterHandler.chapterTitles
        let mediaSize = self.chunkSizes.sum()
        let titleDataSize = titles.reduce(0) { $0 + 2 + $1.utf8.count }
        let mdatContentSize = mediaSize + titleDataSize
        let mdatPreliminarySize = mdatContentSize + 8
        let mdatHeaderSize = mdatPreliminarySize > UInt32.max ? 16 : 8

        try setChapterTrack(tag: tag, mdatHeaderSize: mdatHeaderSize)

        // Version promotion (from setMdat — may change atom sizes)
        for track in self.moov.tracks {
            track.tkhd.promoteVersionIfNeeded()
        }
        for track in self.moov.tracks {
            track.recalculateSize()
        }
        self.moov.recalculateSize()

        // Save original chunk offsets for reading from source file
        let sourceChunkOffsets = self.moov.soundTrack.mdia.minf.stbl.chunkOffsetAtom.chunkOffsetTable
        let sourceChunkSizes = self.chunkSizes

        // Remove mdat from rootAtoms — media will be streamed during write
        self.rootAtoms = self.rootAtoms.filter { $0.identifier != "mdat" }

        // Calculate new sound track chunk offsets with correct mdat header size
        let nonMdatAtomSizes = self.rootAtoms.filter({
            $0.identifier != "free" &&
            $0.identifier != "skip" &&
            $0.identifier != "wide"
        }).map({ $0.size }).sum()

        var currentOffset = mdatHeaderSize + nonMdatAtomSizes
        var newOffsets = [currentOffset]
        for chunkSize in sourceChunkSizes.dropLast() {
            currentOffset += chunkSize
            newOffsets.append(currentOffset)
        }
        guard newOffsets.count == self.moov.soundTrack.mdia.minf.stbl.chunkOffsetAtom.chunkOffsetTable.count else {
            throw Mp4FileError.NewChunkOffsetArrayCountMismatch
        }
        self.moov.soundTrack.mdia.minf.stbl.chunkOffsetAtom.chunkOffsetTable = newOffsets

        // Open source file for streaming media chunks
        let sourceHandle = try FileHandle(forReadingFrom: self.location)

        // Release mapped file data — all needed info is captured above
        self.data = Data()

        // Write to temp file then rename for atomic safety
        let tempURL = outputLocation.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        do {
            let outputHandle = try FileHandle(forWritingTo: tempURL)

            // Write non-mdat atoms (ftyp, moov — small, KB-sized)
            for atom in self.optimizedRoot {
                atom.write(to: outputHandle)
            }

            // Write mdat header
            if mdatPreliminarySize > UInt32.max {
                var sizeField = UInt32(1).bigEndian
                outputHandle.write(Data(bytes: &sizeField, count: 4))
                outputHandle.write("mdat".data(using: .isoLatin1)!)
                var extSize = UInt64(mdatPreliminarySize).bigEndian
                outputHandle.write(Data(bytes: &extSize, count: 8))
            } else {
                var sizeField = UInt32(mdatPreliminarySize).bigEndian
                outputHandle.write(Data(bytes: &sizeField, count: 4))
                outputHandle.write("mdat".data(using: .isoLatin1)!)
            }

            // Stream media chunks from source file in 1MB pieces
            let copyBufferSize = 1_048_576
            for (index, offset) in sourceChunkOffsets.enumerated() {
                sourceHandle.seek(toFileOffset: UInt64(offset))
                var remaining = sourceChunkSizes[index]
                while remaining > 0 {
                    try autoreleasepool {
                        let readSize = min(remaining, copyBufferSize)
                        let piece = sourceHandle.readData(ofLength: readSize)
                        if piece.isEmpty {
                            throw Mp4FileError.MissingChunk
                        }
                        outputHandle.write(piece)
                        remaining -= readSize
                    }
                }
            }

            // Write chapter title data
            for title in titles {
                var len = UInt16(title.count).bigEndian
                outputHandle.write(Data(bytes: &len, count: 2))
                outputHandle.write(Data(title.utf8))
            }

            outputHandle.closeFile()
            sourceHandle.closeFile()
        } catch {
            sourceHandle.closeFile()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        if FileManager.default.fileExists(atPath: outputLocation.path) {
            try FileManager.default.removeItem(at: outputLocation)
        }
        try FileManager.default.moveItem(at: tempURL, to: outputLocation)
    }
    
    /// Sorts atoms into order to preserve media offsets
    /// - Parameters:
    ///   - identifier: the identifier of the atom being sorted
    private func sortingGroup(forIdentifier identifier: String) -> Int {
        switch identifier {
            case "ftyp": return 1
            case "mdat": return 4
            case "moov": return 3
            default: return 2
        }
    }
    
    /// The array of root atoms, arranged to preserve media offsets
    private var optimizedRoot: [Atom] {
        var rearrangedAtoms = self.rootAtoms.filter({$0.identifier != "free" &&
                                                        $0.identifier != "skip" &&
                                                        $0.identifier != "wide"})
        rearrangedAtoms.sort(
            by: { sortingGroup(forIdentifier: $0.identifier) < sortingGroup(forIdentifier: $1.identifier) }
        )
        return rearrangedAtoms
    }
    
    // properties
    var duration: Double {
        return moov.mvhd.duration
    }
    
    var languages: [Language]? {
        get {
            if let elng = moov.soundTrack.mdia.elng {
                return elng.languages
            } else {
                return nil
            }
        }
        set {
            if let new = newValue, !new.isEmpty {
                let newTracks = self.moov.tracks
                for track in newTracks {
                    if track.mdia.elng != nil {
                        track.mdia.elng?.languages = new
                        track.mdia.mdhd.language = Mdhd.getLanguage(from: track.mdia.elng!)
                    } else {
                        var locales: [ICULocaleCode] = []
                        for language in new {
                            locales.append(language.localeCode)
                        }
                        do {
                            let elng = try Elng(locales: locales)
                            track.mdia.elng = elng
                            track.mdia.mdhd.language = Mdhd.getLanguage(from: track.mdia.elng!)
                        } catch {
                            fatalError("WARNING: Unable to initialize extended language atom")
                        }
                    }
                }
                self.moov.tracks = newTracks
            } else {
                self.moov.soundTrack.mdia.elng = nil
                self.moov.soundTrack.mdia.mdhd.language = .unspecified
                if self.moov.chapterTrack != nil {
                    self.moov.chapterTrack?.mdia.elng = nil
                    self.moov.chapterTrack?.mdia.mdhd.language = .unspecified
                }
            }
            for track in self.moov.tracks {
                track.mdia.recalculateSize()
                track.recalculateSize()
            }
            self.moov.recalculateSize()
        }
    }
    
    // MARK: Internal properties
    var moov: Moov {
        get {
            if let moov = rootAtoms.first(where: {$0.identifier == "moov"}) as? Moov {
                return moov
            } else {
                fatalError("Required atom 'moov' is inaccessible")
            }
        }
        set {
            var newRoot = rootAtoms.filter({$0.identifier != "moov"})
            newRoot.append(newValue)
            rootAtoms = newRoot
        }
    }
    
    var mdats: [Mdat] {
        get {
            if let mdats = rootAtoms.filter({$0.identifier == "mdat"}) as? [Mdat] {
                return mdats
            } else {
                return []
            }
        }
        set {
            var newRoot = rootAtoms.filter({$0.identifier != "mdat"})
            newRoot.append(contentsOf: newValue)
            rootAtoms = newRoot
        }
    }
}

enum Mp4FileError: Error {
    /// Error thrown when the file is not an MP4 format audio file
    case InvalidFileFormat
    /// Error thrown when writing operation fails
    case OutputFailure
    /// Error thrown when atoms fail to initialize
    case UnableToInitializeAtomsFromFileData
    case UnableToInitializeRequiredAtom(AtomIdentifier)
    /// Error thrown when a required root atom is missing
    case MoovAtomNotFound
    /// Error thrown when a required root atom is missing
    case MdatAtomNotFound
    /// Error thrown when samples cannot be located
    case MissingSample
    /// Error thrown when media chunk cannot be located
    case MissingChunk
    /// Error thrown when entry count of the chunkSizes array does not match the count of the chunkOffsets array
    case ChunkSizeToChunkOffsetCountMismatch
    /// Error thrown when the new chunk offsets array doesn't match the old chunk offsets array
    case NewChunkOffsetArrayCountMismatch
    case ChapterHandlerMissing
}
