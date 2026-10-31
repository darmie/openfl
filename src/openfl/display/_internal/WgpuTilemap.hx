package openfl.display._internal;

#if (!flash && openfl_wgpu)
import openfl.display.BitmapData;
import openfl.display.TileContainer;
import openfl.display.Tilemap;
import openfl.display.Tileset;
import openfl.display.WgpuRenderer;
import openfl.geom.Matrix;
import openfl.geom.Rectangle;

/**
	Draws a `Tilemap` as textured quads, one per visible tile, clipped to the tilemap's size. Tiles batch while the
	tileset's bitmap stays the same. No tile color transforms or blend modes yet.
**/
@:access(openfl.display.BitmapData)
@:access(openfl.display.DisplayObject)
@:access(openfl.display.Tile)
@:access(openfl.display.TileContainer)
@:access(openfl.display.Tilemap)
@:access(openfl.display.Tileset)
@:access(openfl.geom.Matrix)
@:access(openfl.geom.Rectangle)
class WgpuTilemap
{
	public static function renderDrawable(tilemap:Tilemap, renderer:WgpuRenderer):Void
	{
		WgpuDisplayObject.renderDrawable(tilemap, renderer);
		render(tilemap, renderer);
	}

	public static function render(tilemap:Tilemap, renderer:WgpuRenderer):Void
	{
		if (!renderer.__canRender(tilemap) || tilemap.__group.__tiles.length == 0) return;

		var alpha = renderer.__getAlpha(tilemap.__worldAlpha);
		if (alpha <= 0) return;

		renderer.__pushMaskObject(tilemap);

		var rect = Rectangle.__pool.get();
		rect.setTo(0, 0, tilemap.__width, tilemap.__height);
		renderer.__pushMaskRect(rect, tilemap.__renderTransform);

		var parent = Matrix.__pool.get();
		parent.copyFrom(tilemap.__renderTransform);
		if (renderer.__worldTransform != null) parent.concat(renderer.__worldTransform);

		renderTileContainer(tilemap.__group, renderer, parent, tilemap.__tileset, renderer.__allowSmoothing && tilemap.smoothing, tilemap.tileAlphaEnabled, alpha,
			rect);

		Matrix.__pool.release(parent);
		renderer.__popMaskRect();
		renderer.__popMaskObject(tilemap);
		Rectangle.__pool.release(rect);
	}

	private static function renderTileContainer(group:TileContainer, renderer:WgpuRenderer, parentTransform:Matrix, defaultTileset:Tileset, smooth:Bool,
			alphaEnabled:Bool, worldAlpha:Float, rect:Rectangle):Void
	{
		var context3D = renderer.__context.wgpu.context3D;
		var tileTransform = Matrix.__pool.get();
		var tiles = group.__tiles;

		for (i in 0...group.__length)
		{
			var tile = tiles[i];

			var alpha = tile.alpha * worldAlpha;
			if (!tile.visible || alpha <= 0) continue;
			if (!alphaEnabled) alpha = 1;

			tileTransform.setTo(1, 0, 0, 1, -tile.originX, -tile.originY);
			tileTransform.concat(tile.matrix);
			tileTransform.concat(parentTransform);

			var tileset = tile.tileset != null ? tile.tileset : defaultTileset;

			if (tile.__length > 0)
			{
				renderTileContainer(cast tile, renderer, tileTransform, tileset, smooth, alphaEnabled, alpha, rect);
				continue;
			}

			if (tileset == null) continue;

			var tileRect:Rectangle;
			if (tile.id == -1)
			{
				tileRect = tile.__rect;
				if (tileRect == null || tileRect.width <= 0 || tileRect.height <= 0) continue;
			}
			else
			{
				var data = tileset.__data[tile.id];
				if (data == null) continue;
				rect.setTo(data.x, data.y, data.width, data.height);
				tileRect = rect;
			}

			var bitmapData = tileset.__bitmapData;
			if (bitmapData == null || bitmapData.image == null) continue;

			var texture = WgpuBitmap.texture(bitmapData, context3D);
			if (texture == null) continue;

			renderer.__beginQuads(texture, WgpuBitmap.isPremultiplied(bitmapData), smooth);

			var w = tileRect.width;
			var h = tileRect.height;
			var invW = 1 / texture.width;
			var invH = 1 / texture.height;
			renderer.__quads.addQuad(tileTransform.a * w, tileTransform.b * w, tileTransform.c * h, tileTransform.d * h, tileTransform.tx, tileTransform.ty,
				tileRect.x * invW, tileRect.y * invH, w * invW, h * invH, alpha);
		}

		Matrix.__pool.release(tileTransform);
	}
}
#end
