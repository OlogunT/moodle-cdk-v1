<?php
/**
 * Patch format_menutopic/lib.php to add a static reentrancy guard around
 * set_sectionnum() inside __construct(), preventing the recursive
 * build_course_cache() deadlock that causes 10+ second hangs and OOM.
 */

$file = '/app/moodle/course/format/menutopic/lib.php';
$content = file_get_contents($file);
if ($content === false) {
    fwrite(STDERR, "ERROR: cannot read $file\n");
    exit(1);
}

// 1. Add the static reentrancy guard property after the last existing static property block.
$old_prop = "    /** @var array Modules used in template */\n    public \$tplcmsused = [];";
$new_prop = "    /** @var array Modules used in template */\n    public \$tplcmsused = [];\n\n    /** @var bool Static reentrancy guard: prevents recursive set_sectionnum() during modinfo rebuild */\n    private static \$in_set_sectionnum = false;";

if (strpos($content, 'in_set_sectionnum') !== false) {
    echo "INFO: static guard already present — skipping property insert.\n";
} elseif (strpos($content, $old_prop) !== false) {
    $content = str_replace($old_prop, $new_prop, $content);
    echo "OK: inserted static \$in_set_sectionnum property.\n";
} else {
    fwrite(STDERR, "ERROR: could not locate tplcmsused property anchor.\n");
    exit(2);
}

// 2. Replace the existing try/catch with a reentrancy-guarded version.
$old_try = <<<'OLDTRY'
                // Guard against recursive deadlock: set_sectionnum() may call
                // get_fast_modinfo() which tries to acquire the modinfo cache lock.
                // If this constructor is invoked during a cache rebuild (which already
                // holds that lock), the lock acquisition fails and throws a moodle_exception.
                // We catch it here so the page can still render (defaulting to section 0)
                // instead of producing a fatal "Unable to acquire a lock for caching" error.
                try {
                    $this->set_sectionnum($displaysection);
                } catch (\moodle_exception $e) {
                    debugging(
                        'format_menutopic: set_sectionnum skipped during modinfo cache rebuild ' .
                        '(lock contention avoided): ' . $e->getMessage(),
                        DEBUG_DEVELOPER
                    );
                }
OLDTRY;

$new_try = <<<'NEWTRY'
                // Guard against recursive deadlock: set_sectionnum() calls get_fast_modinfo()
                // which may trigger build_course_cache(). If this constructor is invoked DURING
                // a cache rebuild (inner_build_course_cache -> get_array_of_activities ->
                // course_get_format -> format_menutopic::instance), the second build_course_cache()
                // will spin waiting for the Redis lock already held by the outer build, causing
                // 10+ second hangs and eventual OOM. The static flag detects this re-entrancy
                // and immediately skips set_sectionnum() so cache building can complete quickly.
                if (!self::$in_set_sectionnum) {
                    self::$in_set_sectionnum = true;
                    try {
                        $this->set_sectionnum($displaysection);
                    } catch (\moodle_exception $e) {
                        debugging(
                            'format_menutopic: set_sectionnum skipped during modinfo cache rebuild ' .
                            '(lock contention avoided): ' . $e->getMessage(),
                            DEBUG_DEVELOPER
                        );
                    } finally {
                        self::$in_set_sectionnum = false;
                    }
                } else {
                    debugging(
                        'format_menutopic: set_sectionnum skipped (recursive constructor during modinfo rebuild)',
                        DEBUG_DEVELOPER
                    );
                }
NEWTRY;

if (strpos($content, $old_try) !== false) {
    $content = str_replace($old_try, $new_try, $content);
    echo "OK: replaced try/catch with reentrancy-guarded version.\n";
} else {
    fwrite(STDERR, "ERROR: could not locate existing try/catch block — manual check needed.\n");
    exit(3);
}

// 3. Write back.
if (file_put_contents($file, $content) === false) {
    fwrite(STDERR, "ERROR: cannot write $file\n");
    exit(4);
}
echo "OK: file written successfully.\n";

// 4. Verify.
$verify = file_get_contents($file);
if (strpos($verify, 'in_set_sectionnum') !== false && strpos($verify, 'self::$in_set_sectionnum = true') !== false) {
    echo "VERIFY: patch confirmed in file.\n";
} else {
    fwrite(STDERR, "ERROR: verification failed — patch not found in written file.\n");
    exit(5);
}

