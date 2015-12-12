//
//  ViewController.m
//  GStreamer4iOS
//
//  Created by Allen Chan on 12/9/15.
//  Copyright © 2015 Allen Chan. All rights reserved.
//

#import "ViewController.h"
#include "GStreamerBackend.h"
#include "UIView+Toast.h"
#include "GSVideoView.h"

@interface ViewController (){
    GStreamerBackend *gst_backend;
    int media_width;
    int media_height;
}
@property (weak, nonatomic) IBOutlet UIButton *playButton;
@property (weak, nonatomic) IBOutlet UIButton *pauseButton;
@property (weak, nonatomic) IBOutlet GSVideoView *videoView;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.playButton setEnabled:NO];
    [self.pauseButton setEnabled:NO];
    // Do any additional setup after loading the view, typically from a nib.
    gst_backend = [[GStreamerBackend alloc]initWithDelegate:self];
    NSLog(@"GStreamer Backend = %@",[gst_backend getGStreamerVersion]);
    [gst_backend setVideoView:self.videoView];
    [gst_backend initGStreamer];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}
- (IBAction)palyAction:(id)sender {
    [gst_backend play];
}
- (IBAction)pauseAction:(id)sender {
    [gst_backend pause];
}

-(void) gstreamerInitialized
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.view makeToast:@"GStreamer Init finished"];
        [self.pauseButton setEnabled:YES];
        [self.playButton setEnabled:YES];
    });
}

-(void) gstreamerSetUIMessage:(NSString*) message
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.view makeToast:message];
    });
}

@end
