import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:developer' as debug;
import 'dart:ui';

// import 'package:flutter/cupertino.dart';
// import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hsluv/hsluvcolor.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';
import 'package:tree_edit/keybindings.dart';
import 'package:tree_edit/nearhit.dart';
import 'package:tree_edit/smooth_animation.dart';
import 'package:tree_edit/util.dart';
// import 'package:super_editor/super_editor.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    var parentTheme = Theme.of(context);
    return MaterialApp(
      title: 'tree edit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorScheme: parentTheme.colorScheme
              .copyWith(surfaceDim: const Color.fromARGB(255, 230, 230, 230)),
          textTheme: const TextTheme(
              displaySmall: TextStyle(
            color: Color.fromARGB(255, 84, 84, 84),
            fontSize: 17,
            fontWeight: FontWeight.bold,
          ))),
      home: const BrowsingWindow(title: 'tree edit'),
    );
  }
}

class TreeView extends StatefulWidget {
  final String fileName;
  late final TreeWidgetConf conf;
  TreeView(this.fileName, {TreeWidgetConf? conf, super.key}) {
    this.conf = conf ?? TreeWidgetConf();
  }

  @override
  State<TreeView> createState() {
    return TreeViewState();
  }
}

abstract class TreeEdit {
  void apply(TreeViewState ts);
  void undo(TreeViewState ts);
}

/// deleting a whole segment from the tree. Contrast with "DeleteSpill", which deletes just a node and spills its children into the parent.
class TreeDelete extends TreeEdit {
  final TreeNode snapshot;
  late final TreeCursor at;
  final bool deleteEntireSegment;
  TreeDelete({required this.snapshot, required this.deleteEntireSegment}) {
    at = TreeCursor((snapshot.key as GNKey).currentState!.widget.parent!,
            snapshot.key as GNKey)
        .next()!;
  }
  @override
  void apply(TreeViewState ts) {
    ts.rawDelete(snapshot, spillContents: !deleteEntireSegment);
  }

  @override
  undo(TreeViewState ts) {
    ts.rawInsert(at, encompassingContents: !deleteEntireSegment, snapshot);
    // I think this feels better for some reason, but it's frivolous, and causes a crash because the widget isn't mounted yet. I guess we're being punished for using the widget states/id as our model. Take heed. A time will come when we can no longer do that.
    // ts.cursorPlacement.value = CursorPlacement.forKeyboardCursor(
    // TreeCursor.addressInParent(snapshot.key as GNKey));
  }
}

class TreeInsertNode extends TreeEdit {
  late final TreeNode tw;
  final TreeCursor insertAt;

  /// how many of the nodes in insertAt.into are encompassed by tw (these nodes are assumed/asserted to equal the nodes that are in insertAt.into at that insertion range, and that many nodes at that range will be removed)
  final int encompassing;
  TreeInsertNode(
      {required this.insertAt, required this.tw, required this.encompassing});
  TreeInsertNode.fresh({required this.insertAt, required this.encompassing}) {
    // tw = TreeNode.fromJson({"value": text, "children": const []}, insertAt.into,
    //     key: GlobalKey(debugLabel: "TreeNode"));
    int depth = (insertAt.into.currentWidget as TreeNode).depth + 1;
    GNKey nn = GlobalKey<TreeNodeState>(debugLabel: "created TreeNode");
    int ii = insertAt.index();
    tw = TreeNode(insertAt.into, "",
        initiallyEdited: true,
        key: nn,
        depth: depth,
        children: List.unmodifiable(snoop(insertAt.into.currentState!.children)
            .getRange(ii, ii + encompassing)
            .map((tn) => tn.redepthed(depth + 1, parent: nn))));
  }

  @override
  void apply(TreeViewState ts) {
    ts.rawInsert(insertAt, tw, encompassingContents: encompassing != 0);
  }

  @override
  void undo(TreeViewState ts) {
    ts.rawDelete(tw, spillContents: encompassing != 0);
  }
}

enum NodeCursorState {
  none,
  before,
  after,
  inside,

  /// in which case there's another cursor in the way
  focused,
}

bool whetherVisible(NodeCursorState v) =>
    !(v == NodeCursorState.none || v == NodeCursorState.focused);

/// points to a position in the tree. Notably, doesn't just point at a tree node, because it's possible for it to point at the position at the end of a parent tree node, where there currently is no node.
@immutable
class TreeCursor {
  // into may get invalidated, so don't rely on it unless you're in bofore==null mode
  final GNKey into;
  // null if it's pointing at the end
  final GNKey? before;
  const TreeCursor(this.into, this.before);

  static TreeCursor addressInParent(GNKey na) {
    return TreeCursor((na.currentWidget! as TreeNode).parent!, na);
  }

  // we don't just assume we should use `into`. The method we use here instead will still get the correct parent even if `before` has been moved into a new parent since this TreeCursor was made. `into` is only necessary when we're pointing at the end of the node.
  GNKey parent() =>
      before != null ? before!.currentState!.widget.parent! : into;

  List<TreeNode> parentChildren() => snoop(parent().currentState!.children);

  int index() {
    var pc = parentChildren();
    if (before == null) {
      return pc.length;
    } else {
      return pc.indexWhere((c) => c.key == before);
    }
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is TreeCursor && other.into == into && other.before == before);
  }

  @override
  int get hashCode => Object.hash(into, before);

  @override
  String toString() {
    return 'TreeCursor(into: ${into.toString()}, before: ${before?.toString() ?? "null"})';
  }

  TreeCursor? nextFirmly() {
    if (before == null) {
      return parentCursor()?.nextFirmly();
    }
    var pca = parentChildren();
    int i = pca.indexWhere((c) => c.key == before);
    if (i + 1 < pca.length) {
      return TreeCursor(into, pca[i + 1].key as GNKey);
    } else {
      return TreeCursor(into, null);
    }
  }

  TreeCursor? prevFirmly() {
    var pca = parentChildren();
    int i =
        before != null ? pca.indexWhere((c) => c.key == before) : pca.length;
    if (i > 0) {
      return TreeCursor(into, pca[i - 1].key as GNKey);
    } else {
      return parentCursor()?.prevFirmly();
    }
  }

  TreeCursor? next() {
    if (before == null) {
      return null;
    }
    var pca = parentChildren();
    int i = pca.indexWhere((c) => c.key == before);
    if (i + 1 < pca.length) {
      return TreeCursor(into, pca[i + 1].key as GNKey);
    } else {
      return TreeCursor(into, null);
    }
  }

  TreeCursor? prev() {
    var pca = parentChildren();
    int i =
        before != null ? pca.indexWhere((c) => c.key == before) : pca.length;
    if (i > 0) {
      return TreeCursor(into, pca[i - 1].key as GNKey);
    } else {
      return null;
    }
  }

  TreeCursor moveOverBy(int by) {
    var pc = parentChildren();
    int to = max(0, min(index() + by, pc.length));
    var bef = to < pc.length ? pc[to].key as GNKey : null;
    return TreeCursor(into, bef);
  }

  TreeCursor? parentCursor() {
    var ps = into.currentState!;
    var pp = ps.widget.parent;
    if (pp != null) {
      return TreeCursor(pp, into);
    } else {
      return null;
    }
  }

  TreeCursor? firstChild() {
    return before != null
        ? TreeCursor(before!,
            snoop(before!.currentState!.children).firstOrNull?.key as GNKey?)
        : null;
  }

  // usually the cursor is pointing at a node, but not always
  GNKey? get selectingNode => before;
}

enum EditingMode {
  mousing,
  typing,
  keyboardNavigating,
}

typedef GNKey = GlobalKey<TreeNodeState>;

// all of the info about where the cursors are
class CursorPlacement {
  // used for insertions and keyboard control
  TreeCursor insertionCursor;
  // used for deletion and wrapping, is also the one that displays the cursor
  GNKey targetNode;
  // and how it's going to display it
  NodeCursorState hostedHow;
  CursorPlacement({
    required this.insertionCursor,
    required this.targetNode,
    required this.hostedHow,
  });

  static CursorPlacement forKeyboardCursor(TreeCursor v) {
    var vc = v.parentChildren();
    CursorPlacement doin(GNKey targetNode, NodeCursorState cs) =>
        CursorPlacement(
            insertionCursor: v, targetNode: targetNode, hostedHow: cs);
    return v.before != null
        ? doin(v.before!, NodeCursorState.before)
        : vc.isNotEmpty
            ? doin(vc.lastOrNull?.key as GNKey, NodeCursorState.after)
            : doin(v.into, NodeCursorState.inside);
  }
}

