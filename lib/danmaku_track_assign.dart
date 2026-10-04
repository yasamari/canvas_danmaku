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
/// * **A danmaku is assigned a track once and keeps it.** The decision
///   ([admitScrollTrack] / [admitStaticTrack]) reads no clock value and is
///   recorded on the [DanmakuItem], which the store shares between views.
///   Deciding again is *not* the same answer: the rows depend on which
///   danmaku were assigned before, and a rebuilt window starts at a different
///   point of the birth order, so the difference reaches the danmaku still on
///   screen. Records are what make a rebuilt, rotated or fullscreen view
///   reproduce the layout the user is already looking at; they are dropped
///   (`DanmakuStore.resetTracks`) when the collision math itself changes, i.e.
///   the text width or the durations.
///
/// The scroll collision test is a port of the former
/// `_DanmakuScreenState._scrollCanAddToTrack` occupancy check from
/// "current x positions" to birth-time math: the position of an existing
/// danmaku at the new danmaku's birth is computed with [scrollDanmakuX] and
/// subjected to the same two non-overlap conditions.
library;

import 'package:canvas_danmaku/models/danmaku_item.dart';

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

/// One view's scroll track occupancy: birth order in, one track out.
///
/// [take] answers "which track is the first one free at this danmaku's birth",
/// which is a pure function of `(birth, width, view size, duration)` and reads
/// no clock value. Occupants more than [durationMs] old are dropped from the
/// head ([trackReplaySpanMs] shows that is where they stop being able to block
/// anything), so the per-track lists stay short while a channel is busy.
///
/// The occupancy is per view and rebuilt from scratch whenever the view's
/// window is ([rewind]); *which* track a danmaku got is not kept here but on
/// [DanmakuItem.track], so a rebuilt — or newly built — view reproduces the
/// rows the danmaku already had instead of re-deciding them.
class ScrollTrackAllocator {
  ScrollTrackAllocator({
    required int trackCount,
    required this.viewWidth,
    required this.durationMs,
  }) : _occupants = List.generate(
         trackCount < 0 ? 0 : trackCount,
         (_) => <_ScrollOccupant>[],
         growable: false,
       );

  /// Width the positions and the collision test are computed for.
  final double viewWidth;

  /// On-screen duration of one danmaku (width-independent, see
  /// [scrollDanmakuGone]). Part of the collision math, so a change invalidates
  /// every recorded track: build a new allocator instead of rewinding.
  final double durationMs;

  final List<List<_ScrollOccupant>> _occupants;

  /// Number of tracks, i.e. the height of the danmaku area.
  int get trackCount => _occupants.length;

  /// Assigns [birthTick]/[width] to the lowest free track and occupies it, or
  /// returns null when every track is busy (the danmaku is dropped).
  ///
  /// [selfSend] and [massiveFallback] cover the deliberate overlaps that ignore
  /// occupancy; the resulting track is occupied like any other.
  int? take({
    required int birthTick,
    required double width,
    bool selfSend = false,
    bool massiveFallback = false,
  }) {
    var track = firstFree(birthTick: birthTick, width: width);
    if (track == null && selfSend) {
      track = 0;
    } else if (track == null && massiveFallback) {
      track = massiveFallbackTrack(birthTick: birthTick, trackCount: trackCount);
    }
    if (track == null) return null;
    occupy(track, birthTick: birthTick, width: width);
    return track;
  }

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
  void occupy(int track, {required int birthTick, required double width}) {
    if (track < 0 || track >= _occupants.length) return;
    _occupants[track].add(_ScrollOccupant(birthTick, width));
  }

  /// Empties the occupancy; the caller re-feeds it in birth order.
  void rewind() {
    for (final track in _occupants) {
      track.clear();
    }
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

/// One view's top/bottom track occupancy, the static counterpart of
/// [ScrollTrackAllocator]: a track is busy for [staticDurationMs] after its
/// last danmaku.
class StaticTrackAllocator {
  StaticTrackAllocator({
    required int trackCount,
    required this.staticDurationMs,
  }) : _lastBirth = List.filled(trackCount < 0 ? 0 : trackCount, null);

  /// How long a top/bottom danmaku stays on screen, and therefore how long it
  /// blocks its track.
  final double staticDurationMs;

  /// Birth tick of the danmaku currently holding each track.
  final List<int?> _lastBirth;

  /// Number of tracks, i.e. the height of the danmaku area.
  int get trackCount => _lastBirth.length;

  /// Assigns [birthTick] to the lowest free track and occupies it, or returns
  /// null when every track is still busy.
  ///
  /// [minTrack] skips the bottom tracks reserved for subtitles.
  int? take({required int birthTick, int minTrack = 0}) {
    for (var i = minTrack < 0 ? 0 : minTrack; i < _lastBirth.length; i++) {
      final lastBirth = _lastBirth[i];
      if (lastBirth != null &&
          !staticTrackFree(
            lastBirth: lastBirth,
            newBirth: birthTick,
            staticDurationMs: staticDurationMs,
          )) {
        continue;
      }
      _lastBirth[i] = birthTick;
      return i;
    }
    return null;
  }

  /// Empties the occupancy; the caller re-feeds it in birth order.
  void rewind() {
    for (var i = 0; i < _lastBirth.length; i++) {
      _lastBirth[i] = null;
    }
  }
}

/// The scroll track for [item], assigning one on first sight.
///
/// [DanmakuItem.track] is the record, so this is the whole rule: an already
/// assigned danmaku keeps its track (and re-occupies it, which is what rebuilds
/// a view's occupancy in birth order), everything else is decided by
/// [ScrollTrackAllocator.take]. A recorded track above the view's track count
/// (a shorter danmaku area after a rotation) is re-decided.
///
/// Returns null when the danmaku has to be dropped (every track busy). It is
/// worth another try later: a window rebuild may find a free track by then.
int? admitScrollTrack(
  DanmakuItem item,
  ScrollTrackAllocator tracks, {
  required bool massiveMode,
}) {
  final birth = item.birthTick;
  if (birth == null) return null;
  final known = item.track;
  if (known != null && known < tracks.trackCount) {
    tracks.occupy(known, birthTick: birth, width: item.width);
    return known;
  }
  final track = tracks.take(
    birthTick: birth,
    width: item.width,
    selfSend: item.content.selfSend,
    massiveFallback: massiveMode,
  );
  if (track != null) item.track = track;
  return track;
}

/// The static (top/bottom) track for [item], assigning one on first sight.
///
/// Same rule as [admitScrollTrack]; [minTrack] skips the bottom tracks
/// reserved for subtitles.
int? admitStaticTrack(
  DanmakuItem item,
  StaticTrackAllocator tracks, {
  int minTrack = 0,
}) {
  final birth = item.birthTick;
  if (birth == null) return null;
  final known = item.track;
  if (known != null && known < tracks.trackCount) {
    tracks.take(birthTick: birth, minTrack: known);
    return known;
  }
  final track = tracks.take(birthTick: birth, minTrack: minTrack);
  if (track != null) item.track = track;
  return track;
}
