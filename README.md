# ClamAV Database Downloader with CDIFF Fallback

## Overview

This is not an official ClamAV tool. Use at your own risk.

`clamdownloader.pl` is an enhanced version of the original ClamAV database downloader
script by Frederic Vanden Poel.

The script maintains a local mirror of ClamAV databases (`main.cvd`, `daily.cvd`,
`bytecode.cvd`) with support for incremental updates, mirror fallback, and persistent
handling of missing CDIFF files.

It is designed for **local or internal mirrors**

---

## Key Features

- DNS TXT based version detection (`current.cvd.clamav.net`)
- Incremental updates using `.cdiff` files
- Automatic fallback to full `.cvd` download if incremental update is not possible
- Multiple HTTP mirrors with failover
- `If-Modified-Since` support to reduce bandwidth usage
- Persistent cache of missing CDIFF files
- Optional skipping of the `daily` database update
- Safe updates using temporary files and validation

---

## Differences from the Original Script

This script is based on the original `clamdownloader.pl` from:

The following enhancements and behavioral differences were introduced:

### 1. Persistent CDIFF Missing Cache

**New behavior:**
- Missing CDIFF files are permanently recorded in `cdiff_history.txt`
- Once a CDIFF is known to be unavailable, it is never retried
- Prevents repeated failed HTTP requests on every run

### 2. Multi-Mirror Fallback

**New behavior:**
- Multiple mirrors are defined for both `.cvd` and `.cdiff` downloads
- Mirrors are tried sequentially until a successful download occurs

### 3. Robust Incremental Update Logic

**New behavior:**
- Sequential CDIFF download verification
- If *any* required CDIFF is missing:
  - All partial CDIFFs are discarded
  - Full CVD download is triggered automatically

### 4. If-Modified-Since Optimization

**New behavior:**
- Uses `If-Modified-Since` HTTP header when downloading full CVD files
- Avoids unnecessary downloads if the file has not changed

### 5. Temporary File Safety

**New behavior:**
- All downloads are written to a temporary directory first
- Files are only moved into place if:
  - They exist
  - They are non-empty
  - They are newer than the current version

### 6. Command-Line Control

**New behavior:**
- `--skip-daily` option allows skipping `daily.cvd` updates

### 7. Intended Use Case

**This script:**
- Local or internal ClamAV mirrors

## Requirements

### System tools
- `sigtool` (from ClamAV)

### Perl modules
- `Getopt::Long`
- `Net::DNS`
- `LWP::UserAgent`
- `HTTP::Request`
- `File::Copy`
- `File::Compare`

## Directory Layout

clamav/
├── main.cvd
├── daily.cvd
├── bytecode.cvd
├── main-XXXX.cdiff
├── daily-XXXX.cdiff
├── temp/
│ └── *.cvd
├── dns.txt
└── cdiff_history.txt

## Usage

### Normal run

```bash
perl clamdownloader.pl
```

### Skip daily database update

```bash
perl clamdownloader.pl --skip-daily
```

### Notes

This script does not apply CDIFFs — ClamAV handles that internally

The script only manages downloads and file replacement

Invalid or zero-sized downloads are discarded automatically
