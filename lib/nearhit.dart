import 'dart:developer' as debug;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

double distanceFromRect(Offset p, Rect r) {
  var mc = (p - r.center);
  var hw = r.size.width / 2;
  var hh = r.size.height / 2;
  if (mc.dx.abs() < hw) {
    return mc.dy.abs() - hh;
  }
  if (mc.dy.abs() < hh) {
    return mc.dx.abs() - hw;
  }
  return [
    (r.topLeft - p).distance,
    (r.topRight - p).distance,
    (r.bottomLeft - p).distance,
    (r.bottomRight - p).distance,
  ].fold(double.infinity, min);
}

/// Nearhitting is when your widgets can be activated from indirect clicks, that is, clicks that were just fairly close to them and not closer to any other widgets. It often creates better ergonomics.
/// mix this in if you want to be clickable in a nearhit scope. Doing so will prevent you from being nearhitted yourself.
/// there should maybe be a version of this for RenderObjects, but I haven't needed it yet.
mixin NearhitRecipientRenderObject on RenderBox {
  /// from is relative to this one's offset
  double distance(Offset from) {
    return distanceFromRect(from, Offset.zero & size);
  }
}

Offset robjOffset(RenderBox v) {
  if (v.parentData is BoxParentData) {
    return (v.parentData as BoxParentData).offset;
  } else {
    return Offset.zero;
  }
}

/// catches click events that didn't hit any child widgets, penetrates most widgets, and transmits click events to the nearest descendent NearhitRecipient (or other NearhitRecipientRenderObject producing widgets). This allows a much wider tollerance for grabs, ensures that there aren't dead spaces in the UI where clicking does nothing, which all generally feels nicer to interact with. It makes it easier to lay widgets out spacially and visually, since it means that you no longer have to have widgets take up the entire hit region.
/// again, it will only nearhit on descendents if every child widget containing them bleeds. Widgets do not bleed by default. I should probably try to offer a widget that causes its descendents to bleed, but then I'd also want to provide a BleedStopper.
/// treats child as permeable even if it isn't.
class NearhitScope extends SingleChildRenderObjectWidget {
  /// if the mouse event is this far away from the nearest widget, even the nearest widget wont be clicked
  final double maxDistance;
  const NearhitScope({required super.child, this.maxDistance = 90, super.key});
  @override
  RenderObject createRenderObject(BuildContext context) {
    return NearhitScopeRobj(
      maxDistance: maxDistance,
    );
  }
}

bool expect(bool condition, String expectation) {
  if (!condition) {
    debug.log(expectation, level: 4);
  }
  return condition;
}

class NearhitScopeRobj extends RenderProxyBoxWithHitTestBehavior {
  final double maxDistance;
  NearhitRecipientContainerRobj? currentlyHoveredRecipient;
  NearhitScopeRobj(
      {required this.maxDistance,
      super.child,

      /// this should probably never be set to anything else
      super.behavior = HitTestBehavior.opaque});

  @override
  void performLayout() {
    child!.layout(constraints, parentUsesSize: true);
    size = child!.size;
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    var nearestOffset = Offset.zero;
    NearhitRecipientRenderObject? nearestSoFar;
    var distance = maxDistance;

    void descendOn(Offset relTo, RenderObject cur) {
      if (cur is RenderBox) {
        var dr = distanceFromRect(position - relTo, (robjOffset(cur) & size));
        if (dr < distance) {
          if (cur is NearhitRecipientRenderObject) {
            var nd = cur.distance(position - relTo);
            if (nd < distance) {
              nearestOffset = relTo;
              nearestSoFar = cur;
              distance = nd;
            }
          } else {
            cur.visitChildren((c) => descendOn(relTo + robjOffset(cur), c));
          }
        }
      }
    }

    descendOn(Offset.zero, child!);

    if (nearestSoFar != null) {
      result.addWithPaintOffset(
          offset: nearestOffset,
          position: position,
          hitTest: (result, pr) => nearestSoFar!.hitTest(result, position: pr));
      result.add(NearhitTestEntry(this, position, hitChild: nearestSoFar));
      return true;
    } else {
      return false;
    }
  }
}

class NearhitTestEntry extends BoxHitTestEntry {
  NearhitRecipientRenderObject? hitChild;
  NearhitTestEntry(super.target, super.localPosition, {this.hitChild});
}

class NearhitRecipient extends SingleChildRenderObjectWidget {
  final void Function(Offset at)? onPointerDown;
  final void Function(Offset at, bool to)? onHoverChange;
  const NearhitRecipient(
      {super.child, this.onPointerDown, this.onHoverChange, super.key});
  @override
  RenderObject createRenderObject(BuildContext context) {
    return NearhitRecipientContainerRobj(
        onPointerDown: onPointerDown, onHoverChange: onHoverChange);
  }
}

class NearhitRecipientContainerRobj extends RenderProxyBoxWithHitTestBehavior
    with NearhitRecipientRenderObject
    implements MouseTrackerAnnotation {
  Function(Offset at)? onPointerDown;
  final void Function(Offset at, bool to)? onHoverChange;

  @override
  late final PointerEnterEventListener? onEnter;
  @override
  late final PointerExitEventListener? onExit;
  @override
  MouseCursor get cursor {
    if (child is MouseTrackerAnnotation) {
      return (child as MouseTrackerAnnotation).cursor;
    } else {
      return MouseCursor.defer;
    }
  }

  @override
  bool validForMouseTracker = true;

  NearhitRecipientContainerRobj({this.onPointerDown, this.onHoverChange})
      : super(behavior: HitTestBehavior.opaque) {
    onEnter = (e) {
      onHoverChange?.call(e.position, true);
    };
    onExit = (e) {
      onHoverChange?.call(e.position, false);
    };
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (hitTestChildren(result, position: position) || hitTestSelf(position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    } else {
      return false;
    }
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) {
      onPointerDown?.call(event.position);
    } else if (event is PointerEnterEvent) {
      onHoverChange?.call(event.position, true);
    } else if (event is PointerExitEvent) {
      onHoverChange?.call(event.position, false);
    }
    super.handleEvent(event, entry);
  }

  // tombstone: this was copied from MouseRegion. Without it, events will still be received after widget disposal. Disgusting, but presumably according to design for some reason.
  @override
  void detach() {
    validForMouseTracker = false;
    super.detach();
  }

  // tombstone: I added the above not knowing it would break hover events without the below!
  @override
  void attach(PipelineOwner owner) {
    validForMouseTracker = true;
    super.attach(owner);
  }

  // has to catch everything, including out of bound hits. We don't know what the maxDistance is going to be, so we have to just accept any distance :<
  @override
  bool hitTestSelf(Offset position) {
    return true;
  }
}
