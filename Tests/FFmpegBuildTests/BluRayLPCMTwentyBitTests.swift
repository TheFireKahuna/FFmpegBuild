import Testing
import AetherLibavcodec
import AetherLibavutil

/// Blu-ray LPCM at 20 bits per sample decodes (build.sh `patch_ffmpeg_bluray_20bit`). Stock n8.1.3
/// reads the depth off the header and then refuses 20 by name, so such a track never produced a frame.
struct BluRayLPCMTwentyBitTests {

    @Test("a 20-bit Blu-ray LPCM packet decodes to its samples, stated as 20-bit")
    func twentyBitDecodes() throws {
        // Header: payload size, stereo (3) at 48 kHz (1), 20 bits (2); then four stereo frames of
        // 20-bit samples in 24-bit words, big-endian, the low four bits clear.
        let values: [Int32] = [1 << 12, -(1 << 12), 300_000 << 4, -(300_000 << 4), 16, -16, 0, 524_287 << 4]
        var packet: [UInt8] = [0, UInt8(values.count * 3), 3 << 4 | 1, 2 << 6]
        for v in values {
            let w = UInt32(bitPattern: v)
            packet += [UInt8(w >> 16 & 0xFF), UInt8(w >> 8 & 0xFF), UInt8(w & 0xFF)]
        }

        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_PCM_BLURAY))
        var ctx = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&ctx) }
        let c = try #require(ctx)
        try #require(avcodec_open2(c, codec, nil) == 0)
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        try #require(av_new_packet(pkt, Int32(packet.count)) == 0)
        pkt!.pointee.data.update(from: packet, count: packet.count)
        #expect(avcodec_send_packet(c, pkt) == 0)
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        #expect(avcodec_receive_frame(c, frame) == 0)

        #expect(c.pointee.bits_per_coded_sample == 20)
        #expect(c.pointee.bits_per_raw_sample == 20)
        #expect(frame!.pointee.format == AV_SAMPLE_FMT_S32.rawValue)
        #expect(frame!.pointee.nb_samples == 4)
        let out = UnsafeRawPointer(frame!.pointee.data.0!).assumingMemoryBound(to: Int32.self)
        #expect((0..<values.count).map { out[$0] >> 8 } == values.map { ($0 << 8) >> 8 })
    }
}
