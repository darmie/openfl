package openfl.display._internal;

#if (!flash && openfl_wgpu)
import lime.graphics.RenderContext;
import openfl.display.BitmapData;
import openfl.display.BlendMode;
import openfl.display.IBitmapDrawable;
import openfl.display.WgpuRenderer;
import openfl.geom.ColorTransform;
import openfl.geom.Matrix;
import openfl.geom.Rectangle;
import puffpuff.gpu.WgpuContext;
import puffpuff.snapshot.Offscreen;

/**
	`BitmapData.draw` on the GPU. Draws into the bitmap's texture with its own offscreen renderer, so it works with
	no frame in flight. The image reads back from the texture when something asks for it, so repeated draws, and
	drawing a bitmap to the screen, never wait on the GPU.
**/
@:access(openfl.display.BitmapData)
@:access(openfl.display.DisplayObjectRenderer)
@:access(openfl.display.WgpuRenderer)
@:access(openfl.geom.ColorTransform)
class WgpuBitmapData
{
	private static var renderer:WgpuRenderer;
	private static var offscreen:Offscreen;

	private static function setup():Void
	{
		if (renderer != null) return;

		var context = new WgpuContext(null, false);
		renderer = new WgpuRenderer(new RenderContext(null, context, {background: 0}));
		offscreen = new Offscreen(context.device);
	}

	/**
		Draws `source` into `target`. `transform` maps source space to bitmap pixels. Alpha and color transform
		apply on top of the source's own.
	**/
	public static function draw(target:BitmapData, source:IBitmapDrawable, transform:Matrix, alpha:Float, colorTransform:ColorTransform,
			blendMode:BlendMode, clipRect:Rectangle, clipMatrix:Matrix, smoothing:Bool):Void
	{
		if (!target.__isValid || !target.readable) return;

		setup();

		if (!target.__wgpuDirty)
		{
			var image = target.image;
			if (image == null) return;

			// Drawing blends premultiplied color.
			if (image.transparent && !image.premultiplied) image.premultiplied = true;
		}

		var texture = WgpuBitmap.texture(target, renderer.__context.wgpu.context3D);
		if (texture == null) return;

		renderer.__allowSmoothing = smoothing;
		renderer.__overrideBlendMode = blendMode;
		renderer.__worldTransform = transform;
		renderer.__worldAlpha = alpha;
		renderer.__worldColorTransform = colorTransform;

		target.__wgpuDirty = true;
		renderer.__renderToTexture(source, texture, clipRect, clipMatrix);

		renderer.__worldTransform = null;
		renderer.__worldColorTransform = null;
		renderer.__overrideBlendMode = null;
	}

	/** Reads the texture back into `bitmapData`'s image, if drawing changed it. **/
	public static function sync(bitmapData:BitmapData):Void
	{
		if (!bitmapData.__wgpuDirty) return;
		bitmapData.__wgpuDirty = false;

		var texture = bitmapData.__wgpuTexture;
		var image = bitmapData.image;
		if (texture == null || image == null || image.buffer == null || image.buffer.data == null) return;

		var pixels = offscreen.readRaw(texture.gpuTexture, texture.width, texture.height);
		image.buffer.data.toBytes().blit(0, pixels, 0, pixels.length);
		image.dirty = true;
		image.version++;
		bitmapData.__wgpuTextureVersion = image.version;
	}
}
#end
