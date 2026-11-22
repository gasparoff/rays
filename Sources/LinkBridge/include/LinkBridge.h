#ifndef LIGHT_SYSTEM_LINK_BRIDGE_H
#define LIGHT_SYSTEM_LINK_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle wrapping a real `ableton::Link` instance.
typedef struct LSLink LSLink;

/// Snapshot of the Link session captured on the application thread.
typedef struct LSLinkState {
  double tempo;
  double beat;
  double phase;
  bool isPlaying;
  bool isEnabled;
  bool isStartStopSyncEnabled;
  uint64_t numPeers;
  int64_t hostTimeMicros;
} LSLinkState;

/// Creates a Link instance (disabled, as the SDK does). Returns NULL on failure.
LSLink *ls_link_create(double bpm);
void ls_link_destroy(LSLink *link);

void ls_link_set_enabled(LSLink *link, bool enabled);
bool ls_link_is_enabled(const LSLink *link);
void ls_link_set_start_stop_sync(LSLink *link, bool enabled);
uint64_t ls_link_num_peers(const LSLink *link);

/// Captures tempo, beat, phase and playing state at the current Link clock time.
LSLinkState ls_link_capture(const LSLink *link, double quantum);

/// Commits a tempo change to the session. Only call on explicit user action.
void ls_link_set_tempo(LSLink *link, double bpm);

/// Follows an external beat (XDJ deck chosen by the user): sets the tempo and
/// requests that the nearest beat with `beatInBar` (0..3) falls on "now".
/// Uses the SDK's polite requestBeatAtTime, never forceBeatAtTime.
void ls_link_follow_beat(LSLink *link, double bpm, int beatInBar);

#ifdef __cplusplus
}
#endif

#endif
