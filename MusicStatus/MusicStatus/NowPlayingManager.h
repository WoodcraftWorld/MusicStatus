//
//  NowPlayingManager.h
//  MusicStatus
//
//  Created by max on 16/05/2026.
//


#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>

@interface NowPlayingManager : NSObject

// Properties to hold the song metadata
@property (nonatomic, strong, readonly) NSString *trackName;
@property (nonatomic, strong, readonly) NSString *artistName;
@property (nonatomic, strong, readonly) NSImage *albumArt;
@property (nonatomic, assign, readonly) NSTimeInterval duration;
@property (nonatomic, assign, readonly) NSTimeInterval elapsedTime;

- (void)startObservingNowPlaying;

@end