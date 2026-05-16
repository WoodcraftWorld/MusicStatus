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
        
        for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
            if ([app.bundleIdentifier isEqualToString:@"com.apple.Music"]) musicRunning = YES;
            if ([app.bundleIdentifier isEqualToString:@"com.spotify.client"]) spotifyRunning = YES;
        }
        
        __block NSString *tName = nil;
        __block NSString *aName = nil;
        __block double elapsed = 0.0;
        __block double dur = 0.0;
        BOOL success = NO;
        
        // 1. EVALUATE APPLE MUSIC
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
        
        // 2. EVALUATE SPOTIFY FALLBACK
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
        
        // 3. BROADCAST TEXT METADATA
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
                self->_albumArt = [NSImage imageNamed:NSImageNameTouchBarAudioInputTemplate];
            }
            [self notifyUI];
        });
        
        // 4. TRIGGER DECOUPLED ARTWORK DOWNLOAD
        if (success && tName && ![tName isEqualToString:@"No Track Playing"]) {
            [self fetchArtworkForCurrentTrackWithMusicRunning:musicRunning spotifyRunning:spotifyRunning];
        }
    });
}

- (void)fetchArtworkForCurrentTrackWithMusicRunning:(BOOL)musicRunning spotifyRunning:(BOOL)spotifyRunning {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __block NSImage *img = nil;
        
        if (musicRunning) {
            // We tell AppleScript to export the artwork data explicitly as a raw PICT/JPEG payload
            NSString *musicSrc = @"tell application \"Music\"\n"
                                 @"if exists (current track) then\n"
                                 @"tell current track\n"
                                 @"if exists (artwork 1) then\n"
                                 @"set rawData to data of artwork 1\n"
                                 @"return rawData\n"
                                 @"end if\n"
                                 @"end tell\n"
                                 @"end if\n"
                                 @"return missing value\n"
                                 @"end tell";
            
            NSAppleScript *scr = [[NSAppleScript alloc] initWithSource:musicSrc];
            NSAppleEventDescriptor *desc = [scr executeAndReturnError:nil];
            
            if (desc && [desc descriptorType] != 'msng') {
                // Get the raw byte data from the Apple Event descriptor
                NSData *rawData = [desc data];
                
                if (rawData && rawData.length > 0) {
                    // Modern Apple Music embeds raw JPEG/PNG data inside an NSAppleEventDescriptor container.
                    // If regular initialization fails, we strip the Apple Event descriptor header bytes.
                    img = [[NSImage alloc] initWithData:rawData];
                    
                    if (!img && rawData.length > 512) {
                        // Fallback: Strip potential legacy AppleScript data type headers (frequently 512 bytes)
                        NSData *strippedData = [rawData subdataWithRange:NSMakeRange(512, rawData.length - 512)];
                        img = [[NSImage alloc] initWithData:strippedData];
                    }
                }
            }
        }
        
        // --- SPOTIFY FALLBACK ---
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
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Update the image view on the main thread
            if (img) {
                self->_albumArt = img;
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
