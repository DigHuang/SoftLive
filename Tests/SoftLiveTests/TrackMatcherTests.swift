import Foundation
import Testing
@testable import SoftLive

struct TrackMatcherTests {
    private let track = Track(
        id: "1", title: "Viva La Vida (Remastered 2011)", artist: "Coldplay", album: "", duration: 242, source: .appleMusic
    )

    @Test func normalizesDecorationsCaseAndWidth() {
        #expect(TrackMatcher.normalize("Viva La Vida - 2011 Remaster") == "vivalavida")
        #expect(TrackMatcher.normalize("ＨＥＬＬＯ（Live）") == "hello")
        #expect(TrackMatcher.normalize("Song feat. Someone") == "song")
    }

    @Test func prefersExactTitleArtistAndDuration() {
        let candidates = [
            SongCandidate(title: "Viva La Vida", artists: ["Cover Band"], duration: 242),
            SongCandidate(title: "Viva La Vida", artists: ["Coldplay"], duration: 300),
            SongCandidate(title: "Viva La Vida", artists: ["Coldplay"], duration: 243),
        ]
        let best = TrackMatcher.best(candidates, for: track) { $0 }
        #expect(best?.artists == ["Coldplay"])
        #expect(best?.duration == 243)
    }

    @Test func rejectsDifferentSongs() {
        #expect(TrackMatcher.score(SongCandidate(title: "Yellow", artists: ["Coldplay"], duration: 242), for: track) == nil)
    }

    @Test func buildsCleanSearchKeyword() {
        #expect(TrackMatcher.searchKeyword(for: track) == "Viva La Vida Coldplay")
    }
}
