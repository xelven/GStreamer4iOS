# GStreamer4iOS
this work with GStreamer ver 1.61 on iOS
```
- the old way eglglessink is removed from gst-plugins-bad on GStreamer after 1.4 -

just a short announcement to make everybody aware of the removal of 
eglglessink and libgstegl from gst-plugins-bad. This was the video sink 
that was previously used on Android, iOS, Raspberry Pi and others. 

The replacement is the glimagesink element, which is also in 
gst-plugins-bad, and provides the same features (and more) and is also 
supported on all platforms. glimagesink also comes together with 
libgstgl, a library that contains all the infrastructure to handle 
OpenGL/GLES withing GStreamer. 

If you were using eglglessink before, or were displaying video on 
Android, iOS or the Raspberry Pi, please test glimagesink from 
gst-plugins-bad git master and report any issues you find. 1.4 will be 
released without eglglessink. 


On a related note, glimagesink also has a higher rank than osxvideosink 
and will be used instead of osxvideosink on OSX if available. This 
should notably improve the video rendering experience on OSX. 
```
