package openfl.display3D._internal;

#if !flash
#if (lime && !openfl_wgpu)
typedef GLFramebuffer = lime.graphics.opengl.GLFramebuffer;
#else
typedef GLFramebuffer = Dynamic;
#end
#end
