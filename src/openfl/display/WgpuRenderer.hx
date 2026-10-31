package openfl.display;

#if (!flash && openfl_wgpu)
import lime.graphics.RenderContext;
import lime.math.Matrix4;
import openfl.display._internal.WgpuBitmap;
import openfl.display._internal.WgpuDisplayObject;
import openfl.display._internal.WgpuDisplayObjectContainer;
import openfl.display._internal.WgpuTextField;
import openfl.geom.Matrix;
import openfl.geom.Rectangle;
import puffpuff.canvas.Canvas2D;
import puffpuff.gpu.QuadBatcher;
import puffpuff.gpu.WgpuContext3D.WgpuTexture;

/**
	Renders the display list with WebGPU. Vector graphics go through `Canvas2D`, one pass per `__render`. Coordinates
	are device pixels, since the stage display matrix has the window scale.
**/
#if !openfl_debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
@:access(openfl.display.DisplayObject)
@:access(openfl.display.IBitmapDrawable)
@:access(openfl.geom.Matrix)
@:access(openfl.geom.Rectangle)
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
	@:noCompletion private var __quads:QuadBatcher;
	@:noCompletion private var __quadsOpen:Bool;
	@:noCompletion private var __quadsPremultiplied:Bool;
	@:noCompletion private var __quadsSmooth:Bool;
	@:noCompletion private var __vectorsOpen:Bool;
	@:noCompletion private var __clipRects:Array<Rectangle> = [];
	@:noCompletion private var __numClipRects = 0;

	@:noCompletion private function new(context:RenderContext)
	{
		super();

		__context = context;
		__type = WGPU;
		__projection = new Matrix4();
		canvas = new Canvas2D(context.wgpu.context3D);
		__quads = new QuadBatcher(context.wgpu.context3D);
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
		__vectorsOpen = false;
		__quadsOpen = false;
		__numClipRects = 0;
		__context.wgpu.context3D.disableScissor();
		__renderDrawable(object);
		__flush();
		__context.wgpu.context3D.disableScissor();
	}

	@:noCompletion private override function __pushMaskObject(object:DisplayObject, handleScrollRect:Bool = true):Void
	{
		if (handleScrollRect && object.__scrollRect != null)
		{
			__pushMaskRect(object.__scrollRect, object.__renderTransform);
		}
	}

	@:noCompletion private override function __popMaskObject(object:DisplayObject, handleScrollRect:Bool = true):Void
	{
		if (handleScrollRect && object.__scrollRect != null)
		{
			__popMaskRect();
		}
	}

	/**
		Clips later draws to `rect` transformed by `transform` (upright bounding box). Flushes collected draws first,
		unclipped.
	**/
	@:noCompletion private override function __pushMaskRect(rect:Rectangle, transform:Matrix):Void
	{
		__flush();

		if (__numClipRects == __clipRects.length)
		{
			__clipRects[__numClipRects] = new Rectangle();
		}

		var matrix = Matrix.__pool.get();
		matrix.copyFrom(transform);
		matrix.concat(__worldTransform);

		var clip = __clipRects[__numClipRects];
		rect.__transform(clip, matrix);
		Matrix.__pool.release(matrix);

		if (__numClipRects > 0)
		{
			var parent = __clipRects[__numClipRects - 1];
			clip.__contract(parent.x, parent.y, parent.width, parent.height);
		}

		if (clip.width < 0) clip.width = 0;
		if (clip.height < 0) clip.height = 0;

		__numClipRects++;
		__applyClip(clip);
	}

	/**
		Ends the clip. Flushes draws made inside it, still clipped.
	**/
	@:noCompletion private override function __popMaskRect():Void
	{
		__flush();

		if (__numClipRects > 0) __numClipRects--;

		if (__numClipRects > 0)
		{
			__applyClip(__clipRects[__numClipRects - 1]);
		}
		else
		{
			__context.wgpu.context3D.disableScissor();
		}
	}

	@:noCompletion private function __applyClip(clip:Rectangle):Void
	{
		var left = Math.floor(clip.x);
		var top = Math.floor(clip.y);
		__context.wgpu.context3D.setScissorRectangle(left, top, Math.ceil(clip.x + clip.width) - left, Math.ceil(clip.y + clip.height) - top);
	}

	/**
		Draws collected batches. Vectors and quads batch separately, so switching between them flushes the open batch.
		Keeps display order.
	**/
	@:noCompletion private function __flush():Void
	{
		if (__vectorsOpen)
		{
			canvas.flush(__projection);
			__vectorsOpen = false;
		}

		if (__quadsOpen)
		{
			var context3D = __context.wgpu.context3D;
			var srcRgb = context3D.srcRgb;
			var smoothing = context3D.smoothing;

			// Premultiplied colour is added as it is; straight colour is scaled by its alpha.
			if (__quadsPremultiplied)
			{
				context3D.srcRgb = gpu.BlendFactor.One;
			}

			context3D.quadsPremultiplied = __quadsPremultiplied;
			context3D.smoothing = __quadsSmooth;
			__quads.flush(__projection);
			context3D.quadsPremultiplied = false;
			context3D.smoothing = smoothing;
			context3D.srcRgb = srcRgb;
			__quadsOpen = false;
		}
	}

	/**
		Opens the vector batch for drawing with `canvas`.
	**/
	@:noCompletion private function __beginVectors():Void
	{
		if (__vectorsOpen) return;

		__flush();
		canvas.begin();
		__vectorsOpen = true;
	}

	/**
		Opens a quad batch on `texture`. Flushes the open batch if texture or blending differ.
	**/
	@:noCompletion private function __beginQuads(texture:WgpuTexture, premultiplied:Bool, smooth:Bool):Void
	{
		if (__quadsOpen && __quads.texture == texture && __quadsPremultiplied == premultiplied && __quadsSmooth == smooth) return;

		__flush();
		__quads.begin(texture);
		__quadsPremultiplied = premultiplied;
		__quadsSmooth = smooth;
		__quadsOpen = true;
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
			case BITMAP:
				WgpuBitmap.renderDrawable(cast object, this);
			case TEXT_FIELD:
				WgpuTextField.renderDrawable(cast object, this);
			default:
		}
	}

	@:noCompletion private override function __resize(width:Int, height:Int):Void
	{
		__projection.createOrtho(0, width, height, 0, -1, 1);
	}
}
#end
