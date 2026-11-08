import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Proves two mov patches on fragmented MP4, muxed here with this build's movenc:
///
/// - `trex_count` (build.sh `patch_ffmpeg_mov_export_trex_count`, patches/mov-export-trex-count.patch):
///   the mov demuxer exports how many trex boxes the moov carried, above 0 for a fragmented file.
/// - `frag_preroll` (build.sh `patch_ffmpeg_movenc_fragment_preroll`,
///   patches/movenc-fragment-preroll.patch): each fragment of an audio track with seek pre-roll
///   carries the 'prol' group, sgpd + sbgp after tfdt, over its samples that are not sync samples.
///
/// Two AAC tracks (the payloads are never decoded); track 1 has seek_preroll 1024 and frame_size
/// 1024, track 2 none. Track 1's samples per fragment: sync/non-sync patterns below, the second
/// fragment sync samples only. Every sample's bytes are distinct, so a data offset that moved
/// wrong reads the wrong bytes.
struct MovFragmentTests {

    static let fragments = ["SNNNSNN", "SSS", "NNSN"]
    static let fragmentFlags = "+empty_moov+default_base_moof+frag_custom+delay_moov+frag_discont"

    /// The muxed file, and each written sample's bytes per track, in order.
    static func mux(movflags: String?) throws -> (file: [UInt8], samples: [[[UInt8]]]) {
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_alloc_output_context2(&ctxOut, nil, "mp4", "probe.mp4") == 0)
        let ctx = try #require(ctxOut)
        defer { avformat_free_context(ctx) }
        var pb: UnsafeMutablePointer<AVIOContext>?
        try #require(avio_open_dyn_buf(&pb) >= 0)
        ctx.pointee.pb = pb

