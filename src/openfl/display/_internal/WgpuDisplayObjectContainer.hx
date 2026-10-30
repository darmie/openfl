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

		if (!displayObjectContainer.__renderable || displayObjectContainer.__worldAlpha <= 0) return;

		WgpuDisplayObject.renderDrawable(displayObjectContainer, renderer);

		for (child in displayObjectContainer.__children)
		{
			renderer.__renderDrawable(child);
			child.__renderDirty = false;
		}

		displayObjectContainer.__renderDirty = false;
	}
}
#end
