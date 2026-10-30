package openfl.display._internal;

#if (!flash && openfl_wgpu)
import openfl.display.CapsStyle;
import openfl.display.Graphics;
import openfl.display.JointStyle;
import openfl.display.WgpuRenderer;
import puffpuff.canvas.Affine;
import puffpuff.canvas.Canvas2D;
import puffpuff.canvas.Paint;
import puffpuff.canvas.Path;
import puffpuff.canvas.Stroke;

/**
	Draws the commands of a `Graphics` with `Canvas2D`: solid fills and solid line styles, with the
	nonzero and even-odd rules. The fill and the stroke accumulate separate paths, because a line
	style change ends the stroke segment but not the fill.
**/
@:access(openfl.display.Graphics)
class WgpuGraphics
{
	public static function render(graphics:Graphics, renderer:WgpuRenderer, local:Affine, alpha:Float):Void
	{
		var commands = graphics.__commands;
		if (commands == null || commands.length == 0) return;

		var state = new WgpuGraphicsState(renderer.canvas, local, alpha);
		var data = new DrawCommandReader(commands);

		for (type in commands.types)
		{
			switch (type)
			{
				case BEGIN_FILL:
					var c = data.readBeginFill();
					state.beginFill(c.color, c.alpha);

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

private class WgpuGraphicsState
{
	public var evenOdd:Bool = false;

	private var canvas:Canvas2D;
	private var local:Affine;
	private var alpha:Float;
	private var fillPaint:Paint;
	private var fillPath:Path;
	private var stroke:Stroke;
	private var strokePaint:Paint;
	private var strokePath:Path;
	private var x:Float = 0;
	private var y:Float = 0;

	public function new(canvas:Canvas2D, local:Affine, alpha:Float)
	{
		this.canvas = canvas;
		this.local = local;
		this.alpha = alpha;
	}

	public function beginFill(color:Int, fillAlpha:Float):Void
	{
		flushFill();
		fillPaint = fillAlpha < 0.005 ? null : Paint.solid(color & 0xFFFFFF, fillAlpha);
		fillPath = fillPaint == null ? null : new Path().moveTo(x, y);
	}

	public function endFill():Void
	{
		flushFill();
		fillPaint = null;
		fillPath = null;
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

		canvas.fill(fillPath, fillPaint, evenOdd ? EvenOdd : NonZero, local, alpha);
		fillPath = new Path().moveTo(x, y);
	}

	private function flushStroke():Void
	{
		if (stroke == null || strokePath == null) return;

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
