package openfl.display._internal;

#if (!flash && openfl_wgpu)
import openfl.display.BitmapData;
import openfl.display.CapsStyle;
import openfl.display.GradientType;
import openfl.display.Graphics;
import openfl.display.JointStyle;
import openfl.display.SpreadMethod;
import openfl.display.WgpuRenderer;
import openfl.geom.Matrix;
import openfl.Vector;
import puffpuff.canvas.Affine;
import puffpuff.canvas.Canvas2D;
import puffpuff.canvas.Paint;
import puffpuff.canvas.Paint.PaintKind;
import puffpuff.canvas.Path;
import puffpuff.canvas.Stroke;

/**
	Draws the commands of a `Graphics` with `Canvas2D`, and its `drawQuads` with textured quads: solid and gradient fills and line styles, with the
	nonzero and even-odd rules. Gradients take up to four stops, pad, reflect and repeat spreads and any
	gradient matrix; the focal point and linearRGB interpolation are not applied. The fill and the stroke accumulate separate paths, because a line
	style change ends the stroke segment but not the fill.
**/
@:access(openfl.display.Graphics)
@:access(openfl.display.WgpuRenderer)
class WgpuGraphics
{
	public static function render(graphics:Graphics, renderer:WgpuRenderer, local:Affine, alpha:Float):Void
	{
		var commands = graphics.__commands;
		if (commands == null || commands.length == 0) return;

		var state = new WgpuGraphicsState(renderer, local, alpha);
		var data = new DrawCommandReader(commands);

		for (type in commands.types)
		{
			switch (type)
			{
				case BEGIN_FILL:
					var c = data.readBeginFill();
					state.beginFill(c.color, c.alpha);

				case BEGIN_GRADIENT_FILL:
					var c = data.readBeginGradientFill();
					state.beginPaint(WgpuGraphicsState.gradient(c.type, c.colors, c.alphas, c.ratios, c.matrix, c.spreadMethod));

				case BEGIN_BITMAP_FILL:
					var c = data.readBeginBitmapFill();
					state.beginBitmapFill(c.bitmap, c.smooth);

				case DRAW_QUADS:
					var c = data.readDrawQuads();
					state.drawQuads(c.rects, c.indices, c.transforms);

				case END_FILL:
					data.readEndFill();
					state.endFill();

				case WINDING_EVEN_ODD:
					data.readWindingEvenOdd();
					state.evenOdd = true;

				case WINDING_NON_ZERO:
					data.readWindingNonZero();
					state.evenOdd = false;

				case LINE_STYLE:
					var c = data.readLineStyle();
					state.lineStyle(c.thickness, c.color, c.alpha, c.caps, c.joints, c.miterLimit);

				case LINE_GRADIENT_STYLE:
					var c = data.readLineGradientStyle();
					state.strokePaint = WgpuGraphicsState.gradient(c.type, c.colors, c.alphas, c.ratios, c.matrix, c.spreadMethod);

				case MOVE_TO:
					var c = data.readMoveTo();
					state.moveTo(c.x, c.y);

				case LINE_TO:
					var c = data.readLineTo();
					state.lineTo(c.x, c.y);

				case CURVE_TO:
					var c = data.readCurveTo();
					state.curveTo(c.controlX, c.controlY, c.anchorX, c.anchorY);

				case CUBIC_CURVE_TO:
					var c = data.readCubicCurveTo();
					state.cubicCurveTo(c.controlX1, c.controlY1, c.controlX2, c.controlY2, c.anchorX, c.anchorY);

				case DRAW_RECT:
					var c = data.readDrawRect();
					state.drawRect(c.x, c.y, c.width, c.height);

				case DRAW_ROUND_RECT:
					var c = data.readDrawRoundRect();
					state.drawRoundRect(c.x, c.y, c.width, c.height, c.ellipseWidth, c.ellipseHeight);

				case DRAW_CIRCLE:
					var c = data.readDrawCircle();
					state.drawCircle(c.x, c.y, c.radius);

				case DRAW_ELLIPSE:
					var c = data.readDrawEllipse();
					state.drawEllipse(c.x, c.y, c.width, c.height);

				default:
					data.skip(type);
			}
		}

		data.destroy();
		state.finish();
	}
}

@:access(openfl.display.WgpuRenderer)
@:allow(openfl.display._internal.WgpuGraphics)
private class WgpuGraphicsState
{
	public var evenOdd:Bool = false;
	public var strokePaint:Paint;

	private var renderer:WgpuRenderer;
	private var canvas:Canvas2D;
	private var local:Affine;
	private var bitmap:BitmapData;
	private var bitmapSmooth:Bool;
	private var alpha:Float;
	private var fillPaint:Paint;
	private var fillPath:Path;
	private var stroke:Stroke;
	private var strokePath:Path;
	private var x:Float = 0;
	private var y:Float = 0;

	public function new(renderer:WgpuRenderer, local:Affine, alpha:Float)
	{
		this.renderer = renderer;
		this.canvas = renderer.canvas;
		this.local = local;
		this.alpha = alpha;
	}

