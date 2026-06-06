package tool.lt;

class EntityTool extends tool.LayerTool<Int> {
	public var curEntityDef(get,never) : Null<data.def.EntityDef>;
	static var PREV_CHAINABLE_EI: Null<data.inst.EntityInstance>;

	public var group : GenericLevelElementGroup;

	// Edge insertion state
	var edgeInsertSnap : Null<{ fi:data.inst.FieldInstance, ei:data.inst.EntityInstance, li:data.inst.LayerInstance, insertIdx:Int, snapX:Float, snapY:Float }> = null;
	var edgeInsertGraphics : h2d.Graphics;

	public function getCurrentlyEditedEntity(): Null<data.inst.EntityInstance> {
		if (editor.curTool != this || !canEdit())
			return null;

		var sel = editor.selectionTool;
		if (!sel.isSingle())
			return null;

		return switch @:privateAccess sel.group.getElement(0) {
			case Entity(li, ei) if (li == curLayerInstance):
				ei;
			case PointField(li, ei, _, _) if (li == curLayerInstance):
				ei;
			case _:
				null;
		}
	}

	public function isEntityBeingEdited(ei: data.inst.EntityInstance): Bool {
		if (ei == null || !canEdit())
			return false;

		var sel = editor.selectionTool;
		if (!sel.isSingle())
			return false;

		return switch (sel.group.getElement(0)) {
			case Entity(li, selectedEi) if (li == curLayerInstance && selectedEi == ei):
				true;
			case _:
				false;
		}
	}

	public function new() {
		super();

		edgeInsertGraphics = new h2d.Graphics();
		editor.levelRender.root.add(edgeInsertGraphics, Const.DP_UI);

		if( curEntityDef==null && project.defs.entities.length>0 )
			selectValue( project.defs.entities[0].uid );
	}

	override function onGlobalEvent(ev:GlobalEvent) {
		super.onGlobalEvent(ev);

		switch ev {
			case LevelRestoredFromHistory(_), LayerInstancesRestoredFromHistory(_):
				cancelRefChaining();

			case _:
		}
	}

	public static inline function cancelRefChaining() {
		Editor.ME.levelRender.clearTemp();
		PREV_CHAINABLE_EI = null;
	}

	public inline function isChainingRef() {
		return getEntityChainableFieldInstance(PREV_CHAINABLE_EI)!=null;
	}

	override function onBeforeToolActivation() {
		super.onBeforeToolActivation();

		if( curEntityDef==null )
			selectValue( getDefaultValue() );
	}

	inline function get_curEntityDef() return project.defs.getEntityDef( getSelectedValue() );

	override function selectValue(v:Int) {
		super.selectValue(v);
	}

	override function canEdit():Bool {
		return super.canEdit() && getSelectedValue()>=0 && settings.v.showDetails;
	}

	override function getDefaultValue():Int{
		if( project.defs.entities.length>0 ) {
			var ld = curLayerInstance.def;
			if( ld.requiredTags.isEmpty() && ld.excludedTags.isEmpty() )
				return project.defs.entities[0].uid;

			for(ed in project.defs.entities)
				if( ( ld.requiredTags.isEmpty() || ed.tags.hasAnyTagFoundIn(ld.requiredTags) )
				  && ( ld.excludedTags.isEmpty() || !ed.tags.hasAnyTagFoundIn(ld.excludedTags) ) )
					return ed.uid;

			return -1;
		}
		else
			return -1;
	}

	function getPlacementX(m:Coords) {
		return snapToGrid()
			? M.round( ( m.cx + curEntityDef.pivotX ) * curLayerInstance.def.gridSize )
			: m.levelX;
	}

	function getPlacementY(m:Coords) {
		return snapToGrid()
			? M.round( ( m.cy + curEntityDef.pivotY ) * curLayerInstance.def.gridSize)
			: m.levelY;
	}

