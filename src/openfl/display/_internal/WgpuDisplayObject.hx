package openfl.display._internal;

#if (!flash && openfl_wgpu)
import openfl.display.DisplayObject;
import openfl.display.WgpuRenderer;
import openfl.display._internal.WgpuColor;
import puffpuff.canvas.Affine;

@:access(openfl.display.DisplayObject)
@:access(openfl.display.Graphics)
@:access(openfl.geom.Matrix)
class WgpuDisplayObject
{
	public static function renderDrawable(displayObject:DisplayObject, renderer:WgpuRenderer):Void
	{
		var graphics = displayObject.__graphics;
		if (graphics == null || !renderer.__canRender(displayObject)) return;

		var colorTransform = renderer.__worldColor(displayObject.__worldColorTransform);
		var alpha = WgpuColor.alpha(renderer.__getAlpha(displayObject.__worldAlpha), colorTransform);
		if (alpha <= 0) return;

		var transform = displayObject.__renderTransform;
		var world = renderer.__worldTransform;
		var local = new Affine(transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty);
		if (world != null)
		{
			local = new Affine(world.a, world.b, world.c, world.d, world.tx, world.ty).after(local);
		}

		renderer.__setBlendMode(displayObject.__worldBlendMode);
		renderer.__pushMaskObject(displayObject);
		renderer.__beginVectors();
		WgpuGraphics.render(graphics, renderer, local, alpha, colorTransform);
		renderer.__popMaskObject(displayObject);
	}
}
#end
