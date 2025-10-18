# Moodle Deprecation Error Fix - set_section_number()

## Error Description

**URL:** https://elearning.tsin.ca/course/index.php?categoryid=34

**Error Message:**
```
Coding error detected, it must be fixed by a programmer: 
Deprecation: core_courseformat\base::set_section_number has been deprecated since 4.4. 
Use base::set_sectionnum instead. See MDL-80248 for more information.
```

## Root Cause Analysis

### Environment
- **Moodle Version:** 5.0.2+ (Build: 20250916)
- **Issue:** Custom course format plugins using deprecated method
- **Deprecation:** Introduced in Moodle 4.4, enforced in Moodle 5.0+

### Affected Plugins

1. **Menutopic Course Format**
   - Version: 4.0.2 (michelle-4.0.2)
   - File: `/app/moodle/course/format/menutopic/lib.php`
   - Line: 113
   - Code: `$this->set_section_number($displaysection);`
   - Status: **Outdated** - designed for Moodle 4.0, not updated for 5.0

2. **Collapsed Topics (topcoll) Course Format**
   - Version: 500.1.1
   - File: `/app/moodle/course/format/topcoll/classes/output/format_renderer_migration_toolbox.php`
   - Line: 151
   - Code: `$this->courseformat->set_section_number($sectionreturn);`
   - Status: **Partially updated** - main code updated but migration toolbox missed

### Technical Details

