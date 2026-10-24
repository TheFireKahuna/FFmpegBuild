import Foundation
import Testing
import AetherLibavformat
import AetherLibavutil

/// A stream whose packets carry no timestamps is numbered by libavformat's core from 0, and records
/// that start (build.sh `patch_ffmpeg_generated_start_time`). Stock n8.1.3 leaves a WAV stream's
/// `start_time` unset, though its first packet comes out at 0: the core records a start only from a
/// container's own timestamp.
struct GeneratedStartTimeTests {

    @Test("a WAV stream states the start its first packet carries")
    func wavStartsAtZero() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("start-\(UUID().uuidString).wav")
        try Self.wav(seconds: 1).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var input: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&input, url.path, nil, nil) == 0)
        defer { avformat_close_input(&input) }
        let ctx = try #require(input)
        try #require(avformat_find_stream_info(ctx, nil) >= 0)
        let stream = try #require(ctx.pointee.streams[0])
        #expect(stream.pointee.start_time == 0)

        let packet = try #require(av_packet_alloc())
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
        try #require(av_read_frame(ctx, packet) == 0)
        #expect(packet.pointee.pts == stream.pointee.start_time, "the start is the first packet's")
    }

    /// 16-bit stereo 48 kHz PCM of `seconds` of silence, in a canonical WAV.
    static func wav(seconds: Int) -> Data {
        let rate = 48_000, channels = 2, pcm = Data(count: rate * channels * 2 * seconds)
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(rate)
        u32(rate * channels * 2); u16(channels * 2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(pcm.count); d.append(pcm)
        return d
    }
}
