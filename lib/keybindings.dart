import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef Infos = Map<ShortcutActivator, (TreeViewIntent, String)>;

typedef Bindings = Map<ShortcutActivator, TreeViewIntent>;

/// why not?
@immutable
abstract class TreeViewIntent extends Intent {
  const TreeViewIntent();
}

@immutable
class DeleteSelected extends TreeViewIntent {
  final bool entireSegment;
  const DeleteSelected({required this.entireSegment});
}

@immutable
class CopySelected extends TreeViewIntent {
  final bool entireSegment;
  final bool alsoDelete;
  const CopySelected({required this.entireSegment, this.alsoDelete = false});
}

@immutable
class CreateNode extends TreeViewIntent {
  final bool insertAround;
  const CreateNode({required this.insertAround});
}

@immutable
class Paste extends TreeViewIntent {
  final bool entireSegment;
  final bool deleteFromBuffer;
  const Paste({required this.entireSegment, this.deleteFromBuffer = false});
}

@immutable
class Undo extends TreeViewIntent {
  const Undo();
}

@immutable
class Redo extends TreeViewIntent {
  const Redo();
}

@immutable
class OpenActionBar extends TreeViewIntent {
  const OpenActionBar();
}

@immutable
class Fold extends TreeViewIntent {
  final bool here;
  final bool within;
  const Fold({required this.here, required this.within});
}

@immutable
class GoBack extends TreeViewIntent {
  const GoBack();
}

@immutable
class GoForward extends TreeViewIntent {
  const GoForward();
}

@immutable
class GoAccess extends TreeViewIntent {
  const GoAccess();
}

// I don't know what I meant by this or how it would differ from GoBack @_@
@immutable
class GoUnaccess extends TreeViewIntent {
  const GoUnaccess();
}

@immutable
class GoActivate extends TreeViewIntent {
  const GoActivate();
}

@immutable
class GoEdit extends TreeViewIntent {
  const GoEdit();
}

/// keyboard scheme for doing everything with the left hand
const Infos basicLeftHandKeyboardSchemeInfo = {
  SingleActivator(LogicalKeyboardKey.keyD, control: true): (
    DeleteSelected(entireSegment: true),
    "delete tree"
  ),
  SingleActivator(LogicalKeyboardKey.keyD, alt: true): (
    DeleteSelected(entireSegment: false),
    "delete node"
  ),

  SingleActivator(LogicalKeyboardKey.keyS, control: true): (
    CreateNode(insertAround: false),
    "insert"
  ),
  SingleActivator(LogicalKeyboardKey.keyS, alt: true): (
    CreateNode(insertAround: true),
    "insert around"
  ),

  SingleActivator(LogicalKeyboardKey.keyC, shift: true): (
    CopySelected(entireSegment: true, alsoDelete: true),
    "move into magazine"
  ),
  SingleActivator(LogicalKeyboardKey.keyC, control: true): (
    CopySelected(entireSegment: true),
    "copy into magazine"
  ),
  SingleActivator(LogicalKeyboardKey.keyC, alt: true): (
    CopySelected(entireSegment: false),
    "copy single node into magazine"
  ),

  SingleActivator(LogicalKeyboardKey.keyV, control: true): (
    Paste(entireSegment: true),
    "paste"
  ),
  SingleActivator(LogicalKeyboardKey.keyV, alt: true): (
    Paste(entireSegment: false),
    "paste around"
  ),
  SingleActivator(LogicalKeyboardKey.keyV, shift: true): (
    Paste(entireSegment: true, deleteFromBuffer: true),
    "paste, removing from magazine"
  ),
  SingleActivator(LogicalKeyboardKey.keyV, shift: true, control: true): (
    Paste(entireSegment: true, deleteFromBuffer: true),
    "paste, removing from magazine"
  ),
  SingleActivator(LogicalKeyboardKey.keyV, shift: true, alt: true): (
    Paste(entireSegment: false, deleteFromBuffer: true),
    "paste around, removing from magazine"
  ),

  SingleActivator(LogicalKeyboardKey.keyZ, control: true): (Undo(), "undo"),
  SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): (
    Redo(),
    "redo"
  ),

  SingleActivator(LogicalKeyboardKey.keyR, control: true): (
    OpenActionBar(),
    "open command bar"
  ),
  // SingleActivator(LogicalKeyboardKey.keyR, shift: true): SymbolSearch(),

  // we need to have find, maybe f should be find
  SingleActivator(LogicalKeyboardKey.keyF, shift: true): (
    Fold(here: true, within: false),
    "fold this node"
  ),
  SingleActivator(LogicalKeyboardKey.keyF, alt: true): (
    Fold(here: false, within: true),
    "fold subnodes"
  ),
  // I'm not sure we really want this one
  SingleActivator(LogicalKeyboardKey.keyF, shift: true, alt: true): (
    Fold(here: true, within: true),
    "fold all nodes and subnodes"
  ),

  SingleActivator(LogicalKeyboardKey.keyW, control: true): (
    GoBack(),
    "go back"
  ),
  SingleActivator(LogicalKeyboardKey.keyW, alt: true): (
    GoForward(),
    "go forward"
  ),

  SingleActivator(
    LogicalKeyboardKey.enter,
  ): (GoEdit(), "edit"),

  SingleActivator(LogicalKeyboardKey.keyA, control: true): (
    GoAccess(),
    "enter link"
  ),
  SingleActivator(LogicalKeyboardKey.keyA, alt: true): (
    GoUnaccess(),
    "exit current place"
  ),
  SingleActivator(LogicalKeyboardKey.keyA, control: true, shift: true): (
    GoActivate(),
    "commit/accept/submit/run/save this file"
  ),
};

