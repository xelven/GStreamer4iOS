//
//  GStreamerBackend.m
//  GStreamer4iOS
//
//  Created by Allen Chan on 12/11/15.
//  Copyright © 2015 Allen Chan. All rights reserved.
//

#import "GStreamerBackend.h"
#include <gst/gst.h>
#include <gst/video/video.h>
#include <gst/video/videooverlay.h>


GST_DEBUG_CATEGORY_STATIC (debug_category);
#define GST_CAT_DEFAULT debug_category


/*
 Do not allow seeks to be performed closer than this distance.
 It is visually useless,
 and probably will confuse some demuxers.
 */
#define SEEK_MIN_DELAY (500 * GST_MSECOND)

@implementation GStreamerBackend{
    id<GStreamBackendDelegate> ui_delegate;
    GstElement* pipeline;
    GstElement* video_sink; /* the video connect this from GStreamer to UIView window handler */
    GMainContext * main_context;
    GMainLoop* main_loop;
    gboolean initialized;
    
    UIView *video_view; /* UIView that holds the video */
    
    GstState target_state;  // Desired pipeline state, to be set once buffering is complete
    GstState current_state; // the Current pipeline state
    gboolean is_live;       // Live streams do not use buffering.
    gint64 duration;        // Cached clip duration
    GstClockTime last_seek_time; // For seeking overflow prevention (throttling)
    gint64 desired_position;    // Position to seek to, once the pipeline is running
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
        [self main_for_stream_video];
    });
}
-(void)stopGStreamer
{
    
}

-(void)setMediaURI:(NSString*)uri
{
    const gchar* uri_string = [uri UTF8String];
    if(self->pipeline){
        g_object_set(self->pipeline, "uri",uri_string, NULL);
        GST_DEBUG("URI set to %s",uri_string);
    }
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
    target_state = GST_STATE_PLAYING;
    is_live = (gst_element_set_state(self->pipeline, GST_STATE_PLAYING)==GST_STATE_CHANGE_NO_PREROLL);
//    if(gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE)
//    {
//        [self setUIMessage:"Failed to set pipeline to playing !"];
//    }
}

-(void)pause
{
    target_state = GST_STATE_PAUSED;
    is_live = (gst_element_set_state(self->pipeline, GST_STATE_PAUSED)==GST_STATE_CHANGE_NO_PREROLL);
//    if(gst_element_set_state(pipeline, GST_STATE_PAUSED) == GST_STATE_CHANGE_FAILURE)
//    {
//        [self setUIMessage:"Failed to set pipeline to paused !"];
//    }
}

/*
 Retrieve the video sink's Caps and tell the application about the media size.
 */
static void check_media_size(GStreamerBackend* self)
{
    GstElement* video_sink;
    GstPad* video_sink_pad;
    GstCaps *video_caps;
    GstVideoFormat video_fmt;
    GstVideoInfo video_info;
    int width;
    int heidht;
    
    /* Retrueve the Caps at the entrance of the video sink */
    g_object_set(self->pipeline, "video-sink",&video_sink, NULL);
    
    /* Do nothing if there is no video sink, may be audio only clip */
    if(!video_sink)
        return;
    
    video_sink_pad = gst_element_get_static_pad(video_sink, "sink");
    video_caps = gst_pad_get_current_caps(video_sink_pad);
    
    if(gst_video_info_from_caps(&video_info,video_caps)){
        int par_n, par_d;
        width = video_info.width;
        heidht = video_info.height;
        /* didnt use fps or pixel aspect into but handy to have */
        par_n = video_info.par_n;
        par_d = video_info.par_d;
        video_fmt = video_info.finfo->format;
        
        NSLog(@"the video format:%d, width:%d, height:%d, par_n:%d, par_d:%d",video_fmt,width,heidht,par_n,par_d);
        
        if(self->ui_delegate && [self->ui_delegate respondsToSelector:@selector(mediaSizeChanged:height:)]){
            [self->ui_delegate mediaSizeChanged:width height:heidht];
        }
    }
    
    gst_caps_unref(video_caps);
    gst_object_unref(video_sink_pad);
    gst_object_unref(video_sink);
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
        
        if(old_state == GST_STATE_READY && new_state == GST_STATE_PAUSED){
            check_media_size(self);
            
            /* 
             If there was a scheduled seek,
             perform it now that we have moed to the Paused state.
             */
            if(GST_CLOCK_TIME_IS_VALID(self->desired_position))
                execute_seek(self->desired_position, self);
        }
    }
}

