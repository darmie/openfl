package openfl.display3D._internal;

#if (!flash && openfl_wgpu)
import gpu.BlendFactor;
import gpu.ColorWrite;
import gpu.CompareFunction;
import gpu.CullMode;
import gpu.StencilOperation;
import gpu.VertexFormat;
import openfl.display.Stage;
import openfl.display.Stage3D;
import openfl.errors.Error;
import openfl.geom.Rectangle;
import puffpuff.gpu.WgpuContext3D;

/**
	`Context3D` on WebGPU. Draws go into the window's frame as they are called, and the display list renders over them.
	Programs are HXSL (`Program3D.uploadHXSL`).
**/
@:access(openfl.display.Stage)
@:access(openfl.display3D.Context3D)
@:access(openfl.display3D.IndexBuffer3D)
@:access(openfl.display3D.Program3D)
@:access(openfl.display3D.VertexBuffer3D)
@:access(openfl.display3D.textures.TextureBase)
class Context3DWgpu
{
	public static function init(context:Context3D, stage:Stage, stage3D:Stage3D):Void
	{
		context.__stage = stage;
		context.__stage3D = stage3D;
		context.__wgpu = new WgpuContext3D(stage.window.context.wgpu);
		context.driverInfo = "WebGPU";
		context.maxBackBufferWidth = context.maxBackBufferHeight = 16384;

		// Flash's defaults: no blending, depth test always passes.
		setBlendFactors(context, ONE, ZERO);
		setDepthTest(context, true, ALWAYS);
	}

	public static function clear(context:Context3D, red:Float, green:Float, blue:Float, alpha:Float, depth:Float, stencil:UInt, mask:UInt):Void
	{
		var wgpu = context.__wgpu;
		wgpu.endRenderPass();
		touch(context);

		var color = mask & Context3DClearMask.COLOR != 0;
		var clearDepth = context.__depthEnabled && mask & Context3DClearMask.DEPTH != 0;
		var clearStencil = context.__depthEnabled && mask & Context3DClearMask.STENCIL != 0;
		wgpu.beginRenderPass(color ? red : null, green, blue, alpha, clearDepth ? depth : null, clearStencil ? stencil & 0xFF : null);
	}

	public static function configureBackBuffer(context:Context3D, width:Int, height:Int, enableDepthAndStencil:Bool):Void
	{
		context.backBufferWidth = width;
		context.backBufferHeight = height;
		context.__depthEnabled = enableDepthAndStencil;
		if (context.__renderToTexture == null) context.__wgpu.depthEnabled = enableDepthAndStencil;
	}

	public static function drawTriangles(context:Context3D, indexBuffer:IndexBuffer3D, firstIndex:Int, numTriangles:Int):Void
	{
		if (context.__cullAll || indexBuffer == null) return;
		if (!touch(context)) clearToStage(context);
		context.__wgpu.drawProgram(indexBuffer.__wgpuBuffer, firstIndex, numTriangles);
	}

	public static function present(context:Context3D):Void
	{
		context.__wgpu.endRenderPass();
		context.__present = true;
	}

	public static function setBlendFactors(context:Context3D, source:Context3DBlendFactor, destination:Context3DBlendFactor):Void
	{
		context.__wgpu.setBlendFactors(blendFactor(source), blendFactor(destination));
	}

	public static function setColorMask(context:Context3D, red:Bool, green:Bool, blue:Bool, alpha:Bool):Void
	{
		context.__wgpu.colorWriteMask = (red ? ColorWrite.RED : 0) | (green ? ColorWrite.GREEN : 0) | (blue ? ColorWrite.BLUE : 0)
			| (alpha ? ColorWrite.ALPHA : 0);
	}

	public static function setCulling(context:Context3D, face:Context3DTriangleFace):Void
	{
		// Neither face is drawn when both are culled.
		context.__cullAll = face == FRONT_AND_BACK;
		context.__wgpu.setCulling(switch (face)
		{
			case FRONT: CullMode.Front;
			case BACK: CullMode.Back;
			default: CullMode.None;
		});
	}

	public static function setDepthTest(context:Context3D, depthMask:Bool, mode:Context3DCompareMode):Void
	{
		context.__wgpu.setDepthTest(depthMask, compareFunction(mode));
	}

	private static function compareFunction(mode:Context3DCompareMode):CompareFunction
	{
		return switch (mode)
		{
			case ALWAYS: CompareFunction.Always;
			case NEVER: CompareFunction.Never;
			case EQUAL: CompareFunction.Equal;
			case GREATER: CompareFunction.Greater;
			case GREATER_EQUAL: CompareFunction.GreaterEqual;
			case LESS: CompareFunction.Less;
			case LESS_EQUAL: CompareFunction.LessEqual;
			case NOT_EQUAL: CompareFunction.NotEqual;
		}
	}

	private static function stencilOperation(action:Context3DStencilAction):StencilOperation
	{
		return switch (action)
		{
			case KEEP: StencilOperation.Keep;
			case ZERO: StencilOperation.Zero;
			case SET: StencilOperation.Replace;
			case INVERT: StencilOperation.Invert;
			case INCREMENT_SATURATE: StencilOperation.IncrementClamp;
			case DECREMENT_SATURATE: StencilOperation.DecrementClamp;
			case INCREMENT_WRAP: StencilOperation.IncrementWrap;
			case DECREMENT_WRAP: StencilOperation.DecrementWrap;
		}
	}

