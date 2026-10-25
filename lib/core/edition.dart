/// Which edition this build is, fixed at compile time by the Android build
/// flavor (`flutter build … --flavor play`), which Flutter passes on as
/// `FLUTTER_APP_FLAVOR`. Tests can pass the same define.
///
/// The Full edition is the unrestricted build released on GitHub. The Play
/// edition is published on Google Play under its own application ID, with a
/// fixed content policy (see `content_policy.dart`), no in-app updater, and
/// Premium. Branch on [kPlayEdition] directly, as a constant, so the
/// compiler drops the other edition's code from each build.
library;

const String kEditionFlavor = String.fromEnvironment('FLUTTER_APP_FLAVOR');

/// Whether this is the Google Play edition.
const bool kPlayEdition = kEditionFlavor == 'play';
