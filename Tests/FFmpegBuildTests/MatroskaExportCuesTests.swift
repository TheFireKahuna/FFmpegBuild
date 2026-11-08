import Foundation
import Testing
import AetherLibavformat
import AetherLibavutil

/// Proves the matroska export_cues patch (build.sh `patch_ffmpeg_matroska_export_cues`,
/// patches/matroska-export-cues.patch) is in the shipped libavformat.
///
/// With `export_cues` the open reads the Cues (here behind the Cluster, reached through the
/// SeekHead) and exports every CueTrackPositions with its CueRelativePosition and CueDuration,
/// each stream's ContentEncoding and the TimestampScale. The fixture is built here because no
/// muxer in this build writes Matroska, and no FFmpeg muxer writes ContentEncodings: two
/// S_TEXT/UTF8 tracks, track 1 header-stripped ("He" taken off every frame), track 2 zlib, one
/// Cluster with three BlockGroups, Cues with both fields on track 1 and neither on track 2.
struct MatroskaExportCuesTests {

    private struct Opened {
        var cuePoints: [Int64]
        var trackCoding: [Int64]
        var timestampScale: Int64
        var packets: [(stream: Int32, pts: Int64, position: Int64)]
    }

    private static func open(_ bytes: [UInt8], export: Bool) throws -> Opened {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkv-export-cues-\(UUID().uuidString).mkv").path
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        var options: OpaquePointer?
        if export { av_dict_set(&options, "export_cues", "1", 0) }
        defer { av_dict_free(&options) }
        var ctxIn: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&ctxIn, path, nil, &options) == 0)
        let ctx = try #require(ctxIn)
        defer { avformat_close_input(&ctxIn) }
        #expect(av_dict_count(options) == 0, "the matroska demuxer consumed the option")

        let priv = ctx.pointee.priv_data
        func array(_ name: String) throws -> [Int64] {
            var count: UInt32 = 0
            try #require(av_opt_get_array_size(priv, name, 0, &count) >= 0)
            var values = [Int64](repeating: 0, count: Int(count))
            if count > 0 {
                try #require(av_opt_get_array(priv, name, 0, 0, count, AV_OPT_TYPE_INT64, &values) >= 0)
            }
            return values
        }
        var scale: Int64 = 0
        try #require(av_opt_get_int(priv, "timestamp_scale", 0, &scale) >= 0)
        let cuePoints = try array("cue_points"), trackCoding = try array("track_coding")

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var packets: [(Int32, Int64, Int64)] = []
        while av_read_frame(ctx, packet) >= 0 {
            packets.append((packet!.pointee.stream_index, packet!.pointee.pts, packet!.pointee.pos))
            av_packet_unref(packet)
        }
        return Opened(cuePoints: cuePoints, trackCoding: trackCoding, timestampScale: scale, packets: packets)
    }

    @Test("export_cues exports every cue position, the track codings and the timestamp scale")
    func exported() throws {
        let file = Fixture()
        let opened = try Self.open(file.bytes, export: true)
        let cluster = Int64(file.clusterPosition)
        #expect(opened.cuePoints == [
            0, 0, cluster, Int64(file.relativePositions[0]), 500,
            1, 0, cluster, -1, -1,
            0, 1000, cluster, Int64(file.relativePositions[2]), 700,
        ])
        // Stream, encodings, type, scope, algorithm, settings size, settings.
        #expect(opened.trackCoding == [0, 1, 0, 1, 3, 2, 0x48, 0x65,
                                       1, 1, 0, 1, 0, 0])
        #expect(opened.timestampScale == 1_000_000)

        // The exported positions are where the file has its Cluster and BlockGroups.
        #expect(Array(file.bytes[Int(cluster)..<Int(cluster) + 4]) == [0x1F, 0x43, 0xB6, 0x75])
        for relative in file.relativePositions {
            #expect(file.bytes[file.clusterDataStart + relative] == 0xA0)
        }
    }

    @Test("without export_cues nothing is exported and the packets are the same")
    func notExported() throws {
        let file = Fixture()
        let plain = try Self.open(file.bytes, export: false)
        let exported = try Self.open(file.bytes, export: true)
        #expect(plain.cuePoints.isEmpty)
        #expect(plain.trackCoding.isEmpty)
        #expect(plain.packets.count == 3)
        #expect(plain.packets.map(\.stream) == exported.packets.map(\.stream))
        #expect(plain.packets.map(\.pts) == exported.packets.map(\.pts))
        #expect(plain.packets.map(\.position) == exported.packets.map(\.position))
    }

    /// The Matroska file the tests open, with the offsets the exports must report.
    private struct Fixture {
        var bytes: [UInt8] = []
        var clusterPosition = 0
        var clusterDataStart = 0
        var relativePositions: [Int] = []

        init() {
            let ebml = Self.element(0x1A45DFA3, Self.uint(0x4286, 1) + Self.uint(0x42F7, 1) + Self.uint(0x42F2, 4)
                                    + Self.uint(0x42F3, 8) + Self.element(0x4282, Array("matroska".utf8))
                                    + Self.uint(0x4287, 4) + Self.uint(0x4285, 2))
            let info = Self.element(0x1549A966, Self.uint(0x2AD7B1, 1_000_000))
            let tracks = Self.element(0x1654AE6B,
                                      Self.track(1, compression: Self.uint(0x4254, 3) + Self.element(0x4255, Array("He".utf8)))
                                      + Self.track(2, compression: Self.uint(0x4254, 0)))
            // zlib of "world" at level 6, as Python's zlib.compress writes it.
            let deflated: [UInt8] = [0x78, 0x9C, 0x2B, 0xCF, 0x2F, 0xCA, 0x49, 0x01, 0x00, 0x06, 0xA6, 0x02, 0x29]
            let timestamp = Self.uint(0xE7, 0)
            let groups = [Self.group(1, 0, Array("llo".utf8), 500), Self.group(2, 0, deflated, 400),
                          Self.group(1, 1000, Array("y".utf8), 700)]
            let cluster = Self.element(0x1F43B675, timestamp + groups.joined())
            relativePositions = [timestamp.count, timestamp.count + groups[0].count,
                                 timestamp.count + groups[0].count + groups[1].count]

            // The SeekHead's position is written in 8 bytes, so its size does not depend on it.
            let seekHeadSize = Self.seekHead(0).count
            let clusterInSegment = seekHeadSize + info.count + tracks.count
            func positions(_ track: UInt64, _ extra: [UInt8]) -> [UInt8] {
                Self.element(0xB7, Self.uint(0xF7, track) + Self.uint(0xF1, UInt64(clusterInSegment)) + extra)
            }
            let cues = Self.element(0x1C53BB6B,
                                    Self.element(0xBB, Self.uint(0xB3, 0)
                                                 + positions(1, Self.uint(0xF0, UInt64(relativePositions[0])) + Self.uint(0xB2, 500))
                                                 + positions(2, []))
                                    + Self.element(0xBB, Self.uint(0xB3, 1000)
                                                   + positions(1, Self.uint(0xF0, UInt64(relativePositions[2])) + Self.uint(0xB2, 700))))
            let body = Self.seekHead(UInt64(clusterInSegment + cluster.count)) + info + tracks + cluster + cues
            let segmentHeader = [0x18, 0x53, 0x80, 0x67] + Self.size(body.count)
            bytes = ebml + segmentHeader + body
            clusterPosition = ebml.count + segmentHeader.count + clusterInSegment
            clusterDataStart = clusterPosition + cluster.count - (timestamp.count + groups.joined().count)
        }

        static func size(_ n: Int) -> [UInt8] {
            for length in 1...8 where n < (1 << (7 * length)) - 1 {
                let value = UInt64(n) | (1 << UInt64(7 * length))
                return (0..<length).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64(8 * $0)) }
            }
            fatalError("element too large")
        }

        static func element(_ id: UInt32, _ payload: [UInt8]) -> [UInt8] {
            let idBytes = (0..<4).reversed().map { UInt8(truncatingIfNeeded: id >> UInt32(8 * $0)) }.drop { $0 == 0 }
            return Array(idBytes) + size(payload.count) + payload
        }

        static func uint(_ id: UInt32, _ value: UInt64, width: Int? = nil) -> [UInt8] {
            let length = width ?? max(1, (64 - value.leadingZeroBitCount + 7) / 8)
            return element(id, (0..<length).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64(8 * $0)) })
        }

        static func track(_ number: UInt64, compression: [UInt8]) -> [UInt8] {
            let encoding = uint(0x5031, 0) + uint(0x5032, 1) + uint(0x5033, 0) + element(0x5034, compression)
            return element(0xAE, uint(0xD7, number) + uint(0x73C5, number) + uint(0x83, 0x11)
                           + element(0x86, Array("S_TEXT/UTF8".utf8)) + element(0x6D80, element(0x6240, encoding)))
        }

        static func group(_ track: Int, _ timecode: Int16, _ data: [UInt8], _ duration: UInt64) -> [UInt8] {
            let block = size(track) + [UInt8(truncatingIfNeeded: timecode >> 8), UInt8(truncatingIfNeeded: timecode), 0] + data
            return element(0xA0, element(0xA1, block) + uint(0x9B, duration))
        }

        static func seekHead(_ cuesPosition: UInt64) -> [UInt8] {
            element(0x114D9B74, element(0x4DBB, element(0x53AB, [0x1C, 0x53, 0xBB, 0x6B]) + uint(0x53AC, cuesPosition, width: 8)))
        }
    }
}
