// C bridge to the official Ableton Link SDK (GPLv2+). The protocol is not reimplemented.
#include "LinkBridge.h"

#include <ableton/Link.hpp>

#include <algorithm>
#include <cmath>
#include <new>

struct LSLink
{
  explicit LSLink(double bpm)
    : link(bpm)
  {
  }

  ableton::Link link;
};

extern "C" {

LSLink *ls_link_create(double bpm)
{
  try
  {
    return new LSLink(std::isfinite(bpm) ? std::clamp(bpm, 20.0, 999.0) : 120.0);
  }
  catch (...)
  {
    return nullptr;
  }
}

void ls_link_destroy(LSLink *link)
{
  if (link)
  {
    link->link.enable(false);
    delete link;
  }
}

void ls_link_set_enabled(LSLink *link, bool enabled)
{
  if (link)
  {
    link->link.enable(enabled);
  }
}

bool ls_link_is_enabled(const LSLink *link)
{
  return link ? link->link.isEnabled() : false;
}

void ls_link_set_start_stop_sync(LSLink *link, bool enabled)
{
  if (link)
  {
    link->link.enableStartStopSync(enabled);
  }
}

uint64_t ls_link_num_peers(const LSLink *link)
{
  return link ? static_cast<uint64_t>(link->link.numPeers()) : 0;
}

LSLinkState ls_link_capture(const LSLink *link, double quantum)
{
  LSLinkState state{};
  if (!link)
  {
    return state;
  }
  const auto session = link->link.captureAppSessionState();
  const auto now = link->link.clock().micros();
  state.tempo = session.tempo();
  state.beat = session.beatAtTime(now, quantum);
  state.phase = session.phaseAtTime(now, quantum);
  state.isPlaying = session.isPlaying();
  state.isEnabled = link->link.isEnabled();
  state.isStartStopSyncEnabled = link->link.isStartStopSyncEnabled();
  state.numPeers = static_cast<uint64_t>(link->link.numPeers());
  state.hostTimeMicros = static_cast<int64_t>(now.count());
  return state;
}

void ls_link_set_tempo(LSLink *link, double bpm)
{
  if (!link || !std::isfinite(bpm))
  {
    return;
  }
  auto session = link->link.captureAppSessionState();
  session.setTempo(std::clamp(bpm, 20.0, 999.0), link->link.clock().micros());
  link->link.commitAppSessionState(session);
}

void ls_link_follow_beat(LSLink *link, double bpm, int beatInBar)
{
  if (!link || !std::isfinite(bpm) || beatInBar < 0 || beatInBar > 3)
  {
    return;
  }
  const double quantum = 4.0;
  const auto now = link->link.clock().micros();
  auto session = link->link.captureAppSessionState();
  session.setTempo(std::clamp(bpm, 20.0, 999.0), now);
  const double beat = session.beatAtTime(now, quantum);
  const double target = std::round((beat - beatInBar) / quantum) * quantum + beatInBar;
  // This call is only fed by fresh, playing console-master beats (or an
  // explicitly selected deck). External clock bridging is the documented use
  // of forceBeatAtTime; requestBeatAtTime would not align peers already in Link.
  session.forceBeatAtTime(target, now, quantum);
  link->link.commitAppSessionState(session);
}

} // extern "C"
