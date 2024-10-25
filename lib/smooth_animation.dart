// State for running an ease animation along a linear quantity. The twist: You can interrupt the animation and point it at a different target. With simpler animation code, this would result in either a sudden jump, or the velocity would suddenly go to zero. InterruptableEaser instead reorients intelligently without any sudden jerks or jumps.

// It works by just remembering the initial velocity and the initial location, instead of sort of simulating, frame by frame, a little thing moving along. It's more accurate and doesn't need to be updated every frame, it is just called at paint.

//translated from https://github.com/makoConstruct/interruptable_easer/blob/master/src/lib.rs by claude sonnet
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:tree_edit/util.dart';

// double currentTime() => DateTime.now().millisecondsSinceEpoch.toDouble();
double currentTime() =>
    SchedulerBinding.instance.currentFrameTimeStamp.inMilliseconds.toDouble();
Duration currentTimeDur() => SchedulerBinding.instance.currentFrameTimeStamp;

double sq(double a) {
  return a * a;
}

double clampUnit(double v) => max(0, min(1, v));

double progressOverTime(double duration, double v) =>
    clampUnit((v - currentTime()) / duration);

double linearAccelerationEaseInOutWithInitialVelocity(
    double t, double initialVelocity) {
  return t *
      (t * ((initialVelocity - 2) * t + (3 - 2 * initialVelocity)) +
          initialVelocity);
}

double velocityOfLinearAccelerationEaseInOutWithInitialVelocity(
    double t, double initialVelocity) {
  return t * ((3 * initialVelocity - 6) * t + (6 - 4 * initialVelocity)) +
      initialVelocity;
}

double constantAccelerationEaseInOutWithInitialVelocity(
    double t, double initialVelocity) {
  if (t >= 1) {
    return 1;
  }
  double sqrtPart = sqrt(2 * sq(initialVelocity) - 4 * initialVelocity + 4);
  double m =
      (2 - initialVelocity + (initialVelocity < 2 ? sqrtPart : -sqrtPart)) / 2;
  double ax = -initialVelocity / (2 * m);
  double ay = initialVelocity * ax / 2;
  double h = (ax + 1) / 2;
  if (t < h) {
    return m * sq(t - ax) + ay;
  } else {
    return -m * sq(t - 1) + 1;
  }
}

double velocityOfConstantAccelerationEaseInOutWithInitialVelocity(
    double t, double initialVelocity) {
  if (t >= 1) {
    return 0;
  }
  double sqrtPart = sqrt(2 * sq(initialVelocity) - 4 * initialVelocity + 4);
  double m =
      (2 - initialVelocity + (initialVelocity < 2 ? sqrtPart : -sqrtPart)) / 2;
  double ax = -initialVelocity / (2 * m);
  double h = (ax + 1) / 2;
  if (t < h) {
    return 2 * m * (t - ax);
  } else {
    return 2 * m * (1 - t);
  }
}

double ease(
  double startValue,
  double endValue,
  double startTime,
  double endTime,
  double currentTime,
  double initialVelocity,
) {
  if (startTime == double.negativeInfinity) {
    return endValue;
  }
  if (startValue == endValue) {
    return startValue;
  }
  double normalizedTime = (currentTime - startTime) / (endTime - startTime);
  double normalizedVelocity =
      initialVelocity / (endValue - startValue) * (endTime - startTime);
  double normalizedOutput = normalizedVelocity > 2
      ? linearAccelerationEaseInOutWithInitialVelocity(
          normalizedTime, normalizedVelocity)
      : constantAccelerationEaseInOutWithInitialVelocity(
          normalizedTime, normalizedVelocity);
  return startValue + normalizedOutput * (endValue - startValue);
}

double velEase(
  double startValue,
  double endValue,
  double startTime,
  double endTime,
  double currentTime,
  double initialVelocity,
) {
  if (startTime == double.negativeInfinity) {
    return 0.0;
  }
  if (startValue == endValue) {
    return 0.0;
  }
  double normalizedTime = (currentTime - startTime) / (endTime - startTime);
  double normalizedVelocity =
      initialVelocity / (endValue - startValue) * (endTime - startTime);
  double normalizedOutput = normalizedVelocity > 2
      ? velocityOfLinearAccelerationEaseInOutWithInitialVelocity(
          normalizedTime, normalizedVelocity)
      : velocityOfConstantAccelerationEaseInOutWithInitialVelocity(
          normalizedTime, normalizedVelocity);
  return normalizedOutput * (endValue - startValue) / (endTime - startTime);
}

