package openfl.display3D._internal;

#if !flash
#if (lime && !openfl_wgpu)
typedef GLTexture = lime.graphics.opengl.GLTexture;
#else
typedef GLTexture = Dynamic;
#end
#end
