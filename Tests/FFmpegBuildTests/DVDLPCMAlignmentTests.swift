import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// DVD LPCM decodes from any packet (build.sh `patch_ffmpeg_dvd_lpcm_alignment`). Its sample blocks
/// straddle packets; a decoder opened or flushed at a packet that starts mid-block used to read every
/// block from the wrong byte for as long as it ran. Now the demuxer hands on each packet's first
/// access unit pointer, and the decoder starts a fresh run at the first whole block and stamps each
/// frame at its first sample.
struct DVDLPCMAlignmentTests {

    @Test("a decode from any packet matches continuous playback at the time it states", arguments: [16, 24])
    func decodesFromAnyPacket(bits: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lpcm-\(UUID().uuidString).vob")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(url, bits: bits, seconds: 2)

        var input: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&input, url.path, nil, nil) == 0)
        defer { avformat_close_input(&input) }
        try #require(avformat_find_stream_info(input, nil) >= 0)
        let stream = try #require(input!.pointee.streams[0])
        try #require(stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_PCM_DVD)
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        defer { for p in packets { var q: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&q) } }
        while true {
            let p = try #require(av_packet_alloc())
            guard av_read_frame(input, p) == 0 else { var q: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&q); break }
            packets.append(p)
        }
        let blockBytes = bits == 16 ? 4 : 12
        #expect(packets.contains { (Int($0.pointee.size) - 3) % blockBytes != 0 },
                "the stream straddles blocks across packets, or there is nothing to test")

        let continuous = try Decoder(stream)
        var reference: [Int64: [Int32]] = [:]   // sample position -> the frame's samples, every channel
        for p in packets {
            for (position, samples) in continuous.decode(p) {
                for (i, s) in samples.enumerated() { reference[position + Int64(i)] = s }
            }
        }
        try #require(reference.count > 48_000)

        let flushed = try Decoder(stream)
        for k in stride(from: 1, to: packets.count - 4, by: 3) {
            let fresh = try Decoder(stream)
            avcodec_flush_buffers(flushed.ctx)
            for decoder in [fresh, flushed] {
                var compared = 0
                for p in packets[k..<(k + 4)] {
                    for (position, samples) in decoder.decode(p) {
                        for (i, s) in samples.enumerated() {
                            #expect(reference[position + Int64(i)] == s, "from packet \(k), sample \(position + Int64(i))")
                            compared += 1
                        }
                    }
                }
                #expect(compared > 0, "from packet \(k)")
            }
            for p in packets[(k + 4)..<min(k + 7, packets.count)] { _ = flushed.decode(p) }
        }
    }

    private final class Decoder {
        let ctx: UnsafeMutablePointer<AVCodecContext>
        let frame = av_frame_alloc()!
        init(_ stream: UnsafeMutablePointer<AVStream>) throws {
            let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_PCM_DVD))
            ctx = avcodec_alloc_context3(codec)!
            avcodec_parameters_to_context(ctx, stream.pointee.codecpar)
            ctx.pointee.pkt_timebase = stream.pointee.time_base
            try #require(avcodec_open2(ctx, codec, nil) == 0)
        }
        deinit {
            var c: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&c)
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
        }
        /// Each frame's first sample position (its pts in samples) and its samples, channels together.
        func decode(_ packet: UnsafeMutablePointer<AVPacket>) -> [(Int64, [[Int32]])] {
            var out: [(Int64, [[Int32]])] = []
            guard avcodec_send_packet(ctx, packet) >= 0 else { return out }
            while avcodec_receive_frame(ctx, frame) >= 0 {
                let f = frame.pointee
                let channels = Int(f.ch_layout.nb_channels)
                let position = av_rescale_q(f.pts, ctx.pointee.pkt_timebase, AVRational(num: 1, den: f.sample_rate))
                let samples: [[Int32]] = (0..<Int(f.nb_samples)).map { i in
                    (0..<channels).map { c in
                        f.format == AV_SAMPLE_FMT_S16.rawValue
                            ? Int32(UnsafeRawPointer(f.data.0!).assumingMemoryBound(to: Int16.self)[i * channels + c])
                            : UnsafeRawPointer(f.data.0!).assumingMemoryBound(to: Int32.self)[i * channels + c]
                    }
                }
                out.append((position, samples))
                av_frame_unref(frame)
            }
            return out
        }
    }

    /// `seconds` of stereo 48 kHz DVD LPCM at `bits` as a DVD carries it: MPEG-2 packs, each a
    /// private stream 1 PES whose payload is the LPCM substream header (frame header count, first
    /// access unit pointer, LPCM header) and 2010 bytes of samples, so blocks straddle packets. The
    /// pointer and the PTS name the first 1/600 s access unit that starts in the packet (DVD-Video).
    /// Every sample a value of its own, so a misread byte shows.
    static func write(_ url: URL, bits: Int, seconds: Int) throws {
        let frameBytes = bits == 16 ? 4 : 6
        let frames = 48_000 * seconds
        var samples = [UInt8]()
        samples.reserveCapacity(frames * frameBytes)
        func value(_ frame: Int, _ channel: Int) -> Int32 { Int32(frame * 7 % 30_000) + Int32(channel) * 1_000 }
        if bits == 16 {
            for f in 0..<frames { for c in 0..<2 { let v = UInt16(bitPattern: Int16(value(f, c))); samples += [UInt8(v >> 8), UInt8(v & 0xFF)] } }
        } else {
            // A block is two frames: the four samples' top 16 bits, then their low 8.
            for f in stride(from: 0, to: frames, by: 2) {
                let v = [value(f, 0), value(f, 1), value(f + 1, 0), value(f + 1, 1)].map { UInt32(bitPattern: $0 << 8) }
                for x in v { samples += [UInt8(x >> 24 & 0xFF), UInt8(x >> 16 & 0xFF)] }
                for x in v { samples.append(UInt8(x >> 8 & 0xFF)) }
            }
        }
        let accessUnit = 80 * frameBytes
        let payload = 2010
        var file = [UInt8]()
        var at = 0
        while at < samples.count {
            let chunk = Array(samples[at..<min(at + payload, samples.count)])
            let firstUnit = (at + accessUnit - 1) / accessUnit * accessUnit
            let hasUnit = firstUnit < at + chunk.count
            // Pack header, SCR 0, 10.08 Mbit/s.
            file += [0, 0, 1, 0xBA, 0x44, 0x00, 0x04, 0x00, 0x04, 0x01, 0x01, 0x89, 0xC3, 0xF8]
            var pes: [UInt8] = [0x81, hasUnit ? 0x80 : 0x00, hasUnit ? 5 : 0]
            if hasUnit {
                let pts = Int64(firstUnit / frameBytes) * 90_000 / 48_000
                pes += [UInt8(0x21 | (pts >> 29 & 0x0E)), UInt8(pts >> 22 & 0xFF), UInt8(pts >> 14 & 0xFE | 1),
                        UInt8(pts >> 7 & 0xFF), UInt8(pts << 1 & 0xFE | 1)]
            }
            let pointer = hasUnit ? 4 + firstUnit - at : 0
            // Substream 0xA0, one frame header, the pointer; emphasis off, frame 0; 16 or 24 bits,
            // 48 kHz, two channels; dynamic range control off.
            pes += [0xA0, 1, UInt8(pointer >> 8), UInt8(pointer & 0xFF), 0x00, (bits == 16 ? 0x00 : 0x80) | 0x01, 0x80]
            pes += chunk
            file += [0, 0, 1, 0xBD, UInt8(pes.count >> 8), UInt8(pes.count & 0xFF)] + pes
            at += chunk.count
        }
        file += [0, 0, 1, 0xB9]
        try Data(file).write(to: url)
    }
}
