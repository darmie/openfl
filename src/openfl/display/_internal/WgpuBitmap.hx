package openfl.display._internal;

#if (!flash && openfl_wgpu)
import lime.graphics.Image;
import lime.graphics.PixelFormat;
import openfl.display.Bitmap;
import openfl.display.BitmapData;
import openfl.display.WgpuRenderer;
import puffpuff.gpu.WgpuContext3D;
import puffpuff.gpu.WgpuContext3D.WgpuTexture;

/**
	Draws a `Bitmap` as a textured quad. Pixels upload once, again only if the image changes. Texture keeps the image's
	channel order and alpha convention.
**/
@:access(openfl.display.Bitmap)
@:access(openfl.display.BitmapData)
@:access(openfl.display.DisplayObject)
class WgpuBitmap
{
	public static function renderDrawable(bitmap:Bitmap, renderer:WgpuRenderer):Void
	{
		if (bitmap.__bitmapData != null && bitmap.__bitmapData.image != null)
		{
			bitmap.__imageVersion = bitmap.__bitmapData.image.version;
		}

		WgpuDisplayObject.renderDrawable(bitmap, renderer);
		render(bitmap, renderer);
	}

	public static function render(bitmap:Bitmap, renderer:WgpuRenderer):Void
	{
		if (!renderer.__canRender(bitmap)) return;

		var bitmapData = bitmap.__bitmapData;
		if (bitmapData == null || !bitmapData.__isValid || !bitmapData.readable) return;

		var alpha = renderer.__getAlpha(bitmap.__worldAlpha);
		if (alpha <= 0) return;

		var texture = WgpuBitmap.texture(bitmapData, renderer.__context.wgpu.context3D);
		if (texture == null) return;

		renderer.__pushMaskObject(bitmap);

		renderer.__beginQuads(texture, isPremultiplied(bitmapData), renderer.__allowSmoothing && bitmap.smoothing);

		var transform = bitmap.__renderTransform;
		var world = renderer.__worldTransform;
		var a = transform.a, b = transform.b, c = transform.c, d = transform.d, tx = transform.tx, ty = transform.ty;
		if (world != null)
		{
			var na = a * world.a + b * world.c;
			var nb = a * world.b + b * world.d;
			var nc = c * world.a + d * world.c;
			var nd = c * world.b + d * world.d;
			var ntx = tx * world.a + ty * world.c + world.tx;
			var nty = tx * world.b + ty * world.d + world.ty;
			a = na;
			b = nb;
			c = nc;
			d = nd;
			tx = ntx;
			ty = nty;
		}

		var width = bitmapData.width;
		var height = bitmapData.height;
		renderer.__quads.addQuad(a * width, b * width, c * height, d * height, tx, ty, 0, 0, 1, 1, alpha);
		renderer.__popMaskObject(bitmap);
	}

	/** Whether `bitmapData` is premultiplied. Blending needs it. **/
	public static function isPremultiplied(bitmapData:BitmapData):Bool
	{
		var image = bitmapData.image;
		return image != null && image.premultiplied && image.transparent;
	}

	/** GPU texture for `bitmapData`. Uploaded when new or changed. **/
	public static function texture(bitmapData:BitmapData, context3D:WgpuContext3D):WgpuTexture
	{
		var image = bitmapData.image;
		if (image == null || image.buffer == null || image.buffer.data == null) return null;

		var texture = bitmapData.__wgpuTexture;
		if (texture != null && bitmapData.__wgpuTextureVersion == image.version && texture.width == image.width && texture.height == image.height)
		{
			return texture;
		}

		if (image.format == ARGB32) image.format = RGBA32;

		var format = image.format == BGRA32 ? gpu.TextureFormat.Bgra8unorm : gpu.TextureFormat.Rgba8unorm;
		if (texture == null || texture.width != image.width || texture.height != image.height || texture.format != format)
		{
			if (texture != null) texture.dispose();
			texture = new WgpuTexture(context3D, image.width, image.height, format);
			bitmapData.__wgpuTexture = texture;
		}

		texture.uploadFromBytes(image.buffer.data.toBytes(), image.buffer.stride);
		bitmapData.__wgpuTextureVersion = image.version;
		return texture;
	}
}
#end
