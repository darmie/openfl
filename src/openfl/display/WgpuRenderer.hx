package openfl.display;

#if (!flash && openfl_wgpu)
import lime.graphics.RenderContext;
import lime.math.Matrix4;
import openfl.display._internal.WgpuDisplayObject;
import openfl.display._internal.WgpuDisplayObjectContainer;
import puffpuff.canvas.Canvas2D;

/**
	Renders the display list with WebGPU. Vector graphics are tessellated and drawn by `Canvas2D`
	in one pass per `__render`; coordinates are device pixels (the stage display matrix carries the
	window scale).
**/
#if !openfl_debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
@:access(openfl.display.DisplayObject)
@:access(openfl.display.IBitmapDrawable)
@:access(openfl.display.Stage)
@:allow(openfl.display._internal)
@:allow(openfl.display)
class WgpuRenderer extends DisplayObjectRenderer
{
	/**
		Collects this frame's vector draws.
	**/
	public var canvas(default, null):Canvas2D;

	@:noCompletion private var __projection:Matrix4;
	@:noCompletion private var __width:Int;
	@:noCompletion private var __height:Int;

	@:noCompletion private function new(context:RenderContext)
	{
		super();

		__context = context;
		__type = WGPU;
		__projection = new Matrix4();
		canvas = new Canvas2D(context.wgpu.context3D);
	}

	@:noCompletion private override function __clear():Void
	{
		var context3D = __context.wgpu.context3D;
		context3D.endRenderPass();

		if (__stage != null && !__stage.__transparent)
		{
			context3D.beginRenderPass(__stage.__colorSplit[0], __stage.__colorSplit[1], __stage.__colorSplit[2], 1);
		}
		else
		{
			context3D.beginRenderPass(0, 0, 0, 0);
		}

		__cleared = true;
	}

	@:noCompletion private override function __render(object:IBitmapDrawable):Void
	{
		canvas.pixelRatio = __pixelRatio;
		canvas.begin();
		__renderDrawable(object);
		canvas.flush(__projection);
	}

	@:noCompletion private function __renderDrawable(object:IBitmapDrawable):Void
	{
		if (object == null) return;

		switch (object.__drawableType)
		{
			case STAGE, SPRITE:
				WgpuDisplayObjectContainer.renderDrawable(cast object, this);
			case SHAPE:
				WgpuDisplayObject.renderDrawable(cast object, this);
			default:
		}
	}

	@:noCompletion private override function __resize(width:Int, height:Int):Void
	{
		__width = width;
		__height = height;
		__projection.createOrtho(0, width / __pixelRatio, height / __pixelRatio, 0, -1, 1);
	}
}
#end
