import 'package:flutter/rendering.dart';
import 'package:signals/signals_flutter.dart';

/// just avoids nesting hell. eg, `avoidNestingHell(end:v, [a, b, c, d, e, f]) == a(b(c(d(e(f(v))))))`
T avoidNestingHell<T>(List<T Function(T)> through, {required T end}) {
  return through.reversed.fold(end, (T a, b) => b(a));
}

/// Accesses value without subscribing to it. Needed every time you read in a callback basically. writing untracked(()=> ) everywhere sure is irritating! This works the way I wish peek() had worked.
T snoop<T>(ReadonlySignal<T> v) => untracked(() => v.value);

typedef Time = double;

Rect bounds(Offset offset, RenderObject? ro) =>
    (offset + ((ro as RenderBox).parentData as BoxParentData).offset) & ro.size;

Iterable<T> mapSeparated<T>(Iterable<T> parts, {required T separator}) sync* {
  var i = parts.iterator;

  if (!i.moveNext()) {
    return;
  }
  while (true) {
    yield i.current;
    if (i.moveNext()) {
      yield separator;
    } else {
      return;
    }
  }
}
