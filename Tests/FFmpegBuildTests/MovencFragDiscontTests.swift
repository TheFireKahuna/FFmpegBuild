import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Proves that `+frag_discont` takes effect before movenc checks a packet's timestamps
/// (build.sh `patch_ffmpeg_movenc_frag_discont_before_check`,
/// patches/movenc-frag-discont-before-check.patch).
///
/// Shape: a fragmented muxer primed with one audio frame [0, 1024) so the moov is written early,
/// the primed fragment's bytes dropped, `+frag_discont` set again, and the real samples written
/// from their own timestamps. Stock movenc checks the first real packet against the end of the
/// primed frame before it reads the flag, so a packet starting inside the primed frame has its dts
/// moved past it (1025) and its pts dropped. The real samples must come back exactly as written.
struct MovencFragDiscontTests {

    static let movflags = "+empty_moov+default_base_moof+frag_custom+delay_moov+frag_discont"

    @Test("a discontinuous fragment may start inside the primed frame")
    func startsInsidePrimedFrame() throws {
        let starts: [Int64] = [0, 1024, 2048, 3072]
        let read = try Self.demux(Self.muxPrimed(realDts: starts))
        #expect(read.map(\.dts) == starts)
        #expect(read.map(\.pts) == starts)
    }

    /// Control: a discontinuous fragment that starts after the primed frame passes the check on
    /// stock builds too. A broken fixture fails here instead of reading as a fix.
    @Test("a discontinuous fragment after the primed frame keeps its timestamps")
    func startsAfterPrimedFrame() throws {
        let starts: [Int64] = [48_000, 49_024, 50_048]
        let read = try Self.demux(Self.muxPrimed(realDts: starts))
        #expect(read.map(\.dts) == starts)
        #expect(read.map(\.pts) == starts)
    }

    /// Muxes the prime and the real samples, and returns the file without the primed fragment.
    static func muxPrimed(realDts: [Int64]) throws -> [UInt8] {
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_alloc_output_context2(&ctxOut, nil, "mp4", "probe.mp4") == 0)
        let ctx = try #require(ctxOut)
        defer { avformat_free_context(ctx) }
        var pb: UnsafeMutablePointer<AVIOContext>?
        try #require(avio_open_dyn_buf(&pb) >= 0)
        let sink = try #require(pb)
        ctx.pointee.pb = sink

        let asc: [UInt8] = [0x11, 0x90] // AAC LC, 48 kHz, stereo; the payloads are never decoded
        let stream = try #require(avformat_new_stream(ctx, nil))
        let par = stream.pointee.codecpar!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_AAC
        par.pointee.sample_rate = 48_000
        par.pointee.frame_size = 1024
        av_channel_layout_default(&par.pointee.ch_layout, 2)
        let extradata = av_mallocz(asc.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))!.assumingMemoryBound(to: UInt8.self)
        extradata.update(from: asc, count: asc.count)
        par.pointee.extradata = extradata
        par.pointee.extradata_size = Int32(asc.count)
        stream.pointee.time_base = AVRational(num: 1, den: 48_000)

        var opts: OpaquePointer?
        av_dict_set(&opts, "movflags", movflags, 0)
        av_dict_set(&opts, "use_editlist", "0", 0)
        av_dict_set(&opts, "avoid_negative_ts", "disabled", 0)
        let header = avformat_write_header(ctx, &opts)
        av_dict_free(&opts)
        try #require(header >= 0)

        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        func write(dts: Int64) throws {
            let p = try #require(pkt)
            try #require(av_new_packet(p, 32) >= 0)
            memset(p.pointee.data, 0x21, 32)
            p.pointee.stream_index = 0
            p.pointee.pts = dts
            p.pointee.dts = dts
            p.pointee.duration = 1024
            p.pointee.flags = AV_PKT_FLAG_KEY
            try #require(av_interleaved_write_frame(ctx, p) >= 0)
        }

        // The prime: under delay_moov the first flush writes the moov, the second the fragment.
        try write(dts: 0)
        _ = av_interleaved_write_frame(ctx, nil)
        _ = av_write_frame(ctx, nil)
        let moovEnd = Int(avio_tell(sink))
        _ = av_write_frame(ctx, nil)
        let primeEnd = Int(avio_tell(sink))
        try #require(primeEnd > moovEnd)
        try #require(av_opt_set(ctx.pointee.priv_data, "movflags", "+frag_discont", 0) >= 0)

        for dts in realDts { try write(dts: dts) }
        _ = av_interleaved_write_frame(ctx, nil)
        _ = av_write_frame(ctx, nil)
        try #require(av_write_trailer(ctx) >= 0)

        var buf: UnsafeMutablePointer<UInt8>?
        let size = Int(avio_close_dyn_buf(sink, &buf))
        defer { av_free(buf) }
        let bytes = Array(UnsafeBufferPointer(start: buf, count: size))
        return Array(bytes[..<moovEnd] + bytes[primeEnd...])
    }

    static func demux(_ file: [UInt8]) throws -> [(dts: Int64, pts: Int64)] {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("frag-discont-\(UUID().uuidString).mp4").path
        try Data(file).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        var ctxIn: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&ctxIn, path, nil, nil) == 0)
        defer { avformat_close_input(&ctxIn) }
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        var read: [(dts: Int64, pts: Int64)] = []
        while av_read_frame(ctxIn, pkt) >= 0 {
            read.append((pkt!.pointee.dts, pkt!.pointee.pts))
            av_packet_unref(pkt)
        }
        return read
    }
}
