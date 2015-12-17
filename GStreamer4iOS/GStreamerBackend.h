//
//  GStreamerBackend.h
//  GStreamer4iOS
//
//  Created by Allen Chan on 12/11/15.
//  Copyright © 2015 Allen Chan. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
@protocol GStreamBackendDelegate <NSObject>

-(void) gstreamerInitialized;
-(void) gstreamerSetUIMessage:(NSString*) message;
-(void) setCurrentPosition:(NSInteger)position duration:(NSInteger)duration;
-(void) mediaSizeChanged:(NSInteger)width height:(NSInteger)height;

@end

@interface GStreamerBackend : NSObject

-(id)initWithDelegate:(id<GStreamBackendDelegate>)delegate;
-(void)initGStreamer;
-(void)stopGStreamer;
-(void) setVideoView:(UIView*)_videoView;
-(NSString*) getGStreamerVersion;

-(void)setMediaURI:(NSString*)uri;
-(void) play;
-(void) pause;

@end
