# kopia-wrapper
A wrapper script for [Kopia Backup Software](https://kopia.io/) to send
notifications when running on headless servers. This functionality is sorely
missing from Kopia at this time.

# Overview
kopia-wrapper captures the output and return codes from executing Kopia
snapshot and maintenance commands. Notifications may be sent for every
execution, or only for errors. Backup policies are retrieved from kopia and
snapshots performed sequentially. It is expected that Kopia will provide it's
own notification system in the future and kopia-wrapper would no longer be
necessary in favour of running kopia server instead. By keeping policy
definitions within Kopia, migration to Kopia server should be as simple
as setting a schedule for each policy and using systemd to start the service.

## Notes
 - Supports [Apprise Push Notifications](https://github.com/caronc/apprise) to
   send notifications to many popular services.
 - Do not set a schedule for Kopia policies. It is ignored by kopia-wrapper and
   would cause Kopia server (or kopia-ui) to perform snapshots itself if it
   is running (which contradicts the whole purpose of kopia-wrapper).

# Installation

# Kopia Configuration - CLI

## Set new policy
```
kopia policy set --before-snapshot-root-action </full/path/to/script.sh> </full/path/to/backup/>
```

# Kopia Configuration - GUI


# Example kopia-wrapper notification
