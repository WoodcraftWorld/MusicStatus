#import "NowPlayingManager.h"
#import <Cocoa/Cocoa.h>

@interface NowPlayingManager ()
- (void)fetchArtworkWithMusicRunning:(BOOL)musicRunning spotifyRunning:(BOOL)spotifyRunning vlcRunning:(BOOL)vlcRunning;
@end

@implementation NowPlayingManager {
    NSTimer *_pollingTimer;
}

- (void)startObservingNowPlaying {
    // 1. Listen for instant push notifications from Apple Music and Spotify
    NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(playerInfoChanged:) name:@"com.apple.Music.playerInfo" object:nil];
    [center addObserver:self selector:@selector(playerInfoChanged:) name:@"com.spotify.client.PlaybackStateChanged" object:nil];
    
    // 2. CRITICAL FOR VLC: Start a 1-second background poll timer.
    // This catches VLC track changes instantly and keeps the progress bar perfectly fluid!
    _pollingTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                     target:self
                                                   selector:@selector(updateNowPlayingInfo)
                                                   userInfo:nil
                                                    repeats:YES];
    
    [self updateNowPlayingInfo];
}

- (void)playerInfoChanged:(NSNotification *)notification {
    [self updateNowPlayingInfo];
}

- (void)updateNowPlayingInfo {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        BOOL musicRunning = NO;
        BOOL spotifyRunning = NO;
        BOOL vlcRunning = NO;
        
        for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
            if ([app.bundleIdentifier isEqualToString:@"com.apple.Music"]) musicRunning = YES;
            if ([app.bundleIdentifier isEqualToString:@"com.spotify.client"]) spotifyRunning = YES;
            if ([app.bundleIdentifier isEqualToString:@"org.videolan.vlc"]) vlcRunning = YES;
        }
        
        __block NSString *tName = nil;
        __block NSString *aName = nil;
        __block double elapsed = 0.0;
        __block double dur = 0.0;
        __block NSString *vlcPath = nil; // Tracks VLC's file path for local artwork lookups
        BOOL success = NO;
        
        // 1. APPLE MUSIC EVALUATION
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
                if (tName && ![tName isEqualToString:@"No Track Playing"]) success = YES;
            }
        }
        
        // 2. SPOTIFY EVALUATION
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
                if (dur > 2000) { elapsed /= 1000.0; dur /= 1000.0; }
                if (tName && ![tName isEqualToString:@"No Track Playing"]) success = YES;
            }
        }
        
        // 3. VLC EVALUATION (WITH DYNAMIC STRING PARSING)
        if (vlcRunning && !success) {
            // We also ask VLC for the raw path of the current item to trace local artwork files!
            NSAppleScript *vlcScript = [[NSAppleScript alloc] initWithSource:
                                        @"tell application \"VLC\"\n"
                                        @"if playing then\n"
                                        @"return {name of current item, current time, duration of current item, path of current item}\n"
                                        @"else\n"
                                        @"return {\"No Track Playing\", 0.0, 0.0, \"\"}\n"
                                        @"end if\n"
                                        @"end tell"];
            NSAppleEventDescriptor *descriptor = [vlcScript executeAndReturnError:nil];
            if (descriptor && [descriptor numberOfItems] >= 4) {
                NSString *rawVlcTitle = [[descriptor descriptorAtIndex:1] stringValue];
                elapsed = [[descriptor descriptorAtIndex:2] doubleValue];
                dur = [[descriptor descriptorAtIndex:3] doubleValue];
                vlcPath = [[descriptor descriptorAtIndex:4] stringValue];
                
                if (rawVlcTitle && ![rawVlcTitle isEqualToString:@"No Track Playing"]) {
                    // Smart String Splitter: Look for the classic " - " divider separator
                    if ([rawVlcTitle containsString:@" - "]) {
                        NSArray *components = [rawVlcTitle componentsSeparatedByString:@" - "];
                        aName = [components firstObject];
                        
                        // Recombine the rest of the string just in case the track name contains a hyphen too
                        NSMutableArray *trackComponents = [components mutableCopy];
                        [trackComponents removeObjectAtIndex:0];
                        tName = [trackComponents componentsJoinedByString:@" - "];
                        
                        // Clean up file extensions if VLC is displaying the raw file name (.mp3, .m4a, etc)
                        tName = [tName stringByDeletingPathExtension];
                    } else {
                        tName = [rawVlcTitle stringByDeletingPathExtension];
                        aName = @"VLC Player";
                    }
                    success = YES;
                }
            }
        }
        
        // 4. MAIN THREAD UI BROADCAST
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL trackChanged = ![tName isEqualToString:self->_trackName];
            
            if (success && tName) {
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
            
            if (success && trackChanged) {
                [self fetchArtworkWithMusicRunning:musicRunning
                                    spotifyRunning:spotifyRunning
                                        vlcRunning:vlcRunning
                                           vlcPath:vlcPath];
            }
        });
    });
}

- (void)fetchArtworkWithMusicRunning:(BOOL)musicRunning
                      spotifyRunning:(BOOL)spotifyRunning
                          vlcRunning:(BOOL)vlcRunning
                             vlcPath:(NSString *)vlcPath {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __block NSImage *img = nil;
        
        // APPLE MUSIC EXTRACTION
        if (musicRunning) {
            NSString *musicSrc = @"tell application \"Music\"\n"
                                 @"if exists (current track) then\n"
                                 @"tell current track\n"
                                 @"if exists (artwork 1) then\n"
                                 @"return data of artwork 1\n"
                                 @"end if\n"
                                 @"end tell\n"
                                 @"end if\n"
                                 @"return missing value\n"
                                 @"end tell";
            NSAppleScript *scr = [[NSAppleScript alloc] initWithSource:musicSrc];
            NSAppleEventDescriptor *desc = [scr executeAndReturnError:nil];
            if (desc && [desc descriptorType] != 'msng') {
                NSData *rawData = [desc data];
                if (rawData && rawData.length > 0) {
                    img = [[NSImage alloc] initWithData:rawData];
                    if (!img && rawData.length > 512) {
                        NSData *strippedData = [rawData subdataWithRange:NSMakeRange(512, rawData.length - 512)];
                        img = [[NSImage alloc] initWithData:strippedData];
                    }
                }
            }
        }
        
        // SPOTIFY EXTRACTION
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
        
        // SMART VLC ARTWORK EXTRACTION (LOCAL FILE COVERS)
        if (!img && vlcRunning && vlcPath && vlcPath.length > 0) {
            NSURL *fileURL = [NSURL fileURLWithPath:vlcPath];
            NSURL *directoryURL = [fileURL URLByDeletingLastPathComponent];
            NSURL *fileURLNoExtension = [fileURL URLByDeletingPathExtension];
            NSString *fileNameNoExtension = [fileURLNoExtension lastPathComponent];
            NSString *jpegExtension = @".jpg";
            NSString *albumArtJpegFile = [fileNameNoExtension stringByAppendingString:jpegExtension];
            // Traditional album art names stored alongside local media tracks
            NSArray *artworkNames = @[@"cover.jpg", @"cover.png", @"album.jpg", @"folder.jpg", @"Folder.jpg", albumArtJpegFile];
            
            for (NSString *artName in artworkNames) {
                NSURL *artURL = [directoryURL URLByAppendingPathComponent:artName];
                if ([[NSFileManager defaultManager] fileExistsAtPath:artURL.path]) {
                    img = [[NSImage alloc] initWithContentsOfURL:artURL];
                    if (img) break;
                }
            }
        }
        
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
    [_pollingTimer invalidate];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

@end
