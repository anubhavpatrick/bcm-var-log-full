# BCM Head Node var/ Storage Recovery Toolkit

Recovery and monitoring scripts for a BCM head node after the `/var` disk exhaustion incident (INC-2025-0210).

**What happened:** The syslog file grew to 173 GB with no size limit, filling the entire 194 GB `/var` partition. This caused rsyslog to enter an error loop, which prevented CMDaemon from starting, making `cmsh` inaccessible. See `docs/incident-report.md` for the full timeline.

---

## The Two Scripts

This toolkit contains **two independent scripts**. They do not depend on each other and can be used separately.

### 1. `bcm-recovery.sh` -- One-time Recovery

**Purpose:** Fix the head node after the disk exhaustion incident.

You run this **once**. It backs up the bloated syslog, frees disk space, restarts all affected services, and installs preventive config changes (logrotate size limits + rsyslog rate limiting) so the problem doesn't happen again.

**Config file:** `scripts/bcm-recovery.conf`

### 2. `bcm-log-monitor.sh` -- Ongoing Monitoring

**Purpose:** Keep an eye on `/var` disk usage going forward.

This runs **every 30 minutes via cron** (you set it up once, then it runs automatically). Each run it checks disk usage, records what's consuming space, samples recent log activity, and raises an alert if `/var` gets too full.

**Config file:** `scripts/bcm-log-monitor.conf`

---

## What's in This Repo

```
scripts/
  bcm-recovery.sh        One-time recovery script
  bcm-recovery.conf      Settings for the recovery script
  bcm-log-monitor.sh     Ongoing monitoring script (cron)
  bcm-log-monitor.conf   Settings for the monitoring script
```

At runtime the scripts create these directories under the project root:

```
backups/    Syslog backup + original config file copies (created by recovery script)
logs/       Daily log files -- logs/YYYY-MM-DD/ (created by both scripts)
debug/      Daily monitoring reports -- debug/YYYY-MM-DD/ (created by monitoring script)
```

> **Note on the syslog backup:** The recovery script copies the ~173 GB syslog file to
> `backups/` before truncating it. This backup takes up a lot of space. Once you have
> reviewed the monitoring reports in `debug/` and confirmed the root cause (the rsyslog
> error loop) and that the system is stable, you can safely delete it:
>
> ```bash
> rm /root/bcm-var-log-full/backups/*/syslog.incident-backup
> ```
>
> Keep the rest of the `backups/` folder -- it contains the original config files you may
> need for rollback.

---

## Before You Start

You need:
- **Root access** on the head node (all commands below use `sudo`)
- **180 GB free** on the `/` partition (for the syslog backup) -- check with `df -h /`
- SSH or console access (do not rely on `cmsh`, it is currently down)

Quick sanity checks:

```bash
# Confirm /var is full (or nearly full)
df -h /var

# Confirm root partition has space for the backup
df -h /

# Confirm these three services exist (they should show up in the output)
#   cmd.service       -- BCM daemon
#   rsyslog.service   -- system logging
#   postfix.service   -- mail transport
systemctl list-units --type=service | grep -E 'cmd|rsyslog|postfix'
```

---

## Step 1 -- Review the Configuration

Open `scripts/bcm-recovery.conf` and verify that the paths and service names match your system. The most important settings:

| Setting | Default | What it means |
|---------|---------|---------------|
| `PROJECT_DIR` | `/root/bcm-var-log-full` | Where this project lives on the head node |
| `SYSLOG_FILE` | `/var/log/syslog` | The bloated log file to back up and truncate |
| `CMD_SERVICE` | `cmd.service` | The CMDaemon systemd unit name |

If you are unsure about a value, the defaults should work for a standard BCM installation.

---

## Step 2 -- Run the Recovery Script

```bash
cd /root/bcm-var-log-full
chmod +x scripts/bcm-recovery.sh scripts/bcm-log-monitor.sh
sudo scripts/bcm-recovery.sh
```

The script will walk through three phases automatically. It stops immediately if anything fails.

| Phase | What it does | How long |
|-------|-------------|----------|
| Pre-flight | Checks root access, disk space, required commands, service status | 1-2 min |
| Phase 1 | Backs up the 173 GB syslog file, then truncates it to free space (see note below) | **10-30 min** |
| Phase 2 | Restarts rsyslog, flushes stuck mail, cleans temp files, restarts CMDaemon, verifies `cmsh` works | 2-5 min |
| Phase 3 | Installs new logrotate config (with size limits), adds rsyslog rate limiting | 1-2 min |

> **About Phase 1 (backup):** The syslog file is ~173 GB and rsyslog continues writing to it
> during the copy, so the backup may take a long time and end up slightly larger than the
> original size shown. If the backup fails (e.g., out of space, I/O error), the script will
> ask whether you want to continue without a backup rather than aborting the entire recovery.
>
> If you need to recover as fast as possible and don't need the syslog backup, skip it entirely:
>
> ```bash
> sudo scripts/bcm-recovery.sh --skip-backup
> ```
>
> This goes straight to truncation, saving 10-30 minutes. The syslog data will be permanently
> lost. Config file backups (Phase 3) are still created regardless of this flag.

**To watch progress** from another terminal:

```bash
# Replace the date with today's date
tail -f /root/bcm-var-log-full/logs/$(date +%Y-%m-%d)/bcm-recovery.log
```

**After it finishes,** verify everything is working:

```bash
cmsh -c "device status"
df -h /var
systemctl status cmd.service rsyslog
```

---

## Step 3 -- Set Up the Monitoring Cron Job

