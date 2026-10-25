import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil

/// Proves the colour patches are in the shipped libavcodec: every sequence header or SPS states its own colour
/// (build.sh `patch_ffmpeg_libdav1d_colour`, `patch_ffmpeg_h264_colour`), and the alternative transfer
/// characteristics SEI lasts one coded video sequence and crosses frame threads
/// (`patch_ffmpeg_alternative_transfer`).
///
/// Each stream is two runs of six 64x64 frames with an IDR (a key frame) at the start of each: x264, x265 and
/// SVT-AV1. Upstream labels the second run with the first run's colour (H.264, AV1) or keeps the first run's HLG
/// (the SEI is in the first run only).
struct ColourPerSequenceTests {

    struct Colour: Equatable {
        var primaries: AVColorPrimaries
        var transfer: AVColorTransferCharacteristic
        var matrix: AVColorSpace
        var range: AVColorRange
    }

    /// The access units of an Annex B stream with one slice per picture: a picture starts at its first non-VCL
    /// NAL after a VCL one, or at a second VCL NAL.
    static func accessUnits(_ data: Data, isVCL: (UInt8) -> Bool) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
        }
        var units: [[UInt8]] = [], unit: [UInt8] = [], hasVCL = false
        for (k, start) in starts.enumerated() {
            var end = k + 1 < starts.count ? starts[k + 1] - 3 : bytes.count
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            let vcl = isVCL(bytes[start])
            if hasVCL { units.append(unit); unit = []; hasVCL = false }
            unit += [0, 0, 0, 1] + bytes[start..<end]
            hasVCL = vcl
        }
        if !unit.isEmpty { units.append(unit) }
        return units
    }

    /// AV1 low-overhead (Section 5) temporal units: each starts at a temporal delimiter OBU.
    static func temporalUnits(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var units: [[UInt8]] = [], start = 0, i = 0
        while i < bytes.count {
            let header = bytes[i]
            if (header >> 3) & 0xF == 2, i > start { units.append(Array(bytes[start..<i])); start = i }
            i += 1 + (header & 0x4 != 0 ? 1 : 0)
            var size = 0, shift = 0
            while i < bytes.count { let b = bytes[i]; i += 1; size |= Int(b & 0x7F) << shift; shift += 7; if b & 0x80 == 0 { break } }
            i += size
        }
        units.append(Array(bytes[start...]))
        return units
    }

    static func decode(_ decoder: String, _ units: [[UInt8]], threads: Int32 = 1) throws -> [Colour] {
        let codec = try #require(avcodec_find_decoder_by_name(decoder))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        let ctx = try #require(context)
        ctx.pointee.thread_count = threads
        ctx.pointee.thread_type = FF_THREAD_FRAME
        try #require(avcodec_open2(ctx, codec, nil) >= 0)
        var packet = av_packet_alloc(), frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        var out: [Colour] = []
        func drain() {
            while avcodec_receive_frame(ctx, frame) >= 0 {
                out.append(Colour(primaries: frame!.pointee.color_primaries, transfer: frame!.pointee.color_trc,
                                  matrix: frame!.pointee.colorspace, range: frame!.pointee.color_range))
                av_frame_unref(frame)
            }
        }
        for unit in units {
            try #require(av_new_packet(packet, Int32(unit.count)) >= 0)
            unit.withUnsafeBytes { _ = memcpy(packet!.pointee.data, $0.baseAddress!, unit.count) }
            _ = avcodec_send_packet(ctx, packet)
            av_packet_unref(packet)
            drain()
        }
        _ = avcodec_send_packet(ctx, nil)
        drain()
        return out
    }

    static func h264VCL(_ header: UInt8) -> Bool { [1, 5].contains(header & 0x1F) }
    static func hevcVCL(_ header: UInt8) -> Bool { (header >> 1) & 0x3F < 32 }

    @Test("H.264: an SPS without a colour description is unspecified, not the previous SPS's colour", arguments: [Int32(1), 4])
    func h264ColourPerSPS(threads: Int32) throws {
        let frames = try Self.decode("h264", Self.accessUnits(try #require(Data(base64Encoded: Self.h264TwoSPS)), isVCL: Self.h264VCL),
                                     threads: threads)
        try #require(frames.count == 12)
        let bt709 = Colour(primaries: AVCOL_PRI_BT709, transfer: AVCOL_TRC_BT709, matrix: AVCOL_SPC_BT709, range: AVCOL_RANGE_MPEG)
        let unspecified = Colour(primaries: AVCOL_PRI_UNSPECIFIED, transfer: AVCOL_TRC_UNSPECIFIED, matrix: AVCOL_SPC_UNSPECIFIED,
                                 range: AVCOL_RANGE_UNSPECIFIED)
        #expect(Array(frames[0..<6]) == Array(repeating: bt709, count: 6))
        #expect(Array(frames[6...]) == Array(repeating: unspecified, count: 6))
    }

    @Test("AV1: a sequence header without a colour description is unspecified, not the previous header's colour")
    func av1ColourPerSequenceHeader() throws {
        let frames = try Self.decode("libdav1d", Self.temporalUnits(try #require(Data(base64Encoded: Self.av1TwoSequenceHeaders))))
        try #require(frames.count == 12)
        #expect(frames[0..<6].allSatisfy { $0.primaries == AVCOL_PRI_BT709 && $0.transfer == AVCOL_TRC_BT709 && $0.matrix == AVCOL_SPC_BT709 })
        #expect(frames[6...].allSatisfy { $0.primaries == AVCOL_PRI_UNSPECIFIED && $0.transfer == AVCOL_TRC_UNSPECIFIED
                                          && $0.matrix == AVCOL_SPC_UNSPECIFIED })
    }

    @Test("HEVC: the alternative transfer SEI lasts its coded video sequence, the next IDR without it goes back to the SPS's")
    func hevcAlternativeTransfer() throws {
        let frames = try Self.decode("hevc", Self.accessUnits(try #require(Data(base64Encoded: Self.hevcAlternativeTransfer)),
                                                              isVCL: Self.hevcVCL))
        try #require(frames.count == 12)
        #expect(frames[0..<6].allSatisfy { $0.transfer == AVCOL_TRC_ARIB_STD_B67 }, "\(frames.map(\.transfer.rawValue))")
        #expect(frames[6...].allSatisfy { $0.transfer == AVCOL_TRC_BT2020_10 }, "\(frames.map(\.transfer.rawValue))")
    }

    @Test("H.264: the alternative transfer SEI lasts its coded video sequence, on every frame thread", arguments: [Int32(1), 4])
    func h264AlternativeTransfer(threads: Int32) throws {
        let frames = try Self.decode("h264", Self.accessUnits(try #require(Data(base64Encoded: Self.h264AlternativeTransfer)),
                                                              isVCL: Self.h264VCL), threads: threads)
        try #require(frames.count == 12)
        #expect(frames[0..<6].allSatisfy { $0.transfer == AVCOL_TRC_ARIB_STD_B67 }, "\(frames.map(\.transfer.rawValue))")
        #expect(frames[6...].allSatisfy { $0.transfer == AVCOL_TRC_BT2020_10 }, "\(frames.map(\.transfer.rawValue))")
    }

    // x264 (SEI removed), tagged BT.709 then untagged.
    static let h264TwoSPS =
        "AAAAAWdkAAqs2UQmwFqAgICgAAADACAAAAZB4kSywAAAAAFo6+PLIsAAAAFliIQAN//+9vD+A0JQlxHN6Hz9AAVXa9rh4i//" +
        "VGEAAAABQZokbEL//ozTYAAAAAFBnkJ4hf8JuQAAAAEBnmF0Qr8MOAAAAAEBnmNqQr8MOQAAAAFBmmVJqEFomUwIV//+OI3B" +
        "AAAAAWdkAAqs2UQmwEQAAAMABAAAAwDIPEiWWAAAAAFo6+PLIsAAAAFliIQAN//+9vD+A0JQlxHN6Hz9AAVXa9rh4i//VGEA" +
        "AAABQZokbEL//ozTYAAAAAFBnkJ4hf8JuQAAAAEBnmF0Qr8MOAAAAAEBnmNqQr8MOQAAAAFBmmVJqEFomUwIV//+OI3B"
    // SVT-AV1, BT.709 then no colour description.
    static let av1TwoSequenceHeaders =
        "EgAKDgIAAAVVf/xq+ZAQEBBAMg4QAK4CBRQggQAACACQwBIAMhEoBABAAAAdjAAAAgAADACcEDIRKAICAAAknYwAAAEAAAYA" +
        "m3AyETADAAABDDsYAAACAAAMAJZAEgAaAcgSADIRMAYAEEhJOxgAAAIAAAwAlkASABoBmBIAMhEwCgAEEkk7GAAAAgAAAACX" +
        "wBIACgsCAAAFVX/8avmAQDIOEACuAgUUIIEAAAgAkMASADIRKAQAQAAAHYwAAAIAAAwAnBAyESgCAgAAJJ2MAAABAAAGAJtw" +
        "MhEwAwAAAQw7GAAAAgAADACWQBIAGgHIEgAyETAGABBISTsYAAACAAAMAJZAEgAaAZgSADIRMAoABBJJOxgAAAIAAAAAl8A="
    // x265, BT.2020 / BT.2020 10-bit: the first run with an alternative transfer SEI naming HLG at its IDR.
    static let hevcAlternativeTransfer =
        "AAAAAUABDAH//wIgAAADAJAAAAMAAAMAHpWYCQAAAAFCAQECIAAAAwCQAAADAAADAB6gIIEE2WVmkkyvAWoSHBIIAAADAAgA" +
        "AAMAyEAAAAABRAHBcrQiQAAAAAFOAZMBEoAAAAABKAGvHYD3AjV/WrcJUcAAAAABAgHQKUvhDGOQ+oQAAAABAgHgZJ14YSTF" +
        "YAAAAAEAAeAk9V+iwpjIIAAAAAEAAeBE11+iwojIIAAAAAEAAeCGt/1GFMDIIAAAAAFAAQwB//8CIAAAAwCQAAADAAADAB6V" +
        "mAkAAAABQgEBAiAAAAMAkAAAAwAAAwAeoCCBBNllZpJMrwFqEhwSCAAAAwAIAAADAMhAAAAAAUQBwXK0IkAAAAEoAa8dgPcC" +
        "NX9atwlRwAAAAAECAdApS+EMY5D6hAAAAAECAeBknXhhJMVgAAAAAQAB4CT1X6LCmMggAAAAAQAB4ETXX6LCiMggAAAAAQAB" +
        "4Ia3/UYUwMgg"
    // x264 10-bit, the same.
    static let h264AlternativeTransfer =
        "AAAAAWduAAqmzZRCbAWoSHBKAAADAAIAAAMAZB4kSywAAAABaOvjyyLAAAAAAQaTARKAAAAAAWWIhAAR//73iB8yjnK13IR5" +
        "6xU/UYjGW1z52a6GKd8AAAABQZokbEP//qmdNAAAAAFBnkJ4h/8ExQAAAAEBnmF0Q78FvAAAAAEBnmNqQ78FvQAAAAFBmmU0" +
        "tEwEO//+qZ01AAAAAWduAAqmzZRCbAWoSHBKAAADAAIAAAMAZB4kSywAAAABaOvjyyLAAAABZYiEABH//veIHzKOcrXchHnr" +
        "FT9RiMZbXPnZroYp3wAAAAFBmiRsQ//+qZ00AAAAAUGeQniH/wTFAAAAAQGeYXRDvwW8AAAAAQGeY2pDvwW9AAAAAUGaZTS0" +
        "TAQ7//6pnTU="
}
