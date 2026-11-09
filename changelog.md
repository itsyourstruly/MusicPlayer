### v0.4 (10)
* New:
  -  Within the Appearance settings, new option to toggle album backgrounds to: match the Album Color, Album Blur, or keep the Solid color from the set theme.
  - Also in the Appearance settings, expand the 'HOME PAGE' section to reorder, toggle existing sections, and add library tabs. 
  - New option in Sources settings 'Merge Albums.' Depending on source and organization, you may have a duplicate album, or tracks separated into different albums, or singles. LAP will now find when an album you open has the identical name, and artist as another, and offer to merge them. When albums are merged, you can tap the album artwork inside the album page to use the artwork from any of the merged albums. Long press on an artwork to use its release year alongside another cover. 
  - New 'Hide Duplicates' option for online sources, which will automatically hide duplicate tracks found in Albums. Automatically hidden tracks show up in Settings->Sources->Hidden, separate from manually hidden tracks. Local sources are still able to scan for duplicates using the "Find Track Tags" option.
  - Long press a tab (Artists, Albums, or Playlists) on the Library page to adjust the amount of columns.
  - Add your own separators for artists in Settings->Sources->Artist Separators. This only affects local sources. 
  - Disable CAPITALIZATION thoughout the app in Settings->Appearance.
- Modifications:
  - In albums, the tracklist no longer shows the album artwork, and has been replaced by the track #, or '-' if missing.
  - In Sources settings, clear options now match the set theme to show they can be selected. Added option for merges to undo all merges. It will now only show options to clear what it's actually using. 
  - For the Sources settings, if both Local, and Online sources are added, the Online sources will appear at the top, with the related options below. Local sources will show up below the Online options, with their related options. This change was made to differentiate source options easier. 
  - Source settings starts empty until you add a source.
  - In Appearance settings, 'USE PROGRESS BAR' now defaults to ON.
  - In album view, tapping the MERGED pill now displays merged albums with an UNMERGE option. Tapping unmerges the album without automatically closing the sheet. Unmerging is instantaneous, and unmerged albums can still be manually merged at any time from the music note menu.
  - When merging albums automatically, the selected album's artwork is preserved instead of selecting an artwork arbitrarily. Tapping the album artwork in a merged album directly opens an artwork picker sheet displaying all available covers in a 2-column grid with their release years.
  - When in library selection mode, the top-left selected items counter now matches the app's theme color.
- Fixes:
  - When changing local folder organization, the library would not rebuild after saving and rescanning. This has been fixed. Saving a change will now apply the changes immediately. 
  - Merging duplicate albums now reliably matches split releases and edition variations where tracks had differing featured artist or suffix metadata (such as single tracks split off from full albums).
  - The waveform timeline in the fullscreen player was buggy, and did not move smoothly. This has been fixed. 

### v0.4 (8)
* New:
  -  Option to toggle icons for the player controls. Found in Appearance settings, and by tapping the album artwork.
  - Option in playback settings to cache tracks from online sources in advance. Cached songs will appear with an icon in the queue. 
  - Hidden section under sources settings to manage hidden tracks.
  - New context menu option in the library: 'SELECT' - This selects the current track, and allows you to further tap tracks or albums to select them. Selected items can be added to a playlist, or queued via the counter in the top left of the library. Selection is exited after action, when none are selected, or with 'END SELECTION'.
  - Artist images will now fetch the image from your online source, if available. Otherwise it defaults to their latest album.
- Modifications:
  - Added context menu options and altered existing ones for consistency. 
  - Expanding/minimizing the player while using the album blur background is smoother.
  - Play/Pause buttons now slide into position. 
  - Changed the 'INFO' text in the fullscreen player to 'i'
  - Cleaned up the Edit, and New Playlist sheets. 'NEW' option now also in the 'ADD TO PLAYLIST' sheet.
  - Search bars now consistently use the native search bar. 
  - The 'SET SHUFFLE TARGET' sheet now only shows the latest plays by default.
- Fixes:
  - Accidental queue swipe triggers.
  - Losing connection while streaming may interrupt your session and not allow you to resume. This has been fixed. 
  - When more than one source is connected, It was possible to disable a source via the sources tab, and remove the other source which wouldn't allow you to re-enable the disabled source. This has been fixed so that if only a single source is remaining it is always enabled. 
