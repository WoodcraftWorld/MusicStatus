#import "NowPlayingManager.h"
#import <Cocoa/Cocoa.h>

// This private interface lets our methods talk to each other without compilation errors
@interface NowPlayingManager ()
- (void)fetchArtworkForCurrentTrackWithMusicRunning:(BOOL)musicRunning spotifyRunning:(BOOL)spotifyRunning;
@end

@implementation NowPlayingManager

- (void)startObservingNowPlaying {
    NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
    
    // Apple Music updates
    [center addObserver:self
               selector:@selector(playerInfoChanged:)
                   name:@"com.apple.Music.playerInfo"
                 object:nil];
    
    // Spotify updates
    [center addObserver:self
               selector:@selector(playerInfoChanged:)
                   name:@"com.spotify.client.PlaybackStateChanged"
                 object:nil];
    
    [self updateNowPlayingInfo];
}

- (void)playerInfoChanged:(NSNotification *)notification {
    // Whenever a track shifts, trigger a fresh evaluation loop
    [self updateNowPlayingInfo];
}

- (void)updateNowPlayingInfo {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        BOOL musicRunning = NO;
        BOOL spotifyRunning = NO;
        BOOL vlcRunning = NO;
        
        // 1. Check if VLC is active alongside the other players
        for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
            if ([app.bundleIdentifier isEqualToString:@"com.apple.Music"]) musicRunning = YES;
            if ([app.bundleIdentifier isEqualToString:@"com.spotify.client"]) spotifyRunning = YES;
            if ([app.bundleIdentifier isEqualToString:@"org.videolan.vlc"]) vlcRunning = YES;
        }
        
        __block NSString *tName = nil;
        __block NSString *aName = nil;
        __block double elapsed = 0.0;
        __block double dur = 0.0;
        BOOL success = NO;
        
        // 2. TRY APPLE MUSIC
        if (musicRunning) {
            NSAppleScript *musicScript = [[NSAppleScript alloc] initWithSource:
                                          @"tell application \"Music\"\n"
                                          @"if player state is playing or player state is paused then\n"
                                          @"get {name of current track, artist of current track, player position, duration of current track}\n"
                                          @"else\n"
                                          @"return {\"No Track Playing\", \"—\", 0.0, 0.0}\n"
                                          @"end if\n"
                                          @"end tell"];
            NSAppleEventDescriptor *descriptor = [musicScript executeAndReturnError:nil];
            
            if (descriptor && [descriptor numberOfItems] >= 4) {
                tName = [[descriptor descriptorAtIndex:1] stringValue];
                aName = [[descriptor descriptorAtIndex:2] stringValue];
                elapsed = [[descriptor descriptorAtIndex:3] doubleValue];
                dur = [[descriptor descriptorAtIndex:4] doubleValue];
                success = YES;
            }
        }
        
        // 3. TRY SPOTIFY
        if (spotifyRunning && !success) {
            NSAppleScript *spotifyScript = [[NSAppleScript alloc] initWithSource:
                                            @"tell application \"Spotify\"\n"
                                            @"if player state is playing or player state is paused then\n"
                                            @"get {name of current track, artist of current track, player position, duration of current track}\n"
                                            @"else\n"
                                            @"return {\"No Track Playing\", \"—\", 0.0, 0.0}\n"
                                            @"end if\n"
                                            @"end tell"];
            NSAppleEventDescriptor *descriptor = [spotifyScript executeAndReturnError:nil];
            
            if (descriptor && [descriptor numberOfItems] >= 4) {
                tName = [[descriptor descriptorAtIndex:1] stringValue];
                aName = [[descriptor descriptorAtIndex:2] stringValue];
                elapsed = [[descriptor descriptorAtIndex:3] doubleValue];
                dur = [[descriptor descriptorAtIndex:4] doubleValue];
                
                if (dur > 2000) {
                    elapsed = elapsed / 1000.0;
                    dur = dur / 1000.0;
                }
                success = YES;
            }
        }
        
        // 4. TRY VLC NEW FALLBACK
        if (vlcRunning && !success) {
            // VLC scripting language maps to "name of current item" and "currentTime" / "duration"
            NSAppleScript *vlcScript = [[NSAppleScript alloc] initWithSource:
                                        @"tell application \"VLC\"\n"
                                        @"if playing then\n"
                                        @"return {name of current item, \"VLC Player\", current time, duration of current item}\n"
                                        @"else\n"
                                        @"return {\"No Track Playing\", \"—\", 0.0, 0.0}\n"
                                        @"end if\n"
                                        @"end tell"];
            NSAppleEventDescriptor *descriptor = [vlcScript executeAndReturnError:nil];
            
            if (descriptor && [descriptor numberOfItems] >= 4) {
                tName = [[descriptor descriptorAtIndex:1] stringValue];
                aName = [[descriptor descriptorAtIndex:2] stringValue];
                elapsed = [[descriptor descriptorAtIndex:3] doubleValue];
                dur = [[descriptor descriptorAtIndex:4] doubleValue];
                success = YES;
            }
        }
        
        // 5. UPDATE TEXT MAIN THREAD PIPELINE
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success && tName && ![tName isEqualToString:@"No Track Playing"]) {
                self->_trackName = tName;
                self->_artistName = aName ?: @"Unknown Artist";
                self->_elapsedTime = elapsed;
                self->_duration = dur;
            } else {
                self->_trackName = @"No Track Playing";
                self->_artistName = @"—";
                self->_elapsedTime = 0.0;
                self->_duration = 0.0;
                self->_albumArt = [NSImage imageNamed:@"NoArtworkPlaceholder"];
            }
            [self notifyUI];
        });
        
        // 6. PROCESS ARTWORK WITH VLC RUNNING ARGS
        if (success && tName && ![tName isEqualToString:@"No Track Playing"]) {
            [self fetchArtworkForCurrentTrackWithMusicRunning:musicRunning
                                              spotifyRunning:spotifyRunning
                                                  vlcRunning:vlcRunning];
        }
    });
}

