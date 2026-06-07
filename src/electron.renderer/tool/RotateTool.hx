package tool;

class RotateTool extends Tool<Int> {
	static var DEFAULT_ALPHA = 0.75;
	static var HANDLE_RADIUS = 5;
	static var HANDLE_DIST = 16;

	var g : h2d.Graphics;
	var ge : GenericLevelElement;
	var rotatedAnything = false;
	var isDragging = false;
	var invalidated = true;
	var _handlePos : Null<{ x:Float, y:Float }>;

	public function new(ge:GenericLevelElement) {
		super();
		this.ge = ge;
		createRootInLayers(editor.levelRender.root, Const.DP_UI);
		g = new h2d.Graphics(root);
		g.alpha = DEFAULT_ALPHA;
		render();
	}

	function getEntity() : Null<data.inst.EntityInstance> {
		return switch ge {
			case Entity(li, ei): ei;
			case _: null;
		}
	}

	// Returns handle position in level space (absolute, like ResizeTool handles)
	function getHandlePos() : { x:Float, y:Float } {
		if( _handlePos != null )
			return _handlePos;

		var ei = getEntity();
		if( ei == null ) return { x:0, y:0 };

		// Local offset: centered horizontally, above top edge
		var localX = ei.width * (0.5 - ei.def.pivotX);
		var localY = -ei.height * ei.def.pivotY - HANDLE_DIST;

		// Rotate local offset by entity rotation
		var angle = ei.getEffectiveRotation() * Math.PI / 180;
		var cos = Math.cos(angle);
		var sin = Math.sin(angle);
		var rotX = localX * cos - localY * sin;
		var rotY = localX * sin + localY * cos;

		// Add entity position to get level-space coords
		_handlePos = {
			x: ei.x + rotX,
			y: ei.y + rotY,
		}
		return _handlePos;
	}

	function render() {
		g.clear();
		var ei = getEntity();
		if( ei == null ) return;

		var hp = getHandlePos();
		var zoomScale = 1 / Editor.ME.camera.adjustedZoom;

		// Line from entity position to handle
		g.lineStyle(1 * zoomScale, 0xff9100, 0.6);
		var lineEnd = {
			x: ei.x + (hp.x - ei.x) * 0.5,
			y: ei.y + (hp.y - ei.y) * 0.5,
		};
		g.moveTo(lineEnd.x, lineEnd.y);
		g.lineTo(hp.x, hp.y);

		// Handle circle
		g.lineStyle(1 * zoomScale, 0x0, 0.5);
		g.beginFill(0xff9100, 1);
		g.drawCircle(hp.x, hp.y, HANDLE_RADIUS * 0.6, 16);
		g.endFill();
	}

	function isOverHandle(m:Coords) : Bool {
		var hp = getHandlePos();
		var dist = M.dist(m.levelX, m.levelY, hp.x, hp.y);
		return dist <= HANDLE_RADIUS * 2;
	}

	public function onMouseDown(ev:hxd.Event, m:Coords) {
		if( isOverHandle(m) )
			startUsing(ev, m);
	}

	override function startUsing(ev:hxd.Event, m:Coords, ?extraParam:String) {
		super.startUsing(ev, m, extraParam);
		rotatedAnything = false;
		isDragging = true;
		ev.cancel = true;
	}

	override function stopUsing(m:Coords) {
		super.stopUsing(m);
		isDragging = false;
		if( rotatedAnything ) {
			switch ge {
				case Entity(li, ei):
					editor.curLevelTimeline.markEntityChange(ei);
					editor.curLevelTimeline.saveLayerState(li);
				case _:
			}
		}
	}

	override function onMouseMoveCursor(ev:hxd.Event, m:Coords) {
		super.onMouseMoveCursor(ev, m);
		if( ev.cancel ) return;

		if( isOverHandle(m) || isDragging ) {
			editor.cursor.set( Pointer );
			ev.cancel = true;
		}
	}

	override function onMouseMove(ev:hxd.Event, m:Coords) {
		super.onMouseMove(ev, m);

		if( !isDragging ) {
			g.alpha = isOverHandle(m) ? 1.0 : DEFAULT_ALPHA;
			return;
		}

		ev.cancel = true;
		g.alpha = 1.0;

		var ei = getEntity();
		if( ei == null ) return;

		var dx = m.levelX - ei.x;
		var dy = m.levelY - ei.y;
		var angle = Math.atan2(dy, dx) * 180 / Math.PI + 90;
		angle = angle % 360;
		if( angle < 0 ) angle += 360;

		if( ei.def.rotationSnapDegrees > 0 ) {
			var snap = ei.def.rotationSnapDegrees;
			angle = M.round(angle / snap) * snap % 360;
		}

		ei.rotation = angle;
		invalidate();
		rotatedAnything = true;
		editor.ge.emit( EntityInstanceChanged(ei) );
	}

	override function onGlobalEvent(ev:GlobalEvent) {
		super.onGlobalEvent(ev);
		switch ev {
			case EntityInstanceChanged(ei):
				if( isOnEntity(ei) )
					invalidate();

			case EntityInstanceRemoved(ei):
				if( isOnEntity(ei) )
					editor.clearRotateTool();

			case ViewportChanged(_):
				invalidate();

			case _:
		}
	}

	public function isOnEntity(targetEi:data.inst.EntityInstance) {
		return switch ge {
			case Entity(li, ei): ei == targetEi;
			case _: false;
		}
	}

	public inline function invalidate() {
		invalidated = true;
	}

	override function isRunning() : Bool {
		return isDragging;
	}

	override function postUpdate() {
		super.postUpdate();
		if( invalidated ) {
			_handlePos = null; // clear cache so it recalculates
			render();
			invalidated = false;
		}
	}
}