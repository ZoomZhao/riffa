#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
RESOURCES_DIR="$PROJECT_DIR/Sources/RiffaApp/Resources"
DYNAMIC_KEYS_PATH="$SCRIPT_DIR/dynamic-localization-keys.json"

ruby -KU -rjson - \
    "$RESOURCES_DIR/Localizable.xcstrings" \
    "$RESOURCES_DIR/InfoPlist.xcstrings" \
    "$RESOURCES_DIR/ServicesMenu.xcstrings" \
    "$PROJECT_DIR/Sources/RiffaApp" \
    "$DYNAMIC_KEYS_PATH" <<'RUBY'
localizable_path,
  info_plist_path,
  services_menu_path,
  app_source_path,
  dynamic_keys_path = ARGV
catalog_paths = [localizable_path, info_plist_path, services_menu_path]
failures = []

catalogs = catalog_paths.to_h do |path|
  begin
    [path, JSON.parse(File.read(path))]
  rescue JSON::ParserError => error
    failures << "#{File.basename(path)} is not valid JSON: #{error.message}"
    [path, {}]
  end
end

catalogs.each do |path, catalog|
  next if catalog.empty?

  failures << "#{File.basename(path)} must use English as its source language" unless catalog["sourceLanguage"] == "en"
  failures << "#{File.basename(path)} must use string catalog version 1.0" unless catalog["version"] == "1.0"
  failures << "#{File.basename(path)} has no strings dictionary" unless catalog["strings"].is_a?(Hash)
end

