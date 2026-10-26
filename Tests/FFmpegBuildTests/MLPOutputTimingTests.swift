import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil

/// Proves the TrueHD output timing patch (build.sh `patch_ffmpeg_mlp_output_timing`,
/// patches/mlp-output-timing.patch) is in the shipped libavcodec.
///
/// Every TrueHD restart header (one per major sync) states output_timing, the frame its access unit
/// plays at, modulo 2^16. Upstream's decoder reads past it; with the patch the access unit's frame
/// carries it as the metadata entry `mlp_output_timing`, and frames whose unit has no restart header
/// carry nothing. The sample is 48 access units of a 48 kHz stereo sine from FFmpeg's own TrueHD
/// encoder, whose clock starts at 0 and steps 40 frames a unit, with a major sync every 16 units.
struct MLPOutputTimingTests {

    @Test("each frame whose access unit restates the clock carries its output_timing; the rest carry none")
    func outputTimingOnFrames() throws {
        let data = try #require(Data(base64Encoded: Self.sample, options: .ignoreUnknownCharacters))
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_TRUEHD))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        try #require(avcodec_open2(context, codec, nil) >= 0)
        let parser = try #require(av_parser_init(Int32(AV_CODEC_ID_TRUEHD.rawValue)))
        defer { av_parser_close(parser) }
        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }

        var timings: [Int: Int] = [:]
        var frames = 0
        func drain() {
            while avcodec_receive_frame(context, frame) >= 0 {
                if let entry = av_dict_get(frame!.pointee.metadata, "mlp_output_timing", nil, 0) {
                    timings[frames] = Int(String(cString: entry.pointee.value))
                }
                frames += 1
                av_frame_unref(frame)
            }
        }
        data.withUnsafeBytes { raw in
            var cursor = raw.bindMemory(to: UInt8.self).baseAddress!
            var remaining = Int32(raw.count)
            // A final empty call flushes the unit the parser holds.
            while true {
                var out: UnsafeMutablePointer<UInt8>?
                var outSize: Int32 = 0
                let used = av_parser_parse2(parser, context, &out, &outSize, remaining > 0 ? cursor : nil, remaining,
                                            Int64.min, Int64.min, 0)
                if let out, outSize > 0 {
                    packet!.pointee.data = out
                    packet!.pointee.size = outSize
                    if avcodec_send_packet(context, packet) >= 0 { drain() }
                    packet!.pointee.data = nil
                    packet!.pointee.size = 0
                }
                if remaining == 0 { break }
                cursor += Int(used)
                remaining -= used
            }
        }
        #expect(frames == 48)
        #expect(timings == [0: 0, 16: 640, 32: 1280])
    }

    /// 48 access units: `ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=0.04" -ac 2
    /// -c:a truehd -strict -2 -f truehd`, then `base64 -b 100`.
    static let sample = """
        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
        """
}