- (void)fetchArtworkForCurrentTrackWithMusicRunning:(BOOL)musicRunning
                                     spotifyRunning:(BOOL)spotifyRunning
                                         vlcRunning:(BOOL)vlcRunning {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __block NSImage *img = nil;
        
        // Apple Music Extraction
        if (musicRunning) {
            NSString *musicSrc = @"tell application \"Music\"\n"
                                 @"if exists (current track) and exists (artwork 1 of current track) then\n"
                                 @"return data of artwork 1 of current track\n"
                                 @"end if\n"
                                 @"return missing value\n"
                                 @"end tell";
            NSAppleScript *scr = [[NSAppleScript alloc] initWithSource:musicSrc];
            NSAppleEventDescriptor *desc = [scr executeAndReturnError:nil];
            if (desc && [desc descriptorType] != 'msng') {
                img = [[NSImage alloc] initWithData:[desc data]];
            }
        }
        
        // Spotify Extraction
        if (!img && spotifyRunning) {
            NSString *spotSrc = @"tell application \"Spotify\" to get artwork url of current track";
            NSAppleScript *scr = [[NSAppleScript alloc] initWithSource:spotSrc];
            NSAppleEventDescriptor *desc = [scr executeAndReturnError:nil];
            NSString *urlStr = [desc stringValue];
            if (urlStr && [urlStr hasPrefix:@"http"]) {
                NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlStr]];
                if (data) img = [[NSImage alloc] initWithData:data];
            }
        }
        
        // VLC Fallback Note: VLC does not store album art blocks inside its AppleScript system API.
        // It will safely cascade directly to your "NoArtworkPlaceholder" layout structure.
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_albumArt = img ?: [NSImage imageNamed:@"NoArtworkPlaceholder"];
            [self notifyUI];
        });
    });
}
- (void)notifyUI {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NowPlayingDataUpdatedNotification" object:nil];
}

- (void)dealloc {
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

@end
