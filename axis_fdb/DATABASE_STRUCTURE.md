# Axis Camera Station Database Structure

## Overview
- **ACS.FDB** - Main configuration database
- **ACS_RECORDINGS.FDB** - Recordings metadata database

## ACS.FDB Tables

### CAMERA
- `ID` (INTEGER) - Primary key
- `NAME` (VARCHAR) - Camera name
- `IS_ENABLED` (BOOLEAN) - Camera status
- `MANUFACTURER` (VARCHAR) - Device manufacturer
- `MODEL` (VARCHAR) - Device model

### STORAGE
- `ID` (INTEGER) - Primary key
- `VERSION` (INTEGER) - Version number
- `LAST_SAVED` (TIMESTAMP) - Last save time
- `CREATED_TIME` (TIMESTAMP) - Creation time

### STORAGE_LOCAL_DISK
- `STORAGE_ID` (INTEGER) - References STORAGE.ID
- `ROOT_PATH` (VARCHAR) - Root directory (e.g., "C:\")
- `RECORDING_DIRECTORY` (VARCHAR) - Subdirectory (e.g., "Recording")
- `MAX_USE_PERCENT` (INTEGER) - Max usage %
- `IS_DEFAULT_BODY_WORN_STORAGE` (BOOLEAN)

### CAMERA_STORAGE
- `CAMERA_ID` (INTEGER) - References CAMERA.ID
- `STORAGE_ID` (INTEGER) - References STORAGE.ID
- `KEEP_TIME` (BIGINT) - Retention time in ticks
- `IS_FAILOVER_RECORDING_ENABLED` (BOOLEAN)

## ACS_RECORDINGS.FDB Tables

### RECORDING
- `CAMERA_ID` (INTEGER) - References CAMERA.ID
- `ID` (INTEGER) - Recording session ID

### RECORDING_FILE
- `CAMERA_ID` (INTEGER) - References CAMERA.ID
- `STORAGE_ID` (INTEGER) - References STORAGE.ID
- `START_TIME` (BIGINT) - Start timestamp in ticks
- `STOP_TIME` (BIGINT) - Stop timestamp in ticks
- `STORAGE_SIZE` (BIGINT) - File size in bytes
- `IS_COMPLETE` (BOOLEAN) - Completion status

## Data Conversions
- **Ticks to Unix**: `(ticks / 10000000) - 62135596800`
- **Retention to Days**: `ticks / 864000000000`
- **Storage Path**: `ROOT_PATH + RECORDING_DIRECTORY`

## Current Metrics (16 total)
1. `axis_camera_oldest_recording_timestamp` - Oldest recording timestamp per camera
2. `axis_camera_total_recordings` - Total number of recordings
3. `axis_camera_total_cameras` - Total number of cameras
4. `axis_camera_newest_recording_timestamp` - Newest recording timestamp
5. `axis_camera_monitoring_last_update` - Last monitoring update timestamp
6. `axis_camera_storage_used_bytes` - Total storage used by all recordings
7. `axis_camera_enabled_total` - Number of enabled cameras
8. `axis_camera_disabled_total` - Number of disabled cameras
9. `axis_camera_storage_used_bytes_per_camera` - Storage used per camera
10. `axis_camera_last_recording_stop_timestamp_seconds` - Last recording stop time per camera
11. `axis_camera_last_recording_start_timestamp_seconds` - Last recording start time per camera
12. `axis_camera_incomplete_recordings_total` - Number of incomplete recordings
13. `axis_camera_avg_recording_size_bytes` - Average recording size in bytes
14. `axis_camera_avg_recording_duration_seconds` - Average recording duration in seconds
15. `axis_camera_recordings_total_per_camera` - Number of recordings per camera
16. `axis_camera_retention_days_per_camera` - Retention time in days per camera
17. `axis_camera_recordings_total_by_storage` - Number of recordings by storage
18. `axis_camera_storage_used_bytes_by_storage` - Storage used by storage in bytes

## ACS.FDB (Main Configuration Database)

### DEVICE Table
**Purpose**: Device information
**Key Fields**:
- `MANUFACTURER` (VARCHAR) - Device manufacturer
- `MODEL` (VARCHAR) - Device model

### STORAGE_NAS Table
**Purpose**: Network Attached Storage configuration
**Key Fields**:
- `STORAGE_ID` (INTEGER) - References STORAGE.ID
- `ROOT_PATH` (VARCHAR) - Network path
- `RECORDING_DIRECTORY` (VARCHAR) - Recording subdirectory
- `USERNAME` (VARCHAR) - NAS username
- `PASSWORD` (VARCHAR) - NAS password
- `MAX_USE_PERCENT` (INTEGER) - Maximum usage percentage
- `IS_DEFAULT_BODY_WORN_STORAGE` (BOOLEAN) - Default body worn storage flag

### Other Configuration Tables
- `BUTTON_CONFIGURATION`
- `CAMERA_MOTION_DETECTION_CONFIG`
- `CAMERA_PTZ_CONFIGURATION`
- `COMPONENT_PERMISSION_CONFIG`
- `EXTERNAL_DATA_SEARCH_CONFIG`
- `SCHEDULED_EXPORT_CONFIGURATION`

## Data Types and Conversions

### Timestamps
- **Storage Format**: BIGINT ticks (100-nanosecond intervals since .NET epoch)
- **Conversion to Unix**: `(ticks / 10000000) - 62135596800`
- **Example**: 638869535242396611 ticks = 1751356724 Unix seconds

### Retention Time
- **Storage Format**: BIGINT ticks
- **Conversion to Days**: `ticks / 864000000000` (864000000000 = 1 day in ticks)
- **Example**: 77760000000000 ticks = 90 days

## Relationships

### Camera → Storage
- `CAMERA.ID` → `CAMERA_STORAGE.CAMERA_ID`
- `CAMERA_STORAGE.STORAGE_ID` → `STORAGE.ID`
- `STORAGE.ID` → `STORAGE_LOCAL_DISK.STORAGE_ID` or `STORAGE_NAS.STORAGE_ID`

### Recording → Camera
- `RECORDING.CAMERA_ID` → `CAMERA.ID`
- `RECORDING_FILE.CAMERA_ID` → `CAMERA.ID`

### Recording → Storage
- `RECORDING_FILE.STORAGE_ID` → `STORAGE.ID`

## Notes
- All timestamps are stored in .NET ticks format
- Storage paths are constructed as `ROOT_PATH + RECORDING_DIRECTORY`
- Retention time is stored per camera-storage combination
- Event categories may be empty in some installations 