        let asc: [UInt8] = [0x11, 0x90] // AAC LC, 48 kHz, stereo
        for track in 0..<2 {
            let stream = try #require(avformat_new_stream(ctx, nil))
            let par = stream.pointee.codecpar!
            par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
            par.pointee.codec_id = AV_CODEC_ID_AAC
            par.pointee.sample_rate = 48_000
            par.pointee.frame_size = 1024
            if track == 0 { par.pointee.seek_preroll = 1024 }
            av_channel_layout_default(&par.pointee.ch_layout, 2)
            let extradata = av_mallocz(asc.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))!.assumingMemoryBound(to: UInt8.self)
            extradata.update(from: asc, count: asc.count)
            par.pointee.extradata = extradata
            par.pointee.extradata_size = Int32(asc.count)
            stream.pointee.time_base = AVRational(num: 1, den: 48_000)
        }

        var opts: OpaquePointer?
        if let movflags { av_dict_set(&opts, "movflags", movflags, 0) }
        let header = avformat_write_header(ctx, &opts)
        av_dict_free(&opts)
        try #require(header >= 0)

        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        var samples: [[[UInt8]]] = [[], []]
        var dts: Int64 = 0
        var value: UInt8 = 1
        for fragment in fragments {
            for kind in fragment {
                for track in 0..<2 {
                    let bytes = [UInt8](repeating: value, count: 16 + track)
                    value &+= 1
                    try #require(av_new_packet(pkt, Int32(bytes.count)) >= 0)
                    pkt!.pointee.data.update(from: bytes, count: bytes.count)
                    pkt!.pointee.stream_index = Int32(track)
                    pkt!.pointee.pts = dts
                    pkt!.pointee.dts = dts
                    pkt!.pointee.duration = 1024
                    pkt!.pointee.flags = track == 1 || kind == "S" ? AV_PKT_FLAG_KEY : 0
                    try #require(av_write_frame(ctx, pkt) >= 0)
                    samples[track].append(bytes)
                }
                dts += 1024
            }
            // The first flush writes the moov (delay_moov), the second the fragment.
            _ = av_write_frame(ctx, nil)
            if fragment == fragments[0] { _ = av_write_frame(ctx, nil) }
        }
        try #require(av_write_trailer(ctx) >= 0)
        var buf: UnsafeMutablePointer<UInt8>?
        let size = Int(avio_close_dyn_buf(ctx.pointee.pb, &buf))
        ctx.pointee.pb = nil
        defer { av_free(buf) }
        return (Array(UnsafeBufferPointer(start: buf, count: size)), samples)
    }

    // MARK: - trex_count

    @Test("trex_count is above 0 for a fragmented file and 0 for a plain one", arguments: [true, false])
    func trexCount(fragmented: Bool) throws {
        let file = try Self.mux(movflags: fragmented ? Self.fragmentFlags : nil).file
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("trex-\(UUID().uuidString).mp4").path
        try Data(file).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        var ctxIn: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&ctxIn, path, nil, nil) == 0)
        defer { avformat_close_input(&ctxIn) }
        var count: Int64 = -1
        try #require(av_opt_get_int(ctxIn!.pointee.priv_data, "trex_count", 0, &count) >= 0)
        #expect(count == (fragmented ? 2 : 0))
    }

    // MARK: - frag_preroll

    struct Box { let type: String; let start: Int; let body: Int; let end: Int }

    static func boxes(_ d: [UInt8], _ from: Int, _ to: Int) -> [Box] {
        var out: [Box] = []
        var at = from
        while at + 8 <= to {
            let size = Int(be32(d, at))
            guard size >= 8, at + size <= to else { break }
            out.append(Box(type: String(decoding: d[(at + 4)..<(at + 8)], as: UTF8.self), start: at, body: at + 8, end: at + size))
            at += size
        }
        return out
    }

    static func be32(_ d: [UInt8], _ at: Int) -> UInt32 {
        UInt32(d[at]) << 24 | UInt32(d[at + 1]) << 16 | UInt32(d[at + 2]) << 8 | UInt32(d[at + 3])
    }

    static func u32(_ v: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: v >> UInt32(8 * $0)) } }

    /// One traf as read back: its track, the box types in order, its sgpd/sbgp bytes, and the
    /// bytes of each sample its truns point at.
    struct Traf { var track: UInt32; var types: [String]; var group: [UInt8]; var samples: [[UInt8]] }

    static func trafs(_ d: [UInt8]) -> [Traf] {
        var out: [Traf] = []
        for moof in boxes(d, 0, d.count) where moof.type == "moof" {
            for traf in boxes(d, moof.body, moof.end) where traf.type == "traf" {
                var result = Traf(track: 0, types: [], group: [], samples: [])
                var defaultSize = 0
                for box in boxes(d, traf.body, traf.end) {
                    result.types.append(box.type)
                    switch box.type {
                    case "tfhd":
                        result.track = be32(d, box.body + 4)
                        // Base data offset, sample description index and default duration come
                        // before the default size, each present by its flag.
                        let flags = be32(d, box.body) & 0xFFFFFF
                        var at = box.body + 8
                        if flags & 0x1 != 0 { at += 8 }
                        for bit: UInt32 in [0x2, 0x8] where flags & bit != 0 { at += 4 }
                        if flags & 0x10 != 0 { defaultSize = Int(be32(d, at)) }
                    case "sgpd", "sbgp": result.group += d[box.start..<box.end]
                    case "trun":
                        // movenc writes the data offset; size per sample or the tfhd default.
                        let flags = be32(d, box.body) & 0xFFFFFF
                        let count = Int(be32(d, box.body + 4))
                        var at = box.body + 8
                        var data = moof.start + Int(Int32(bitPattern: be32(d, at)))
                        at += 4
                        if flags & 0x4 != 0 { at += 4 }
                        for _ in 0..<count {
                            if flags & 0x100 != 0 { at += 4 }
                            var size = defaultSize
                            if flags & 0x200 != 0 {
                                size = Int(be32(d, at))
                                at += 4
                            }
                            if flags & 0x400 != 0 { at += 4 }
                            if flags & 0x800 != 0 { at += 4 }
                            result.samples.append(Array(d[data..<data + size]))
                            data += size
                        }
                    default: break
                    }
                }
                out.append(result)
            }
        }
        return out
    }

    /// The boxes the patch writes for track 1's samples of one fragment's sync pattern.
    static func expectedGroup(_ pattern: String) -> [UInt8] {
        guard pattern.contains("N") else { return [] }
        var runs: [(count: UInt32, index: UInt32)] = []
        for kind in pattern {
            let index: UInt32 = kind == "S" ? 0 : 0x1_0001
            if let last = runs.last, last.index == index { runs[runs.count - 1].count += 1 } else { runs.append((1, index)) }
        }
        var bytes = u32(26) + Array("sgpd".utf8) + u32(1 << 24) + Array("prol".utf8) + u32(2) + u32(1) + [0, 1]
        bytes += u32(UInt32(20 + 8 * runs.count)) + Array("sbgp".utf8) + u32(0) + Array("prol".utf8) + u32(UInt32(runs.count))
        for run in runs { bytes += u32(run.count) + u32(run.index) }
        return bytes
    }

    @Test("frag_preroll writes the prol group in each fragment of the pre-roll track", arguments: [false, true])
    func fragmentPreroll(separateMoof: Bool) throws {
        let flags = Self.fragmentFlags + (separateMoof ? "+separate_moof" : "") + "+frag_preroll"
        let (file, samples) = try Self.mux(movflags: flags)
        let trafs = Self.trafs(file)

        let preroll = trafs.filter { $0.track == 1 }
        #expect(preroll.flatMap(\.samples) == samples[0])
        // Each traf's slice of the sync pattern, in the order the samples were written.
        var pattern = Substring(Self.fragments.joined())
        var syncOnly = 0
        for traf in preroll {
            let slice = String(pattern.prefix(traf.samples.count))
            pattern = pattern.dropFirst(traf.samples.count)
            #expect(traf.group == Self.expectedGroup(slice))
            if slice.contains("N") {
                #expect(Array(traf.types.prefix(4)) == ["tfhd", "tfdt", "sgpd", "sbgp"])
            } else {
                syncOnly += 1
            }
        }
        #expect(syncOnly == 1, "the fragment of sync samples only is its own traf, without the group")

        let other = trafs.filter { $0.track == 2 }
        #expect(other.allSatisfy { $0.group.isEmpty })
        #expect(other.flatMap(\.samples) == samples[1])
    }

    @Test("without frag_preroll no fragment carries the group", arguments: [false, true])
    func noPreroll(separateMoof: Bool) throws {
        let (file, samples) = try Self.mux(movflags: Self.fragmentFlags + (separateMoof ? "+separate_moof" : ""))
        let trafs = Self.trafs(file)
        #expect(trafs.allSatisfy { $0.group.isEmpty })
        #expect(trafs.filter { $0.track == 1 }.flatMap(\.samples) == samples[0])
        #expect(trafs.filter { $0.track == 2 }.flatMap(\.samples) == samples[1])
    }
}
