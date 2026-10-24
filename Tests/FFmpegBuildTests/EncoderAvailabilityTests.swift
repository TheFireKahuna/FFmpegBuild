import Testing
import AetherLibavcodec

/// Pins the encoder allowlist in `build.sh` against the shipped binaries.
///
/// FLAC and E-AC-3 drive AetherEngine's audio bridge. AAC, ALAC and the AC-3
/// encoder E-AC-3 pulls in write the silence AetherEngine appends to a
/// stream-copied track whose audio ends before its video (AetherEngine#847):
/// AVPlayer ends an item the moment its audio runs out, so the fill has to be in
/// the track's own codec. A missing encoder there does not fail anything, the
/// engine logs it and the tail is lost again, which is why it is pinned here.
struct EncoderAvailabilityTests {

    @Test("Every encoder the engine relies on is in the binary",
          arguments: ["flac", "eac3", "ac3", "aac", "alac"])
    func encoderShips(name: String) {
        #expect(avcodec_find_encoder_by_name(name) != nil, "\(name) encoder missing")
    }

    @Test("The build carries no encoder beyond the allowlist")
    func noOtherEncoders() {
        let allowed: Set<String> = ["flac", "eac3", "ac3", "aac", "alac"]
        var opaque: UnsafeMutableRawPointer?
        var found: [String] = []
        while let codec = av_codec_iterate(&opaque) {
            if av_codec_is_encoder(codec) != 0 { found.append(String(cString: codec.pointee.name)) }
        }
        #expect(Set(found).subtracting(allowed).isEmpty, "unexpected encoders: \(found.sorted())")
    }
}
