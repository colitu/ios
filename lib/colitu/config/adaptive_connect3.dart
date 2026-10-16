/// Adaptive Connect 3.0 build switch. True forces the hinted start from
/// `network_hints.preferred` and the recovery set on (a test build); false
/// leaves the decision to the panel ([ColituAc3Switch]).
const bool kAdaptiveConnect3 = false;

/// Whether Adaptive Connect 3.0 runs on this device: forced by the build or
/// turned on by the panel (`features.adaptive_connect_3` of `/servers`, admin
/// rollout by platform and share of devices). Off, there is no hinted start and
/// no recovery set (no fetch, no use) - the app behaves as before 3.0. The
/// panel's last value is stored and holds while the panel cannot be reached;
/// sign-out clears it.
abstract final class ColituAc3Switch {
  static bool _remote = false;

  static bool get enabled =>
      enabledFor(buildForced: kAdaptiveConnect3, remote: _remote);

  static bool enabledFor({required bool buildForced, required bool remote}) =>
      buildForced || remote;

  /// The panel's last value (false when never told or signed out).
  static bool get remote => _remote;

  static void setRemote(bool on) => _remote = on;

  /// `features.adaptive_connect_3` of a `/servers` body; null when absent
  /// (an older panel: the stored value stays) or not a boolean.
  static bool? parse(Object? json) {
    if (json is! Map) return null;
    final features = json['features'];
    if (features is! Map) return null;
    final value = features['adaptive_connect_3'];
    return value is bool ? value : null;
  }
}
