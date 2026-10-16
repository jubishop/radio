import RadioCore
import Testing

@Suite struct MatchingTests {
    func song(_ artist: String, _ title: String, album: String = "Album", explicit: Bool = false, id: String = "1") -> CatalogSong {
        CatalogSong(id: id, name: title, artistName: artist, albumName: album, url: "https://music.apple.com/us/song/x/\(id)", isExplicit: explicit)
    }

    @Test func aMissingLeadingTheStillMatches() {
        let match = chooseMatch(artist: "Postal Service", title: "Such Great Heights",
                                candidates: [song("The Postal Service", "Such Great Heights")])
        #expect(match != nil)
    }

    @Test func aSlashCreditMatchesItsFirstArtist() {
        let match = chooseMatch(artist: "Gorillaz / De La Soul", title: "Feel Good Inc.",
                                candidates: [song("Gorillaz", "Feel Good Inc.")])
        #expect(match != nil)
    }

    /// Seen 2026-10-15: each of these credits held back a song that Apple
    /// Music credits differently.
    @Test func aCreditSharingALeadArtistMatches() {
        #expect(chooseMatch(artist: "BEYONCE/JAY-Z", title: "CRAZY IN LOVE",
                            candidates: [song("Beyoncé", "Crazy in Love (feat. JAŸ-Z)")]) != nil)
        #expect(chooseMatch(artist: "Usher f/ Pitbull", title: "DJ Got Us Fallin' In Love",
                            candidates: [song("USHER", "DJ Got Us Fallin' In Love (feat. Pitbull)")]) != nil)
        #expect(chooseMatch(artist: "21 Savage, Metro Boomin, The Weeknd", title: "Creepin",
                            candidates: [song("Metro Boomin, The Weeknd & 21 Savage", "Creepin'")]) != nil)
    }

    /// Seen 2026-10-13 to 15: songs held back for a featured credit in the
    /// played title.
    @Test func aFeaturedCreditInTheTitleIsIgnored() {
        #expect(chooseMatch(artist: "Weezer", title: "We Might As Well Be Strangers Ft. Wednesday",
                            candidates: [song("Weezer", "We Might as Well Be Strangers (ft. Wednesday)")]) != nil)
        #expect(chooseMatch(artist: "Justice", title: "Flower In A Hurricane Ft. Tame Impala, Sza",
                            candidates: [song("Justice, Tame Impala, SZA & King Gizzard & The Lizard Wizard",
                                              "Flower In A Hurricane [from GTAVI]")]) != nil)
    }

    @Test func aNameWithASlashOrAmpersandStillMatchesItself() {
        #expect(chooseMatch(artist: "HUNTR/X", title: "Golden", candidates: [song("HUNTR/X", "Golden")]) != nil)
        #expect(chooseMatch(artist: "Mumford & Sons", title: "I Will Wait",
                            candidates: [song("Mumford and Sons", "I Will Wait")]) != nil)
    }

    @Test func sharingOnlyAFeaturedArtistDoesNotMatch() {
        #expect(chooseMatch(artist: "Calvin Harris feat. Rihanna", title: "Same Old Song",
                            candidates: [song("David Guetta & Rihanna", "Same Old Song")]) == nil)
    }

    @Test func ampersandAndPunctuationAreIgnored() {
        #expect(chooseMatch(artist: "Mumford & Sons", title: "I Will Wait",
                            candidates: [song("Mumford & Sons", "I Will Wait")]) != nil)
        #expect(chooseMatch(artist: "Dexter And The Moonrocks", title: "Freakin' Out",
                            candidates: [song("Dexter and The Moonrocks", "Freakin’ Out")]) != nil)
    }

    @Test func parentheticalSubtitlesAreIgnored() {
        let match = chooseMatch(artist: "My Chemical Romance", title: "Helena (So Long & Goodnight)",
                                candidates: [song("My Chemical Romance", "Helena")])
        #expect(match != nil)
    }

    @Test func explicitVersionsArePreferred() {
        let match = chooseMatch(artist: "Lola Young", title: "Messy", candidates: [
            song("Lola Young", "Messy", explicit: false, id: "clean"),
            song("Lola Young", "Messy", explicit: true, id: "explicit"),
        ])
        #expect(match?.id == "explicit")
    }

    @Test func cleanVersionIsUsedWhenNoExplicitOneExists() {
        let match = chooseMatch(artist: "Weezer", title: "Africa", candidates: [song("Weezer", "Africa", id: "only")])
        #expect(match?.id == "only")
    }

    @Test func liveRemixAndKaraokeVersionsAreRejected() {
        let candidates = [
            song("Nirvana", "Come As You Are (Live)", id: "live"),
            song("Nirvana", "Come As You Are", album: "MTV Unplugged in New York", id: "unplugged"),
            song("Nirvana", "Come As You Are - Remix", id: "remix"),
            song("Karaoke Hits", "Come As You Are", id: "karaoke"),
        ]
        #expect(chooseMatch(artist: "Nirvana", title: "Come As You Are", candidates: candidates) == nil)
    }

    /// Seen 2026-10-13: four songs matched crossfaded "(Mixed)" tracks from
    /// "(DJ Mix)" compilation albums.
    @Test func djMixVersionsAreRejected() {
        let candidates = [
            song("Florence + the Machine", "Dog Days Are Over (Mixed)", album: "Festival Mix 2022 (DJ Mix)", id: "mixed"),
            song("Nine Inch Nails", "The Hand That Feeds", album: "YOU PRIDE ME OPEN (DJ Mix)", id: "dj"),
        ]
        #expect(chooseMatch(artist: "Florence + The Machine", title: "Dog Days Are Over", candidates: candidates) == nil)
        #expect(chooseMatch(artist: "Nine Inch Nails", title: "The Hand That Feeds", candidates: candidates) == nil)
        let studio = song("Florence + the Machine", "Dog Days Are Over", album: "Lungs", id: "studio")
        #expect(chooseMatch(artist: "Florence + The Machine", title: "Dog Days Are Over", candidates: candidates + [studio])?.id == "studio")
    }

    @Test func aLiveVersionMatchesWhenTheStationPlayedOne() {
        let match = chooseMatch(artist: "Pearl Jam", title: "Last Kiss (Live)",
                                candidates: [song("Pearl Jam", "Last Kiss (Live)", id: "live")])
        #expect(match?.id == "live")
    }

    @Test func aDifferentArtistOrTitleDoesNotMatch() {
        #expect(chooseMatch(artist: "Linkin Park", title: "Numb",
                            candidates: [song("Linkin Park & Jay-Z", "Numb / Encore")]) == nil)
        #expect(chooseMatch(artist: "Iron & Wine", title: "Such Great Heights",
                            candidates: [song("The Postal Service", "Such Great Heights")]) == nil)
    }

    @Test func remasterNotesStillMatch() {
        let match = chooseMatch(artist: "Third Eye Blind", title: "Jumper",
                                candidates: [song("Third Eye Blind", "Jumper (2006 Remaster)")])
        #expect(match != nil)
    }

    @Test func songLinksYieldCatalogIDs() {
        #expect(catalogSongID(fromLink: "https://music.apple.com/us/album/savior/281024999?i=281025018") == "281025018")
        #expect(catalogSongID(fromLink: "https://music.apple.com/us/song/savior/281025018") == "281025018")
        #expect(catalogSongID(fromLink: " 281025018 ") == "281025018")
        #expect(catalogSongID(fromLink: "https://music.apple.com/us/album/appeal-to-reason/281024999") == nil)
        #expect(catalogSongID(fromLink: "https://example.com/song/1") == nil)
    }
}