	function getEdgeInsertSnap(m:Coords, ei: data.inst.EntityInstance) : Null<{ fi:data.inst.FieldInstance, ei:data.inst.EntityInstance, li:data.inst.LayerInstance, insertIdx:Int, snapX:Float, snapY:Float }> {

		final snapDist = 15.0 / editor.camera.adjustedZoom;
		var bestDist = snapDist;
		var best = null;

		for( fi in ei.fieldInstances ) {
			if( fi.def.type != F_Point )
				continue;

			var isPath = switch fi.def.editorDisplayMode {
				case PointPath, PointPathLoop: true;
				case _: false;
			}
			if( !isPath )
				continue;

			var n = fi.getArrayLength();
			if( n < 1 )
				continue;

			var isLoop = fi.def.editorDisplayMode == PointPathLoop;

			// Build the full list of level-space vertices, starting from entity origin
			var verts : Array<{ x:Float, y:Float }> = [];

			var li = ei._li;

			// First vertex: entity point origin (level space)
			verts.push({
				x: ei.getPointOriginX(li.def) + li.pxTotalOffsetX,
				y: ei.getPointOriginY(li.def) + li.pxTotalOffsetY,
			});

			// Remaining vertices: the actual array points
			for( i in 0...n ) {
				var pt = fi.getPointGrid(i);
				if( pt == null )
					verts.push(null);
				else
					verts.push({
						x: (pt.cx + 0.5) * li.def.gridSize + li.pxTotalOffsetX,
						y: (pt.cy + 0.5) * li.def.gridSize + li.pxTotalOffsetY,
					});
			}

			// Now check each segment.
			// verts[0] is the entity origin (not an array element).
			// verts[1..n] correspond to fi array indices 0..n-1.
			// Inserting between verts[i] and verts[i+1] means insertIdx = i (array index).
			var segCount = isLoop ? verts.length : verts.length - 1;

			for( seg in 0...segCount ) {
				var a = verts[seg];
				var b = verts[(seg + 1) % verts.length];
				if( a == null || b == null )
					continue;

				var mx = m.levelX * 1.0;
				var my = m.levelY * 1.0;

				var dx = b.x - a.x;
				var dy = b.y - a.y;
				var lenSq = dx*dx + dy*dy;
				if( lenSq < 0.001 )
					continue;

				var t = ( (mx - a.x)*dx + (my - a.y)*dy ) / lenSq;
				t = Math.max(0.0, Math.min(1.0, t));

				var nearX = a.x + t*dx;
				var nearY = a.y + t*dy;
				var dist = Math.sqrt( (mx-nearX)*(mx-nearX) + (my-nearY)*(my-nearY) );

				if( dist < bestDist ) {
					bestDist = dist;
					// seg=0 means between origin and array[0], so insertIdx=0
					// seg=1 means between array[0] and array[1], so insertIdx=1
					// etc.

					// TODO - if snapToGrid is on, we should snap nearX/nearY to grid before returning them, otherwise the inserted point will be off-grid.
					// Only do this if we ever store points as floats.
					/*if( !snapToGrid() ) {
					var gridSize = li.def.gridSize;
					nearX = Std.int( (nearX - li.pxTotalOffsetX) / gridSize );
					nearY = Std.int( (nearY - li.pxTotalOffsetY) / gridSize );*/

					best = {
						fi: fi,
						ei: ei,
						li: li,
						insertIdx: seg,
						snapX: nearX,
						snapY: nearY,
					};
				}
			}
		}

		return best;
	}

	override function onMouseMoveCursor(ev:hxd.Event, m:Coords) {
		super.onMouseMoveCursor(ev, m);
		updateChainRefPreview(m);
	}

	override function customCursor(ev:hxd.Event, m:Coords) {
		super.customCursor(ev,m);

		// editor.levelRender.clearTemp();

		if( curEntityDef==null ) {
			editor.cursor.set(Forbidden);
			ev.cancel = true;
		}
		else if( !settings.v.showDetails ) {
			editor.cursor.set(Forbidden);
			ev.cancel = true;
		}
		else if( isRunning() && curMode==Remove ) {
			editor.cursor.set( Eraser(m.levelX,m.levelY) );
			ev.cancel = true;
		}
		else if( curLevel.inBounds(m.levelX, m.levelY) ) {
			var ge = editor.getGenericLevelElementAt(m, true);
			switch ge {
				case Entity(li, ei):
					editor.cursor.set( Entity(curLayerInstance, ei.def, ei, ei.x, ei.y, true) );
					editor.cursor.overrideNativeCursor("grab");

				case PointField(li, ei, fi, arrayIdx):
					editor.cursor.set(Move);
					// var pt = fi.getPointGrid(arrayIdx);
					// editor.cursor.set( GridCell(curLayerInstance, pt.cx, pt.cy, ei.getSmartColor(false)) );
					// editor.cursor.overrideNativeCursor("grab");

				case _:
					editor.cursor.set( Entity(curLayerInstance, curEntityDef, getPlacementX(m), getPlacementY(m), false) );
			}
			ev.cancel = true;
			updateChainRefPreview(m);
		}
	}


