//
//  GSVideoView.m
//  GStreamer4iOS
//
//  Created by Allen Chan on 12/12/15.
//  Copyright © 2015 Allen Chan. All rights reserved.
//

#import "GSVideoView.h"
#import <QuartzCore/QuartzCore.h>

@implementation GSVideoView

/*
// Only override drawRect: if you perform custom drawing.
// An empty implementation adversely affects performance during animation.
- (void)drawRect:(CGRect)rect {
    // Drawing code
}
*/
+ (Class) layerClass
{
    return [CAEAGLLayer class];
}


@end
