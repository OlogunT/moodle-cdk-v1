<?php
/**
 * Add debug settings to Moodle config.php
 * This script safely adds debug configuration to the Moodle config file
 */

$configFile = '/app/moodle/config.php';

if (!file_exists($configFile)) {
    echo "ERROR: config.php not found at $configFile\n";
    exit(1);
}

echo "=== Adding Debug Settings to Moodle Config ===\n";
echo "\n";

// Read the current config
echo "Step 1: Reading current config.php...\n";
$content = file_get_contents($configFile);

// Create backup
echo "Step 2: Creating backup...\n";
$backupFile = $configFile . '.backup.' . time();
if (!copy($configFile, $backupFile)) {
    echo "ERROR: Could not create backup\n";
    exit(1);
}
echo "Backup created at: $backupFile\n";
echo "\n";

// Check if debug settings already exist
echo "Step 3: Checking for existing debug settings...\n";
if (strpos($content, '$CFG->debug') !== false) {
    echo "Debug settings already present, removing old ones...\n";
    // Remove existing debug lines
    $lines = explode("\n", $content);
    $newLines = array();
    foreach ($lines as $line) {
        if (strpos($line, '$CFG->debug') === false &&
            strpos($line, '$CFG->debugdisplay') === false &&
            strpos($line, '$CFG->debugstringkeys') === false &&
            strpos($line, '$CFG->debugpageinfo') === false &&
            trim($line) !== '// Debug settings') {
            $newLines[] = $line;
        }
    }
    $content = implode("\n", $newLines);
}

// Find the require_once line
echo "Step 4: Inserting debug settings...\n";
$requireLine = "require_once(__DIR__ . '/lib/setup.php');";
$debugSettings = <<<'PHP'

// Debug settings
$CFG->debug = (E_ALL | E_STRICT);
$CFG->debugdisplay = 1;
$CFG->debugstringkeys = true;
$CFG->debugpageinfo = true;
PHP;

if (strpos($content, $requireLine) !== false) {
    $content = str_replace($requireLine, $debugSettings . "\n\n" . $requireLine, $content);
    echo "Debug settings inserted before require_once\n";
} else {
    echo "WARNING: Could not find require_once line\n";
    echo "Appending debug settings to end of file\n";
    $content .= "\n" . $debugSettings;
}

echo "\n";

// Write the updated config
echo "Step 5: Writing updated config.php...\n";
if (!file_put_contents($configFile, $content)) {
    echo "ERROR: Could not write config.php\n";
    exit(1);
}
echo "Config updated successfully\n";
echo "\n";

// Verify the changes
echo "Step 6: Verifying changes...\n";
$newContent = file_get_contents($configFile);
if (strpos($newContent, '$CFG->debug') !== false) {
    echo "✓ Debug settings verified in config.php\n";
} else {
    echo "✗ Debug settings not found in config.php\n";
    exit(1);
}

echo "\n";
echo "SUCCESS: Debug mode enabled!\n";
echo "\n";
echo "Debug settings enabled:\n";
echo "  - \$CFG->debug = (E_ALL | E_STRICT)\n";
echo "  - \$CFG->debugdisplay = 1\n";
echo "  - \$CFG->debugstringkeys = true\n";
echo "  - \$CFG->debugpageinfo = true\n";
echo "\n";
echo "Backup saved to: $backupFile\n";
?>