	public function beginFill(color:Int, fillAlpha:Float):Void
	{
		beginPaint(fillAlpha < 0.005 ? null : Paint.solid(color & 0xFFFFFF, fillAlpha));
	}

	public function beginPaint(paint:Paint):Void
	{
		flushFill();
		fillPaint = paint;
		fillPath = paint == null ? null : new Path().moveTo(x, y);
	}

	/**
		Gradient paint. The matrix maps the gradient box onto the shape. Linear runs along x from -819.2 to 819.2,
		radial has radius 819.2.
	**/
	public static function gradient(type:GradientType, colors:Array<Int>, alphas:Array<Float>, ratios:Array<Int>, matrix:Matrix, spread:SpreadMethod):Paint
	{
		var stops = [];
		for (i in 0...colors.length)
		{
			stops.push({offset: ratios[i] / 255, rgb: colors[i] & 0xFFFFFF, alpha: alphas[i]});
		}

		// A paint holds four stops. Keep first and last, spread the rest evenly.
		if (stops.length > 4)
		{
			var picked = [];
			for (i in 0...4) picked.push(stops[Math.round(i * (stops.length - 1) / 3)]);
			stops = picked;
		}

		var radial = type == RADIAL;
		var scale = radial ? 819.2 : 1638.4;
		var shift = radial ? 0.0 : -819.2;
		var unit = new Affine(scale, 0, 0, scale, shift, shift);
		var box = matrix == null ? unit : new Affine(matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty).after(unit);
		var spreadMode = switch (spread)
		{
			case REFLECT: 1;
			case REPEAT: 2;
			default: 0;
		}

		return Paint.boxed(radial ? Radial : Linear, box, stops, spreadMode);
	}

	public function endFill():Void
	{
		flushFill();
		fillPaint = null;
		fillPath = null;
		bitmap = null;
	}

	/**
		The bitmap `drawQuads` samples. Paths filled with a bitmap are not drawn yet, so a bitmap fill ends any
		other fill.
	**/
	public function beginBitmapFill(bitmapData:BitmapData, smooth:Bool):Void
	{
		beginPaint(null);
		bitmap = bitmapData;
		bitmapSmooth = smooth;
	}

	/**
		Draws quads of the bitmap fill. `rects` are bitmap rectangles, `indices` pick one per quad, and `transforms`
		place each quad: six-value matrix, four values (position is origin), two values (a position), or nothing
		(rectangle's own position). Shape's transform applies on top.
	**/
	public function drawQuads(rects:Vector<Float>, indices:Vector<Int>, transforms:Vector<Float>):Void
	{
		flushFill();
		flushStroke();

		if (bitmap == null || rects == null) return;

		var texture = WgpuBitmap.texture(bitmap, renderer.__context.wgpu.context3D);
		if (texture == null) return;

		var hasIndices = indices != null;
		var length = hasIndices ? indices.length : Math.floor(rects.length / 4);
		var matrixAndPosition = false, matrix = false, position = false;
		if (transforms != null)
		{
			if (transforms.length >= length * 6) matrixAndPosition = true;
			else if (transforms.length >= length * 4) matrix = true;
			else if (transforms.length >= length * 2) position = true;
		}

		renderer.__beginQuads(texture, WgpuBitmap.isPremultiplied(bitmap), renderer.__allowSmoothing && bitmapSmooth);

		var invW = 1 / texture.width;
		var invH = 1 / texture.height;
		for (i in 0...length)
		{
			var ri = hasIndices ? indices[i] * 4 : i * 4;
			if (ri < 0) continue;

			var w = rects[ri + 2];
			var h = rects[ri + 3];
			if (w <= 0 || h <= 0) continue;

			var ta = 1.0, tb = 0.0, tc = 0.0, td = 1.0, tx = 0.0, ty = 0.0;
			if (matrixAndPosition)
			{
				var ti = i * 6;
				ta = transforms[ti];
				tb = transforms[ti + 1];
				tc = transforms[ti + 2];
				td = transforms[ti + 3];
				tx = transforms[ti + 4];
				ty = transforms[ti + 5];
			}
			else if (matrix)
			{
				var ti = i * 4;
				ta = transforms[ti];
				tb = transforms[ti + 1];
				tc = transforms[ti + 2];
				td = transforms[ti + 3];
			}
			else if (position)
			{
				tx = transforms[i * 2];
				ty = transforms[i * 2 + 1];
			}
			else
			{
				tx = rects[ri];
				ty = rects[ri + 1];
			}

			// Quad's matrix, then the shape's.
			var a = local.a * ta + local.c * tb;
			var b = local.b * ta + local.d * tb;
			var c = local.a * tc + local.c * td;
			var d = local.b * tc + local.d * td;
			renderer.__quads.addQuad(a * w, b * w, c * h, d * h, local.a * tx + local.c * ty + local.e, local.b * tx + local.d * ty + local.f, rects[ri] * invW,
				rects[ri + 1] * invH, w * invW, h * invH, alpha);
		}
	}

