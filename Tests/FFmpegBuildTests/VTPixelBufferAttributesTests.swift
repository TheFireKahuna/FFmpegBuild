import CoreVideo
import Testing
import AetherLibavfilter
import AetherLibavutil

/// Proves the VideoToolbox frames context patch (build.sh
/// `patch_ffmpeg_vt_pixel_buffer_attributes`, patches/videotoolbox-pixel-buffer-attributes.patch)
/// is in the shipped libavutil and libavfilter.
///
/// `AVVTFramesContext.pixel_buffer_attributes` carries extra CVPixelBuffer attributes into
/// the frames context's pool, and yadif_videotoolbox makes its output pictures with the
/// attributes of its input, so a caller can display them as they come. The attribute
/// measured is `kCVPixelBufferExtendedPixelsRightKey`, which a picture reports back through
/// CVPixelBufferGetExtendedPixels; nothing upstream sets it.
struct VTPixelBufferAttributesTests {

    private static let extendedRight = 32
    private static let width: Int32 = 128, height: Int32 = 72

    private static func framesContext(_ format: AVPixelFormat, attributes: Bool)
        throws -> UnsafeMutablePointer<AVBufferRef> {
        var device: UnsafeMutablePointer<AVBufferRef>?
        try #require(av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0)
        defer { av_buffer_unref(&device) }
        let ref = try #require(av_hwframe_ctx_alloc(device))
        let frames = ref.pointee.data.withMemoryRebound(to: AVHWFramesContext.self, capacity: 1) { $0 }
        frames.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX
        frames.pointee.sw_format = format
        frames.pointee.width = width
        frames.pointee.height = height
        if attributes {
            let vt = frames.pointee.hwctx.assumingMemoryBound(to: AVVTFramesContext.self)
            let dictionary = [kCVPixelBufferExtendedPixelsRightKey: extendedRight] as CFDictionary
            vt.pointee.pixel_buffer_attributes = Unmanaged.passRetained(dictionary)
        }
        guard av_hwframe_ctx_init(ref) >= 0 else {
            var unref: UnsafeMutablePointer<AVBufferRef>? = ref
            av_buffer_unref(&unref)
            throw CancellationError()
        }
        return ref
    }

    private static func extendedPixelsRight(_ frame: UnsafePointer<AVFrame>) -> Int {
        guard let raw = frame.pointee.data.3 else { return -1 }
        let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
        var left = 0, right = 0, top = 0, bottom = 0
        CVPixelBufferGetExtendedPixels(buffer, &left, &right, &top, &bottom)
        return right
    }

    @Test("the frames context's pictures carry the caller's attributes")
    func poolTakesAttributes() throws {
        var frames: UnsafeMutablePointer<AVBufferRef>? = try Self.framesContext(AV_PIX_FMT_NV12, attributes: true)
        defer { av_buffer_unref(&frames) }
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        try #require(av_hwframe_get_buffer(frames, frame, 0) >= 0)
        #expect(Self.extendedPixelsRight(frame!) == Self.extendedRight)
        let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(frame!.pointee.data.3!)).takeUnretainedValue()
        #expect(CVPixelBufferGetWidth(buffer) == Int(Self.width), "width still comes from the frames context")
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil, "the IOSurface properties are still set")
    }

    /// A buffer source -> yadif_videotoolbox -> buffer sink graph over `frames`.
    private static func yadifGraph(_ frames: UnsafeMutablePointer<AVBufferRef>)
        throws -> (graph: UnsafeMutablePointer<AVFilterGraph>, source: UnsafeMutablePointer<AVFilterContext>,
                   sink: UnsafeMutablePointer<AVFilterContext>, configured: Int32) {
        let graph = try #require(avfilter_graph_alloc())
        var yadif: UnsafeMutablePointer<AVFilterContext>?
        var sink: UnsafeMutablePointer<AVFilterContext>?
        // A hardware format needs its frames context before the buffer source initialises.
        let source = try #require(avfilter_graph_alloc_filter(graph, avfilter_get_by_name("buffer"), "in"))
        let parameters = try #require(av_buffersrc_parameters_alloc())
        parameters.pointee.format = Int32(AV_PIX_FMT_VIDEOTOOLBOX.rawValue)
        parameters.pointee.width = width
        parameters.pointee.height = height
        parameters.pointee.time_base = AVRational(num: 1, den: 24)
        parameters.pointee.sample_aspect_ratio = AVRational(num: 1, den: 1)
        parameters.pointee.hw_frames_ctx = frames
        try #require(av_buffersrc_parameters_set(source, parameters) >= 0)
        av_free(parameters)
        try #require(avfilter_init_str(source, nil) >= 0)
        try #require(avfilter_graph_create_filter(&yadif, avfilter_get_by_name("yadif_videotoolbox"), "yadif", nil, nil, graph) >= 0)
        try #require(avfilter_graph_create_filter(&sink, avfilter_get_by_name("buffersink"), "out", nil, nil, graph) >= 0)
        try #require(avfilter_link(source, 0, yadif, 0) >= 0)
        try #require(avfilter_link(yadif, 0, sink, 0) >= 0)
        return (graph, source, sink!, avfilter_graph_config(graph, nil))
    }

    @Test("yadif_videotoolbox makes its output pictures with its input's attributes")
    func yadifOutputTakesAttributes() throws {
        var frames: UnsafeMutablePointer<AVBufferRef>? = try Self.framesContext(AV_PIX_FMT_NV12, attributes: true)
        defer { av_buffer_unref(&frames) }
        let built = try Self.yadifGraph(frames!)
        var graph: UnsafeMutablePointer<AVFilterGraph>? = built.graph
        defer { avfilter_graph_free(&graph) }
        try #require(built.configured >= 0)

        var output = av_frame_alloc()
        defer { av_frame_free(&output) }
        var got = false
        for pts in 0..<4 {
            var frame = av_frame_alloc()
            try #require(av_hwframe_get_buffer(frames, frame, 0) >= 0)
            frame!.pointee.pts = Int64(pts)
            frame!.pointee.flags |= AV_FRAME_FLAG_INTERLACED | AV_FRAME_FLAG_TOP_FIELD_FIRST
            try #require(av_buffersrc_add_frame(built.source, frame) >= 0)
            av_frame_free(&frame)
            if av_buffersink_get_frame(built.sink, output) >= 0 { got = true; break }
        }
        try #require(got, "yadif put out a picture")
        #expect(Self.extendedPixelsRight(output!) == Self.extendedRight)
    }

    @Test("yadif_videotoolbox refuses a format it cannot texture when it configures")
    func yadifRefusesBGRA() throws {
        var frames: UnsafeMutablePointer<AVBufferRef>? = try Self.framesContext(AV_PIX_FMT_BGRA, attributes: false)
        defer { av_buffer_unref(&frames) }
        let built = try Self.yadifGraph(frames!)
        var graph: UnsafeMutablePointer<AVFilterGraph>? = built.graph
        defer { avfilter_graph_free(&graph) }
        // Stock FFmpeg configures, then logs "Unsupported pixel format" for every frame.
        #expect(built.configured == -78)  // AVERROR(ENOSYS) on Darwin
    }
}
