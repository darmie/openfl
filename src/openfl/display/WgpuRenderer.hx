package openfl.display;

#if (!flash && openfl_wgpu)
import lime.graphics.RenderContext;
import lime.math.Matrix4;
import openfl.display._internal.WgpuBitmap;
import openfl.display._internal.WgpuDisplayObject;
import openfl.display._internal.WgpuDisplayObjectContainer;
import openfl.display._internal.WgpuTextField;
import openfl.display._internal.WgpuTilemap;
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
	@:noCompletion private var __quadsMultiply:Bool;
	@:noCompletion private var __vectorsOpen:Bool;
	@:noCompletion private var __clipRects:Array<Rectangle> = [];
	@:noCompletion private var __numClipRects = 0;
	@:noCompletion private var __deviceWidth = 0;
	@:noCompletion private var __deviceHeight = 0;
	@:noCompletion private var __maskTextures:Array<WgpuTexture> = [];
	@:noCompletion private var __maskObjects:Array<DisplayObject> = [];
	@:noCompletion private var __maskTargets:Array<WgpuTexture> = [];
	@:noCompletion private var __target:WgpuTexture;
	@:noCompletion private var __renderingMask = 0;

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
		__blendMode = NORMAL;
		__maskObjects = [];
		__maskTargets = [];
		__target = null;
		__context.wgpu.context3D.disableScissor();
		__renderDrawable(object);
		__setBlendMode(NORMAL);
		__flush();
		__context.wgpu.context3D.disableScissor();
	}

	@:noCompletion private override function __pushMaskObject(object:DisplayObject, handleScrollRect:Bool = true):Void
	{
		if (handleScrollRect && object.__scrollRect != null)
		{
			__pushMaskRect(object.__scrollRect, object.__renderTransform);
		}

		if (object.__mask != null)
		{
			__pushMask(object.__mask);
		}
	}

	@:noCompletion private override function __popMaskObject(object:DisplayObject, handleScrollRect:Bool = true):Void
	{
		if (!object.__isCacheBitmapRender && object.__mask != null)
		{
			__popMask();
		}

		if (handleScrollRect && object.__scrollRect != null)
		{
			__popMaskRect();
		}
	}

	/**
		Starts a mask. Draws go to their own transparent texture until `__popMask`.
	**/
	@:noCompletion private override function __pushMask(mask:DisplayObject):Void
	{
		__flush();

		__maskObjects.push(mask);
		__maskTargets.push(__target);
		__setTarget(__maskTexture((__maskObjects.length - 1) * 2), true);
	}

	/**
		Ends a mask. Scales the content by the mask's coverage texture and draws the result onto the previous target.
	**/
	@:noCompletion private override function __popMask():Void
	{
		__flush();

		var mask = __maskObjects.pop();
		var parent = __maskTargets.pop();
		var content = __target;
		var coverage = __maskTexture(__maskObjects.length * 2 + 1);

		__setTarget(coverage, true);
		__renderingMask++;
		__renderDrawable(mask);
		__flush();
		__renderingMask--;

		__setTarget(content, false);
		__drawTexture(coverage, false, true);

		__setTarget(parent, false);
		__drawTexture(content, true, false);
	}

	/** Draws `texture`, the size of the target, over the whole target. **/
	@:noCompletion private override function __setBlendMode(value:BlendMode):Void
	{
		if (value == null) value = NORMAL;

		if (__blendMode != value)
		{
			__flush();
			__blendMode = value;
		}
	}

	@:noCompletion private function __saveBlend(context3D:puffpuff.gpu.WgpuContext3D):Array<Int>
	{
		return [context3D.srcRgb, context3D.dstRgb, context3D.opRgb, context3D.srcAlpha, context3D.dstAlpha, context3D.opAlpha];
	}

	@:noCompletion private function __restoreBlend(context3D:puffpuff.gpu.WgpuContext3D, saved:Array<Int>):Void
	{
		context3D.srcRgb = saved[0];
		context3D.dstRgb = saved[1];
		context3D.opRgb = saved[2];
		context3D.srcAlpha = saved[3];
		context3D.dstAlpha = saved[4];
		context3D.opAlpha = saved[5];
	}

	/**
		Sets the blend factors for the current blend mode. `premultiplied` is whether the source color is already
		multiplied by alpha. Overlay, hard light, difference and invert aren't supported, draw as normal.
	**/
	@:noCompletion private function __applyBlendMode(context3D:puffpuff.gpu.WgpuContext3D, premultiplied:Bool):Void
	{
		var source:gpu.BlendFactor = premultiplied ? gpu.BlendFactor.One : gpu.BlendFactor.SrcAlpha;

		switch (__blendMode)
		{
			case ADD:
				context3D.srcRgb = source;
				context3D.dstRgb = gpu.BlendFactor.One;
			case MULTIPLY:
				context3D.srcRgb = gpu.BlendFactor.Dst;
				context3D.dstRgb = gpu.BlendFactor.OneMinusSrcAlpha;
			case SCREEN:
				context3D.srcRgb = source;
				context3D.dstRgb = gpu.BlendFactor.OneMinusSrc;
			case SUBTRACT:
				context3D.opRgb = gpu.BlendOperation.ReverseSubtract;
				context3D.srcRgb = source;
				context3D.dstRgb = gpu.BlendFactor.One;
			case DARKEN:
				context3D.opRgb = gpu.BlendOperation.Min;
				context3D.srcRgb = gpu.BlendFactor.One;
				context3D.dstRgb = gpu.BlendFactor.One;
			case LIGHTEN:
				context3D.opRgb = gpu.BlendOperation.Max;
				context3D.srcRgb = gpu.BlendFactor.One;
				context3D.dstRgb = gpu.BlendFactor.One;
			case ERASE:
				context3D.srcRgb = gpu.BlendFactor.Zero;
				context3D.dstRgb = gpu.BlendFactor.OneMinusSrcAlpha;
				context3D.srcAlpha = gpu.BlendFactor.Zero;
				context3D.dstAlpha = gpu.BlendFactor.OneMinusSrcAlpha;
			case ALPHA:
				context3D.srcRgb = gpu.BlendFactor.Zero;
				context3D.dstRgb = gpu.BlendFactor.SrcAlpha;
				context3D.srcAlpha = gpu.BlendFactor.Zero;
				context3D.dstAlpha = gpu.BlendFactor.SrcAlpha;
			default:
				context3D.srcRgb = source;
		}
	}

	/** Whether to draw `object`. Skips hidden objects and masks, unless the mask itself is drawn as coverage. **/
	@:noCompletion private inline function __canRender(object:DisplayObject):Bool
	{
		return __renderingMask > 0 ? (object.__visible && object.__scaleX != 0 && object.__scaleY != 0) : object.__renderable;
	}

	@:noCompletion private function __drawTexture(texture:WgpuTexture, premultiplied:Bool, multiply:Bool):Void
	{
		__beginQuads(texture, premultiplied, false, multiply);
		__quads.addQuad(__deviceWidth, 0, 0, __deviceHeight, 0, 0, 0, 0, 1, 1, 1.0);
		__flush();
	}

	/** Sets the texture to draw into (null for the window), cleared to transparent if `clear` is set. **/
	@:noCompletion private function __setTarget(target:WgpuTexture, clear:Bool):Void
	{
		var context3D = __context.wgpu.context3D;
		if (target == null) context3D.setRenderToBackBuffer() else context3D.setRenderToTexture(target);
		__target = target;

		if (clear) context3D.beginRenderPass(0, 0, 0, 0) else context3D.beginRenderPass();
	}

	@:noCompletion private function __maskTexture(index:Int):WgpuTexture
	{
		while (__maskTextures.length <= index)
		{
			__maskTextures.push(__context.wgpu.context3D.createTexture(__deviceWidth, __deviceHeight));
		}

		return __maskTextures[index];
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
			var context3D = __context.wgpu.context3D;
			var saved = __saveBlend(context3D);
			// Premultiplied color, so half-covered edge pixels blend by half. Darken and lighten compare colors
			// regardless of coverage, so they use straight color.
			var premultiplied = switch (__blendMode)
			{
				case ADD, MULTIPLY, SCREEN, SUBTRACT: true;
				default: false;
			}
			__applyBlendMode(context3D, premultiplied);
			context3D.vectorsPremultiplied = premultiplied;
			canvas.flush(__projection);
			context3D.vectorsPremultiplied = false;
			__restoreBlend(context3D, saved);
			__vectorsOpen = false;
		}

		if (__quadsOpen)
		{
			var context3D = __context.wgpu.context3D;
			var saved = __saveBlend(context3D);
			var smoothing = context3D.smoothing;

			if (__quadsMultiply)
			{
				// Multiply scales destination by source alpha and adds nothing, so mask coverage removes whatever it
				// doesn't cover.
				context3D.srcRgb = gpu.BlendFactor.Zero;
				context3D.dstRgb = gpu.BlendFactor.SrcAlpha;
				context3D.srcAlpha = gpu.BlendFactor.Zero;
				context3D.dstAlpha = gpu.BlendFactor.SrcAlpha;
			}
			else
			{
				__applyBlendMode(context3D, __quadsPremultiplied);
			}

			context3D.quadsPremultiplied = __quadsPremultiplied;
			context3D.smoothing = __quadsSmooth;
			__quads.flush(__projection);
			context3D.quadsPremultiplied = false;
			context3D.smoothing = smoothing;
			__restoreBlend(context3D, saved);
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
	@:noCompletion private function __beginQuads(texture:WgpuTexture, premultiplied:Bool, smooth:Bool, multiply:Bool = false):Void
	{
		if (__quadsOpen
			&& __quads.texture == texture
			&& __quadsPremultiplied == premultiplied
			&& __quadsSmooth == smooth
			&& __quadsMultiply == multiply) return;

		__flush();
		__quads.begin(texture);
		__quadsPremultiplied = premultiplied;
		__quadsSmooth = smooth;
		__quadsMultiply = multiply;
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
			case TILEMAP:
				WgpuTilemap.renderDrawable(cast object, this);
			default:
		}
	}

	@:noCompletion private override function __resize(width:Int, height:Int):Void
	{
		__projection.createOrtho(0, width, height, 0, -1, 1);

		if (width != __deviceWidth || height != __deviceHeight)
		{
			for (texture in __maskTextures) texture.dispose();
			__maskTextures = [];
			__deviceWidth = width;
			__deviceHeight = height;
		}
	}
}
#end
