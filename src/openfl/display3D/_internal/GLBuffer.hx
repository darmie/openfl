package openfl.display3D._internal;

#if !flash
#if (lime && !openfl_wgpu)
typedef GLBuffer = lime.graphics.opengl.GLBuffer;
#else
typedef GLBuffer = Dynamic;
#end
#end