	override function startUsing(ev:hxd.Event, m:Coords, ?extraParam:String) {
		super.startUsing(ev,m,extraParam);

		if( edgeInsertSnap != null ) {
			var snap = edgeInsertSnap;
			edgeInsertSnap = null;
			edgeInsertGraphics.clear();

			var gridSize = snap.li.def.gridSize;
			var cx = Std.int( (snap.snapX - snap.li.pxTotalOffsetX) / gridSize );
			var cy = Std.int( (snap.snapY - snap.li.pxTotalOffsetY) / gridSize );

			snap.fi.insertArrayValue(snap.insertIdx);
			snap.fi.parseValue(snap.insertIdx, cx + Const.POINT_SEPARATOR + cy);

			editor.ge.emit( EntityFieldInstanceChanged(snap.ei, snap.fi) );
			editor.curLevelTimeline.markEntityChange(snap.ei);
			editor.curLevelTimeline.saveLayerState(snap.li);

			stopUsing(m);
			ev.cancel = true;
			return;
		}

		var ge = editor.getGenericLevelElementAt(m, true);
		switch ge {
			case Entity(li,ei) if( ev.button==0 ):
				if( tryToChainRefTo(PREV_CHAINABLE_EI, ei) )
					PREV_CHAINABLE_EI = ei;
				if( !editor.gifMode )
					editor.selectionTool.selectAndStartUsing( ev, m, Entity(curLayerInstance,ei) );
				stopUsing(m);
				return;

			case PointField(_) if( ev.button==0 ):
				editor.selectionTool.startUsing(ev,m);
				stopUsing(m);
				return;

			case _:
		}

		if( ev.button!=2 )
			editor.selectionTool.clear();

		switch curMode {
			case null:
			case Add:
				if( curLevel.inBounds(m.levelX, m.levelY) ) {
					// Create entity
					var ei : data.inst.EntityInstance = null; // will stay null if some limit prevents adding more
					if( curEntityDef.maxCount<=0 )
						ei = curLayerInstance.createEntityInstance(curEntityDef);
					else {
						// Apply count limit
						var all = project.getAllEntitiesFromLimitScope(curLayerInstance, curEntityDef, curEntityDef.limitScope);
						switch curEntityDef.limitBehavior {
							case DiscardOldOnes:
								while( all.length>=curEntityDef.maxCount ) {
									var otherEi = all.shift();
									otherEi._li.removeEntityInstance( otherEi );
									editor.ge.emit( EntityInstanceRemoved(otherEi) );
								}
								ei = curLayerInstance.createEntityInstance(curEntityDef);

							case PreventAdding:
								if( all.length<curEntityDef.maxCount )
									ei = curLayerInstance.createEntityInstance(curEntityDef);
								else
									N.error(L.t._("You cannot have more than ::n:: ::name::.", { n:curEntityDef.maxCount, name:curEntityDef.identifier }));

							case MoveLastOne:
								if( all.length>=curEntityDef.maxCount && all.length>0 ) {
									var otherEi = all.pop();
									otherEi._li.removeEntityInstance(otherEi);
									curLayerInstance.entityInstances.push(otherEi);
									editor.levelRender.invalidateLayer(curLayerInstance);
									editor.ge.emit( EntityInstanceRemoved(otherEi) );
									ei = otherEi;
								}
								else
									ei = curLayerInstance.createEntityInstance(curEntityDef);
						}
					}

					// Done
					if( ei!=null ) {
						var prevEi = PREV_CHAINABLE_EI;

						// Finalize entity
						ei.x = getPlacementX(m);
						ei.y = getPlacementY(m);
						onEditAnything();
						stopUsing(m);
						if( ei.def.isResizable() ) {
							editor.selectionTool.select([ Entity(curLayerInstance, ei) ]);
							if( editor.resizeTool!=null )
								editor.resizeTool.startUsing(ev, m);
						}
						else if( !editor.gifMode )
							editor.selectionTool.selectAndStartUsing( ev, m, Entity(curLayerInstance,ei) );
						ei.tidy(project, curLayerInstance); // Force creation of field instances & update _li
						LOG.userAction("Added entity "+ei);

						// Try to auto chain previous entity to the new one
						var chainFi = getEntityChainableFieldInstance(prevEi);
						if( chainFi!=null ) {
							if( tryToChainRefTo(prevEi, ei) ) {
								LOG.userAction("  Created ref "+prevEi+" => "+ei);
								PREV_CHAINABLE_EI = ei;
							}
							else
								cancelRefChaining();
						}
						else
							PREV_CHAINABLE_EI = ei;
						updateChainRefPreview(m);

						editor.ge.emit( EntityInstanceAdded(ei) );
					}
				}

			case Remove:
				cancelRefChaining();
				if( removeAnyEntityOrPointAt(m) ) {
					ev.cancel  = true;
					onEditAnything();
				}
		}
	}

