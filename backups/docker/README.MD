
# UpdraftPlus Backup Setup Guide

This guide covers setting up automated UpdraftPlus backups for WordPress running in Docker, copying backups out of the container to the host server, and scheduling the process with cron.

> **Important:** Backups are currently stored **locally on the host server**, outside the Docker container. This protects against container deletion, but not server disk failure. You should enhance this setup later to copy backups to remote storage such as Azure Blob Storage, AWS S3, Google Cloud Storage, or another off-site location.

---

## Table of Contents

1. [Install and Configure UpdraftPlus](#1-install-and-configure-updraftplus)
2. [Set Up Scheduled Backups](#2-set-up-scheduled-backups)
3. [Install the Backup Collector Script](#3-install-the-backup-collector-script)
4. [Configure Crontab](#4-configure-crontab)
5. [Verify the Setup](#5-verify-the-setup)
6. [Important Warnings](#6-important-warnings)
7. [Next Steps: Remote Storage](#7-next-steps-remote-storage)

---

## 1. Install and Configure UpdraftPlus

1. Log in to your WordPress admin dashboard.
2. Go to **Plugins → Add New Plugin**.
3. Search for **UpdraftPlus**.
4. Click **Install Now**, then **Activate**.
5. Navigate to **Settings → UpdraftPlus Backups**.

UpdraftPlus Free is sufficient for local backups and basic migrations.

---

## 2. Set Up Scheduled Backups

1. In WordPress, go to **Settings → UpdraftPlus Backups**.
2. Click the **Settings** tab.
3. Configure the following:

   | Setting | Recommended Value |
   |---------|-------------------|
   | Files backup schedule | Daily |
   | Files backup retention | 7 |
   | Database backup schedule | Daily |
   | Database backup retention | 7 |

4. Choose your backup time if using UpdraftPlus Premium. With the Free version, UpdraftPlus will run at the scheduled interval from the time it was set.
5. Scroll down and click **Save Changes**.

UpdraftPlus will now create backups automatically inside the container at:

/var/www/html/wp-content/updraft/

---

## 3. Install the Backup Collector Script

The backup collector script runs on the host server. It discovers all running WordPress Docker containers, finds their UpdraftPlus backups, and copies them to the host filesystem.

### 3.1 Create the script directory

```bash
mkdir -p ~/scripts
```

### 3.2 Save the script

Save the script as `~/scripts/sync.sh` and make it executable:

```bash
chmod +x ~/scripts/sync.sh
```

### 3.3 Create required directories

```bash
mkdir -p ~/backups/updraft
mkdir -p ~/logs
```

### 3.4 Test the script

Run the script manually to verify everything works:

```bash
~/scripts/sync.sh
```

Check the log:

```bash
tail -f ~/logs/updraft-collector.log
```

Verify the backups were copied:

```bash
ls -la ~/backups/updraft/
```

You should see a structure like:

```text
~/backups/updraft/
└── midriver/
    ├── 2026-07-07-1937/
    │   └── backup_2026-07-07-1937_MiDriver_f0eb4df40a87-...
    └── 2026-07-07-1948/
        └── backup_2026-07-07-1948_MiDriver_5a2c56ef6d17-...
```

---

## 4. Configure Crontab

Schedule the script to run once per day, after UpdraftPlus has created its backup.

1. Open crontab:

   ```bash
   crontab -e
   ```

2. Add the following line. Adjust the time if your UpdraftPlus backup runs at a different hour.

   ```bash
   # Collect UpdraftPlus backups from all WordPress containers daily at 4:00 AM
   0 4 * * * /home/bitsavvyadmin/scripts/sync.sh >> /home/bitsavvyadmin/logs/updraft-collector-cron.log 2>&1
   ```

3. Save and exit.

### Verify the cron job is set

```bash
crontab -l
```

---

## 5. Verify the Setup

### Check cron logs

```bash
cat ~/logs/updraft-collector-cron.log
```

### Check backup files

```bash
find ~/backups/updraft -type f -name "backup_*" | sort
```

### Test the exact cron command

You can run the cron command manually to confirm it works:

```bash
/home/bitsavvyadmin/scripts/sync.sh >> /home/bitsavvyadmin/logs/updraft-collector-cron.log 2>&1
```

---

## 6. Important Warnings

### Backups are stored locally

> ⚠️ **Warning:** The backups copied by this script are stored on the **same physical server** as the Docker containers. This protects you from:
>
> - Accidental container deletion
> - Container recreation
> - Container-level data loss
>
> It does **not** protect you from:
>
> - Server disk failure
> - Server theft or loss
> - Data center outages
> - Ransomware or malicious deletion
> - Fire, flood, or physical damage

For true disaster recovery, backups must be copied to an independent, off-site or cloud storage location.

### UpdraftPlus Free limitations

- Backups run on WordPress cron or scheduled intervals, not at exact times.
- Remote storage destinations are limited compared to Premium.
- WP-CLI commands require the Premium version.

### File retention

The script keeps backups for **14 days** by default. Older backup folders are deleted automatically. You can change this by editing the `RETENTION_DAYS` variable in the script.

---

## 7. Next Steps: Remote Storage

Enhance this setup by copying backups to remote storage. Recommended options:

### Option A: Azure Blob Storage

Use `azcopy` or `rclone` to sync `~/backups/updraft/` to an Azure Blob container.

Example with `azcopy`:

```bash
azcopy sync "$HOME/backups/updraft" "https://<account>.blob.core.windows.net/<container>?<sas-token>" --recursive
```

### Option B: AWS S3

Use the AWS CLI:

```bash
aws s3 sync ~/backups/updraft/ s3://your-backup-bucket/updraft/
```

### Option C: Google Cloud Storage

Use `gsutil`:

```bash
gsutil -m rsync -r ~/backups/updraft/ gs://your-backup-bucket/updraft/
```

### Option D: Another server with rsync

```bash
rsync -avz --delete ~/backups/updraft/ user@backup-server:/backups/updraft/
```

### Suggested enhancement

Add a final step to the `sync.sh` script that uploads the newly copied backups to remote storage immediately after collection. This ensures every backup exists in at least two locations.

---

## Support

If the script fails:

1. Check the log file: `~/logs/updraft-collector.log`
2. Verify Docker containers are running: `docker ps`
3. Verify UpdraftPlus created backups: `docker compose exec wordpress ls -la /var/www/html/wp-content/updraft/`
4. Ensure the script is executable: `chmod +x ~/scripts/sync.sh`
```

Save it as `README.md`:

```bash
cat > ~/scripts/README.md << 'EOF'
[paste the content above]
EOF
```

Or use `nano`:

```bash
nano ~/scripts/README.md
```