format_specifier = /%(?:\d+\$)?(?:[-+0 #']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?(?:@|[diuoxXfFeEgGaAcCsSp]))/
placeholder_signature = lambda do |value|
  implicit_position = 0
  value.scan(format_specifier).map do |token|
    explicit_position = token.match(/\A%(\d+)\$/)&.captures&.first
    position = if explicit_position
      explicit_position.to_i
    else
      implicit_position += 1
    end
    [position, token.sub(/%\d+\$/, "%")]
  end.sort
end

localizable = catalogs.fetch(localizable_path).fetch("strings", {})
if localizable.length < 1_100
  failures << "Localizable.xcstrings contains only #{localizable.length} keys; expected the complete UI catalog"
end

localizable.each do |key, entry|
  %w[en zh-Hans].each do |language|
    string_unit = entry.dig("localizations", language, "stringUnit")
    if string_unit.nil?
      failures << "#{key.inspect} has no #{language} translation"
      next
    end

    value = string_unit["value"]
    failures << "#{key.inspect} has an invalid #{language} value" unless value.is_a?(String)
    failures << "#{key.inspect} is not marked translated for #{language}" unless string_unit["state"] == "translated"
    if value.is_a?(String) && placeholder_signature.call(value) != placeholder_signature.call(key)
      failures << "#{key.inspect} changes format placeholders in #{language}"
    end
  end
end

required_ui_keys = [
  "Settings", "Session Library", "Workspace", "Resource Tools",
  "Folder Compare", "Folder Merge", "Folder Sync",
  "Text Compare", "Text Merge", "Text Patch",
  "Hex Compare", "Media Compare", "Image Compare", "PDF Compare",
  "Office Compare", "Archive Compare", "Metadata Compare",
  "Version Compare", "Table Compare",
  "Choose Left", "Choose Right", "Swap folders", "Refresh comparison",
  "Export Report", "Load Demo", "Cancel", "Apply", "Save", "Open",
  "Choose two folders", "No Saved Sessions", "No Results",
  "Delete from Left…", "Delete from Right…", "Apply to Target…",
  "Swap left and right folders", "Refresh folder comparison",
  "Opens a local file picker", "Open this comparison type",
  "Personalize language and appearance across every Riffa window.",
  "Switch Riffa’s interface language without restarting.",
  "Theme Preset", "Custom Accent", "Use Preset Accent",
  "Imported Theme", "Import Theme…", "Remove", "Reset Theme",
  "Live Preview",
  "Surfaces, focus, and semantic colors update immediately.",
  "Import Riffa Theme", "System", "English", "Simplified Chinese",
  "Light", "Dark", "Midnight", "Graphite", "Ocean", "Forest",
  "Selected", "Not selected",
  "LANGUAGE", "App Language", "APPEARANCE", "Theme",
  "Choose a built-in palette, custom accent, or validated theme document.",
  "ACCESSIBILITY", "System accessibility",
  "Riffa follows macOS settings for contrast, motion, transparency, and color.",
  "Focused dark appearance",
  "Riffa adapts to your system settings to improve readability and reduce strain.",
  "Increase Contrast", "Boosts contrast for text and interface elements.",
  "Reduce Transparency", "Keeps every workspace surface fully opaque.",
  "Reduce Motion", "Minimizes hover and state-change animations.",
  "Differentiate Without Color",
  "Adds symbols and labels to every comparison state.",
  "Follow System", "PRIVACY", "Riffa does not upload compared files.",
  "Compared files stay on this Mac",
  "Reports are saved only when requested",
  "Remote credentials require explicit Keychain save",
  "Choose a Riffa theme JSON document. It will be validated before use.",
  "Import"
]
missing_ui_keys = required_ui_keys - localizable.keys
unless missing_ui_keys.empty?
  failures << "Localizable.xcstrings is missing required UI keys: #{missing_ui_keys.join(", ")}"
end

required_dynamic_keys = [
  "None", "Basic", "Bearer",
  "All statuses", "All differences", "Left only", "Right only",
  "Pages", "Text", "Visual", "Metadata",
  "Title", "Author", "Subject", "Keywords", "Creator", "Producer",
  "Creation Date", "Modification Date",
  "Text Comparison", "Folder Comparison", "Folder Synchronization",
  "Folder Merge", "Text Merge", "Text Patch", "Table Comparison",
  "Hexadecimal Comparison", "Image Comparison", "PDF Comparison",
  "Office Comparison", "Archive Comparison", "Metadata Comparison",
  "Version Comparison", "Media Comparison",
  "Informational", "Normal", "Important", "Critical",
  "Leftonly", "Rightonly",
  "File Name", "File Size", "Content Type", "Duration (seconds)",
  "Playable", "Track Count", "Duration", "Artist", "Comment", "Copyright",
  "Update Left", "Update Right", "Update Both",
  "Mirror Left → Right", "Mirror Right → Left",
  "Low", "Medium", "High", "Unresolved",
  "All items", "Document type", "Properties", "Sections", "Package parts",
  "All", "Changes", "Errors", "Both", "Unique",
  "Left newer", "Right newer", "Left newer + unique",
  "Right newer + unique", "Side by Side", "Difference",
  "Conflicts", "Omit", "Unfinished", "Finished", "Sync", "Merge",
  "Name", "Type", "Size (bytes)", "Modified",
  "Modified nanosecond component", "POSIX permissions",
  "Owner ID", "Group ID", "Created", "Created nanosecond component",
  "BSD flags", "Symbolic link destination",
  "Access-control entries", "Access-control list",
  "Inspect two directory trees", "Reconcile three folder trees",
  "Preview safe copy and delete plans", "Aligned lines and inline changes",
  "Resolve three-way text changes", "Review and safely apply unified diffs",
  "Compare large binary files", "Inspect audio and video metadata",
  "Overlay pixels and highlight changes",
  "Review pages, text, and document metadata",
  "Compare DOCX, XLSX, PPTX, and ODS package content",
  "Compare ZIP and TAR contents without extracting",
  "Compare safe file-system attributes",
  "Inspect versions, architectures, and signatures",
  "Match rows, keys, and worksheets"
]
required_dynamic_keys.concat(
  %w[
    kind uncompressedByteCount modificationDate permissions compression
    symbolicLinkDestination content file directory symbolicLink none deflate
    size rotation label text
    caseCollision unicodeCollision metadataUnavailable directoryUnreadable
    symbolicLinkTargetUnavailable contentUnreadable fileChangedDuringCapture
    invalidSnapshot other
    same modified leftOnly rightOnly duplicateKey error
    copy createDirectory delete move replace omit
    pending executing completed failed rolledBack
    missing regularFile
    cancelled invalidPlan sourceMissing sourceChanged targetChanged
    permissionDenied insufficientSpace symbolicLinkTraversal backupFailed
    actionFailed rollbackFailed recoveryInterrupted ioFailure unknown
    invalidRelativePath rootUnavailable nonDirectoryAncestor
    concurrentModification
  ]
)
required_dynamic_keys.concat(
  [
    "Changed", "Added", "Removed",
    "Copy", "Create folder", "Move", "Replace", "Conflict", "No change",
    "Property", "Section", "Package part",
    "Word document (DOCX)", "Excel workbook (XLSX)",
    "PowerPoint presentation (PPTX)",
    "OpenDocument spreadsheet (ODS)",
    "Folder Snapshots", "Archive Browser", "WebDAV", "Operations",
    "Type mismatch", "Issue", "Link",
    "Comma", "Tab", "Semicolon", "Pipe", "Error",
    "Unchanged", "Left changed", "Right changed", "Both same",
    "Left deleted", "Right deleted", "Both deleted", "Type conflict",
    "Copy from Left", "Copy from Right", "Copy from Base",
    "Create directory", "Omit from output", "Resolve conflict",
    "Inserted", "Deleted", "Mixed",
    "Active", "Archived", "Preparing", "Executing", "Rolling back",
    "Completed", "Rolled back", "Failed",
    "BASE", "LEFT", "RIGHT", "OUTPUT", "BACKUP",
    "Matches completed", "Matches rolled back", "Review required",
    "Inconsistent scene", "Unsafe to infer",
    "completed scene", "rolled-back scene", "review required",
    "inconsistent", "not observable",
    "Display name", "Resource kind", "Bundle identifier",
    "Short version", "Bundle version", "Package type",
    "Minimum system version", "Architectures", "Main binary bytes",
    "Main binary SHA-256", "Signature status",
    "Signing team identifier", "Signing identifier",
    "Signature diagnostic code", "Application bundle", "Framework",
    "Bundle", "Mach-O executable", "Dynamic library",
    "Mach-O binary", "Regular file", "Signature valid",
    "Signature invalid", "Unsigned", "Not applicable",
    "Symbolic link", "Character device", "Block device",
    "FIFO", "Socket", "Unknown type"
  ]
)
required_dynamic_keys.concat(
  [
    "The item already matches on both sides.",
    "The item exists only on the synchronization source.",
    "The item exists only on the target and update mode preserves it.",
    "The paired items differ and the target should be replaced from the source.",
    "Both sides contain different content, so bidirectional sync cannot choose safely.",
    "The path represents different item types on the two sides.",
    "The comparison could not determine a safe synchronization action.",
    "Mirror mode removes an item that exists only on the target.",
    "Mirror mode can move a verified matching file within the target instead of copying and deleting it.",
    "The user explicitly chose a new leaf name for one ordinary file on this side.",
    "The user explicitly selected this item for deletion from one side.",
    "The current item matches the step's persisted completed state.",
    "The current item matches the step's persisted rolled-back state.",
    "The journal remained in preparation and the pre-operation state is still present.",
    "The verified move item is absent at its source and present at its destination.",
    "The verified move item is still present at its source and absent at its destination.",
    "The target that was absent before the step remains absent.",
    "The recorded destructive postcondition is present.",
    "The recorded creation postcondition is present.",
    "Schema 2 does not contain enough content identity to prove this outcome.",
    "The current scene could represent either no execution or a completed no-op.",
    "The step recorded failure and requires human review.",
    "A case-only rename may have stopped at its hidden same-directory intermediate name. Neither public name is changed automatically; inspect the parent folder before retrying.",
    "The current item does not match the state persisted by the journal.",
    "The move's source and destination form a conflicting scene.",
    "Descriptor-safe observation could not be completed."
  ]
)
missing_dynamic_keys = required_dynamic_keys - localizable.keys
unless missing_dynamic_keys.empty?
  failures << "Localizable.xcstrings is missing dynamic UI keys: #{missing_dynamic_keys.join(", ")}"
end

# `RiffaLocalization.string` is the concrete-String bridge used by AppKit,
# LocalizedError, and dynamic SwiftUI labels. Apple's extractor cannot see
# through a project-defined helper, so scan every literal call instead of
# relying on a hand-maintained subset. Interpolated keys are intentionally
# forbidden here: interpolation belongs in `String(localized:)`, where the
# compiler records a stable placeholder-bearing key.
source_dynamic_keys = {}
Dir.glob(File.join(app_source_path, "**", "*.swift")).sort.each do |source_path|
  source = File.read(source_path)
  source.to_enum(
    :scan,
    /RiffaLocalization\.string\(\s*"((?:[^"\\]|\\.)*)"/m
  ).each do
    match = Regexp.last_match
    raw_key = match[1]
    line = source[0...match.begin(0)].count("\n") + 1

    if raw_key.include?("\\(")
      failures << "#{source_path}:#{line} uses an interpolated RiffaLocalization key; use String(localized:) instead"
      next
    end

    begin
      key = JSON.parse(%Q{"#{raw_key}"})
    rescue JSON::ParserError => error
      failures << "#{source_path}:#{line} has an unreadable RiffaLocalization key: #{error.message}"
      next
    end
    source_dynamic_keys[key] ||= []
    source_dynamic_keys[key] << "#{File.basename(source_path)}:#{line}"
  end

  source.to_enum(:scan, /bundle:\s*\.main\b/).each do
    line = source[0...Regexp.last_match.begin(0)].count("\n") + 1
    failures << "#{source_path}:#{line} passes the process main bundle directly; use RiffaLocalization.localizedBundle so explicit language selection works at runtime"
  end