class TreeViewState extends State<TreeView>
    with SignalsMixin, TickerProviderStateMixin {
  late Signal<String> fileName;
  late final StreamController<TreeEdit> edits;
  // the focus that's selected when the user is selecting on the node level rather than the text level
  late final FocusNode nodeSelectionFocus;
  int rebuildCount = 0;
  late Computed<Future<Widget>> loadedFromFile;
  // these two are used to alter the behavior of left and right events when descending
  int nextJumpSpan = 0;
  bool downHeldFromDescend = false;
  // [todo] persist this
  late final Signal<List<Widget>> copyBuffer;
  FocusScopeNode focusScopeNode = FocusScopeNode(debugLabel: "TreeView");
  // gets set to whichever node is currently being edited
  late final Signal<GNKey?> editedNode;
  // gets set by the TreeNodes on hover, and when keyboard node selection moves around
  // computed from cursorPosition
  late final Computed<GNKey?> selectedNode;

  /// the location of the cursor when the user is dragging the mouse or navigating by keyboard (null when nothing is selected/when the mouse leaves)
  late final Signal<CursorPlacement?> cursorPlacement;
  late final Signal<GNKey?> hoveredNode;
  // is updated to whichever node was last indicated by either of the above signals, pretty much (don't set to it, we set to it)
  late final Computed<GNKey?> targetNode;
  List<void Function()> toDispose = [];
  Offset? currentLocalMousePosition;
  int undoStackEye = -1;
  EditingMode get mode {
    return focusScopeNode.focusedChild == null
        ? EditingMode.mousing
        : EditingMode.typing;
  }

  late final AnimationController blinkAnimation;

  List<TreeEdit> undoStack = [];
  late GNKey rootNode;

  // cursor animation state
  Offset cursorAt = Offset.zero;
  // whether the cursor is anywhere (to animate this properly, you need an array of previous cursorAt positions and when they each started fading down, then cull old images)
  bool cursorWhether = false;

  void applyTreeEdit(TreeEdit edit) {
    setState(() {
      undoStackEye += 1;
      if (undoStack.length <= undoStackEye) {
        undoStack.add(edit);
      } else {
        //doing it this way deletes events that previously may have been after undoStackEye
        undoStack.length = undoStackEye + 1;
        undoStack[undoStackEye] = edit;
      }
      edit.apply(this);
    });
  }

  void undo() {
    if (undoStackEye >= 0) {
      setState(() {
        undoStack[undoStackEye].undo(this);
        undoStackEye -= 1;
      });
    }
  }

  void redo() {
    if (undoStackEye + 1 < undoStack.length) {
      setState(() {
        undoStackEye += 1;
        undoStack[undoStackEye].apply(this);
      });
    }
  }

  /// p is relative to the TreeView.
  CursorPlacement findCursorPlacement(Offset p) {
    TreeWidgetConf conf = widget.conf;

    /// o is the position of ro relative to the root of the tree.
    CursorPlacement? descend(
        GNKey? parent, Offset o, TreeWidgetRenderObject ro) {
      // iterate over all of the children to find where in the sequence this is inserted.
      var children = snoop(ro.key!.currentState!.children);
      if (children.isEmpty) {
        return CursorPlacement(
            insertionCursor: TreeCursor(ro.key!, null),
            targetNode: ro.key!,
            hostedHow: NodeCursorState.inside);
      }
      // otherwise, check the first renderobject child (which is not a treenode), if we're in that, we still need to insert at ro
      var fcpd = ro.firstChild!.parentData as TreeWidgetParentData;
      Rect initialRect = (o + fcpd.offset) & ro.firstChild!.size;
      if (initialRect.contains(p)) {
        GNKey ck = children.first.key as GNKey;
        return CursorPlacement(
            insertionCursor: TreeCursor(ro.key!, ck),
            targetNode: ro.key!,
            hostedHow: NodeCursorState.inside);
      }
      // continue on to the children proper
      double verticalDistance(Offset op, Rect rr) =>
          max(-(op.dy - rr.top), (op.dy - rr.bottom));
      // iterate over all of the children, and return the closest thing from the closest line.
      // first take the distance from the initial element
      RenderBox closestInClosestLine = ro.firstChild!;
      int closestLine = 0;
      double closestLineDistance = verticalDistance(p, initialRect);
      // the closest within this line is kept in case this line turns out to be the closest one
      RenderBox? closestInThisLine = ro.firstChild;
      double closestDistanceWithinThisLine = distanceFromRect(p, initialRect);
      int currentLine = 0;
      TreeWidgetRenderObject? curChild =
          fcpd.nextSibling as TreeWidgetRenderObject;
      void noteEndOfLine() {
        if (currentLine == closestLine) {
          closestInClosestLine = closestInThisLine!;
        }
      }

      while (curChild != null) {
        var pd = curChild.parentData as TreeWidgetParentData;
        var nextChild = pd.nextSibling as TreeWidgetRenderObject?;
        Rect cr = bounds(o, curChild);

        if (pd.lineNumber != currentLine) {
          // end line
          noteEndOfLine();
          currentLine = pd.lineNumber;
          closestInThisLine = null;
          closestDistanceWithinThisLine = double.infinity;
        }

        double ld = verticalDistance(p, cr);
        if (ld < closestLineDistance) {
          currentLine = pd.lineNumber;
          closestLine = currentLine;
          closestLineDistance = ld;
        }
        var distance = distanceFromRect(p, cr);
        if (distance < closestDistanceWithinThisLine) {
          if (distance <= 0) {
            //then it's a *hit* unless the fringes miss
            double dodgeMargin = max(
                conf.insertBeforeZoneWhenAfterMin,
                min(conf.insertBeforeZoneWhenAfterMax,
                    conf.insertBeforeZoneWhenAfterRatio * curChild.size.width));
            // doesn't do right fringe dodge if it's at the end of the line or the beginning (wouldn't need to)
            if (nextChild != null &&
                (nextChild.parentData as TreeWidgetParentData).lineNumber ==
                    currentLine &&
                cr.right - p.dx < dodgeMargin) {
              return CursorPlacement(
                insertionCursor:
                    TreeCursor.addressInParent(curChild.key!).next()!,
                targetNode: curChild.key!,
                hostedHow: NodeCursorState.after,
              );
            } else if (p.dx - cr.left < dodgeMargin) {
              return CursorPlacement(
                insertionCursor: TreeCursor.addressInParent(curChild.key!),
                targetNode: curChild.key!,
                hostedHow: NodeCursorState.before,
              );
            } else {
              return descend(ro.key!, o + pd.offset, curChild);
            }
          }
          closestDistanceWithinThisLine = distance;
          closestInThisLine = curChild;
        }
        curChild = nextChild;
      }
      noteEndOfLine();
      //there were no hits, so use this closest info we just painstakingly assembled
      var cr = bounds(o, closestInClosestLine);
      TreeWidgetRenderObject cc() =>
          closestInClosestLine as TreeWidgetRenderObject;
      bool isAfter = cr.center.dx < p.dx;
      TreeCursor ic() => TreeCursor.addressInParent(cc().key!);
      return closestInClosestLine is TreeWidgetRenderObject
          ? CursorPlacement(
              insertionCursor: isAfter ? ic().next()! : ic(),
              targetNode: cc().key as GNKey,
              hostedHow:
                  isAfter ? NodeCursorState.after : NodeCursorState.before)
          : CursorPlacement(
              insertionCursor:
                  TreeCursor(ro.key!, children.firstOrNull?.key as GNKey?),
              targetNode: ro.key as GNKey,
              hostedHow: NodeCursorState.inside,
            );

      // TreeWidgetRenderObject? curChild =
      //     fcpd.nextSibling as TreeWidgetRenderObject;

      // bool hasFoundLine = false;
      // while (curChild != null) {
      //   //special case for first child
      //   TreeWidgetParentData parentData =
      //       curChild.parentData as TreeWidgetParentData;
      //   var nextSibling = parentData.nextSibling as TreeWidgetRenderObject?;
      //   Offset curOffset = o + parentData.offset;
      //   //ensure that we're (still) in the right line of subwidgets
      //   bool isLowEnough = p.dy >= curOffset.dy - conf.spacing / 2;

      //   bool isInLine = isLowEnough &&
      //       p.dy < curOffset.dy + curChild.size.height + conf.spacing / 2;
      //   if (isInLine) {
      //     hasFoundLine = true;
      //     if (p.dx < curOffset.dx + curChild.size.width) {
      //       double insertZoneMargin = max(
      //           conf.minInsertBeforeZone,
      //           min(conf.insertBeforeZoneMax,
      //               conf.insertBeforeZoneRatio * curChild.size.width));

      //       if (p.dx < curOffset.dx + insertZoneMargin) {
      //         // then insert before (this also covers the case where it's just between the end of the last and before the end of the insertBeforeZone)
      //         return CursorPlacement(
      //             insertionCursor: TreeCursor(ro.key as GNKey, curChild.key!),
      //             targetNode: curChild.key!,
      //             hostedHow: NodeCursorState.before);
      //       } else if (p.dx >
      //           curOffset.dx + curChild.size.width - insertZoneMargin) {
      //         // then insert after
      //         return CursorPlacement(
      //             insertionCursor:
      //                 TreeCursor(ro.key as GNKey, nextSibling?.key!),
      //             targetNode: curChild.key!,
      //             hostedHow: NodeCursorState.after);
      //       } else {
      //         return descend(ro.key!, curOffset, curChild);
      //       }
      //     }
      //   } else {
      //     if (hasFoundLine) {
      //       //then we've left a line without finding anything p was in, so p wont be in anything here
      //       break;
      //     }
      //   }
      //   if (nextSibling == null) {
      //     //end of the line
      //     //insert into the end of the line
      //     return CursorPlacement(
      //         insertionCursor: TreeCursor(ro.key!,
      //             (parentData.nextSibling as TreeWidgetRenderObject?)?.key),
      //         targetNode: curChild.key!,
      //         hostedHow: NodeCursorState.after);
      //   }
      //   curChild = nextSibling;
      // }
      // throw AssertionError(
      //     "*end of the line* code should have run before reaching this point in `cursorPlacementFor`");
    }

    //the rootnode can't be hit, so we don't call descend on it
    // var rootc = snoop(rootNode.currentState!.children);
    // if (rootc.isEmpty) {
    //   return TreeCursor(rootNode, null);
    // }
    // for (var tn in rootc) {
    //   var cro = (tn.key as GNKey).currentContext!.findRenderObject() as TreeWidgetRenderObject;
    //   descend(rootNode, (cro.parentData as TreeWidgetParentData).offset,
    //       cro);
    // }

    // [todo]: bug: offset.zero is wrong here. How are you getting p? That might remind you how to get the right offset.
    var roo =
        rootNode.currentContext!.findRenderObject() as TreeWidgetRenderObject;
    return descend(
        null,
        roo.localToGlobal(Offset.zero, ancestor: context.findRenderObject()),
        roo)!;
  }

  /// raw methods are called by TreeEdits. Ordinarily, to do such an operation, use a TreeEdit, as they're undoable.
  void rawInsert(TreeCursor at, TreeNode v,

      /// if true, it moves the GlobalKeys of the `v.children.length` nodes within the parent with `at`. We have to do this, because we have
      {bool encompassingContents = false}) {
    var parentState = v.parent!.currentState!;
    var cs = parentState.children;
    int ati = at.index();
    var nl = snoop(cs).toList();
    nl.insert(ati, v);
    if (encompassingContents) {
      //remove the copies of those nodes from the parent (they are already in v)
      assert(
          ati + 1 + v.children.length <= nl.length &&
              !Iterable.generate(v.children.length)
                  .any((i) => v.children[i].key != nl[ati + 1 + i as int].key),
          "snapshot.children should be the same (and as numerous) as those being encompassed from the parent");

      nl.removeRange(ati + 1, ati + 1 + v.children.length);
    }
    cs.value = nl;
  }

  void rawDelete(TreeNode snapshot, {required bool spillContents}) {
    var parentKey = snapshot.parent!;
    var parentState = parentKey.currentState!;
    bool cursorCaughtByDeletion = false;
    var tc = TreeCursor.addressInParent(snapshot.key as GNKey);
    TreeCursor newCursorIfCursorCaught = tc.prev() ??
        tc.parentCursor() ??
        tc.next() ??
        tc; //note, if tc.next() is null, that means tc was a null (ending) cursor, so tc is actually still valid
    var cp = snoop(cursorPlacement);
    void checkCursor(GNKey at) {
      if (!cursorCaughtByDeletion && cp != null) {
        if (cp.targetNode == at ||
            cp.insertionCursor.into == at ||
            cp.insertionCursor.before == at) {
          cursorCaughtByDeletion = true;
        }
      }
    }

    checkCursor(snapshot.key as GNKey);
    if (spillContents) {
      List<TreeNode> newList = [];
      // instead of copying c into the new children list, replace it with its contents
      for (var c in snoop(parentState.children)) {
        if (c.key == snapshot.key) {
          for (TreeNode cs in snapshot.children) {
            newList.add(cs.redepthed(snapshot.depth, parent: parentKey));
          }
        } else {
          newList.add(c);
        }
      }
      parentState.children.value = newList;
    } else {
      void checkCursorRecursively(GNKey v) {
        checkCursor(v);
        for (var c in snoop(v.currentState!.children)) {
          checkCursorRecursively(c.key as GNKey);
        }
      }

      checkCursorRecursively(snapshot.key as GNKey);

      parentState.children.value = snoop(parentState.children)
          .where((c) => c.key != snapshot.key)
          .toList();
    }

    if (cursorCaughtByDeletion) {
      cursorPlacement.value =
          CursorPlacement.forKeyboardCursor(newCursorIfCursorCaught);
    }
  }

  Widget coreWidgetFromJson(Map<String, dynamic> jsono, GNKey rootNode) {
    return NearhitScope(
        // maxDistance: TreeWidgetConf.of(context).maxDistance,
        maxDistance: 8,
        child: TreeNode.fromJson(jsono, null, key: rootNode, depth: 0));
  }

  TreeCursor? getInsertionPoint({required bool insertingAround}) {
    if (insertingAround) {
      var tn = snoop(targetNode);
      if (tn == null) {
        return null;
      } else {
        return TreeCursor.addressInParent(tn);
      }
    } else {
      var cp = snoop(cursorPlacement);
      return cp?.insertionCursor;
    }
  }

  void setMousePosition(Offset? v) {
    currentLocalMousePosition = v;
    if (currentLocalMousePosition != null) {
      cursorPlacement.value = findCursorPlacement(currentLocalMousePosition!);
    } else {
      cursorPlacement.value = null;
    }
  }

  Widget completeWidget(Widget coreWidget) {
    Action<I> cb<I extends Intent>(void Function(I) callback) =>
        CallbackAction<I>(onInvoke: (I i) {
          callback(i);
          return null;
        });

    return avoidNestingHell(end: coreWidget, [
      (r) => Focus(
          skipTraversal: true,
          onKeyEvent: (node, event) {
            if (event is KeyUpEvent &&
                (event.logicalKey == LogicalKeyboardKey.arrowDown)) {
              downHeldFromDescend = false;
              nextJumpSpan = 0;
            }
            return KeyEventResult.ignored;
          },
          child: r),
      (r) =>
          Provider<Sink<TreeEdit>>(create: (context) => edits.sink, child: r),
      (r) => MouseRegion(
          onExit: (_) {
            setMousePosition(null);
          },
          onEnter: (e) {
            setMousePosition(e.localPosition);
          },
          onHover: (e) {
            setMousePosition(e.localPosition);
          },
          // tombstone: There used to be a KeyEventResult.handled here, which was preventing any child focusNodes from getting key events. I couldn't accept that this was happening, because leafs were supposed to receive events before roots. But it's documented https://stackoverflow.com/questions/79038389/why-is-keyeventresult-handled-in-a-root-focus-blocking-the-keyevent-from-getting leafs, then roots, then other systems. Things are not processed in one pass over the widget tree. Perhaps for the better. More opportunity for systems to communicate.
          child: r),
      (r) => Shortcuts(
          shortcuts: keyboardShortcuts,
          child: Actions(actions: {
            DeleteSelected: cb<DeleteSelected>((d) {
              var tn = targetNode.value;
              if (tn != null) {
                applyTreeEdit(TreeDelete(
                    snapshot: tn.currentState!.regenerateWidgetTree(),
                    deleteEntireSegment: d.entireSegment));
              }
            }),
            CopySelected: cb<CopySelected>((c) {
              var tn = targetNode.value;
              if (tn != null) {
                copyBuffer.value = List.unmodifiable(snoop(copyBuffer).toList()
                  ..add(tn.currentState!.regenerateWidgetTree(depth: 0)));
                if (c.alsoDelete) {
                  applyTreeEdit(TreeDelete(
                      snapshot: tn.currentState!.regenerateWidgetTree(),
                      deleteEntireSegment: c.entireSegment));
                }
              }
            }),
            Paste: cb<Paste>((c) {
              var cpb = snoop(copyBuffer);
              if (cpb.isNotEmpty) {
                var insertionPoint =
                    getInsertionPoint(insertingAround: !c.entireSegment);
                if (insertionPoint != null) {
                  var cpbl = cpb.last as TreeNode;
                  if (c.deleteFromBuffer) {
                    copyBuffer.value =
                        List.unmodifiable(cpb.getRange(0, cpb.length - 1));
                  }

                  var depth =
                      (insertionPoint.into.currentWidget as TreeNode).depth + 1;

                  TreeNode rekeyRedepth(TreeNode v, int depth,
                      {required GNKey parent, bool initiallySelected = false}) {
                    var tk = (v.key as GNKey).currentWidget != null
                        ? GNKey(debugLabel: "pasted TreeNode")
                        : (v.key as GNKey);
                    return TreeNode(parent, v.initialContent,
                        key: tk,
                        initiallyEdited: false,
                        initiallySelected: initiallySelected,
                        depth: depth,
                        children: List.unmodifiable(v.children.map(
                            (c) => rekeyRedepth(c, depth + 1, parent: tk))));
                  }

                  // tombstone: realized the whole initiallySelected feature just didn't feel right xD well, we don't have to remove it, we can just turn it off.
                  var ni = rekeyRedepth(cpbl, depth,
                      initiallySelected: false, parent: insertionPoint.into);
                  applyTreeEdit(TreeInsertNode(
                      tw: ni,
                      insertAt: insertionPoint,
                      encompassing: c.entireSegment ? 0 : ni.children.length));
                }
              }
            }),
            Undo: cb<Undo>((c) {
              undo();
            }),
            Redo: cb<Redo>((c) {
              redo();
            }),
            CreateNode: cb<CreateNode>((c) {
              var ip = getInsertionPoint(insertingAround: c.insertAround);
              if (ip != null) {
                applyTreeEdit(TreeInsertNode.fresh(
                    insertAt: ip, encompassing: c.insertAround ? 1 : 0));
              }
            }),
            OpenActionBar: cb<OpenActionBar>((c) {
              throw UnimplementedError("OpenActionBar");
            }),
            Fold: cb<Fold>((c) {
              throw UnimplementedError("Fold");
            }),
            GoBack: cb<GoBack>((c) {
              throw UnimplementedError("GoBack");
            }),
            GoForward: cb<GoForward>((c) {
              throw UnimplementedError("GoForward");
            }),
            GoAccess: cb<GoAccess>((c) {
              throw UnimplementedError("GoAccess");
            }),
            GoUnaccess: cb<GoUnaccess>((c) {
              throw UnimplementedError("GoUnaccess");
            }),
            GoActivate: cb<GoActivate>((c) {
              var j = rootNode.currentState!.toJson();
              File(snoop(fileName)).writeAsString(jsonEncode(j));
            }),
            CursorAscend: cb<CursorAscend>((c) {
              CursorPlacement? cp = snoop(cursorPlacement);
              if (cp != null) {
                TreeCursor? nextValue = cp.insertionCursor.parentCursor();
                if (nextValue != null) {
                  cursorPlacement.value =
                      CursorPlacement.forKeyboardCursor(nextValue);
                }
              }
            }),
            CursorDescend: cb<CursorDescend>((c) {
              CursorPlacement? cp = snoop(cursorPlacement);
              if (cp != null) {
                downHeldFromDescend = true;
                nextJumpSpan =
                    snoop(cp.targetNode.currentState!.children).length;
                TreeCursor? nextValue = cp.insertionCursor.firstChild();
                if (nextValue != null) {
                  cursorPlacement.value =
                      CursorPlacement.forKeyboardCursor(nextValue);
                }
              }
            }),
            CursorRight: cb<CursorRight>((c) {
              CursorPlacement? cp = snoop(cursorPlacement);
              if (cp != null) {
                if (downHeldFromDescend) {
                  cursorPlacement.value = CursorPlacement.forKeyboardCursor(
                      cp.insertionCursor.moveOverBy(nextJumpSpan));
                  nextJumpSpan = max((nextJumpSpan / 2).floor(), 1);
                } else {
                  TreeCursor? nextValue = cp.insertionCursor.nextFirmly();
                  if (nextValue != null) {
                    cursorPlacement.value =
                        CursorPlacement.forKeyboardCursor(nextValue);
                    debug.log("${nextValue.before}", level: 3);
                  }
                }
              }
            }),
            CursorLeft: cb<CursorLeft>((c) {
              CursorPlacement? cp = snoop(cursorPlacement);
              if (cp != null) {
                if (downHeldFromDescend) {
                  cursorPlacement.value = CursorPlacement.forKeyboardCursor(
                      cp.insertionCursor.moveOverBy(-nextJumpSpan));
                  nextJumpSpan = max((nextJumpSpan / 2).floor(), 1);
                } else {
                  TreeCursor? prevValue = cp.insertionCursor.prevFirmly();
                  if (prevValue != null) {
                    cursorPlacement.value =
                        CursorPlacement.forKeyboardCursor(prevValue);
                  }
                }
              }
            }),
          }, child: r)),
      (r) => FocusScope(
            /// this has to be here or else the shortcuts wont be detected lol, no idea why shortcuts can't be passed autofocus true
            autofocus: true,
            child: Container(
                padding: EdgeInsets.all(widget.conf.spacing), child: r),
          ),
    ]);
  }

  @override
  initState() {
    super.initState();
    fileName = this.createSignal(widget.fileName);
    editedNode = Signal(null, debugLabel: "editedNode");
    toDispose.add(editedNode.dispose);
    cursorPlacement = Signal(null, debugLabel: "cursorPosition");
    toDispose.add(cursorPlacement.dispose);
    hoveredNode = Signal(null, debugLabel: "focusedNode");
    toDispose.add(hoveredNode.dispose);
    targetNode = Computed(() => cursorPlacement.value?.targetNode,
        debugLabel: "targetNode");
    toDispose.add(targetNode.dispose);
    //these two guarantee both that editedNode and selectedNode peek() always have a value, and that targetNode is whichever of the two most recently changed, and that if either becomes null, targetNode will revert to the other
    // toDispose.add(effect(() {
    //   targetNode.value = editedNode.value ?? snoop(selectedNode);
    // }));
    // toDispose.add(effect(() {
    //   targetNode.value = selectedNode.value ?? snoop(editedNode);
    // }));
    // toDispose.add(effect(() {
    //   var fn = hoveredNode.value;
    //   if (fn != null) {
    //     cursorPosition.value = TreeCursor.addressInParent(fn);
    //   }
    // }));

    toDispose.add(effect(() {
      //notify subject when they're being selected
      GNKey? tv = targetNode.value;
      targetNode.previousValue?.currentState?.targeted.value = false;
      tv?.currentState?.targeted.value = true;
    }));
    toDispose.add(effect(() {
      var cp = cursorPlacement.value;

      void notify(CursorPlacement v, bool status) {
        //update cursor graphic
        // ensure that it's mounted
        var csm = v.targetNode.currentState;
        if (csm != null) {
          csm.cursorState.value = status ? v.hostedHow : NodeCursorState.none;
        }
      }

      if (cursorPlacement.previousValue != null) {
        notify(cursorPlacement.previousValue!, false);
      }
      if (cp != null) {
        notify(cp, true);
      }
    }));
    copyBuffer = Signal([], debugLabel: "copyBuffer");
    toDispose.add(copyBuffer.dispose);
    rootNode = GlobalKey(debugLabel: "root TreeNode");
    edits = StreamController();
    loadedFromFile = this.createComputed(() => File(widget.fileName)
        .readAsString()
        .then((j) =>
            completeWidget(coreWidgetFromJson(jsonDecode(j), rootNode))));
    edits.stream.listen((e) {
      applyTreeEdit(e);
    });
    blinkAnimation = AnimationController(
        duration: Duration(milliseconds: widget.conf.cursorBlinkDuration),
        vsync: this)
      ..repeat();
    toDispose.add(blinkAnimation.dispose);
  }

  @override
  void dispose() {
    focusScopeNode.dispose();
    edits.close();
    editedNode.dispose();
    selectedNode.dispose();
    targetNode.dispose();
    for (var h in toDispose) {
      h();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var loadingMessage = const Text('loading');
    Widget result = StreamBuilder(
        stream: loadedFromFile.toStream(),
        builder: (context, sigst) {
          if (sigst.hasData) {
            return FutureBuilder(
              future: sigst.data!,
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  rebuildCount += 1;
                  debug.log(
                      "This is the ${rebuildCount}th time TreeView built. It's not reparsing json each time though, so it seems benign, but I'd still like to know why.",
                      level: 2);
                  return snapshot.data!;
                } else if (snapshot.hasError) {
                  return Text('error: ${snapshot.error.toString()}');
                } else {
                  return loadingMessage;
                }
              },
            );
          } else {
            debug.log("why is there a nonevent in this damned stream");
            return loadingMessage;
          }
        });
    result = MultiProvider(providers: [
      Provider<TreeWidgetConf>(create: (c) => widget.conf),
      Provider<TreeViewState>(create: (c) => this),
      Provider<BlinkAnimation>(
          create: (c) => BlinkAnimation(blinkAnimation.view)),
    ], child: result);
    return result;
  }
}