	/** One test for front and back faces; the face argument of `setStencilActions` is not used. **/
	public static function setStencilActions(context:Context3D, compare:Context3DCompareMode, bothPass:Context3DStencilAction,
			depthFail:Context3DStencilAction, stencilFail:Context3DStencilAction):Void
	{
		var wgpu = context.__wgpu;
		wgpu.stencilCompare = compareFunction(compare);
		wgpu.stencilPass = stencilOperation(bothPass);
		wgpu.stencilDepthFail = stencilOperation(depthFail);
		wgpu.stencilFail = stencilOperation(stencilFail);
	}

	public static function setStencilReferenceValue(context:Context3D, reference:UInt, readMask:UInt, writeMask:UInt):Void
	{
		var wgpu = context.__wgpu;
		wgpu.stencilReference = reference & 0xFF;
		wgpu.stencilReadMask = readMask & 0xFF;
		wgpu.stencilWriteMask = writeMask & 0xFF;
	}

	public static function setProgram(context:Context3D, program:Program3D):Void
	{
		context.__wgpu.program = program != null ? program.__hxsl : null;
	}

	public static function setRenderToBackBuffer(context:Context3D):Void
	{
		context.__renderToTexture = null;
		context.__wgpu.setRenderToBackBuffer();
		context.__wgpu.depthEnabled = context.__depthEnabled;
	}

	public static function setRenderToTexture(context:Context3D, texture:openfl.display3D.textures.TextureBase, enableDepthAndStencil:Bool):Void
	{
		context.__renderToTexture = texture;
		context.__wgpu.setRenderToTexture(texture.__wgpuTexture);
		context.__wgpu.depthEnabled = enableDepthAndStencil;
	}

	public static function setSamplerStateAt(context:Context3D, sampler:Int, wrap:Context3DWrapMode, filter:Context3DTextureFilter,
			mipfilter:Context3DMipFilter):Void
	{
		context.__wgpu.setSamplerAt(sampler, wrap == REPEAT, filter != NEAREST, switch (mipfilter)
		{
			case MIPLINEAR: 2;
			case MIPNEAREST: 1;
			default: 0;
		});
	}

	public static function setScissorRectangle(context:Context3D, rectangle:Rectangle):Void
	{
		if (rectangle == null)
		{
			context.__wgpu.disableScissor();
		}
		else
		{
			context.__wgpu.setScissorRectangle(Std.int(rectangle.x), Std.int(rectangle.y), Math.ceil(rectangle.width), Math.ceil(rectangle.height));
		}
	}

	public static function setTextureAt(context:Context3D, sampler:Int, texture:openfl.display3D.textures.TextureBase):Void
	{
		context.__wgpu.setTextureAt(sampler, texture != null ? texture.__wgpuTexture : null);
	}

	public static function setVertexBufferAt(context:Context3D, index:Int, buffer:VertexBuffer3D, bufferOffset:Int, format:Context3DVertexBufferFormat):Void
	{
		if (index < 0) return;

		context.__wgpu.setVertexBufferAt(index, buffer != null ? buffer.__wgpuBuffer : null, bufferOffset, switch (format)
		{
			case BYTES_4: VertexFormat.Unorm8x4;
			case FLOAT_1: VertexFormat.Float32;
			case FLOAT_2: VertexFormat.Float32x2;
			case FLOAT_3: VertexFormat.Float32x3;
			case FLOAT_4: VertexFormat.Float32x4;
		});
	}

	public static function unsupported(what:String):Dynamic
	{
		throw new Error(what + " isn't supported with openfl_wgpu. Programs are HXSL: see Program3D.uploadHXSL.");
	}

	/** A draw or clear into the window tells the stage not to clear it before the display list. False if this was the frame's first. **/
	private static inline function touch(context:Context3D):Bool
	{
		if (context.__renderToTexture != null) return true;

		var stage = context.__stage;
		var first = !stage.__stage3DDrawn;
		stage.__stage3DDrawn = true;
		return !first;
	}

	/** A frame whose first Stage3D call draws shows the stage color behind it, as the stage would clear it. **/
	private static function clearToStage(context:Context3D):Void
	{
		var color = context.__stage.__colorSplit;
		var wgpu = context.__wgpu;
		wgpu.endRenderPass();
		wgpu.beginRenderPass(color[0], color[1], color[2], 1.0, context.__depthEnabled ? 1.0 : null);
	}

	private static function blendFactor(factor:Context3DBlendFactor):BlendFactor
	{
		return switch (factor)
		{
			case ZERO: BlendFactor.Zero;
			case ONE: BlendFactor.One;
			case SOURCE_COLOR: BlendFactor.Src;
			case ONE_MINUS_SOURCE_COLOR: BlendFactor.OneMinusSrc;
			case SOURCE_ALPHA: BlendFactor.SrcAlpha;
			case ONE_MINUS_SOURCE_ALPHA: BlendFactor.OneMinusSrcAlpha;
			case DESTINATION_COLOR: BlendFactor.Dst;
			case ONE_MINUS_DESTINATION_COLOR: BlendFactor.OneMinusDst;
			case DESTINATION_ALPHA: BlendFactor.DstAlpha;
			case ONE_MINUS_DESTINATION_ALPHA: BlendFactor.OneMinusDstAlpha;
		}
	}
}
#end