Bindings _shrink(Infos infos) =>
    Map.fromEntries(infos.entries.map((m) => MapEntry(m.key, m.value.$1)));

Bindings basicLeftHandKeyboardScheme = _shrink(basicLeftHandKeyboardSchemeInfo);

class CursorRight extends TreeViewIntent {
  const CursorRight();
}

class CursorLeft extends TreeViewIntent {
  const CursorLeft();
}

class CursorAscend extends TreeViewIntent {
  const CursorAscend();
}

class CursorDescend extends TreeViewIntent {
  final LogicalKeyboardKey? holding;
  const CursorDescend({this.holding});
}

/// why define these separately? No reason not to. Well, it's possible that one day we'll want the extra keybindings in mouse mode to do something different, for full time keyboarders/gazers?
const Infos otherKeyboardControlInfo = {
  SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): (
    CursorDescend(holding: LogicalKeyboardKey.arrowDown),
    "cursor leafward"
  ),
  SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): (
    CursorAscend(),
    "cursor rootward"
  ),
  SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): (
    CursorRight(),
    "cursor to next peer"
  ),
  SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): (
    CursorLeft(),
    "cursor to previous peer"
  ),
  SingleActivator(LogicalKeyboardKey.keyJ, alt: true): (
    CursorDescend(holding: LogicalKeyboardKey.keyJ),
    "cursor leafward"
  ),
  SingleActivator(LogicalKeyboardKey.keyK, alt: true): (
    CursorAscend(),
    "cursor rootward"
  ),
  SingleActivator(LogicalKeyboardKey.keyL, alt: true): (
    CursorRight(),
    "cursor to next peer"
  ),
  SingleActivator(LogicalKeyboardKey.keyH, alt: true): (
    CursorLeft(),
    "cursor to previous peer"
  ),
};

Bindings otherKeyboardControls = _shrink(otherKeyboardControlInfo);

Map<ShortcutActivator, TreeViewIntent> keyboardShortcuts = {
  ...basicLeftHandKeyboardScheme,
  ...otherKeyboardControls
};
