import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Proves the DTS:X height patch (build.sh `patch_ffmpeg_dca_x_heights`,
/// patches/dca-xll-x-heights.patch) is in the shipped libavcodec.
///
/// The patch adds the `dca` decoder option `x_heights`, off by default. With it the
/// decoder reads the height channel set of DTS:X's standard presentation and outputs
/// 7.1.4 (AetherEngine #798), with each height's -3 dB fold taken out of the bed speaker under
/// it. An option avcodec_open2() does not know stays in the dictionary it was handed, so a
/// build without the patch is told apart by that alone. The decode is checked on FFmpeg's FATE
/// sample `dts/dtsx_7.1.4_24bit.dts` when `FATE_SAMPLES` names a checkout of the FATE suite
/// (`rsync -aL rsync://fate-suite.ffmpeg.org/fate-suite/dts/ "$FATE_SAMPLES/dts/"`); the sample
/// is not committed here.
struct DTSXHeightsOptionTests {

    @Test("the dca decoder takes x_heights, and it is off by default")
    func optionExists() throws {
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_DTS))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        var value: Int64 = -1
        #expect(av_opt_get_int(context!.pointee.priv_data, "x_heights", 0, &value) >= 0)
        #expect(value == 0)

        var options: OpaquePointer?
        av_dict_set(&options, "x_heights", "1", 0)
        defer { av_dict_free(&options) }
        #expect(avcodec_open2(context, codec, &options) >= 0)
        #expect(av_dict_get(options, "x_heights", nil, 0) == nil, "the decoder consumed the option")
        #expect(av_opt_get_int(context!.pointee.priv_data, "x_heights", 0, &value) >= 0)
        #expect(value == 1)
    }

    @Test("the dca decoder exports x_presentation, read-only and 0 before any heights decoded")
    func presentationIsExported() throws {
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_DTS))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        #expect(avcodec_open2(context, codec, nil) >= 0)
        var value: Int64 = -1
        #expect(av_opt_get_int(context!.pointee.priv_data, "x_presentation", 0, &value) >= 0)
        #expect(value == 0)
        #expect(av_opt_set_int(context!.pointee.priv_data, "x_presentation", 1, 0) < 0, "read-only")
    }

    static let fateSample = ProcessInfo.processInfo.environment["FATE_SAMPLES"]
        .map { $0 + "/dts/dtsx_7.1.4_24bit.dts" }
        .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }

    /// Every frame's planes, by channel, for the stream decoded with or without `x_heights`.
    private static func decode(_ path: String, heights: Bool) throws -> (layout: String, frames: [[[Int32]]]) {
        var formatIn: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&formatIn, path, nil, nil) == 0)
        defer { avformat_close_input(&formatIn) }
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_DTS))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        try #require(avcodec_parameters_to_context(context, formatIn!.pointee.streams[0]!.pointee.codecpar) >= 0)
        var options: OpaquePointer?
        if heights { av_dict_set(&options, "x_heights", "1", 0) }
        defer { av_dict_free(&options) }
        try #require(avcodec_open2(context, codec, &options) >= 0)

        var packet = av_packet_alloc(), frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        var frames: [[[Int32]]] = []
        var layout = ""
        while av_read_frame(formatIn, packet) >= 0 {
            _ = avcodec_send_packet(context, packet)
            av_packet_unref(packet)
            while avcodec_receive_frame(context, frame) >= 0 {
                try #require(frame!.pointee.format == AV_SAMPLE_FMT_S32P.rawValue)
                var description = [CChar](repeating: 0, count: 64)
                _ = av_channel_layout_describe(&frame!.pointee.ch_layout, &description, description.count)
                layout = String(cString: description)
                let count = Int(frame!.pointee.nb_samples)
                frames.append((0..<Int(frame!.pointee.ch_layout.nb_channels)).map { channel in
                    let plane = UnsafeRawPointer(frame!.pointee.extended_data[channel]!).assumingMemoryBound(to: Int32.self)
                    return Array(UnsafeBufferPointer(start: plane, count: count))
                })
            }
        }
        return (layout, frames)
    }

    /// With the option the bed is the 7.1 the decoder outputs without it, less each height's fold
    /// rounded as the encoder rounded it: bed - ((height * 23170 + 0x4000) >> 15) in the 24-bit
    /// samples. The other bed channels are the same either way.
    @Test("x_heights takes each height's fold out of the bed under it", .enabled(if: fateSample != nil))
    func foldRemoved() throws {
        let path = try #require(Self.fateSample)
        let coded = try Self.decode(path, heights: false)
        let split = try Self.decode(path, heights: true)
        #expect(coded.layout == "7.1")
        #expect(split.layout == "7.1.4")
        try #require(coded.frames.count == split.frames.count && !split.frames.isEmpty)
        // 7.1.4 in native order: FL FR FC LFE BL BR SL SR TFL TFR TBL TBR. Heights fold into FL, FR, BL, BR.
        let foldOf = [0: 8, 1: 9, 4: 10, 5: 11]
        var folded = 0
        for (bed, frame) in zip(coded.frames, split.frames) {
            for channel in 0..<8 {
                guard let height = foldOf[channel] else {
                    #expect(frame[channel] == bed[channel])
                    continue
                }
                let expected = zip(bed[channel], frame[height]).map { coded, height in
                    let h24 = Int64(height >> 8)
                    return Int32((Int64(coded >> 8) - ((h24 * 23170 + 0x4000) >> 15)) << 8)
                }
                #expect(frame[channel] == expected)
                folded += zip(frame[channel], bed[channel]).filter { $0 != $1 }.count
            }
        }
        #expect(folded > 0, "the sample carries heights")
    }
}