end

missing_source_dynamic_keys = source_dynamic_keys.keys - localizable.keys
unless missing_source_dynamic_keys.empty?
  details = missing_source_dynamic_keys.sort.map do |key|
    "#{key.inspect} (#{source_dynamic_keys.fetch(key).join(", ")})"
  end
  failures << "Localizable.xcstrings is missing RiffaLocalization literal keys: #{details.join("; ")}"
end

# Some keys come from enum raw values and other runtime model fields, so neither
# Apple's extractor nor the literal helper scan above can discover them.
# Keep those finite vocabularies in a checked manifest rather than silently
# falling back to English when a new case is introduced.
begin
  manifested_dynamic_keys = JSON.parse(File.read(dynamic_keys_path))
rescue Errno::ENOENT
  failures << "#{File.basename(dynamic_keys_path)} is missing"
  manifested_dynamic_keys = []
rescue JSON::ParserError => error
  failures << "#{File.basename(dynamic_keys_path)} is not valid JSON: #{error.message}"
  manifested_dynamic_keys = []
end

unless manifested_dynamic_keys.is_a?(Array) &&
       manifested_dynamic_keys.all? { |key| key.is_a?(String) }
  failures << "#{File.basename(dynamic_keys_path)} must be an array of string keys"
  manifested_dynamic_keys = []
