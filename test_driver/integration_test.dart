// Driver entry point required to run integration_test on the WEB build.
//
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/app_boot_test.dart \
//     -d chrome
//
// (chromedriver must be running, e.g. `chromedriver --port=4444`.)
// On mobile/desktop you don't need this file — just `flutter test integration_test`.

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