(double, double) easeValVel(
  double startValue,
  double endValue,
  double startTime,
  double endTime,
  double currentTime,
  double initialVelocity,
) {
  if (startTime == double.negativeInfinity || startValue == endValue) {
    return (endValue, 0.0);
  }
  double normalizedTime = (currentTime - startTime) / (endTime - startTime);
  double normalizedVelocity =
      initialVelocity / (endValue - startValue) * (endTime - startTime);

  late double normalizedPOut, normalizedVelOut;
  if (normalizedVelocity > 2) {
    normalizedPOut = linearAccelerationEaseInOutWithInitialVelocity(
        normalizedTime, normalizedVelocity);
    normalizedVelOut = velocityOfLinearAccelerationEaseInOutWithInitialVelocity(
        normalizedTime, normalizedVelocity);
  } else {
    normalizedPOut = constantAccelerationEaseInOutWithInitialVelocity(
        normalizedTime, normalizedVelocity);
    normalizedVelOut =
        velocityOfConstantAccelerationEaseInOutWithInitialVelocity(
            normalizedTime, normalizedVelocity);
  }
  return (
    startValue + normalizedPOut * (endValue - startValue),
    normalizedVelOut * (endValue - startValue) / (endTime - startTime),
  );
}

Duration maxDuration(Duration a, Duration b) {
  return a.compareTo(b) > 0 ? a : b;
}

abstract class Animator extends ChangeNotifier {
  // really I think this should communicate via endTime
  double get duration;
}

const double _midpoint = 0.3;
double defaultPulserFunction(double v) =>
    v < _midpoint ? v / _midpoint : 1 - (v - _midpoint) / (1 - _midpoint);

/// pulses to 1 and sags to 0. Is fairly graceful when interrupted, allowing pulses to overlap. T is a fold over the pulse
class PulserFold<T> extends Animator {
  @override
  double duration;
  T zero;
  List<(double, T)> pulseStarts = [];

  /// pulseTime is the amount of time that's passed since this pulse started. For pulses in the future, it will be negative. For pulses in the past, it will be large. You usually want to get the pulse progress as clampUnit(pulseTime/duration)
  T Function(T accumulator, double pulseTime, T pulseValue) folder;
  PulserFold({this.duration = 200, required this.folder, required this.zero});
  void pulse(T v) {
    pulseStarts.add((currentTime(), v));
    notifyListeners();
  }

  T v() {
    T r = zero;
    double ct = currentTime();
    for (var s in pulseStarts) {
      double tp = ct - s.$1;
      if (tp > 0 && tp < duration) {
        r = folder(r, tp, s.$2);
      }
    }
    return r;
  }
}

class Pulser extends PulserFold<double> {
  double Function(double) pulseFunction;
  Pulser({super.duration = 200, this.pulseFunction = defaultPulserFunction})
      : super(
            folder: (a, t, _) => pulseFunction(clampUnit(t / duration)),
            zero: 0);
  void pulseThat() {
    // this pulser doesn't pay attention to the pulse value, only the time
    super.pulse(0);
  }
}

class BumpPulse extends PulserFold<Offset> {
  BumpPulse({super.duration})
      : super(
            folder: (Offset acc, double bt, Offset b) =>
                acc + b * defaultPulserFunction(clampUnit(bt / duration)),
            zero: Offset.zero);
}

class Easer extends Animator {
  double startValue;
  double endValue;
  double startTime;
  double startVelocity;
  @override
  double duration;

  static const double defaultDuration = 200;
  Easer(double v)
      : startValue = v,
        endValue = v,
        duration = defaultDuration,
        startTime = double.negativeInfinity,
        startVelocity = 0.0;

  /// use this when you want the first approach to reach its destination instantly regardless of transitionDuration
  Easer.unset({this.duration = defaultDuration})
      : startValue = double.nan,
        endValue = double.nan,
        startTime = double.nan,
        startVelocity = double.nan;

  void approach(double v) {
    if (v != endValue) {
      if (startValue.isNaN) {
        startValue = endValue = v;
        startTime = double.negativeInfinity;
        startVelocity = 0;
        // it would be nice if we could tell listeners that the change has infinitesimal duration, but just telling them it's the same duration as ever isn't so bad. Might want to come back to this once you're doing variable durations as a function of the value delta.
      } else {
        var time = currentTime();
        var result = easeValVel(
          startValue,
          endValue,
          startTime,
          startTime + duration,
          time,
          startVelocity,
        );
        startValue = result.$1;
        startVelocity = result.$2;
        startTime = time;
        endValue = v;
      }
      notifyListeners();
    }
  }

