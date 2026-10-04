/// Deterministic danmaku geometry and track assignment math.
///
/// Pure functions of `(birth tick, widths, view size, durations)` with no
/// widget or clock dependency, so danmaku layout is reproducible: the same
/// danmaku set on the same clock always yields the same tracks and
/// positions, regardless of arrival timing, seeks, or view rebuilds
/// (fullscreen / rotation).
///
/// The scroll collision test is a port of the former
/// `_DanmakuScreenState._scrollCanAddToTrack` occupancy check from
/// "current x positions" to birth-time math: the position of an existing
/// danmaku at the new danmaku's birth is computed with [scrollDanmakuX] and
/// subjected to the same two non-overlap conditions.
library;

/// x position of a right-to-left scroll danmaku at [nowMs].
///
/// [birthTick] is the clock time the flight starts (right edge,
/// `x == viewWidth`); it leaves the screen when `x < -itemWidth`.
/// Negative progress (unborn) yields `x > viewWidth` and must be skipped by
/// the caller, never painted.
double scrollDanmakuX({
  required double viewWidth,
  required double itemWidth,
  required int birthTick,
  required int nowMs,
  required double durationMs,
}) {
  final elapsed = (nowMs - birthTick).toDouble();
  return viewWidth - elapsed / durationMs * (viewWidth + itemWidth);
}

/// Full transit time in ms from birth until the danmaku is fully off-screen.
double scrollTransitMs({
  required double viewWidth,
  required double itemWidth,
  required double durationMs,
}) {
  return durationMs * (viewWidth + itemWidth) / viewWidth;
}

/// Whether a scroll track is free for a new danmaku.
///
/// [existingBirth]/[existingWidth] describe the latest overlapping danmaku
/// already assigned to the track; [newBirth]/[newWidth] the candidate.
/// Births are [DanmakuClock] ticks; assignment must run in birth order so
/// that only the latest track occupant can overlap the candidate.
bool scrollTrackFree({
  required double viewWidth,
  required double durationMs,
  required int existingBirth,
  required double existingWidth,
  required int newBirth,
  required double newWidth,
}) {
  final elapsedMs = (newBirth - existingBirth).toDouble();
  // Out-of-order guard: never block on a younger occupant.
  if (elapsedMs < 0) return true;
  final existingX = scrollDanmakuX(
    viewWidth: viewWidth,
    itemWidth: existingWidth,
    birthTick: existingBirth,
    nowMs: newBirth,
    durationMs: durationMs,
  );
  // The existing danmaku has not fully entered the screen yet.
  if (viewWidth - (existingX + existingWidth) < 0) return false;
  // A slower (narrower) danmaku ahead must not be caught up with.
  if (existingWidth < newWidth) {
    if ((1 - ((viewWidth - existingX) / (existingWidth + viewWidth))) >
        (viewWidth / (viewWidth + newWidth))) {
      return false;
    }
  }
  return true;
}

/// Whether a static (top/bottom) track is free for a new danmaku.
///
/// A track is occupied while the previously assigned danmaku is still
/// visible, i.e. its age is below [staticDurationMs].
bool staticTrackFree({
  required int lastBirth,
  required int newBirth,
  required double staticDurationMs,
}) {
  return (newBirth - lastBirth) >= staticDurationMs;
}

/// Deterministic fallback track when every track is occupied and
/// `massiveMode` allows overlap.
///
/// Replaces the former `Random().nextInt(trackCount)` so repeated layouts
/// of the same danmaku set pick the same track. A Knuth multiplicative hash
/// of the birth tick spreads neighbouring births across tracks.
int massiveFallbackTrack({
  required int birthTick,
  required int trackCount,
}) {
  assert(trackCount > 0);
  var h = (birthTick * 2654435761) & 0x7fffffffffffffff;
  h ^= h >> 16;
  h = (h * 2246822519) & 0x7fffffffffffffff;
  h ^= h >> 13;
  return h % trackCount;
}
