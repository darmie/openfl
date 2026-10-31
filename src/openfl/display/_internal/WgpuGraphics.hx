package openfl.display._internal;

#if (!flash && openfl_wgpu)
import openfl.display.BitmapData;
import openfl.display.CapsStyle;
import openfl.display.GradientType;
import openfl.display.Graphics;
import openfl.display.JointStyle;
import openfl.display.SpreadMethod;
import openfl.display.TriangleCulling;
import openfl.display.WgpuRenderer;
import openfl.geom.ColorTransform;
import openfl.geom.Matrix;
import openfl.Vector;
import puffpuff.canvas.Affine;
import puffpuff.canvas.Canvas2D;
import puffpuff.canvas.Paint;
import puffpuff.canvas.Paint.PaintKind;
import puffpuff.canvas.Path;
import puffpuff.canvas.Stroke;
import puffpuff.gpu.TriangleBatcher;
import puffpuff.gpu.WgpuContext3D.WgpuTexture;

/**
	Draws `Graphics` commands with `Canvas2D`: solid and gradient fills and line styles, nonzero and even-odd.
	`drawQuads`, `drawTriangles` and bitmap-filled rectangles use textured quads and triangles. Gradients: four stops,
	pad/reflect/repeat, any matrix, no focal point or linearRGB. Fill and stroke keep separate paths, since a line style
	change ends the stroke segment but not the fill.
**/
@:access(openfl.display.Graphics)
@:access(openfl.display.WgpuRenderer)
class WgpuGraphics
{
	public static function render(graphics:Graphics, renderer:WgpuRenderer, local:Affine, alpha:Float, colorTransform:ColorTransform = null):Void
	{
		var commands = graphics.__commands;
		if (commands == null || commands.length == 0) return;

		var state = new WgpuGraphicsState(renderer, local, alpha, colorTransform);
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
					state.beginPaint(WgpuGraphicsState.gradient(c.type, c.colors, c.alphas, c.ratios, c.matrix, c.spreadMethod, colorTransform));

				case BEGIN_BITMAP_FILL:
					var c = data.readBeginBitmapFill();
					state.beginBitmapFill(c.bitmap, c.matrix, c.repeat, c.smooth);

				case DRAW_TRIANGLES:
					var c = data.readDrawTriangles();
					state.drawTriangles(c.vertices, c.indices, c.uvtData, c.culling);

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
					state.strokePaint = WgpuGraphicsState.gradient(c.type, c.colors, c.alphas, c.ratios, c.matrix, c.spreadMethod, colorTransform);

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
	private var colorTransform:ColorTransform;
	private var bitmap:BitmapData;
	private var bitmapSmooth:Bool;
	private var bitmapRepeat:Bool;
	private var bitmapMatrix:Matrix;
	private var solidRgba:Int;
	private var alpha:Float;
	private var fillPaint:Paint;
	private var fillPath:Path;
	private var stroke:Stroke;
	private var strokePath:Path;
	private var x:Float = 0;
	private var y:Float = 0;

	public function new(renderer:WgpuRenderer, local:Affine, alpha:Float, colorTransform:ColorTransform)
	{
		this.colorTransform = colorTransform;
		this.renderer = renderer;
		this.canvas = renderer.canvas;
		this.local = local;
		this.alpha = alpha;
	}

	public function beginFill(color:Int, fillAlpha:Float):Void
	{
		beginPaint(fillAlpha < 0.005 ? null : Paint.solid(WgpuColor.rgb(color, colorTransform), fillAlpha));
		solidRgba = fillAlpha < 0.005 ? 0 : rgba(WgpuColor.rgb(color, colorTransform), WgpuColor.alpha(fillAlpha, colorTransform) * alpha);
	}

	public function beginPaint(paint:Paint):Void
	{
		flushFill();
		bitmap = null;
		solidRgba = 0;
		fillPaint = paint;
		fillPath = paint == null ? null : new Path().moveTo(x, y);
	}

	/**
		Gradient paint. The matrix maps the gradient box onto the shape. Linear runs along x from -819.2 to 819.2,
		radial has radius 819.2.
	**/
	public static function gradient(type:GradientType, colors:Array<Int>, alphas:Array<Float>, ratios:Array<Int>, matrix:Matrix, spread:SpreadMethod,
			colorTransform:ColorTransform = null):Paint
	{
		var stops = [];
		for (i in 0...colors.length)
		{
			stops.push({offset: ratios[i] / 255, rgb: WgpuColor.rgb(colors[i], colorTransform), alpha: alphas[i]});
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
		Bitmap sampled by `drawQuads`, `drawTriangles` and `drawRect`. Other bitmap-filled paths aren't drawn yet, so a
		bitmap fill ends any other fill.
	**/
	public function beginBitmapFill(bitmapData:BitmapData, matrix:Matrix, repeat:Bool, smooth:Bool):Void
	{
		beginPaint(null);
		bitmap = bitmapData;
		bitmapMatrix = matrix;
		bitmapRepeat = repeat;
		bitmapSmooth = smooth;
	}

	/** 8-bit tint with red in the low byte, as `TriangleBatcher` wants. **/
	private static function rgba(rgb:Int, a:Float):Int
	{
		var alpha = Math.round((a < 0 ? 0 : (a > 1 ? 1 : a)) * 255);
		return ((rgb >> 16) & 0xFF) | (rgb & 0xFF00) | ((rgb & 0xFF) << 16) | (alpha << 24);
	}

	/**
		Draws triangles with the current fill. Bitmap fill uses `uvtData` (two or three values per vertex, third is
		perspective), or the vertex position within the bounds if there's none. Solid fill just colors them. `culling`
		drops triangles by winding.
	**/
	public function drawTriangles(vertices:Vector<Float>, indices:Vector<Int>, uvtData:Vector<Float>, culling:TriangleCulling):Void
	{
		flushFill();
		flushStroke();

		if (vertices == null || vertices.length < 6) return;

		var texture:WgpuTexture = null;
		var tint = 0xFFFFFFFF;
		var smooth = false;
		var repeat = false;
		var premultiplied = false;
		var invW = 1.0, invH = 1.0;

		if (bitmap != null)
		{
			texture = WgpuBitmap.texture(bitmap, renderer.__context.wgpu.context3D);
			if (texture == null) return;

			premultiplied = WgpuBitmap.isPremultiplied(bitmap);
			smooth = renderer.__allowSmoothing && bitmapSmooth;
			repeat = bitmapRepeat;
			invW = 1 / texture.width;
			invH = 1 / texture.height;
			tint = rgba(WgpuColor.tint(colorTransform), WgpuColor.alpha(1, colorTransform) * alpha);
		}
		else
		{
			if (solidRgba == 0) return;
			tint = solidRgba;
		}

		var numVertices = Math.floor(vertices.length / 2);
		var hasUV = bitmap != null && uvtData != null && uvtData.length >= numVertices * 2;
		var stride = hasUV && uvtData.length >= numVertices * 3 ? 3 : 2;
		var length = indices != null ? indices.length : numVertices;

		renderer.__beginTriangles(texture, premultiplied, smooth, repeat);
		var triangles = renderer.__triangles;

		var i = 0;
		while (i + 2 < length)
		{
			var i0 = indices != null ? indices[i] : i;
			var i1 = indices != null ? indices[i + 1] : i + 1;
			var i2 = indices != null ? indices[i + 2] : i + 2;
			i += 3;

			var x0 = vertices[i0 * 2], y0 = vertices[i0 * 2 + 1];
			var x1 = vertices[i1 * 2], y1 = vertices[i1 * 2 + 1];
			var x2 = vertices[i2 * 2], y2 = vertices[i2 * 2 + 1];

			// Winding as authored. GL renderer culls on this sign before any transform.
			var area = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0);
			switch (culling)
			{
				case POSITIVE: if (area >= 0) continue;
				case NEGATIVE: if (area <= 0) continue;
				default:
			}

			emit(triangles, x0, y0, i0, hasUV, uvtData, stride, tint, invW, invH);
			emit(triangles, x1, y1, i1, hasUV, uvtData, stride, tint, invW, invH);
			emit(triangles, x2, y2, i2, hasUV, uvtData, stride, tint, invW, invH);
		}
	}

	private inline function emit(triangles:TriangleBatcher, x:Float, y:Float, index:Int, hasUV:Bool, uvt:Vector<Float>, stride:Int, tint:Int, invW:Float,
			invH:Float):Void
	{
		var u:Float, v:Float, t = 1.0;
		if (hasUV)
		{
			u = uvt[index * stride];
			v = uvt[index * stride + 1];
			if (stride == 3) t = uvt[index * stride + 2];
		}
		else
		{
			// No texture coordinates: vertex maps to the bitmap pixel at its own position.
			u = x * invW;
			v = y * invH;
		}

		triangles.vertex(local.a * x + local.c * y + local.e, local.b * x + local.d * y + local.f, u, v, t, tint);
	}

	/**
		Draws a rectangle filled with the bitmap. Inverse of the fill matrix gives each corner's bitmap position.
	**/
	private function bitmapRect(rx:Float, ry:Float, w:Float, h:Float):Void
	{
		var texture = WgpuBitmap.texture(bitmap, renderer.__context.wgpu.context3D);
		if (texture == null) return;

		var m = bitmapMatrix;
		var det = m == null ? 1.0 : m.a * m.d - m.b * m.c;
		if (det == 0) return;

		var ia = 1.0, ib = 0.0, ic = 0.0, id = 1.0, itx = 0.0, ity = 0.0;
		if (m != null)
		{
			ia = m.d / det;
			ib = -m.b / det;
			ic = -m.c / det;
			id = m.a / det;
			itx = -(ia * m.tx + ic * m.ty);
			ity = -(ib * m.tx + id * m.ty);
		}

		var invW = 1 / texture.width;
		var invH = 1 / texture.height;
		var tint = rgba(WgpuColor.tint(colorTransform), WgpuColor.alpha(1, colorTransform) * alpha);

		renderer.__beginTriangles(texture, WgpuBitmap.isPremultiplied(bitmap), renderer.__allowSmoothing && bitmapSmooth, bitmapRepeat);
		var triangles = renderer.__triangles;

		var xs = [rx, rx + w, rx, rx, rx + w, rx + w];
		var ys = [ry, ry, ry + h, ry + h, ry, ry + h];
		for (k in 0...6)
		{
			var x = xs[k], y = ys[k];
			triangles.vertex(local.a * x + local.c * y + local.e, local.b * x + local.d * y + local.f, (ia * x + ic * y + itx) * invW,
				(ib * x + id * y + ity) * invH, 1, tint);
		}
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

		var tint = WgpuColor.tint(colorTransform);
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
				rects[ri + 1] * invH, w * invW, h * invH, alpha, tint);
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
		strokePaint = Paint.solid(WgpuColor.rgb(color, colorTransform), lineAlpha);
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
		if (bitmap != null)
		{
			flushStroke();
			bitmapRect(rx, ry, w, h);
		}

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
