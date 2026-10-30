package openfl.display3D._internal;

#if !flash
#if (lime && !openfl_wgpu)
typedef GLProgram = lime.graphics.opengl.GLProgram;
#else
typedef GLProgram = Dynamic;
#end
#end
