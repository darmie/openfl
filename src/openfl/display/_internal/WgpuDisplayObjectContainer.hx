package openfl.display._internal;

#if (!flash && openfl_wgpu)
import openfl.display.DisplayObjectContainer;
import openfl.display.WgpuRenderer;

@:access(openfl.display.DisplayObject)
@:access(openfl.display.DisplayObjectContainer)
class WgpuDisplayObjectContainer
{
	public static function renderDrawable(displayObjectContainer:DisplayObjectContainer, renderer:WgpuRenderer):Void
	{
		displayObjectContainer.__cleanupRemovedChildren();

		if (!renderer.__canRender(displayObjectContainer) || displayObjectContainer.__worldAlpha <= 0) return;

		WgpuDisplayObject.renderDrawable(displayObjectContainer, renderer);

		renderer.__pushMaskObject(displayObjectContainer);

		for (child in displayObjectContainer.__children)
		{
			renderer.__renderDrawable(child);
			child.__renderDirty = false;
		}

		renderer.__popMaskObject(displayObjectContainer);

		displayObjectContainer.__renderDirty = false;
	}
}
#end