/* C-Style need to define first */
static gboolean delayed_seek_cb(GStreamerBackend* self);

/*
 Perform seek, if we are not too close to the previous seek.
 Otherwise, schedule the seek for some time in the future.
 */
static void execute_seek (gint64 position, GStreamerBackend * self)
{
    gint64 diff;
    
    if(position == GST_CLOCK_TIME_NONE)
        return;
    
    diff = gst_util_get_timestamp() - self->last_seek_time;
    
    if(GST_CLOCK_TIME_IS_VALID(self->last_seek_time) && diff < SEEK_MIN_DELAY){
        /* The previous seek was too close, delay this */
        GSource* timeout_source;
        if(self->desired_position == GST_CLOCK_TIME_NONE){
            /* 
             There was no previous seek scheduled.
             Setup a timer for some time in the future.
             */
            timeout_source = g_timeout_source_new((SEEK_MIN_DELAY - diff)/GST_MSECOND);
            g_source_set_callback(timeout_source, (GSourceFunc)delayed_seek_cb, (__bridge void*)self, NULL);
            g_source_attach(timeout_source, self->main_context);
            g_source_unref(timeout_source);
        }
        
        /*
         Update the desired seek position.
         IF multiple requests are received before it is time to perform a seek, only the last one is remembered.
         */
        self->desired_position = position;
        GST_DEBUG("Throttling seek to %" GST_TIME_FORMAT ", will be in %" GST_TIME_FORMAT,
                  GST_TIME_ARGS (position), GST_TIME_ARGS (SEEK_MIN_DELAY - diff));
    } else {
        /* Perform the seek now */
        GST_DEBUG("Seeking to %"GST_TIME_FORMAT, GST_TIME_ARGS(position));
        self->last_seek_time = gst_util_get_timestamp();
        gst_element_seek_simple(self->pipeline, GST_FORMAT_TIME, GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT, position);
        self->desired_position = GST_CLOCK_TIME_NONE;
    }
}

/*
 Delayed seek callback.
 This gets called by the timer setup in the above function.
 */
static gboolean delayed_seek_cb(GStreamerBackend* self)
{
    GST_DEBUG ("Doing delayed seek to %" GST_TIME_FORMAT, GST_TIME_ARGS (self->desired_position));
    execute_seek(self->desired_position, self);
    return FALSE;
}


/*
 Called when the End of the Stream is reached.
 Just move to beginning of the media and pause.
 */
static void eos_cb(GstBus *bus, GstMessage *msg, GStreamerBackend *self){
    self->target_state = GST_STATE_PAUSED;
    self->is_live = (gst_element_set_state(self->pipeline, GST_STATE_PAUSED) == GST_STATE_CHANGE_NO_PREROLL);
    execute_seek (0, self);
}

/*
 Called when the duration of the media changes,
 Just mark it as unknown, so we re-query it in the next ui refresh.
 */
static void duration_cb(GstBus *bus, GstMessage *msg, GStreamerBackend *self){
    self->duration = GST_CLOCK_TIME_NONE;
}

/*
 Called when buffering messages are received.
 We inform the UI about the current buffering level and keep the popeline paused until 100% buffering is reached.
 At that point, set the desired state.
 */
