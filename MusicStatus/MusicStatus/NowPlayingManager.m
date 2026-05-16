#import "NowPlayingManager.h"

@implementation NowPlayingManager

- (void)startObservingNowPlaying {
    // 1. Listen for standard Apple Player notification broadcasts
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
    
    // Trigger an initial manual state pull
    [self updateNowPlayingInfo];
}

- (void)playerInfoChanged:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    if (!userInfo) return;
    
    // Map tracking properties based on which player broadcasted
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([notification.name containsString:@"Music"]) {
            // Apple Music payload format
            self->_trackName = userInfo[@"Name"] ?: @"Unknown Title";
            self->_artistName = userInfo[@"Artist"] ?: @"Unknown Artist";
            
            NSNumber *durationNum = userInfo[@"Total Time"]; // given in milliseconds
            self->_duration = durationNum ? ([durationNum doubleValue] / 1000.0) : 0.0;
        } else {
            // Spotify payload format
            self->_trackName = userInfo[@"Track"] ?: @"Unknown Title";
            self->_artistName = userInfo[@"Artist"] ?: @"Unknown Artist";
            
            NSNumber *durationNum = userInfo[@"Duration"]; // given in milliseconds
            self->_duration = durationNum ? ([durationNum doubleValue] / 1000.0) : 0.0;
        }
        
        // Reset local timer state offset back to zero on track modifications
        self->_elapsedTime = 0.0;
        
        // Fetch artwork using our script fallbacks
        [self fetchArtworkForCurrentTrack];
    });
}

- (void)updateNowPlayingInfo {
    // Run this on a background thread so the UI never pinwheels
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        BOOL musicRunning = NO;
        BOOL spotifyRunning = NO;
        
        // Fast, non-blocking check to see what is actually open
        for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
            if ([app.bundleIdentifier isEqualToString:@"com.apple.Music"]) musicRunning = YES;
            if ([app.bundleIdentifier isEqualToString:@"com.spotify.client"]) spotifyRunning = YES;
        }
        
        NSAppleEventDescriptor *descriptor = nil;
        BOOL dataLoaded = NO;
        
        // 1. Check Apple Music if running
        if (musicRunning) {
            NSAppleScript *musicScript = [[NSAppleScript alloc] initWithSource:
                                          @"tell application \"Music\" to get {name of current track, artist of current track, player position, duration of current track}"];
            descriptor = [musicScript executeAndReturnError:nil];
            
            if (descriptor && [descriptor numberOfItems] >= 4) {
                NSString *tName = [[descriptor descriptorAtIndex:1] stringValue] ?: @"Unknown Title";
                NSString *aName = [[descriptor descriptorAtIndex:2] stringValue] ?: @"Unknown Artist";
                double elapsed = [[descriptor descriptorAtIndex:3] doubleValue];
                double dur = [[descriptor descriptorAtIndex:4] doubleValue];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_trackName = tName;
                    self->_artistName = aName;
                    self->_elapsedTime = elapsed;
                    self->_duration = dur;
                });
                dataLoaded = YES;
            }
        }
        
        // 2. Check Spotify if running and Music wasn't active
        if (spotifyRunning && !dataLoaded) {
            NSAppleScript *spotifyScript = [[NSAppleScript alloc] initWithSource:
                                            @"tell application \"Spotify\" to get {name of current track, artist of current track, player position, duration of current track}"];
            descriptor = [spotifyScript executeAndReturnError:nil];
            
            if (descriptor && [descriptor numberOfItems] >= 4) {
                NSString *tName = [[descriptor descriptorAtIndex:1] stringValue] ?: @"Unknown Title";
                NSString *aName = [[descriptor descriptorAtIndex:2] stringValue] ?: @"Unknown Artist";
                double elapsed = [[descriptor descriptorAtIndex:3] doubleValue] / 1000.0;
                double dur = [[descriptor descriptorAtIndex:4] doubleValue] / 1000.0;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_trackName = tName;
                    self->_artistName = aName;
                    self->_elapsedTime = elapsed;
                    self->_duration = dur;
                });
                dataLoaded = YES;
            }
        }
        
        // 3. Update UI based on results
        if (dataLoaded) {
            [self fetchArtworkForCurrentTrack];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_trackName = @"No Track Playing";
                self->_artistName = @"—";
                self->_duration = 0.0;
                self->_elapsedTime = 0.0;
                self->_albumArt = [NSImage imageNamed:NSImageNameTouchBarAudioInputTemplate];
                [self notifyUI];
            });
        }
    });
}

- (void)fetchArtworkForCurrentTrack {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *scriptSource = @"if application \"Music\" is running then\n"
                                 @"tell application \"Music\"\n"
                                 @"if exists (current track) then\n"
                                 @"tell current track to get raw data of artwork 1\n"
                                 @"end if\n"
                                 @"end tell\n"
                                 @"end if";
        
        NSAppleScript *artworkScript = [[NSAppleScript alloc] initWithSource:scriptSource];
        NSAppleEventDescriptor *descriptor = [artworkScript executeAndReturnError:nil];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (descriptor && [descriptor data]) {
                self->_albumArt = [[NSImage alloc] initWithData:[descriptor data]];
            } else {
                self->_albumArt = [NSImage imageNamed:NSImageNameTouchBarAudioInputTemplate];
            }
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