class BlinkAnimation {
  final Animation<double> v;
  BlinkAnimation(this.v);
}

/// an editable text node
class TreeNode extends StatefulWidget {
  final GNKey? parent;
  late final String initialContent;
  final int depth;
  late final List<TreeNode> children;
  final bool initiallySelected;
  final GlobalKey<EditableTextState> editableKey;
  final bool initiallyEdited;

  TreeNode.fromJson(Object json, this.parent,
      {required GNKey super.key,
      this.initiallyEdited = false,
      this.initiallySelected = false,
      required this.depth})
      : editableKey = GlobalKey(debugLabel: "editable") {
    var jso = json as Map<String, dynamic>;
    initialContent = jso["value"];
    children = List.unmodifiable(jso["children"].map((j) => TreeNode.fromJson(
        j, key as GNKey?,
        key: GlobalKey(debugLabel: "json"), depth: depth + 1)));
  }
  TreeNode.blank(
      {required this.parent,
      this.initiallyEdited = true,
      this.initiallySelected = true,
      super.key,
      required this.depth})
      : editableKey = GlobalKey(debugLabel: "EditableText") {
    initialContent = "";
    children = [];
  }
  TreeNode(this.parent, this.initialContent,
      {required super.key,
      this.initiallyEdited = false,
      required this.depth,
      this.initiallySelected = false,
      this.children = const [],
      GlobalKey<EditableTextState>? editableKey})
      : editableKey =
            editableKey ?? GlobalKey<EditableTextState>(debugLabel: "editable");
  @override
  TreeNodeState createState() {
    return TreeNodeState();
  }

