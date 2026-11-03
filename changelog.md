### v0.4 (4)
* New:
  -  Option to toggle icons for the player controls. Found in Appearance settings, and by tapping the album artwork.
  - Option in playback settings to cache tracks from online sources in advance. Cached songs will appear with an icon in the queue. 
  - Hidden section under sources settings to manage hidden tracks.
  - New context menu option in the library: "SELECT" - This selects the current track, and allows you to further tap tracks or albums to select them. Selected items can be added to a playlist, or queued via the counter in the top left of the library. Selection is exited after action, when none are selected, or with "END SELECTION".
  - Artist images will now fetch the image from your online source, if available. Otherwise it defaults to their latest album.
- Modifications:
  - Added context menu options and altered existing ones for consistency. 
  - Expanding/minimizing the player while using the album blur background is smoother.
  - Play/Pause buttons now slide into position. 
  - Changed the "INFO" text in the fullscreen player to "i"
  - Cleaned up the Edit, and New Playlist sheets. "NEW" option now also in the "ADD TO PLAYLIST" sheet.
  - Search bars now consistently use the native search bar. 
  - The "SET SHUFFLE TARGET" sheet now only shows the latest plays by default.
- Fixes:
  - Accidental queue swipe triggers.
  - Losing connection while streaming may interrupt your session and not allow you to resume. This has been fixed. 
  - When more than one source is connected, It was possible to disable a source via the sources tab, and remove the other source which wouldn't allow you to re-enable the disabled source. This has been fixed so that if only a single source is remaining it is always enabled. 
