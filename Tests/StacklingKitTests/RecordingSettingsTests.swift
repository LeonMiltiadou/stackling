import AVFoundation
import Testing
@testable import StacklingKit

@Suite struct RecordingSettingsTests {
    @Test func h264UpTo4K() {
        #expect(RecordingSettings.codec(width: 3840, height: 2160) == .h264)
        #expect(RecordingSettings.codec(width: 4096, height: 2304) == .h264)
    }

    @Test func hevcForBiggerDisplays() {
        #expect(RecordingSettings.codec(width: 5120, height: 2880) == .hevc)
        #expect(RecordingSettings.codec(width: 2000, height: 2400) == .hevc)
    }

    @Test func bitRateHasAFloor() {
        #expect(RecordingSettings.bitRate(width: 100, height: 100) == 2_000_000)
        #expect(RecordingSettings.bitRate(width: 1920, height: 1080) == 1920 * 1080 * 4)
    }

    @Test func pixelSizeIsEven() {
        let size = RecordingSettings.evenPixelSize(points: CGSize(width: 300.5, height: 201), scale: 2)
        #expect(size.width == 600 && size.height == 402)
        let odd = RecordingSettings.evenPixelSize(points: CGSize(width: 301, height: 201), scale: 1)
        #expect(odd.width == 300 && odd.height == 200)
    }

    @Test func longClipsGetFewerGIFFrames() {
        #expect(GIFMaker.fps(forDuration: 10) == 12)
        #expect(GIFMaker.fps(forDuration: 30) == 12)
        #expect(GIFMaker.fps(forDuration: 31) == 8)
    }
}