	override function stopUsing(m:Coords) {
		edgeInsertSnap = null;
		edgeInsertGraphics.clear();

		super.stopUsing(m);
	}

	function removeAnyEntityOrPointAt(m:Coords) {
		var ge = editor.getGenericLevelElementAt(m, true);
		switch ge {
			case Entity(curLayerInstance, instance):
				editor.curLevelTimeline.markEntityChange(instance);
				curLayerInstance.removeEntityInstance(instance);
				editor.ge.emit( EntityInstanceRemoved(instance) );
				editor.levelRender.bleepEntity(instance);
				return true;

			case PointField(li, ei, fi, arrayIdx):
				var pt = fi.getPointGrid(arrayIdx);
				if( pt!=null && pt.cx==m.cx && pt.cy==m.cy ) {
					if( fi.def.isArray )
						fi.removeArrayValue(arrayIdx);
					else
						fi.parseValue(arrayIdx, null);
					editor.ge.emit( EntityFieldInstanceChanged(ei,fi) );
					editor.selectionTool.select([ GenericLevelElement.Entity(li,ei) ]);
					editor.levelRender.bleepPoint(
						(pt.cx+0.5) * li.def.gridSize,
						(pt.cy+0.5) * li.def.gridSize,
						ei.getSmartColor(true)
					);
					return true;
				}
				else
					return false;

			case _:
		}

		return false;
	}


	function updateChainRefPreview(m:Coords) {
		if( PREV_CHAINABLE_EI==null )
			return;

		editor.levelRender.clearTemp();

		if( m==null )
			return;

		var chainFi = getEntityChainableFieldInstance(PREV_CHAINABLE_EI);
		if( chainFi!=null && chainFi.def.acceptsEntityRefTo(PREV_CHAINABLE_EI, curEntityDef, curLevel) ) {
			var ge = editor.getGenericLevelElementAt(m);
			final alpha = 0.33;
			switch ge {
				case Entity(li, ei):
					display.FieldInstanceRender.renderRefLink(
						editor.levelRender.temp, PREV_CHAINABLE_EI.getSmartColor(true),
						PREV_CHAINABLE_EI.worldX + PREV_CHAINABLE_EI._li.pxTotalOffsetX - curLevel.worldX,
						PREV_CHAINABLE_EI.worldY + PREV_CHAINABLE_EI._li.pxTotalOffsetY - curLevel.worldY,
						ei.getRefAttachX(chainFi.def) + ei._li.pxTotalOffsetX,
						ei.getRefAttachY(chainFi.def) + ei._li.pxTotalOffsetY,
						alpha,
						chainFi.def.editorLinkStyle,
						Full
					);

				case _:
					display.FieldInstanceRender.renderRefLink(
						editor.levelRender.temp, PREV_CHAINABLE_EI.getSmartColor(true),
						PREV_CHAINABLE_EI.worldX + PREV_CHAINABLE_EI._li.pxTotalOffsetX - curLevel.worldX,
						PREV_CHAINABLE_EI.worldY + PREV_CHAINABLE_EI._li.pxTotalOffsetY - curLevel.worldY,
						getPlacementX(m) + curLayerInstance.pxTotalOffsetX,
						getPlacementY(m) + curLayerInstance.pxTotalOffsetY,
						alpha,
						chainFi.def.editorLinkStyle,
						Full
					);
			}
		}
	}