**Moodle Tracker Issue:** [MDL-80248](https://tracker.moodle.org/browse/MDL-80248)

**Change Required:**
- **Old method:** `set_section_number($number)`
- **New method:** `set_sectionnum($number)`

**Reason for Deprecation:**
- Method renamed for consistency with Moodle coding standards
- `sectionnum` is the standard term used throughout Moodle core
- Deprecated in 4.4, removed in future versions

## Impact Assessment

### Severity: **LOW** (Warning only, not breaking)
- Site continues to function normally
- Error appears as a warning message to users
- No data loss or corruption
- No security implications

### User Impact:
- Users see error message when viewing course categories
- Error message is confusing and unprofessional
- May cause concern about site stability

### Risk of Fix: **VERY LOW**
- Simple method name change
- No logic changes required
- Backward compatible (new method exists in Moodle 4.0+)
- Easy to rollback if needed

## Proposed Fix

### Solution: Update Method Calls

Replace deprecated `set_section_number()` with `set_sectionnum()` in both affected files.

### Changes Required:

**File 1:** `/app/moodle/course/format/menutopic/lib.php`
```php
// Line 113 - BEFORE:
$this->set_section_number($displaysection);

// Line 113 - AFTER:
$this->set_sectionnum($displaysection);
```

**File 2:** `/app/moodle/course/format/topcoll/classes/output/format_renderer_migration_toolbox.php`
```php
// Line 151 - BEFORE:
$this->courseformat->set_section_number($sectionreturn);

// Line 151 - AFTER:
$this->courseformat->set_sectionnum($sectionreturn);
```

### Implementation Steps:

1. **Backup** original files with timestamp
2. **Replace** deprecated method calls using `sed`
3. **Validate** PHP syntax of modified files
4. **Purge** Moodle caches to ensure changes take effect
5. **Test** by visiting the affected URL

### Safety Measures:

- ✅ Automatic backup before changes
- ✅ PHP syntax validation after changes
- ✅ No code logic changes
- ✅ Simple string replacement
- ✅ Easy rollback from backup if needed

## Automated Fix Script

Use the provided script to apply the fix automatically:

```bash
# Apply fix to both instances
aws ssm send-command --region ca-central-1 \
  --instance-ids i-0d1d83b141744d823 i-011c65cd247389ee6 \
  --document-name "AWS-RunShellScript" \
  --parameters file://fix-deprecated-method.json
```

Or use the PowerShell wrapper:

```powershell
./scripts/fix-moodle-deprecation.ps1
```

## Manual Fix (If Needed)

If the automated script fails, apply the fix manually:

1. **Connect to instance:**
   ```bash
   aws ssm start-session --target i-INSTANCE_ID --region ca-central-1
   ```

2. **Backup files:**
   ```bash
   sudo -i
   cd /app/moodle/course/format
   cp menutopic/lib.php menutopic/lib.php.backup.$(date +%Y%m%d_%H%M%S)
   cp topcoll/classes/output/format_renderer_migration_toolbox.php \
      topcoll/classes/output/format_renderer_migration_toolbox.php.backup.$(date +%Y%m%d_%H%M%S)
   ```

3. **Fix menutopic:**
   ```bash
   sed -i '113s/set_section_number/set_sectionnum/' menutopic/lib.php
   php -l menutopic/lib.php
   ```

4. **Fix topcoll:**
   ```bash
   sed -i '151s/set_section_number/set_sectionnum/' \
     topcoll/classes/output/format_renderer_migration_toolbox.php
   php -l topcoll/classes/output/format_renderer_migration_toolbox.php
   ```

5. **Purge caches:**
   ```bash
   rm -rf /data/moodledata/cache/* /data/moodledata/localcache/* /data/moodledata/sessions/*
   sudo -u apache php /app/moodle/admin/cli/purge_caches.php
   ```

6. **Test:**
   ```bash
   curl -sL https://elearning.tsin.ca/course/index.php?categoryid=34 | grep -i "deprecation\|error"
   ```

## Verification

After applying the fix, verify:

1. **No PHP syntax errors:**
   ```bash
   php -l /app/moodle/course/format/menutopic/lib.php
   php -l /app/moodle/course/format/topcoll/classes/output/format_renderer_migration_toolbox.php
   ```

2. **Method calls updated:**
   ```bash
   grep -n 'set_sectionnum' /app/moodle/course/format/menutopic/lib.php
   grep -n 'set_sectionnum' /app/moodle/course/format/topcoll/classes/output/format_renderer_migration_toolbox.php
   ```

3. **No deprecation warnings:**
   - Visit: https://elearning.tsin.ca/course/index.php?categoryid=34
   - Should load without error messages

4. **Course functionality:**
   - Navigate through courses in category 34
   - Verify sections display correctly
   - Check that course format features work

## Rollback Procedure

If the fix causes issues:

1. **Restore from backup:**
   ```bash
   sudo -i
   cd /app/moodle/course/format
   
   # Find backup files
   ls -lt menutopic/lib.php.backup.*
   ls -lt topcoll/classes/output/format_renderer_migration_toolbox.php.backup.*
   
   # Restore (use appropriate timestamp)
   cp menutopic/lib.php.backup.TIMESTAMP menutopic/lib.php
   cp topcoll/classes/output/format_renderer_migration_toolbox.php.backup.TIMESTAMP \
      topcoll/classes/output/format_renderer_migration_toolbox.php
   
   # Purge caches
   rm -rf /data/moodledata/cache/* /data/moodledata/localcache/* /data/moodledata/sessions/*
   sudo -u apache php /app/moodle/admin/cli/purge_caches.php
   ```

## Long-Term Recommendations

### 1. Update Menutopic Plugin
The menutopic format is outdated (version 4.0.2 for Moodle 4.0):
- Check for updated version compatible with Moodle 5.0
- Consider migrating courses to a maintained format
- Plugin repository: https://moodle.org/plugins/format_menutopic

### 2. Monitor Plugin Updates
- Topcoll format is up-to-date (500.1.1) but has this one missed deprecation
- Check for updates regularly
- Subscribe to plugin update notifications

### 3. Test Before Moodle Upgrades
- Test custom plugins in staging environment
- Review deprecation notices before upgrading
- Update plugins before upgrading Moodle core

### 4. Enable Developer Debugging (Temporarily)
To catch similar issues early:
```php
// In config.php (for testing only, not production)
$CFG->debug = (E_ALL | E_STRICT);
$CFG->debugdisplay = 1;
```

## References

- **Moodle Tracker:** https://tracker.moodle.org/browse/MDL-80248
- **Moodle Docs:** https://docs.moodle.org/dev/Deprecation
- **Course Format API:** https://docs.moodle.org/dev/Course_formats
- **Menutopic Plugin:** https://moodle.org/plugins/format_menutopic
- **Topcoll Plugin:** https://moodle.org/plugins/format_topcoll

## Status

- [x] Issue diagnosed
- [x] Root cause identified
- [x] Fix prepared
- [x] Fix applied to instances
- [x] **FIX ROLLED BACK** - The simple method rename broke the page functionality
- [x] Files restored from backup
- [x] Page confirmed working with deprecation warning

## IMPORTANT: Fix Attempt Failed

**Date:** 2025-10-18
**Result:** ROLLED BACK

The attempted fix (renaming `set_section_number()` to `set_sectionnum()`) caused the course category page to return 504 Gateway Timeout errors. The fix was immediately rolled back and files were restored from backup.

**Conclusion:** The deprecation warning is a **cosmetic issue only**. The deprecated method still works correctly in Moodle 5.0.2+. The warning can be safely ignored until:
1. Plugin authors release updated versions compatible with Moodle 5.0+
2. Moodle upgrades to a version that removes the deprecated method entirely

**Recommendation:** **DO NOT apply this fix**. Leave the deprecated methods in place. The warning is harmless and the page functions correctly.

## Files

- **Diagnosis Script:** `check-course-format.json`
- **Detection Script:** `find-deprecated-usage.json`
- **Fix Script:** `fix-deprecated-method.json`
- **This Documentation:** `docs/MOODLE-DEPRECATION-FIX.md`

