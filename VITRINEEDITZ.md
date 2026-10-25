# vitrineeditz: extra features for Vitrine / spoti.pw forks

This branch is [Vitrine](https://github.com/My-Name-Is-Jeff/vitrine)'s `main` with a set of extra features on
top. Each feature is a commit of its own, and none of them touch the Premium or ad parts of the mod.

**All the changes:** [compare with Vitrine's main](https://github.com/My-Name-Is-Jeff/vitrine/compare/main...JakeGitHubAcc:vitrineeditz:share-features)

Tested on Spotify 9.1.94 under iOS 26, with Redesigned UI on.

## What's added

**Lock screen and covers**
- **Extended cover**: a lock screen style for songs without an animated artwork. The cover is shown at the screen's full width, with its edges drawn out and blurred.
- **Animated album covers**: *Animate this album's cover* in an album's ⋯ menu. The clip is made on your own computer by **Vitrine Animate** (`animate/`, see [animate/README.md](animate/README.md)). It plays on the lock screen, behind the player and at the top of the album page.
  - Text and faces stay still. People, curtains, trees, flowers, bees and clouds move as cut-out layers. Fog drifts, jewelry and other shiny things glint, and the light slowly shifts.
  - It needs a Windows PC with an NVIDIA GPU (8 GB is enough) on the same Wi-Fi as the phone.

**Local files**
- **Local Albums**: your local files grouped into albums, the way iTunes and YouTube Music show them.
  - Sort by title, artist or recently added.
  - Each album has a page laid out like Spotify's own album pages, with Play, Shuffle and Edit Info, and a type (Album, Single, EP or Compilation) picked from its ⋯.
  - Albums play from the queue, with the album's name at the top of the player.
  - Open it from the button in Your Library's header, or from **Mod Settings → Local albums**.
- **Add from Google Drive**: paste a share link to a song, a folder or a .zip.
  - FLAC, WAV and AIFF are converted to AAC 256 kbps, with their tags and cover kept.
  - MP3 and M4A are kept as they are.
  - Open it from **Mod Settings → Add from Google Drive** or the + on Local Albums.
- **Featured artists credited**: "Song (feat. A & B)" by C shows as "Song" by "C, A, B" in the player, the mini player, the lock screen and Local Albums. The files themselves aren't changed.
- **Go to Album** in the player's ⋯ menu while a local file plays.
- **Tap the artist** under a local file in the player for the same sheet a Spotify song gives: each credited artist's real Spotify page (found by name) and the song's local album.

**Fixes for Spotify 9.1.94**
- The redesigned Library header applies again (it was left as Spotify's).
- The mod finds Spotify's player again, which playing an album from the mod needs.

## Adding them to your fork

The easiest way is to merge the whole branch. The features share code, so taking only some of them is harder.

With git:

```sh
git remote add vitrineeditz https://github.com/JakeGitHubAcc/vitrineeditz.git
git fetch vitrineeditz share-features
git merge vitrineeditz/share-features
```

On GitHub, without git: open this link with your own name and fork in it, and create the pull request into your fork:

```
https://github.com/YOUR-NAME/YOUR-FORK/compare/main...JakeGitHubAcc:vitrineeditz:share-features
```

If your fork isn't based on Vitrine's recent `main`, expect a few conflicts. Each commit says what it changes and why.

Then build the IPA the way your fork does. For Vitrine, that's the **Build IPA from your own Spotify IPA** workflow under Actions.

## Credits

Built on [Vitrine](https://github.com/My-Name-Is-Jeff/vitrine) and spoti.pw. Written with Claude Code.
