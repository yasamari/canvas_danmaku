/// Deterministic danmaku geometry and track assignment math.
///
/// Pure functions of `(birth tick, widths, view size, durations)` with no
/// widget or clock dependency, so danmaku layout is reproducible: the same
/// danmaku set on the same clock always yields the same tracks and
/// positions, regardless of arrival timing, seeks, or view rebuilds
/// (fullscreen / rotation).
///
/// Two invariants the view relies on:
///
/// * **Lifetime is `durationMs`, never width-dependent.** [scrollDanmakuX]
///   moves the danmaku by `viewWidth + itemWidth` in `durationMs`, so it is
///   fully off-screen (`x == -itemWidth`) exactly [scrollDanmakuGone] one
///   duration after birth. Expiry therefore follows birth order, which is what
///   lets the view drop the expired head of its alive window in one pass.
/// * **Track assignment never reads the current time.** [ScrollTrackAllocator]
///   assigns from birth order, width and view size only. That is what makes a
///   window rebuilt from a seek / rotation / fullscreen view reproduce the
///   tracks of the view it replaces instead of re-picking them: an already
///   visible danmaku keeps its track for its whole flight.
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
///
/// Because `x == -itemWidth` holds exactly at `nowMs - birthTick ==
/// durationMs`, the on-screen lifetime is [durationMs] for **every** width:
/// wider danmaku travel faster (`(viewWidth + itemWidth) / durationMs`) but
/// also start further left, so they leave after the same amount of time.
/// Do not derive a width-dependent transit time from this function; use
/// [scrollDanmakuGone].
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

/// Whether a scroll danmaku has fully left the screen at [nowMs].
///
/// True from `birthTick + durationMs` on, independent of width and view size
/// (see [scrollDanmakuX]). The view drops such danmaku from its alive window,
/// so they stop being painted and stop occupying a track.
bool scrollDanmakuGone({
  required int birthTick,
  required int nowMs,
  required double durationMs,
}) {
  return (nowMs - birthTick) >= durationMs;
}

/// Span of danmaku history a window rebuild has to replay, in clock ms.
///
/// Both scroll collision conditions ([scrollTrackFree]) and the static
/// occupancy test ([staticTrackFree]) can only be violated by a danmaku born
/// less than `durationMs` **before** the candidate, so replaying the last
/// `2 * durationMs` reproduces every track the still-visible danmaku had.
/// Anything older provably blocks nothing and can be left out.
double trackReplaySpanMs({required double durationMs}) => durationMs * 2;

/// Whether a scroll track is free for a new danmaku.
///
/// [existingBirth]/[existingWidth] describe a danmaku already assigned to the
/// track; [newBirth]/[newWidth] the candidate.
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
  // Both non-overlap conditions below require `elapsedMs < durationMs`, so an
  // occupant that old is already off-screen and never blocks. Short-circuiting
  // here keeps the scan cheap without changing the result.
  if (elapsedMs >= durationMs) return true;
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

/// One view's scroll track assignment, driven purely by birth order.
///
/// The view admits danmaku in birth order (as they arrive, or replayed from
/// the start of the window on a seek / rotation / fullscreen rebuild) and asks
/// for the first track that is free at the candidate's birth. Since nothing
/// here reads the current time, replaying the same sequence always yields the
/// same tracks: a rebuild can never move a danmaku that is still on screen.
///
/// Occupants that are more than [durationMs] old are dropped from the head
/// ([trackReplaySpanMs] shows that is the point where they stop being able to
/// block anything), so the per-track lists stay short while a channel is busy.
class ScrollTrackAllocator {
  ScrollTrackAllocator({
    required this.trackCount,
    required this.viewWidth,
    required this.durationMs,
  }) : _occupants = List.generate(
         trackCount < 0 ? 0 : trackCount,
         (_) => <_ScrollOccupant>[],
         growable: false,
       );

  /// Number of tracks, i.e. the height of the danmaku area.
  final int trackCount;

  /// Width the positions and the collision test are computed for.
  final double viewWidth;

  /// On-screen duration of one danmaku (width-independent, see
  /// [scrollDanmakuGone]).
  final double durationMs;

  final List<List<_ScrollOccupant>> _occupants;

  /// The lowest track free at [birthTick], or null when every track is busy.
  ///
  /// Records nothing; call [occupy] to keep the danmaku on the returned track.
  int? firstFree({required int birthTick, required double width}) {
    if (trackCount <= 0) return null;
    _dropUnblockable(birthTick);
    for (var i = 0; i < _occupants.length; i++) {
      if (_isFree(i, birthTick, width)) return i;
    }
    return null;
  }

  /// Marks [track] as taken by a danmaku born at [birthTick].
///
/// Used for the free-track result and for the deliberate overlaps
/// (`selfSend`, `massiveMode`) that ignore occupancy.
  void occupy(int track, {required int birthTick, required double width}) {
    if (track < 0 || track >= _occupants.length) return;
    _occupants[track].add(_ScrollOccupant(birthTick, width));
  }

  /// Occupants that can no longer block anything at [birthTick] are exactly
  /// the ones born `durationMs` or more earlier, and each track list is in
  /// birth order, so trimming the head is enough.
  void _dropUnblockable(int birthTick) {
    final cutoff = birthTick - durationMs;
    for (final track in _occupants) {
      var drop = 0;
      while (drop < track.length && track[drop].birthTick <= cutoff) {
        drop++;
      }
      if (drop > 0) track.removeRange(0, drop);
    }
  }

  bool _isFree(int track, int birthTick, double width) {
    for (final occupant in _occupants[track]) {
      if (!scrollTrackFree(
        viewWidth: viewWidth,
        durationMs: durationMs,
        existingBirth: occupant.birthTick,
        existingWidth: occupant.width,
        newBirth: birthTick,
        newWidth: width,
      )) {
        return false;
      }
    }
    return true;
  }
}

class _ScrollOccupant {
  const _ScrollOccupant(this.birthTick, this.width);

  final int birthTick;
  final double width;
}
