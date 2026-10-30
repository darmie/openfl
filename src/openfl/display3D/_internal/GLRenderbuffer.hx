package openfl.display3D._internal;

#if !flash
#if (lime && !openfl_wgpu)
typedef GLRenderbuffer = lime.graphics.opengl.GLRenderbuffer;
#else
typedef GLRenderbuffer = Dynamic;
#end
#end
