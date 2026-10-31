package openfl.display._internal;

#if (!flash && openfl_wgpu)
import openfl.display.WgpuRenderer;
import openfl.text.AntiAliasType;
import openfl.text.TextField;
import openfl.text._internal.TextEngine;
import puffpuff.canvas.Affine;
import puffpuff.canvas.Paint;
import puffpuff.canvas.Path;
import puffpuff.canvas.Stroke;

/**
	Draws a `TextField` from its layout. Each layout group comes from the glyph atlas at its position, in its format's
	font, size and color, through the display transform. Background and border are vector shapes. Text follows the
	transform's position and scale. No rotation, selection, caret or underlines yet.
**/
@:access(openfl.display.DisplayObject)
@:access(openfl.geom.Matrix)
@:access(openfl.text.TextField)
@:access(openfl.text._internal.TextEngine)
class WgpuTextField
{
	public static function renderDrawable(textField:TextField, renderer:WgpuRenderer):Void
	{
		if (textField.__dirty)
		{
			textField.__updateLayout();
			textField.__dirty = false;
		}

		if (!renderer.__canRender(textField)) return;

		var alpha = renderer.__getAlpha(textField.__worldAlpha);
		if (alpha <= 0) return;

		var textEngine = textField.__textEngine;
		var transform = textField.__renderTransform;
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

		renderer.__pushMaskObject(textField);

		var useTextBounds = !(textEngine.background || textEngine.border);
		var bounds = useTextBounds ? textEngine.textBounds : textEngine.bounds;

		if (!useTextBounds)
		{
			renderer.__beginVectors();
			var local = new Affine(a, b, c, d, tx, ty);
			var box = new Path().rect(0.5, 0.5, bounds.width - 1, bounds.height - 1);
			if (textEngine.background)
			{
				renderer.canvas.fill(box, Paint.solid(textEngine.backgroundColor & 0xFFFFFF), NonZero, local, alpha);
			}

			if (textEngine.border)
			{
				renderer.canvas.stroke(box, new Stroke(1), Paint.solid(textEngine.borderColor & 0xFFFFFF), local, alpha);
			}
		}

		var text = textEngine.text;
		if (text == null || text == "")
		{
			renderer.__popMaskObject(textField);
			return;
		}

		var scale = Math.sqrt(Math.abs(a * d - b * c));
		var scrollX = -textField.scrollH;
		var scrollY = 0.0;
		for (i in 0...textField.scrollV - 1)
		{
			scrollY -= textEngine.lineHeights[i];
		}

		// Layout uses hinted advances if TextEngine asked for them, so glyphs are placed the same way.
		var hinted = puffpuff.text.FontAtlas.hintedAdvances && (textEngine.antiAliasType != AntiAliasType.ADVANCED || textEngine.sharpness < 400);
		var atlas = puffpuff.text.FontAtlas.getDefault(renderer.__context.wgpu.context3D);
		renderer.__beginQuads(atlas.upload(renderer.__context.wgpu.context3D), false, true);

		for (group in textEngine.layoutGroups)
		{
			if (group.lineIndex < textField.scrollV - 1) continue;
			if (group.lineIndex > textEngine.bottomScrollV - 1) break;

			var font = TextEngine.getFontInstance(group.format);
			if (font == null) continue;

			// `drawText` takes the top of the line, which is `offsetY`. Baseline is `ascent` below it.
			var localX = group.offsetX + scrollX;
			var localY = group.offsetY + scrollY;
			font.drawText(renderer.__quads, text.substring(group.startIndex, group.endIndex), a * localX + c * localY + tx, b * localX + d * localY + ty,
				group.format.size * scale, group.format.color & 0xFFFFFF, alpha, {
					letterSpacing: group.format.letterSpacing != null ? group.format.letterSpacing * scale : null,
					hinted: hinted
				});
		}

		renderer.__popMaskObject(textField);
	}
}
#end