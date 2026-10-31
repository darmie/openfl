package openfl.display._internal;

#if (!flash && openfl_wgpu)
import openfl.geom.ColorTransform;

/**
	Applies a `ColorTransform` when a color is made: solid fills, gradient stops, text, and tint and alpha of textured
	quads. Texture tints only use multipliers up to 1. Offsets only apply in `drawQuads`.
**/
class WgpuColor
{
	public static inline function isDefault(transform:ColorTransform):Bool
	{
		return transform == null
			|| (transform.redMultiplier == 1
				&& transform.greenMultiplier == 1
				&& transform.blueMultiplier == 1
				&& transform.alphaMultiplier == 1
				&& transform.redOffset == 0
				&& transform.greenOffset == 0
				&& transform.blueOffset == 0
				&& transform.alphaOffset == 0);
	}

	/** `rgb` with the red, green and blue multipliers and offsets applied. **/
	public static function rgb(color:Int, transform:ColorTransform):Int
	{
		if (isDefault(transform)) return color & 0xFFFFFF;

		var r = clamp(((color >> 16) & 0xFF) * transform.redMultiplier + transform.redOffset);
		var g = clamp(((color >> 8) & 0xFF) * transform.greenMultiplier + transform.greenOffset);
		var b = clamp((color & 0xFF) * transform.blueMultiplier + transform.blueOffset);
		return (r << 16) | (g << 8) | b;
	}

	/** `alpha` (0 to 1) with the alpha multiplier and offset applied. **/
	public static function alpha(alpha:Float, transform:ColorTransform):Float
	{
		if (transform == null) return alpha;

		var a = alpha * transform.alphaMultiplier + transform.alphaOffset / 255;
		return a < 0 ? 0 : (a > 1 ? 1 : a);
	}

	/** Multipliers as a quad tint. 0xFFFFFF leaves the texture alone. **/
	public static function tint(transform:ColorTransform):Int
	{
		if (transform == null) return 0xFFFFFF;

		return pack(transform.redMultiplier, transform.greenMultiplier, transform.blueMultiplier);
	}

	/** Multipliers (0 to 1) as a tint. Black is 0x000001 since a tint of 0 means none. **/
	public static function pack(red:Float, green:Float, blue:Float):Int
	{
		var tint = (clamp(red * 255) << 16) | (clamp(green * 255) << 8) | clamp(blue * 255);
		return tint == 0 ? 1 : tint;
	}

	private static inline function clamp(value:Float):Int
	{
		return value < 0 ? 0 : (value > 255 ? 255 : Math.round(value));
	}
}
#end