The monitoring script is separate from the recovery script. It checks `/var` disk usage every 30 minutes and saves a report. You need to set it up manually.

**Add the cron job:**

```bash
sudo crontab -e
```

A text editor will open. Scroll to the bottom and paste these two lines:

```
# BCM Log Monitoring -- runs every 30 minutes
*/30 * * * * /root/bcm-var-log-full/scripts/bcm-log-monitor.sh /root/bcm-var-log-full/scripts/bcm-log-monitor.conf >> /root/bcm-var-log-full/debug/cron.log 2>&1
```

Save and exit the editor (in `vi`: press `Esc`, type `:wq`, press `Enter`).

**Verify it was saved:**

```bash
sudo crontab -l | grep bcm-log-monitor
```

You should see the line you just added.

**Test it once by hand** to make sure it works:

```bash
sudo /root/bcm-var-log-full/scripts/bcm-log-monitor.sh /root/bcm-var-log-full/scripts/bcm-log-monitor.conf
```

It will print a report to the screen and also save it to `debug/<today's date>/`.

**To remove the cron job later:**

```bash
sudo crontab -e
```

Delete the two `bcm-log-monitor` lines, save, and exit.

---

## Reverting to the Old Syslog Configuration

The recovery script (Phase 3) changes two system config files:
- `/etc/logrotate.d/rsyslog` -- new size-based rotation limits
- `/etc/rsyslog.conf` -- added rate limiting

The original versions are saved in your backup directory. To revert:

**1. Find your backup:**

```bash
ls /root/bcm-var-log-full/backups/
```

You will see a folder named with the date and time of the recovery run (e.g., `20250211_143022`).

**2. Restore the original logrotate config:**

```bash
sudo cp /root/bcm-var-log-full/backups/<FOLDER>/rsyslog.pre-recovery /etc/logrotate.d/rsyslog
```

Replace `<FOLDER>` with the actual folder name from step 1.

**3. Restore the original rsyslog.conf:**

```bash
sudo cp /root/bcm-var-log-full/backups/<FOLDER>/rsyslog.conf.pre-recovery /etc/rsyslog.conf
```

**4. Restart rsyslog so the old config takes effect:**

```bash
sudo systemctl restart rsyslog
```

**5. Verify rsyslog is running:**

```bash
sudo systemctl status rsyslog
```

---

## Checking Monitoring Reports

Reports are organized by date:

```
debug/
  2025-02-11/
    monitor-143000.txt
    monitor-150000.txt
    ...
  2025-02-12/
    monitor-000000.txt
    ...
  ALERTS.log              Only exists if disk usage exceeded thresholds
```

**View today's reports:**

```bash
ls /root/bcm-var-log-full/debug/$(date +%Y-%m-%d)/
```

**Read the latest report:**

```bash
cat /root/bcm-var-log-full/debug/$(date +%Y-%m-%d)/$(ls -t /root/bcm-var-log-full/debug/$(date +%Y-%m-%d)/ | head -1)
```

**Check if any alerts were triggered:**

```bash
cat /root/bcm-var-log-full/debug/ALERTS.log 2>/dev/null || echo "No alerts -- all clear."
```

Reports older than 30 days are automatically deleted (configurable via `RETENTION_DAYS` in `bcm-log-monitor.conf`).

---

## Sharing Logs with Support

If you need to send diagnostic data to a support team, you can bundle the `logs/` and `debug/` directories into a single archive:

**Everything (all days):**

```bash
cd /root/bcm-var-log-full
tar czf bcm-diagnostics-$(date +%Y%m%d).tar.gz logs/ debug/
```

This creates a file like `bcm-diagnostics-20250211.tar.gz` in the project directory.

**Just one specific day:**

```bash
cd /root/bcm-var-log-full
tar czf bcm-diagnostics-2025-02-11.tar.gz logs/2025-02-11/ debug/2025-02-11/
```

Replace `2025-02-11` with the date you need.

**Include the config files too** (helpful for support to see your settings):

```bash
cd /root/bcm-var-log-full
tar czf bcm-diagnostics-full-$(date +%Y%m%d).tar.gz logs/ debug/ scripts/*.conf
```

The resulting `.tar.gz` file can be copied off the node with `scp` or any file transfer tool:

```bash
scp /root/bcm-var-log-full/bcm-diagnostics-*.tar.gz user@your-machine:/tmp/
```

---

## Troubleshooting

**"Configuration file not found"** -- Pass the full path:

```bash
sudo /root/bcm-var-log-full/scripts/bcm-recovery.sh /root/bcm-var-log-full/scripts/bcm-recovery.conf
```

**"This script must be run as root"** -- Add `sudo`:

```bash
sudo scripts/bcm-recovery.sh
```

**"Insufficient space for syslog backup"** -- The `/` partition needs 180 GB free. Check with `df -h /`. Free up space or change `BACKUP_BASE_DIR` in the config.

**CMDaemon won't start after recovery:**

```bash
# Check the CMDaemon log
tail -100 /var/log/cmdaemon

# Check if MySQL is running (CMDaemon depends on it)
sudo systemctl status mysql

# Check for stale PID files
ls -la /var/run/cmd.pid /var/run/cmdaemon.*

# If stale PID files exist, remove them and retry
sudo rm -f /var/run/cmd.pid /var/run/cmdaemon.*
sudo systemctl restart cmd.service
```

**Monitoring cron not running:**

```bash
# Is the cron service itself running?
systemctl status cron

# Is the job in the crontab?
sudo crontab -l | grep bcm-log-monitor

# Any errors from previous runs?
cat /root/bcm-var-log-full/debug/cron.log
```
