package openfl.display3D._internal;

#if !flash
#if (lime && !openfl_wgpu)
typedef GLUniformLocation = lime.graphics.opengl.GLUniformLocation;
#else
typedef GLUniformLocation = Dynamic;
#end
#end