	public function lineStyle(thickness:Null<Float>, color:Int, lineAlpha:Float, caps:CapsStyle, joints:JointStyle, miterLimit:Float):Void
	{
		flushStroke();

		if (thickness == null)
		{
			stroke = null;
			strokePaint = null;
			strokePath = null;
			return;
		}

		var cap = switch (caps)
		{
			case NONE: LineCap.Butt;
			case SQUARE: LineCap.Square;
			default: LineCap.Round;
		}

		var join = switch (joints)
		{
			case BEVEL: LineJoin.Bevel;
			case MITER: LineJoin.Miter;
			default: LineJoin.Round;
		}

		stroke = new Stroke(thickness > 0 ? thickness : 1, cap, join, miterLimit);
		strokePaint = Paint.solid(color & 0xFFFFFF, lineAlpha);
		strokePath = new Path().moveTo(x, y);
	}

	public function moveTo(px:Float, py:Float):Void
	{
		if (fillPath != null) fillPath.moveTo(px, py);
		if (strokePath != null) strokePath.moveTo(px, py);
		x = px;
		y = py;
	}

	public function lineTo(px:Float, py:Float):Void
	{
		if (fillPath != null) fillPath.lineTo(px, py);
		if (strokePath != null) strokePath.lineTo(px, py);
		x = px;
		y = py;
	}

	public function curveTo(cx:Float, cy:Float, ax:Float, ay:Float):Void
	{
		if (fillPath != null) fillPath.quadTo(cx, cy, ax, ay);
		if (strokePath != null) strokePath.quadTo(cx, cy, ax, ay);
		x = ax;
		y = ay;
	}

	public function cubicCurveTo(c1x:Float, c1y:Float, c2x:Float, c2y:Float, ax:Float, ay:Float):Void
	{
		if (fillPath != null) fillPath.cubicTo(c1x, c1y, c2x, c2y, ax, ay);
		if (strokePath != null) strokePath.cubicTo(c1x, c1y, c2x, c2y, ax, ay);
		x = ax;
		y = ay;
	}

	public function drawRect(rx:Float, ry:Float, w:Float, h:Float):Void
	{
		if (fillPath != null) fillPath.rect(rx, ry, w, h);
		if (strokePath != null) strokePath.rect(rx, ry, w, h);
		x = rx;
		y = ry;
	}

	public function drawRoundRect(rx:Float, ry:Float, w:Float, h:Float, ellipseWidth:Float, ellipseHeight:Null<Float>):Void
	{
		var radiusX = Math.min(ellipseWidth / 2, w / 2);
		var radiusY = Math.min((ellipseHeight == null ? ellipseWidth : ellipseHeight) / 2, h / 2);

		if (fillPath != null) roundRect(fillPath, rx, ry, w, h, radiusX, radiusY);
		if (strokePath != null) roundRect(strokePath, rx, ry, w, h, radiusX, radiusY);
		x = rx + w;
		y = ry + h - radiusY;
	}

	public function drawCircle(cx:Float, cy:Float, radius:Float):Void
	{
		if (fillPath != null) fillPath.circle(cx, cy, radius);
		if (strokePath != null) strokePath.circle(cx, cy, radius);
		x = cx + radius;
		y = cy;
	}

	public function drawEllipse(ex:Float, ey:Float, w:Float, h:Float):Void
	{
		if (fillPath != null) fillPath.ellipse(ex + w / 2, ey + h / 2, w / 2, h / 2);
		if (strokePath != null) strokePath.ellipse(ex + w / 2, ey + h / 2, w / 2, h / 2);
		x = ex + w;
		y = ey + h / 2;
	}

	public function finish():Void
	{
		flushFill();
		flushStroke();
	}

	private function flushFill():Void
	{
		if (fillPaint == null || fillPath == null) return;

		renderer.__beginVectors();
		canvas.fill(fillPath, fillPaint, evenOdd ? EvenOdd : NonZero, local, alpha);
		fillPath = new Path().moveTo(x, y);
	}

	private function flushStroke():Void
	{
		if (stroke == null || strokePath == null) return;

		renderer.__beginVectors();
		canvas.stroke(strokePath, stroke, strokePaint, local, alpha);
		strokePath = new Path().moveTo(x, y);
	}

	private static function roundRect(path:Path, rx:Float, ry:Float, w:Float, h:Float, radiusX:Float, radiusY:Float):Void
	{
		path.moveTo(rx + radiusX, ry)
			.lineTo(rx + w - radiusX, ry)
			.arcTo(radiusX, radiusY, 0, false, true, rx + w, ry + radiusY)
			.lineTo(rx + w, ry + h - radiusY)
			.arcTo(radiusX, radiusY, 0, false, true, rx + w - radiusX, ry + h)
			.lineTo(rx + radiusX, ry + h)
			.arcTo(radiusX, radiusY, 0, false, true, rx, ry + h - radiusY)
			.lineTo(rx, ry + radiusY)
			.arcTo(radiusX, radiusY, 0, false, true, rx + radiusX, ry)
			.close();
	}
}
#end
