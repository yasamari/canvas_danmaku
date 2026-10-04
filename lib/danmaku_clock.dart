import 'package:flutter/foundation.dart';

/// A monotonic millisecond clock shared by danmaku views.
///
/// The clock value ([nowMs]) is the single source of truth for danmaku
/// positions: every danmaku carries a [birthTick](DanmakuItem.birthTick) on
/// this clock's domain, and its on-screen position is a pure function of
/// `nowMs - birthTick`. Two [DanmakuScreen]s (e.g. the normal video controls
/// and the media_kit fullscreen route, which reuses the same `controls`
/// builder) therefore render the same danmaku at the same position as long
/// as they share one clock instance.
///
/// The wall basis is a process-wide [Stopwatch], so the clock never jumps
/// backwards (NTP adjustments and suspend/resume safe). Advancing between
/// external sync points runs at wall speed:
///
/// * Live: the clock runs freely from session start; danmaku births are
///   stamped with [nowMs] on arrival.
/// * Recording (seekable): the owner re-anchors the clock to the media
///   position with [seekTo] on seeks and on drift, and freezes it with
///   [setRunning] while paused. Between sync points it extrapolates at wall
///   speed, which matches 1x playback.
///
/// The clock itself has no ticker; views drive their repaints with their own
/// tickers and only read [nowMs]. It must outlive the views that share it
/// (e.g. owned by the player state, not by the overlay inside the video
/// controls stack which is rebuilt on rotation and fullscreen changes).
class DanmakuClock extends ChangeNotifier {
  DanmakuClock({int initialMs = 0, bool running = true})
      : _baseMs = initialMs,
        _running = running,
        _wallMs = _wallNow();

  static final Stopwatch _wall = Stopwatch()..start();
  static int _wallNow() => _wall.elapsedMilliseconds;

  int _baseMs;
  int _wallMs;
  bool _running;

  /// Bumped on every [seekTo]; views rebuild their visible windows when this
  /// changes. [setRunning] does not bump it (freezing needs no rebuild).
  int version = 0;

  /// Whether the clock advances with wall time.
  bool get running => _running;

  /// Current time in milliseconds on this clock's domain.
  int get nowMs => _running ? _baseMs + (_wallNow() - _wallMs) : _baseMs;

  /// Re-anchors the clock to [tickMs] (seek, initial sync, drift correction).
  ///
  /// Listeners (danmaku views) rebuild their visible windows from the
  /// shared store on notification.
  void seekTo(int tickMs) {
    _baseMs = tickMs;
    _wallMs = _wallNow();
    version++;
    notifyListeners();
  }

  /// Freezes or resumes wall-speed advancement (e.g. playback pause/resume).
  void setRunning(bool running) {
    if (running == _running) return;
    if (_running) {
      _baseMs = nowMs;
    } else {
      _wallMs = _wallNow();
    }
    _running = running;
    notifyListeners();
  }
}
