/// Adaptive Connect 3.0 off-switch for this release. False: no hinted start
/// from `network_hints.preferred` and no recovery set (no fetch, no use,
/// also not in the connect without a server list) - the app behaves as
/// before 3.0. The code stays; flip to true to turn it on.
const bool kAdaptiveConnect3 = false;