  TreeNode redepthed(int depth, {GNKey? parent}) {
    return TreeNode(parent ?? this.parent, initialContent,
        initiallyEdited: initiallyEdited,
        depth: depth,
        editableKey: editableKey,
        key: key,
        children:
            List.unmodifiable(children.map((c) => c.redepthed(depth + 1))));
  }
}

class Unfocus extends Intent {
  const Unfocus();
}

String stringBeginning(String v) => v.substring(0, min(v.length, 5));

class TreeNodeState extends State<TreeNode> with SignalsMixin {
  late final Signal<String> content;
  late final Signal<List<TreeNode>> children;
  late final FocusNode editFocusNode;
  // these are retained because we need to check on deletion whether they're pointed at us
  late final Signal<GNKey?> retainedEditingNodeSignal;
  late final Signal<GNKey?> retainedHoverSignal;
  // how you get notified when you become the targeted node
  late final Signal<bool> targeted;
  // this is downstream of the treeview one
  late final Signal<NodeCursorState> cursorState;
  late TextEditingController editorController;
  bool hasFocus = false;
  late final Signal<bool> beingEdited;
  List<void Function()> toDispose = [];

  // I think the newer version changes some of these names to Editor and MutableDocumentComposer
  // late final DocumentEditor editor;
  // late final MutableDocument document;
  // late final DocumentComposer composer;
  TreeNodeState();