  double v() {
    return ease(
      startValue,
      endValue,
      startTime,
      startTime + duration,
      currentTime(),
      startVelocity,
    );
  }
}

class SmoothV2 extends Animator {
  Easer dx, dy;
  set duration(double v) {
    dx.duration = v;
    dy.duration = v;
  }

  @override
  double get duration => dx.duration;

  SmoothV2(Offset initial, double transitionDuration)
      : dx = Easer(initial.dx),
        dy = Easer(initial.dy);
  SmoothV2.unset({double duration = Easer.defaultDuration})
      : dx = Easer.unset(duration: duration),
        dy = Easer.unset(duration: duration);
  Offset v() => Offset(dx.v(), dy.v());
  void approach(Offset v) {
    if (dx.endValue != v.dx || dy.endValue != v.dy) {
      dx.approach(v.dx);
      dy.approach(v.dy);
      notifyListeners();
    }
  }
}

class AnimatingPaintResult {
  bool isRepainting;
  AnimatingPaintResult({required bool repainting}) : isRepainting = repainting;
  static AnimatingPaintResult get repainting =>
      AnimatingPaintResult(repainting: true);
  static AnimatingPaintResult get settled =>
      AnimatingPaintResult(repainting: false);
}

/// An alternative to flutter's usual animation stuff. Much simpler and low-level.
/// usage: Call animationBegins(duration) when you begin. This makes sure that `paint` will get called until the end. Use the protected variable `Duration currentPaintTime` to calculate animation progress in `paint`.
/// Especially useful when you want to animate layout changes without running layout repeatedly.
mixin SelfAnimatingRenderObject on RenderObject {
  int _schedulerBinding = -1;
  bool _animating = false;
  @protected
  Duration currentPaintTime = Duration.zero;
  List<(int, Duration)> animationsOngoing = [];
  int latestAnimationID = 0;

  /// preferable when you're about to do a bunch of lerps and unlerps and clamps with it (ie, always)
  @protected
  double get time => currentPaintTime.inMilliseconds.toDouble();
  Duration _deadline = Duration.zero;

  void _tick(Duration time) {
    currentPaintTime = time;
    markNeedsPaint();
    if (currentPaintTime >= _deadline) {
      // animations have ended
      _animating = false;
      _schedulerBinding = -1;
    } else {
      _schedulerBinding = SchedulerBinding.instance
          .scheduleFrameCallback(_tick, rescheduling: true);
    }
  }

  int indefiniteAnimationBegins() {
    return animationBegins(Duration(microseconds: double.maxFinite.toInt()));
  }

  /// returns animationID, which should be used for cancellation
  int animationBegins(Duration duration) {
    var tid = ++latestAnimationID;
    animationsOngoing.add((tid, duration));
    var ct = currentTimeDur();
    _deadline = maxDuration(_deadline, ct + duration);
    if (!_animating) {
      _schedulerBinding = SchedulerBinding.instance
          .scheduleFrameCallback(_tick, rescheduling: false);
      _animating = true;
    }
    // clear out old animation ids
    animationsOngoing.removeWhere((a) => a.$2 < ct);
    return tid;
  }

  void terminateAllAnimation() {
    if (_animating) {
      animationsOngoing.clear();
      SchedulerBinding.instance.cancelFrameCallbackWithId(_schedulerBinding);
      _deadline = currentPaintTime;
      _animating = false;
    }
  }

  void terminateAnimation(int id) {
    if (_animating) {
      var ai = animationsOngoing.indexWhere((e) => e.$1 == id);
      if (ai < 0) {
        return;
      }
      animationsOngoing.removeAt(ai);
      Duration remainingMax =
          animationsOngoing.fold(Duration.zero, (a, b) => maxDuration(a, b.$2));
      if (remainingMax < currentTimeDur()) {
        SchedulerBinding.instance.cancelFrameCallbackWithId(_schedulerBinding);
        _deadline = remainingMax;
        _animating = false;
      }
    }
  }

  void registerEaser(Animator easer) {
    easer.addListener(() {
      animationBegins(fromMils(easer.duration));
    });
  }

  @override
  dispose() {
    terminateAllAnimation();
    super.dispose();
  }
}
