# Check server auto-update

Install `PiricraftCheckServer-1.0.0.jar` into the server's `plugins` folder once.
On startup (after five seconds), and every five minutes, the plugin reads the
official `update-manifest.json` from `Pasta0719/Piricraft`.
The publisher includes a `checkServer` entry (version, URL, size, SHA-256) in the
same manifest update as the corresponding launcher release.

Verified JARs are saved to the server's configured update folder using the
installed plugin's filename. The running JAR is never replaced. Restart the
server to apply the update; `/reload` is not supported as an update mechanism.
This uses [Paper's plugin update-folder mechanism](https://docs.papermc.io/paper/updating/#step-2-update-plugins).

Logs report when the update is ready. Before staging, the previous installed JAR
is backed up under `plugins/PiricraftCheck/update-backups/<sha256>.jar`.
Network errors, hash/size mismatches and foreign manually staged updates leave
the current installed JAR unchanged. The updater retries on its next interval.
Older release versions are not staged. Changes with the same release version
and a different verified hash are supported for repairs.

Existing config files need no changes. Optional settings:

```yaml
auto-update:
  enabled: true
  check-interval-minutes: 5
```

Build and tests (Java 21):

```powershell
./gradlew.bat --no-daemon build '-PreleaseVersion=1.1.26'
```

The publishing workflow builds this source, then sets the exact official MOD
hashes with `PatchCheck` and executes static-initializer regression tests before
publishing. Do not deploy the unpatched Gradle output directly.