  Object toJson() {
    return {
      "value": snoop(content),
      "children": List.unmodifiable(
          snoop(children).map((v) => (v.key as GNKey).currentState!.toJson()))
    };
  }

  // gets an immutable shot of the current state and the states of all of the children, ready to remount, and also recalculates depths
  TreeNode regenerateWidgetTree({int? depth}) {
    int d = depth ?? widget.depth;
    return TreeNode(widget.parent, editorController.text,
        initiallyEdited: snoop(beingEdited),
        depth: d,
        editableKey: widget.editableKey,
        key: widget.key,
        children: List.unmodifiable(snoop(children).map((c) => (c.key as GNKey)
            .currentState!
            .regenerateWidgetTree(depth: d + 1))));
  }

  @override
  initState() {
    super.initState();
    beingEdited = this.createSignal(widget.initiallyEdited,
        debugLabel: "TreeNode edited node");
    TreeViewState treeView = Provider.of(context, listen: false);
    //retained to make sure we can unselect ourselves when we're deleted (we don't retain treeView because retaining states is bad)
    retainedHoverSignal = treeView.hoveredNode;
    retainedEditingNodeSignal = treeView.editedNode;
    toDispose.add(() {
      if (snoop(retainedHoverSignal) == widget.key) {
        retainedHoverSignal.value = null;
      }
    });
    toDispose.add(() {
      // tombstone: quiet leaver: There's a bug (?) ( https://github.com/flutter/flutter/issues/156285 ) with Focus where it doesn't unfocus when disposed, so we need to make sure that's called here:
      // note, the bug was resolved, this could be replaced with editFocusNode.addListener, and then we wouldn't need to retain the signals, because listeners are run before detachment.
      _editFocusHandler(false);
    });
    if (widget.initiallySelected) {
      treeView.cursorPlacement.value = CursorPlacement.forKeyboardCursor(
          TreeCursor.addressInParent(widget.key as GNKey));
    }

    cursorState =
        this.createSignal(NodeCursorState.none, debugLabel: "cursorState");

    targeted = this.createSignal(false, debugLabel: "targeted");

    content = this
        .createSignal(widget.initialContent, debugLabel: "TreeNode content");
    children =
        this.createSignal(widget.children, debugLabel: "TreeNode children");

    editFocusNode = FocusNode(debugLabel: "EditableText");

    toDispose.add(editFocusNode.dispose);
    editorController = TextEditingController(text: snoop(content));
    toDispose.add(editorController.dispose);
    if (widget.initiallyEdited) {
      editorController.selection =
          TextSelection(baseOffset: 0, extentOffset: snoop(content).length);
      editFocusNode.requestFocus();
    }

    // document = MutableDocument(
    //   nodes: [
    //     ParagraphNode(
    //       id: DocumentEditor.createNodeId(),
    //       text: AttributedText(content.value),
    //       // metadata: {
    //       //   'blockType': header1Attribution,
    //       // },
    //     )
    //   ],
    // );
    // editor = DocumentEditor(document: document);
  }

  _editFocusHandler(bool to) {
    var wk = widget.key as GNKey;
    if (to) {
      retainedEditingNodeSignal.value = wk;
    } else {
      editorController.selection = const TextSelection.collapsed(offset: 0);
      if (snoop(retainedEditingNodeSignal) == wk) {
        retainedEditingNodeSignal.value = null;
      }
    }
  }

  @override
  void didUpdateWidget(covariant TreeNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    // should we use beingSelected?
    // this should trigger a rebuild, which also updates depth
    children.value = widget.children;
  }