static void buffering_cb(GstBus *bus, GstMessage *msg, GStreamerBackend *self){
    gint percent;
    
    if(self->is_live)
        return;
    
    gst_message_parse_buffering(msg, &percent);
    if(percent < 100 && self->target_state >= GST_STATE_PAUSED){
        gchar* message_string = g_strdup_printf("Buffering %d%%",percent);
        gst_element_set_state(self->pipeline, GST_STATE_PAUSED);
        [self setUIMessage:message_string];
        g_free(message_string);
    } else if (self->target_state >=GST_STATE_PLAYING){
        gst_element_set_state(self->pipeline, GST_STATE_PLAYING);
    } else if (self->target_state >= GST_STATE_PAUSED){
        [self setUIMessage:"Buffering complete"];
    }
}

/*
 Called when the clock is lost
 */
static void clock_lost_cb (GstBus *bus, GstMessage *msg, GStreamerBackend *self){
    if(self->target_state >= GST_STATE_PLAYING){
        gst_element_set_state(self->pipeline, GST_STATE_PAUSED);
        gst_element_set_state(self->pipeline, GST_STATE_PLAYING);
    }
}

/*
 If we have popeline and it is running,
 query the cuerrent position and clip duration and inform the application.
 */
static gboolean refresh_ui(GStreamerBackend* self)
{
    GstFormat fmt = GST_FORMAT_TIME;
    gint64 position;
    
    /* don't want to update anything unless we have a working pipeline in the PAUSED or PLAYING state */
    if(!self || !self->pipeline || self->current_state < GST_STATE_PAUSED)
        return TRUE;
    
    /* if we didnt know it yet , query the stream duration */
    if(!GST_CLOCK_TIME_IS_VALID(self->duration)){
        gst_element_query_duration(self->pipeline, &fmt, &self->duration);
    }
    
    if(gst_element_query_position(self->pipeline, &fmt, &position)){
        /* UI expects these values in milliseconds, and GStreamer provides nanoseconds */
        [self setCurrentUIPostition:position/GST_MSECOND duration:self->duration/GST_MSECOND];
    }
    
    return TRUE;
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

/* call back application what is the current position and clip duration */
-(void) setCurrentUIPostition:(gint)pos duration:(gint)dur
{
    if(ui_delegate && [ui_delegate respondsToSelector:@selector(setCurrentPosition:duration:)]){
        [ui_delegate setCurrentPosition:pos duration:dur];
    }
}

/* Main method for the bus monitoring code */
-(void)main_for_stream_video
{
    GstBus* bus;
    GSource* bus_source;
    GSource* timeout_source;
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
//    pipeline = gst_parse_launch("videotestsrc ! glimagesink", &error);
    pipeline = gst_parse_launch("playbin", &error);
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
    
    /*more call back for the streaming */
    g_signal_connect(G_OBJECT(bus), "message::eos", (GCallback)eos_cb, (__bridge void*)self);
    g_signal_connect(G_OBJECT(bus), "message::duration", (GCallback)duration_cb, (__bridge void*)self);
    g_signal_connect(G_OBJECT(bus), "message::buffering", (GCallback)buffering_cb, (__bridge void*)self);
    g_signal_connect(G_OBJECT(bus), "message::clock-lost", (GCallback)clock_lost_cb, (__bridge void*)self);
    gst_object_unref(bus);
    
    /* Register a function that GLib will call 4 times per second */
    timeout_source = g_timeout_source_new(250);
    g_source_set_callback(timeout_source, (GSourceFunc)refresh_ui, (__bridge void*)self, NULL);
    g_source_attach(timeout_source, main_context);
    g_source_unref(timeout_source);
    
    
    
    /* Create a GLib Main Loop and set it to run */
    GST_DEBUG("Entering main loop...");
    main_loop = g_main_loop_new(main_context, FALSE);
    //    self check initialized complete status
    [self check_initialization_complete];
    g_main_loop_run(main_loop);
    GST_DEBUG("Exited main loop");
    if (main_loop) {
        g_main_loop_quit(main_loop);
    }
    g_main_loop_unref(main_loop);
    main_loop = NULL;
    
    /* Free all of the temp resource */
    g_main_context_pop_thread_default(main_context);
    g_main_context_unref(main_context);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    
    return;
    
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