	function getEntityChainableFieldInstance(fromEi:data.inst.EntityInstance) : Null<data.inst.FieldInstance> {
		if( fromEi==null )
			return null;

		if( fromEi._li==null || !fromEi._li.containsEntity(fromEi) ) {
			// Prev was lost
			return null;
		}
		else {
			// Check if previously added entity has a field with "autoChainRef" enabled
			for(prevFi in fromEi.fieldInstances) {
				if( prevFi.def.type!=F_EntityRef || !prevFi.def.autoChainRef )
					continue;

				// Render link preview
				if( prevFi.def.acceptsEntityRefTo(fromEi, curEntityDef, curLevel) )
					return prevFi;
			}
			return null;
		}
	}


	/**
		Chain previous EI to target, and return TRUE if chaining should go on
	**/
	function tryToChainRefTo(sourceEi:data.inst.EntityInstance, targetEi:data.inst.EntityInstance) {
		var chainFi = getEntityChainableFieldInstance(sourceEi);
		if( chainFi==null )
			return false;

		if( !chainFi.def.acceptsEntityRefTo(sourceEi, targetEi.def, curLevel) )
			return false;

		if( chainFi.def.isArray )
			chainFi.addArrayValue();
		chainFi.setEntityRefTo(chainFi.getArrayLength()-1, sourceEi, targetEi);

		// Save history properly (only if both entities are in the same level)
		if( sourceEi._li.levelId==targetEi._li.levelId ) {
			editor.curLevelTimeline.markEntityChange(sourceEi);
			editor.curLevelTimeline.saveLayerState(sourceEi._li);
		}
		editor.ge.emit( EntityInstanceChanged(sourceEi) );
		return chainFi.def.isArray || !chainFi.def.symmetricalRef;
	}


	override function onMouseMove(ev:hxd.Event, m:Coords) {
		super.onMouseMove(ev,m);

		// Recompute edge snap whenever mouse moves, regardless of what's under cursor
		edgeInsertGraphics.clear();
		edgeInsertSnap = null;
		

		if( !ev.cancel ) {
			var ge = editor.getGenericLevelElementAt(m);
			switch ge {
				case Entity(_), PointField(_): editor.selectionTool.onMouseMove(ev,m);
				case _:
					var editedEi = getCurrentlyEditedEntity();

					// Only allow point insertion if currently editing a point field entity and not hovered over something

					if (editedEi != null) {
						// There is an entity currently being edited
						// You can do global logic here, or compare to hovered one
						//Sys.println('Currently editing: ' + editedEi.def.identifier);
						
						if( !isRunning() ) {
							edgeInsertSnap = getEdgeInsertSnap(m, editedEi);
							
							if( edgeInsertSnap != null ) {
								var zs = 1.0 / editor.camera.adjustedZoom;
								var r = 5.0 * zs;
								edgeInsertGraphics.lineStyle(2 * zs, 0x00ff88, 1.0);
								edgeInsertGraphics.beginFill(0x00ff88, 0.35);
								edgeInsertGraphics.drawCircle(edgeInsertSnap.snapX, edgeInsertSnap.snapY, r);
								edgeInsertGraphics.endFill();
							}
						}
					}
			}
		}
	}


	override function useAt(m:Coords, isOnStop) {
		super.useAt(m,isOnStop);

		switch curMode {
			case null:
			case Add:

			case Remove:
				cancelRefChaining();
				if( removeAnyEntityOrPointAt(m) )
					return true;
		}

		return false;
	}

	override function useOnRectangle(m:Coords, left:Int, right:Int, top:Int, bottom:Int) {
		super.useOnRectangle(m, left, right, top, bottom);
		return false;
	}


	override function createToolPalette():ui.ToolPalette {
		return new ui.palette.EntityPalette(this);
	}

	override function update() {
		super.update();

		// Suspend chain preview during ALT selections
		if( App.ME.isAltDown() )
			updateChainRefPreview(null);

		// Check if chainable entity lost
		if( PREV_CHAINABLE_EI!=null && PREV_CHAINABLE_EI._li!=null && !PREV_CHAINABLE_EI._li.containsEntity(PREV_CHAINABLE_EI) )
			cancelRefChaining();
	}
}