  // insertNode(String? text, int after){}
  @override
  Widget build(BuildContext context) {
    // notice focus changes
    var theme = Theme.of(context);
    // editFocusNode.addListener(() {
    //   setState(() {});
    // });
    // var color = focusNode.hasFocus
    // var color = hovering
    //     ? const Color.fromARGB(255, 87, 87, 87)
    //     : const Color(0xff000000);
    var color = const Color(0xff000000);
    var textTheme = theme.textTheme.bodySmall!.copyWith(color: color);

    // var result = TextField(
    //     decoration: null,
    //     minLines: null,
    //     maxLines: null,
    //     controller: controller);

    // mainly using EditableText instead of the above for forceLine
    // click drag for selection still doesn't work. But actually don't fix that, we also want rich text, so we're going to switch to SuperEditor
    // var ic = stringBeginning(content.value);

    // const backCol = Color.fromRGBO(230, 230, 230, 1.0);
    TreeWidgetConf conf = Provider.of(context);

    // declining to do animation here in the normal way to see if I can get it to work with needspaint from paint
    Animation<double> blinkAnimation = whetherVisible(cursorState.value)
        ? const AlwaysStoppedAnimation(1)
        : Provider.of<BlinkAnimation>(context).v;
    // Animation<double> blinkAnimation = Provider.of<BlinkAnimation>(context).v;
    return avoidNestingHell(
      [
        (w) => AnimatedBuilder(
            animation: blinkAnimation,
            builder: (context, w) => TreeWidget(
                depth: widget.depth,
                nodeStateKey: widget.key as GNKey,
                highlighted: targeted.value,
                cursorState: cursorState.value,
                head: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: conf.lengthMin),
                    child: w!),
                children: children.value),
            child: w),
        (w) => Shortcuts(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.escape): Unfocus(),
                  SingleActivator(LogicalKeyboardKey.enter): Unfocus(),
                  // trying to convey here that shift-enter shouldn't cause unfocus, but this was already true
                  SingleActivator(LogicalKeyboardKey.enter, shift: true):
                      DoNothingIntent(),
                },
                child: Actions(actions: {
                  Unfocus: CallbackAction<Unfocus>(
                      onInvoke: (_) => editFocusNode.unfocus())
                }, child: w)),
        (w) => NearhitRecipient(
            onPointerDown: (at) {
              editFocusNode.requestFocus();
              final RenderEditable renderEditable =
                  (widget.editableKey.currentState as EditableTextState)
                      .renderEditable;
              final TextPosition position =
                  renderEditable.getPositionForPoint(at);
              editorController.selection = TextSelection.fromPosition(position);
            },
            onHoverChange: (at, to) {
              if (to) {
                retainedHoverSignal.value = (widget.key! as GNKey);
              } else {
                if (snoop(retainedHoverSignal) == widget.key!) {
                  retainedHoverSignal.value = null;
                }
              }
            },
            child: w),
        (w) => Focus(
            skipTraversal: true,
            onFocusChange: _editFocusHandler,
            onKeyEvent: (FocusNode n, KeyEvent event) {
              bool bsp = event.logicalKey == LogicalKeyboardKey.backspace;
              if (event is KeyDownEvent) {
                if (editorController.text.isEmpty &&
                    (bsp || event.logicalKey == LogicalKeyboardKey.delete)) {
                  if (bsp) {
                    editFocusNode.previousFocus();
                  } else {
                    editFocusNode.nextFocus();
                  }
                  Provider.of<TreeViewState>(context, listen: false).edits.add(
                      TreeDelete(
                          snapshot: regenerateWidgetTree(),
                          deleteEntireSegment: false));
                  return KeyEventResult.handled;
                } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
                    min(editorController.selection.baseOffset,
                            editorController.selection.extentOffset) ==
                        0) {
                  editFocusNode.previousFocus();
                  return KeyEventResult.handled;
                } else if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
                    max(editorController.selection.baseOffset,
                            editorController.selection.extentOffset) ==
                        editorController.text.length) {
                  editFocusNode.nextFocus();
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
            child: w),
      ],
      end: EditableText(
          key: widget.editableKey,
          controller: editorController,
          forceLine: false,
          // major tombstone: There was a bug where sometimes nearhitting wouldn't (seem to) cause the cursor to move, it would leave focusedChild as null. It turned out that the default onTapOutside behavior is to unfocus the EditableText. I noticed this randomly while digging through the EditableText source code. I guess the fact that it was almost random as to whether it happened was a clue that it might have been a result of a race condition. So I thought about which other things might have been grabbing focus and had a look.
          /// So we must always remember to onTapOutside: do nothing, as the default is to unfocus.
          onTapOutside: (_) {},
          maxLines: null,
          // onSubmitted: (v) {
          //   editFocusNode.unfocus();
          // },
          enableInteractiveSelection: true,
          showSelectionHandles: true,
          // works, but not what we're looking for
          // selectionControls: CupertinoTextSelectionControls(),
          focusNode: editFocusNode,
          selectionColor: color.withAlpha(70),
          style: textTheme,
          cursorOpacityAnimates: true,
          cursorOffset: const Offset(-1.2, 0),
          cursorRadius: const Radius.circular(1.3),
          cursorWidth: 1.5,
          cursorColor: color,
          backgroundCursorColor: color),
    );

    // this has a bunch of padding I don't know how to remove at the moment, it also stores a lot of state, also the current version is behind the documentation, also undo isn't in yet.
    // var result = SuperEditor(
    //   editor: editor,
    //   stylesheet: defaultStylesheet.copyWith(
    //     // rules: [
    //     //   StyleRule(
    //     //     const BlockSelector('paragraph'),
    //     //     (doc, docNode) {
    //     //       return {
    //     //         'padding': const EdgeInsets.all(0),
    //     //       };
    //     //     },
    //     //   ),
    //     // ],
    //     documentPadding: const EdgeInsets.all(0),
    //   ),
    // );
  }

  @override
  dispose() {
    for (var d in toDispose) {
      d();
    }
    super.dispose();
  }
}

/// durations are measured in milliseconds
@immutable
class TreeWidgetConf {
  final double lineMax;

  /// the longest an item is allowed to be before we wrap
  final double lengthMax;

  /// the shortest an item is allowed to be squished before we indent
  final double lengthMin;
  final double lineHeight;
  final double indent;
  final double spacing;

  /// the spacing between items in the same line
  final double spacingInLine;

  /// if you insert into the very leftmost beginning of a node, you will insert before it into its parent node. The following three variables control how much of the node will be that insertBeforeZone.
  /// we have different parameters for before and after because before nodes are much more likely to be right next to root elements which are big honking control handles so the space isn't needed there so much
  final double insertBeforeZoneWhenAfterMin;
  final double insertBeforeZoneWhenAfterMax;
  final double insertBeforeZoneWhenAfterRatio;
  final double nodeHighlightOutlineInflation;
  final double insertBeforeZoneWhenBeforeMin;
  final double insertBeforeZoneWhenBeforeRatio;
  final double insertBeforeZoneWhenBeforeMax;

  /// the span of the flanges on either side of a block (which have to be there so that you can click in those spots to create nodes before or after existing nodes)
  final double parenSpan;
  final double nodeStrokeWidth;
  late final List<Color> nodeBackgroundColors;
  final Color nodeHighlightStrokeColor;
  final double nodeBackgroundCornerRounding;
  final double defaultAnimationDuration;

  /// if non-zero, then children can receive hits when they didn't actually catch the hit, if they're the nearest widget within nearestHitRadius units. Currently unused here.
  final double nearestHitRadius;

  final double cursorSpan;
  final double cursorHeight;
  final Color cursorColor;
  final int cursorBlinkDuration;

  /// interpolates between cursorColor towards background this far on the cursor blink lows
  final double cursorColorLowFade;
  final double cursorSpanWhenInside;
  TreeWidgetConf({
    this.lineMax = 18,
    this.lengthMax = double.infinity,
    this.lengthMin = 16,
    this.lineHeight = 18,
    // kind of want this to be the same as spacing though?
    this.spacingInLine = 6,
    this.insertBeforeZoneWhenAfterMin = 2,
    this.insertBeforeZoneWhenAfterRatio = 0.27,
    this.insertBeforeZoneWhenAfterMax = 3,
    this.insertBeforeZoneWhenBeforeMin = 2,
    this.insertBeforeZoneWhenBeforeRatio = 0.3,
    this.insertBeforeZoneWhenBeforeMax = 7,
    this.nodeStrokeWidth = 1.3,
    this.defaultAnimationDuration = 200,
    this.cursorColorLowFade = 0.6,
    this.cursorBlinkDuration = 1600,
    this.cursorColor = const Color.fromARGB(255, 31, 31, 31),
    this.nodeHighlightOutlineInflation = 2,
    this.cursorSpan = 3.3,
    this.cursorHeight = 14,
    this.cursorSpanWhenInside = 7,
    this.nodeBackgroundCornerRounding = 9,
    this.indent = 8,
    this.parenSpan = 13,
    this.spacing = 4,
    this.nodeHighlightStrokeColor = const Color.fromARGB(255, 57, 57, 57),
    this.nearestHitRadius = 5,
    List<Color>? nodeBackgroundColors,
  }) {
    this.nodeBackgroundColors = nodeBackgroundColors ??
        gradient(const [
          (Color.fromARGB(255, 250, 250, 250), 3),
          (Color.fromARGB(255, 207, 207, 207), 2),
          (Color.fromARGB(255, 223, 198, 174), 6),
        ]);
    // gradient(const [
    //   (Color.fromARGB(255, 250, 250, 250), 3),
    //   (Color.fromARGB(255, 207, 207, 207), 2),
    // ]);
  }
}

