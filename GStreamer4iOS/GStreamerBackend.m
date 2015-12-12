//
//  GStreamerBackend.m
//  GStreamer4iOS
//
//  Created by Allen Chan on 12/11/15.
//  Copyright © 2015 Allen Chan. All rights reserved.
//

#import "GStreamerBackend.h"
#include <gst/gst.h>
#include <gst/video/videooverlay.h>


GST_DEBUG_CATEGORY_STATIC (debug_category);
#define GST_CAT_DEFAULT debug_category


@implementation GStreamerBackend{
    id<GStreamBackendDelegate> ui_delegate;
    GstElement* pipeline;
    GstElement* video_sink; /* the video connect this from GStreamer to UIView window handler */
    GMainContext * main_context;
    GMainLoop* main_loop;
    gboolean initialized;
    
    UIView *video_view; /* UIView that holds the video */
}

-(id)initWithDelegate:(id<GStreamBackendDelegate>)delegate
{
    if(self = [super init])
    {
        self->ui_delegate = delegate;
        
        GST_DEBUG_CATEGORY_INIT(debug_category, "allen", 0, "ios");
        gst_debug_set_threshold_for_name("allen", GST_LEVEL_DEBUG);
        gst_debug_set_default_threshold(GST_LEVEL_WARNING);
        
//        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
//            [self main_for_video];
//        });
    }
    return self;
}

-(void)initGStreamer
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self main_for_video];
    });
}

-(void)dealloc
{
    if(pipeline){
        GST_DEBUG("dealloc to pipeline");
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
        pipeline = NULL;
    }
}

-(void) setVideoView:(UIView*)_videoView
{
    self->video_view = _videoView;
}

-(NSString*) getGStreamerVersion
{
    gchar* version_utf8 = gst_version_string();
    NSString* version_string = [NSString stringWithUTF8String:version_utf8];
    g_free(version_utf8);
    return version_string;
}

-(void)play
{
    if(gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE)
    {
        [self setUIMessage:"Failed to set pipeline to playing !"];
    }
}

-(void)pause
{
    if(gst_element_set_state(pipeline, GST_STATE_PAUSED) == GST_STATE_CHANGE_FAILURE)
    {
        [self setUIMessage:"Failed to set pipeline to paused !"];
    }
}

static void error_cb (GstBus *bus, GstMessage *msg, GStreamerBackend *self)
{
    GError * err;
    gchar* debug_info;
    gchar* message_string;
    
    gst_message_parse_error(msg, &err, &debug_info);
    message_string = g_strdup_printf("ERROR: received from element - %s:%s",GST_OBJECT_NAME(msg->src),err->message);
    g_clear_error(&err);
    g_free(debug_info);
    
    [self setUIMessage:message_string];
    g_free(message_string);
    gst_element_set_state(self->pipeline, GST_STATE_NULL);
}

/* Notify the UI about pipeline status has changes */
static void state_changed_cb (GstBus *bus, GstMessage *msg, GStreamerBackend *self)
{
    GstState old_state, new_state, pending_state;
    gst_message_parse_state_changed(msg, &old_state, &new_state, &pending_state);
    /* Only pay attention to messages coming from the popeline , not its children */
    if(GST_MESSAGE_SRC(msg) == GST_OBJECT(self->pipeline)){
        gchar* message = g_strdup_printf("State changed to %s",gst_element_state_get_name(new_state));
        [self setUIMessage:message];
        g_free(message);
    }
}

-(void)setUIMessage:(gchar*) message
{
    NSString* message_string = [NSString stringWithUTF8String:message];
    NSLog(@"[Allen]: %@",message_string);
    if(ui_delegate && [ui_delegate respondsToSelector:@selector(gstreamerSetUIMessage:)])
    {
        [ui_delegate gstreamerSetUIMessage:message_string];
    }
}

