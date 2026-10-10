import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';

/// Simple mode / Advanced mode. Simple mode only hides settings: what is
/// stored stays stored and comes back in Advanced mode. While it is on, the
/// connection picks are automatic (iOS has no manual protocol choice; the
/// transport is always automatic), a pinned multihop route and a rotating
/// exit give way to the automatic server, and the warm spare is on.
class ColituUiMode {
  ColituUiMode._();

  /// The connect target is the automatic pick: chosen by the user, or a
  /// pinned multihop route hidden by Simple mode.
  static bool automaticTarget({
    required bool advanced,
    required bool autoSelection,
    VPNServer? selected,
  }) => autoSelection || (!advanced && selected?.isMultihop == true);

  /// The rotating exit (which limits the tunnel to VLESS) applies.
  static bool rotationApplies({
    required bool advanced,
    required bool rotationActive,
  }) => advanced && rotationActive;

  static bool warmSpareOn({required bool advanced, required bool setting}) =>
      setting || !advanced;

  /// Simple mode shows one "Advanced settings on" line when a hidden
  /// setting that changes how traffic flows is active.
  static bool hiddenSettingsActive({
    required bool advanced,
    required bool splitTunnel,
    required bool strictKillSwitch,
    required bool multihopPinned,
    required bool rotationActive,
  }) =>
      !advanced &&
      (splitTunnel || strictKillSwitch || multihopPinned || rotationActive);
}