double sign(double v) => v > 0 ? 1 : -1;
HSLuvColor lerpHsluv(HSLuvColor a, HSLuvColor b, double p) {
  // find the shortest rout through the hue circle
  var forwards = (b.hue - a.hue);
  var backwards = -(360 - forwards.abs()) * sign(forwards);
  var huePath = forwards.abs() < backwards.abs() ? forwards : backwards;
  return HSLuvColor.fromHSL(
      (a.hue + p * huePath) % 360,
      lerpDouble(a.saturation, b.saturation, p)!,
      lerpDouble(a.lightness, b.lightness, p)!);
}

Color hslerp(Color a, Color b, double p) =>
    lerpHsluv(HSLuvColor.fromColor(a), HSLuvColor.fromColor(b), p).toColor();
List<Color> gradient(List<(Color, int)> nodes) {
  List<Color> totalList = [];
  for (var i = 0; i < nodes.length; ++i) {
    var c = nodes[i];
    var n = nodes[(i + 1) % nodes.length];
    for (int i = 0; i < c.$2; ++i) {
      totalList.add(hslerp(c.$1, n.$1, i.toDouble() / c.$2.toDouble()));
    }
  }
  return totalList;
}

/// a more generic tree widget that is more concerned with layout. Unlike most tree layout widgets that have existed in the flutter ecosystem, it will often automatically lay things out in a horizontal inline flow as long as there isn't too much nested structure.
/// the layout algorithm works as follows:
///   checks the min width and height of each child. For children that are TreeWidgets, we do something different than usual, we test how long they'd be if laid out inline, then if any of our children would be longer than 3 words, (or taller than 1.3 lines) we lay this TreeWidget out vertically, otherwise, we lay the contents of the TreeWidget inline along with the head Widget.
/// animations take place here rather than on the widget layer because layout changes take place here. We want an animation where the visual aspect (ie, the renderobject) tracks behind the layout. This isn't just less boilerplate, it's also correct. Layout updates for interaction/hittesting should generally be instant, the user often knows where a control is going to be, without knowing where in its animation it currently is, and we shouldn't run layout each frame.
class TreeWidget extends MultiChildRenderObjectWidget {
  // used by some exotic hit testing processes
  final GNKey? nodeStateKey;
  final int depth;
  final bool highlighted;
  final NodeCursorState cursorState;
  TreeWidget(
      {
      /// not totally sure head should be required, we can also imagine trees that are flat against the wall and have no indent
      required Widget head,

      /// but really these should be TreeNodes? Only the head should be able to not be a treenode?
      List<Widget> children = const [],
      super.key,
      required this.highlighted,
      required this.depth,
      this.cursorState = NodeCursorState.none,
      this.nodeStateKey})
      : super(children: [head, ...children]);
  @override
  RenderObject createRenderObject(BuildContext context) {
    return TreeWidgetRenderObject(
        // [todo] this is why changing treeconf dynamically doesn't work. I kinda think we should be listening, but I'm not sure how to update on a change of only some variables.
        conf: Provider.of(context, listen: false),
        treeDepth: depth,
        highlighted: highlighted,
        cursorState: cursorState,
        key: nodeStateKey,
        hasChild: children.length > 1);
  }

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderObject renderObject) {
    var ro = renderObject as TreeWidgetRenderObject;
    ro.hasChild = children.length > 1;
    ro.treeDepth.approach(depth.toDouble());
    var nh = highlighted ? 1 : 0;
    if (ro.highlighted.endValue != nh) {
      ro.highlighted.approach(highlighted ? 1 : 0);
      if (highlighted) {
        ro.highlightPulser.pulse();
      }
    }
    if (ro.cursorState != cursorState) {
      // I'm not sure how long these really take right now so just give it the default
      ro.animationBegins(fromMils(
          Provider.of<TreeWidgetConf>(context).defaultAnimationDuration));
    }
    ro.setCursorState(cursorState);
    super.updateRenderObject(context, renderObject);
  }
}

class TreeWidgetRenderObject extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, TreeWidgetParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, TreeWidgetParentData>,
        SelfAnimatingRenderObject {
  final TreeWidgetConf conf;
  final GNKey? key;
  bool hasChild;
  Time focusPulse = double.negativeInfinity;
  // currently not using this
  Easer highlighted;
  SmoothV2 span;
  SmoothV2 position;
  Pulser highlightPulser;
  // sometimes needs to be terminated separately from the other animations
  int indefiniteAnimation = -1;

  /// tracks treeDepth
  Easer treeDepth;

  // null if cursor absent, true iff the cursor (currently denoted by selected) should be rendered after this widget or before. (After render happens when a cursor is pointing at the end of the treenode)
  NodeCursorState cursorState = NodeCursorState.none;

  TreeWidgetRenderObject(
      {required this.conf,
      required int treeDepth,
      required bool highlighted,
      this.key,
      required this.hasChild,
      required NodeCursorState cursorState})
      : span = SmoothV2.unset(duration: conf.defaultAnimationDuration),
        position = SmoothV2.unset(duration: conf.defaultAnimationDuration),
        treeDepth = Easer(treeDepth.toDouble()),
        highlighted = Easer(highlighted ? 1 : 0),
        highlightPulser = Pulser(duration: conf.defaultAnimationDuration) {
    setCursorState(cursorState);
    registerEaser(this.highlighted);
    registerEaser(highlightPulser);
    registerEaser(span);
    registerEaser(position);
    registerEaser(this.treeDepth);
  }

  void setCursorState(NodeCursorState cursor) {
    cursorState = cursor;
    if (whetherVisible(cursor)) {
      var na = indefiniteAnimationBegins();
      terminateAnimation(indefiniteAnimation);
      indefiniteAnimation = na;
    } else {
      terminateAnimation(indefiniteAnimation);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    var animatedDimensions = span.v();

    var td = treeDepth.v();
    var color = td == td.toInt()
        ? conf.nodeBackgroundColors[td.toInt()]
        : hslerp(
            conf.nodeBackgroundColors[
                td.floor() % conf.nodeBackgroundColors.length],
            conf.nodeBackgroundColors[
                (td.floor() + 1) % conf.nodeBackgroundColors.length],
            td - td.floor());
    int lightenComponent(int v, double amount) =>
        min(255, max(0, v + (255 * amount).toInt()));
    Color lighten(Color v, double amount) => Color.fromARGB(
          v.alpha,
          lightenComponent(v.red, amount),
          lightenComponent(v.green, amount),
          lightenComponent(v.blue, amount),
        );

    context.canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(offset.dx, offset.dy, animatedDimensions.dx,
              animatedDimensions.dy),
          Radius.circular(
              conf.nodeBackgroundCornerRounding)), // 10 is the corner radius
      Paint()
        ..color = lighten(color, highlightPulser.v() * -0.03)
        ..style = PaintingStyle.fill,
    );

    // this was kind of cool but was also obscene. Maybe the duration just needed to be lower?
    // var hp = highlightPulser.v();
    // if (hp != 0) {
    //   context.canvas.drawRRect(
    //     RRect.fromRectAndRadius(
    //             Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
    //             Radius.circular(conf.nodeBackgroundCornerRounding))
    //         .inflate(
    //             conf.nodeHighlightOutlineInflation), // 10 is the corner radius
    //     Paint()
    //       ..color = conf.nodeHighlightStrokeColor.withAlpha((255 * hp).toInt())
    //       ..strokeWidth = conf.nodeStrokeWidth
    //       ..style = PaintingStyle.stroke,
    //   );
    // }

    //cursor
    if (whetherVisible(cursorState)) {
      double blinku =
          (time % conf.cursorBlinkDuration) / conf.cursorBlinkDuration;
      var cursorColor = Color.lerp(conf.nodeBackgroundColors[0],
          conf.cursorColor, lerpDouble(conf.cursorColorLowFade, 1, blinku)!)!;
      var isInside = (cursorState == NodeCursorState.inside);
      var fcb = bounds(offset, firstChild);
      var insideCursorGap = (conf.lineHeight - conf.cursorSpanWhenInside) / 2;
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(
                cursorState == NodeCursorState.after
                    ? offset.dx +
                        size.width +
                        conf.spacingInLine / 2 -
                        conf.cursorSpan / 2
                    : cursorState == NodeCursorState.before
                        ? offset.dx -
                            conf.spacingInLine / 2 -
                            conf.cursorSpan / 2
                        : fcb.left +
                            fcb.width -
                            insideCursorGap -
                            conf.cursorSpanWhenInside,
                isInside
                    ? fcb.top + insideCursorGap
                    : offset.dy + conf.lineHeight / 2 - conf.cursorHeight / 2,
                isInside ? conf.cursorSpanWhenInside : conf.cursorSpan,
                isInside
                    ? conf.lineHeight - 2 * insideCursorGap
                    : conf.cursorHeight),
            Radius.circular(conf.cursorSpan / 2)),
        Paint()
          ..color = cursorColor
          ..style = PaintingStyle.fill,
      );
    }

    // just defaultPaint but using animatedOffset
    RenderBox? child = firstChild;
    while (child != null) {
      final TreeWidgetParentData childParentData =
          child.parentData! as TreeWidgetParentData;
      context.paintChild(child, offset + childParentData.animatedOffset);
      child = childParentData.nextSibling;
    }
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! TreeWidgetParentData) {
      child.parentData = TreeWidgetParentData();
    }
  }

  @override
  void performLayout() {
    // [todo] cache the constraints, don't do the layout again if they haven't changed?

    double width = conf.parenSpan * 2;
    double height = conf.lineHeight;
    if (childCount == 0) {
      size = Size(width, height);
      return;
    }
    RenderBox? child = firstChild;

    bool hasLaidSomethingInThisLine = false;
    // if we're squished for space, get rid of parenspan (the inner element must be allowed to be lengthMin too). Also no need for a paren if there's no children, the paren is just to allow  mouse-selecting inserting at the end.
    double parenSpanToBeUsed = hasChild
        ? min(conf.parenSpan, constraints.maxWidth - conf.lengthMin)
        : 0;

    Offset curOffset = Offset.zero;
    int lineNumber = 0;
    while (child != null) {
      final TreeWidgetParentData childParentData =
          child.parentData! as TreeWidgetParentData;

      void adjustOwnSpan() {
        width =
            max(width, curOffset.dx + child!.size.width + parenSpanToBeUsed);
        height = max(height, curOffset.dy + child.size.height);
      }

      void nextLine(double lineHeight) {
        hasLaidSomethingInThisLine = false;
        lineNumber += 1;
        curOffset = Offset(
            // don't indent if there's not enough space
            min(conf.indent,
                constraints.maxWidth - conf.lengthMin - parenSpanToBeUsed),
            curOffset.dy + lineHeight + conf.spacing);
      }

      // attempt to lay out inline
      // [todo]
      // if(s is TreeWidgetRenderObject){
      //   //do an optimized version of layout that doesn't do vertical sizing if it turns out to be longer vertically than maxLine, just returning null
      // } else {}
      childParentData.offset = curOffset;
      childParentData.lineNumber = lineNumber;
      child.layout(
          BoxConstraints.loose(Size(
              constraints.maxWidth - curOffset.dx - parenSpanToBeUsed,
              double.infinity)),
          parentUsesSize: true);

      // we don't wrap over-long items, so they'd get a new line
      bool overWide = child.size.width > constraints.maxWidth - curOffset.dx;
      // we give tall items their own line (for some reason this looks nicer than having jagged lines with voids in them)
      bool isOverTall() => child!.size.height > conf.lineMax;
      bool overTall = isOverTall();
      if (hasLaidSomethingInThisLine && (overTall || overWide)) {
        //we're gonna need to go down at least one line and lay out again
        //gets its own line, and lay it out again
        nextLine(conf.lineHeight);
        childParentData.offset = curOffset;
        childParentData.lineNumber = lineNumber;
        child.layout(
            BoxConstraints.loose(Size(
                constraints.maxWidth - curOffset.dx - parenSpanToBeUsed,
                double.infinity)),
            parentUsesSize: true);
        overTall = isOverTall();
      }
      //finalize offset here
      childParentData.animatedOffsetEaser.approach(curOffset);
      childParentData.multiline = overTall;
      adjustOwnSpan();
      if (overTall) {
        //we don't put anything else in tall item lines
        nextLine(child.size.height);
      } else {
        var nextdx = curOffset.dx + child.size.width + conf.spacingInLine;
        var nextspan = constraints.maxWidth - parenSpanToBeUsed - nextdx;
        if (nextspan < conf.lengthMin) {
          nextLine(conf.lineHeight);
        } else {
          curOffset = Offset(nextdx, curOffset.dy);
          hasLaidSomethingInThisLine = true;
        }
      }

      child = childParentData.nextSibling;
    }

    size = constraints.constrain(Size(width, height));
  }

  @override
  set size(Size v) {
    super.size = v;
    span.approach(v.bottomRight(Offset.zero));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}

