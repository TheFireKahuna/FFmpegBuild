import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Proves a fragment flush survives a queued packet that lies behind the samples
/// already written for its track (build.sh `patch_ffmpeg_movenc_fragment_end`).
///
/// Shape: the last sample of one fragment declares a duration far past the next
/// sample. movenc places the next fragment's first sample at that declared end and
/// check_pkt() clamps the ones after it, so the written dts run ahead of the real
/// ones. A second stream holds one more packet of the track in the interleaver, and
/// av_write_frame(NULL) flushes without draining it. Stock n8.1.3 takes that packet's
/// real dts as the track end and aborts in get_cluster_duration() with
/// "Assertion next_dts >= 0 failed" (StreamX crash 2026-10-10, through AetherEngine's
/// MP4SegmentMuxer, which uses the same movflags).
struct MovencFragmentEndTests {

    @Test("a flush with a queued packet behind clamped samples does not abort")
    func queuedPacketBehindClampedSamples() async {
        await #expect(processExitsWith: .success) {
            #expect(MovencFragmentEndTests.muxOvershootThenFlush(drainFirst: false) > 0)
        }
    }

    /// Control: the same fixture, drained before the flush, never reaches the queued-packet path
    /// and muxes on stock builds too. A broken fixture fails here instead of reading as a fix.
    @Test("the same fixture drained before the flush muxes")
    func drainedControl() {
        #expect(Self.muxOvershootThenFlush(drainFirst: true) > 0)
    }

    /// Returns the number of bytes muxed, or a negative step number on failure.
    static func muxOvershootThenFlush(drainFirst: Bool) -> Int {
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&ctxOut, nil, "mp4", "probe.mp4") == 0,
              let ctx = ctxOut else { return -1 }
        defer { avformat_free_context(ctx) }

        var pb: UnsafeMutablePointer<AVIOContext>?
        guard avio_open_dyn_buf(&pb) >= 0, let sink = pb else { return -2 }
        ctx.pointee.pb = sink

        // AudioSpecificConfig: AAC LC, 48 kHz, stereo. The payloads are never parsed.
        let asc: [UInt8] = [0x11, 0x90]
        for _ in 0..<2 {
            guard let stream = avformat_new_stream(ctx, nil) else { return -3 }
            let par = stream.pointee.codecpar!
            par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
            par.pointee.codec_id = AV_CODEC_ID_AAC
            par.pointee.sample_rate = 48_000
            par.pointee.frame_size = 1024
            av_channel_layout_default(&par.pointee.ch_layout, 2)
            let extradata = av_mallocz(asc.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))!
                .assumingMemoryBound(to: UInt8.self)
            extradata.update(from: asc, count: asc.count)
            par.pointee.extradata = extradata
            par.pointee.extradata_size = Int32(asc.count)
            stream.pointee.time_base = AVRational(num: 1, den: 48_000)
        }

        var opts: OpaquePointer?
        av_dict_set(&opts, "movflags", "+empty_moov+default_base_moof+frag_custom+delay_moov+frag_discont", 0)
        let header = avformat_write_header(ctx, &opts)
        av_dict_free(&opts)
        guard header >= 0 else { return -4 }

        guard let pkt = av_packet_alloc() else { return -5 }
        var pktRef: UnsafeMutablePointer<AVPacket>? = pkt
        defer { av_packet_free(&pktRef) }
        func write(stream: Int32, dts: Int64, duration: Int64) -> Bool {
            guard av_new_packet(pkt, 32) >= 0 else { return false }
            memset(pkt.pointee.data, 0x21, 32)
            pkt.pointee.stream_index = stream
            pkt.pointee.pts = dts
            pkt.pointee.dts = dts
            pkt.pointee.duration = duration
            pkt.pointee.flags = AV_PKT_FLAG_KEY
            return av_interleaved_write_frame(ctx, pkt) >= 0
        }

        // Fragment 1: the last sample of stream 0 declares ten frames.
        guard write(stream: 1, dts: 0, duration: 1024),
              write(stream: 0, dts: 0, duration: 1024),
              write(stream: 0, dts: 1024, duration: 1024),
              write(stream: 0, dts: 2048, duration: 10 * 1024),
              write(stream: 1, dts: 2560, duration: 1024) else { return -6 }
        _ = av_interleaved_write_frame(ctx, nil)
        _ = av_write_frame(ctx, nil)
        _ = av_write_frame(ctx, nil)

        // Fragment 2: four samples below the declared end, all clamped past it. The
        // stream 1 packet releases them; the last stream 0 packet then stays queued.
        for i in 3...6 {
            guard write(stream: 0, dts: Int64(i) * 1024, duration: 1024) else { return -7 }
        }
        guard write(stream: 1, dts: 6656, duration: 1024),
              write(stream: 0, dts: 7168, duration: 1024) else { return -8 }
        if drainFirst { _ = av_interleaved_write_frame(ctx, nil) }
        _ = av_write_frame(ctx, nil)
        _ = av_write_trailer(ctx)

        var buf: UnsafeMutablePointer<UInt8>?
        let size = Int(avio_close_dyn_buf(sink, &buf))
        av_free(buf)
        return size
    }
}