-(void) check_initialization_complete
{
    if(!initialized && main_loop){
        GST_DEBUG("Initialization complete, notifying application.");
        if(ui_delegate && [ui_delegate respondsToSelector:@selector(gstreamerInitialized)]){
            [ui_delegate gstreamerInitialized];
        }
        initialized = TRUE;
    }
}
-(void)main_for_video
{
    GstBus* bus;
    GSource* bus_source;
    GError* error = NULL;
    
    if(!self->video_view)
    {
        gchar* message = g_strdup_printf("the video View didnt ready !!");
        [self setUIMessage:message];
        g_free(message);
        return;
    }
    
    GST_DEBUG("creating Pipeline");
    
    /*Create our own GLib Main Context and make it the default one */
    main_context = g_main_context_new();
    g_main_context_push_thread_default(main_context);
    
    
    /*Build up pipeline*/
//    pipeline = gst_parse_launch("videotestsrc ! warptv ! ffmpegcolorspace ! autovideosink", &error);
    pipeline = gst_parse_launch("videotestsrc ! glimagesink", &error);
    if(error)
    {
        //error
        gchar* message  = g_strdup_printf("Unable to build pipeline : %s",error->message);
        g_clear_error(&error);
        //        self call back to UI
        [self setUIMessage:message];
        g_free(message);
        return;
    }
    
    /* Set the pipeline to READY, so it can already accept a window handle */
    gst_element_set_state(pipeline, GST_STATE_READY);
    
    /* Setup the video view */
    video_sink = gst_bin_get_by_interface(GST_BIN(pipeline), GST_TYPE_VIDEO_OVERLAY);
    if(!video_sink){
        GST_ERROR("Count not retrieve video sink");
        return;
    }
    gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(video_sink), (guintptr)(id)video_view);
    
    /* Instruct the bus to emit signals for each received message , and connect to the interesting signals */
    bus = gst_element_get_bus(pipeline);
    bus_source = gst_bus_create_watch(bus);
    g_source_set_callback(bus_source, (GSourceFunc)gst_bus_async_signal_func, NULL, NULL);
    g_source_attach(bus_source, main_context);
    g_source_unref(bus_source);
    
    g_signal_connect(G_OBJECT(bus), "message::error", (GCallback)error_cb, (__bridge void*)self);
    g_signal_connect(G_OBJECT(bus), "message::state-changed", (GCallback)state_changed_cb, (__bridge void*)self);
    gst_object_unref(bus);
    
    
    /* Create a GLib Main Loop and set it to run */
    GST_DEBUG("ENtering main loop...");
    main_loop = g_main_loop_new(main_context, FALSE);
    //    self check initialized complete status
    [self check_initialization_complete];
    g_main_loop_run(main_loop);
    GST_DEBUG("Exited main loop");
    g_main_loop_unref(main_loop);
    main_loop = NULL;
    
    /* Free all of the temp resource */
    g_main_context_pop_thread_default(main_context);
    g_main_context_unref(main_context);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    
    return;

}

-(void)main_for_audio
{
    GstBus* bus;
    GSource* bus_source;
    GError* error = NULL;
    
    GST_DEBUG("creating Pipeline");
    
    /*Create our own GLib Main Context and make it the default one */
    main_context = g_main_context_new();
    g_main_context_push_thread_default(main_context);
    
    
    /*Build up pipeline*/
    pipeline = gst_parse_launch("audiotestsrc ! audioconvert ! audioresample ! autoaudiosink", &error);
    if(error)
    {
        //error
        gchar* message  = g_strdup_printf("Unable to build pipeline : %s",error->message);
        g_clear_error(&error);
//        self call back to UI
        [self setUIMessage:message];
        g_free(message);
        return;
    }
    
    /* Instruct the bus to emit signals for each received message , and connect to the interesting signals */
    bus = gst_element_get_bus(pipeline);
    bus_source = gst_bus_create_watch(bus);
    g_source_set_callback(bus_source, (GSourceFunc)gst_bus_async_signal_func, NULL, NULL);
    g_source_attach(bus_source, main_context);
    g_source_unref(bus_source);
    
    g_signal_connect(G_OBJECT(bus), "message::error", (GCallback)error_cb, (__bridge void*)self);
    g_signal_connect(G_OBJECT(bus), "message::state-changed", (GCallback)state_changed_cb, (__bridge void*)self);
    gst_object_unref(bus);
    
    
    /* Create a GLib Main Loop and set it to run */
    GST_DEBUG("ENtering main loop...");
    main_loop = g_main_loop_new(main_context, FALSE);
//    self check initialized complete status
    [self check_initialization_complete];
    g_main_loop_run(main_loop);
    GST_DEBUG("Exited main loop");
    g_main_loop_unref(main_loop);
    main_loop = NULL;
    
    /* Free all of the temp resource */
    g_main_context_pop_thread_default(main_context);
    g_main_context_unref(main_context);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    
    return;
}
@end