class TreeWidgetParentData extends ContainerBoxParentData<RenderBox> {
  bool multiline = true;
  SmoothV2 animatedOffsetEaser = SmoothV2.unset();
  double animatedOffsetCachedTime = double.negativeInfinity;
  Offset animatedOffsetCached = Offset.zero;
  int lineNumber = 0;
  Offset get animatedOffset {
    var ct = currentTime();
    if (ct > animatedOffsetCachedTime) {
      animatedOffsetCached = animatedOffsetEaser.v();
      animatedOffsetCachedTime = ct;
    }
    return animatedOffsetCached;
  }
}

Widget controls(BuildContext context) {
  var tc = Theme.of(context);
  Widget keyRow(List<String> parts, String description) {
    List<InlineSpan> keyParts = mapSeparated(
            parts.map((p) => WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                      color: const Color.fromARGB(255, 214, 214, 214),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: const Color.fromARGB(255, 195, 195, 195),
                          width: 2)),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      child: Text(
                        p,
                        style: TextStyle(
                            color: tc.colorScheme.onSurface,
                            fontWeight: FontWeight.bold),
                      )),
                ))),
            separator: const TextSpan(text: '+'))
        .toList();
    return RichText(
      text: TextSpan(style: tc.textTheme.bodySmall, children: [
        ...keyParts,
        TextSpan(text: ' $description'),
      ]),
    );
  }

  String stringOfKey(LogicalKeyboardKey l) {
    if (l == LogicalKeyboardKey.arrowUp) {
      return '↑';
    } else if (l == LogicalKeyboardKey.arrowDown) {
      return '↓';
    } else if (l == LogicalKeyboardKey.arrowLeft) {
      return '←';
    } else if (l == LogicalKeyboardKey.arrowRight) {
      return '→';
    }
    return l.keyLabel;
  }

  List<String> keyStrings(ShortcutActivator a) {
    var sa = a as SingleActivator;
    List<String> ret = [];
    if (sa.control) {
      ret.add('ctrl');
    }
    if (sa.shift) {
      ret.add('shift');
    }
    if (sa.alt) {
      ret.add('alt');
    }
    ret.add(stringOfKey(sa.trigger));
    return ret;
  }

  return SingleChildScrollView(
      child: Container(
          width: 240, //todo: https://docs.flutter.dev/ui/adaptive-responsive
          color: tc.colorScheme.surfaceDim,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: evenPadding(
                  5,
                  (w, sides, before, after) => Padding(
                      padding: EdgeInsets.fromLTRB(sides, before, sides, after),
                      child: w),
                  <Widget>[
                    Text('Controls', style: tc.textTheme.displaySmall),
                    ...otherKeyboardControlInfo.entries
                        .map((me) => keyRow(keyStrings(me.key), me.value.$2)),
                    ...basicLeftHandKeyboardSchemeInfo.entries
                        .map((me) => keyRow(keyStrings(me.key), me.value.$2)),
                  ]))));
}

/// adds padding around the widgets so that the visible distance between them and between the edges of the screen will be the same. This lets you have equal-looking separation without having gaps between the padding widgets.
List<Widget> evenPadding(
    double separation,
    Widget Function(Widget, double, double, double) mapper,
    List<Widget> widgets) {
  var hs = separation / 2;
  List<Widget> out = [];
  for (var i = 0; i < widgets.length; ++i) {
    var wi = widgets[i];
    out.add(i == 0
        ? mapper(wi, separation, separation, hs)
        : (i == widgets.length - 1
            ? mapper(wi, separation, hs, separation)
            : mapper(wi, separation, hs, hs)));
  }
  return out;
}

class BrowsingWindow extends StatefulWidget {
  const BrowsingWindow({super.key, required this.title});
  final String title;
  @override
  State<BrowsingWindow> createState() => _BrowsingWindowState();
}

class _BrowsingWindowState extends State<BrowsingWindow> {
  // StreamController<Message> toastStream;
  @override
  Widget build(BuildContext context) {
    // If I remove the scaffold, horrible things happen, I don't know why. I think one issue is maybe that theme logic doesn't run until it enters the scaffold. But I can replace that.

    return Scaffold(
      body: Stack(children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: TreeView('tree.json')),
            controls(context)
          ],
        )
      ]),
    );
  }
}
