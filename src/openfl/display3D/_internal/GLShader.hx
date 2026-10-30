package openfl.display3D._internal;

#if !flash
#if (lime && !openfl_wgpu)
typedef GLShader = lime.graphics.opengl.GLShader;
#else
typedef GLShader = Dynamic;
#end
#end
