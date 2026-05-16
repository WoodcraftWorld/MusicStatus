#import "AppDelegate.h"
#import "NowPlayingManager.h"

@interface AppDelegate ()

// Add your outlets here so the XIB can see them
@property (weak) IBOutlet NSWindow *window; // Already there by default
@property (weak) IBOutlet NSImageView *albumArtImageView;
@property (weak) IBOutlet NSTextField *trackNameLabel;
@property (weak) IBOutlet NSTextField *artistLabel;
@property (weak) IBOutlet NSProgressIndicator *trackProgressBar;
@property (weak) IBOutlet NSTextField *timeRemainingLabel;

@end

@implementation AppDelegate {
    NowPlayingManager *_nowPlayingManager;
    NSTimer *_progressTimer;
    NSTimeInterval _currentLiveElapsed;
    
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Initialize the media manager
    _nowPlayingManager = [[NowPlayingManager alloc] init];
    
    // Listen for data updates from the manager
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateUIFromManager)
                                                 name:@"NowPlayingDataUpdatedNotification"
                                               object:nil];
    
    [_nowPlayingManager startObservingNowPlaying];
}

- (void)updateUIFromManager {
    // Update text fields and artwork
    self.trackNameLabel.stringValue = _nowPlayingManager.trackName;
    self.artistLabel.stringValue = _nowPlayingManager.artistName;
    self.albumArtImageView.image = _nowPlayingManager.albumArt;
    
    // Configure progress bar limits
    self.trackProgressBar.minValue = 0.0;
    self.trackProgressBar.maxValue = _nowPlayingManager.duration;
    
    // Sync our live tracking timer variable
    _currentLiveElapsed = _nowPlayingManager.elapsedTime;
    self.trackProgressBar.doubleValue = _currentLiveElapsed;
    
    [self updateTimeLabel];
    
    // Handle the smooth progress timer tracking
    [_progressTimer invalidate]; // Reset any existing timer
    _progressTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(tickProgress)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)tickProgress {
    if (_currentLiveElapsed < _nowPlayingManager.duration) {
        _currentLiveElapsed += 1.0;
        self.trackProgressBar.doubleValue = _currentLiveElapsed;
        [self updateTimeLabel];
    }
}

- (void)updateTimeLabel {
    int elapsedMin = (int)_currentLiveElapsed / 60;
    int elapsedSec = (int)_currentLiveElapsed % 60;
    
    int durationMin = (int)_nowPlayingManager.duration / 60;
    int durationSec = (int)_nowPlayingManager.duration % 60;
    
    self.timeRemainingLabel.stringValue = [NSString stringWithFormat:@"%d:%02d / %d:%02d",
                                           elapsedMin, elapsedSec,
                                           durationMin, durationSec];
}

- (void)dealloc {
    [_progressTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


@end