end

if manifested_dynamic_keys.uniq.length != manifested_dynamic_keys.length
  failures << "#{File.basename(dynamic_keys_path)} contains duplicate keys"
end

missing_manifested_dynamic_keys = manifested_dynamic_keys - localizable.keys
unless missing_manifested_dynamic_keys.empty?
  failures << "Localizable.xcstrings is missing manifested dynamic UI keys: #{missing_manifested_dynamic_keys.join(", ")}"
end

expected_catalog_keys = {
  info_plist_path => %w[
    CFBundleDisplayName
    CFBundleTypeName
    NSHumanReadableCopyright
  ],
  services_menu_path => [
    "Compare Files",
    "Compare Folders",
    "Select Left File for Compare",
    "Select Left Folder for Compare"
  ]
}

expected_catalog_keys.each do |path, expected_keys|
  strings = catalogs.fetch(path).fetch("strings", {})
  missing_keys = expected_keys - strings.keys
  failures << "#{File.basename(path)} is missing: #{missing_keys.join(", ")}" unless missing_keys.empty?

  expected_keys.each do |key|
    next unless strings.key?(key)

    %w[en zh-Hans].each do |language|
      unit = strings.dig(key, "localizations", language, "stringUnit")
      failures << "#{File.basename(path)} #{key.inspect} has no #{language} translation" if unit.nil?
      failures << "#{File.basename(path)} #{key.inspect} is not translated for #{language}" if unit && unit["state"] != "translated"
    end
  end
end

unless failures.empty?
  warn "Localization validation failed:"
  failures.each { |failure| warn "  - #{failure}" }
  exit 1
end

puts "Localization validation passed: #{localizable.length} UI keys, English and Simplified Chinese."
RUBY
