#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <pbxproj> <package-name> <package-relative-path>" >&2
  exit 2
fi

PBXPROJ_PATH="$1"
PACKAGE_NAME="$2"
PACKAGE_RELATIVE_PATH="$3"

if [[ ! -f "$PBXPROJ_PATH" ]]; then
  echo "pbxproj not found: $PBXPROJ_PATH" >&2
  exit 1
fi

LOCAL_REF_ID="$(
  PACKAGE_RELATIVE_PATH="$PACKAGE_RELATIVE_PATH" perl -ne '
    my $package_path = $ENV{PACKAGE_RELATIVE_PATH};
    if (/^\s*([A-F0-9]{24}) \/\* XCLocalSwiftPackageReference "([^"]+)" \*\/ = \{/ && $2 eq $package_path) {
      print "$1\n";
      exit 0;
    }
  ' "$PBXPROJ_PATH"
)"

if [[ -z "$LOCAL_REF_ID" ]]; then
  echo "local package reference not found for $PACKAGE_RELATIVE_PATH in $PBXPROJ_PATH" >&2
  exit 1
fi

ruby - "$PBXPROJ_PATH" "$PACKAGE_NAME" "$PACKAGE_RELATIVE_PATH" "$LOCAL_REF_ID" <<'RUBY'
pbxproj_path, package_name, package_relative_path, local_ref_id = ARGV
contents = File.read(pbxproj_path)
package_comment = %(#{local_ref_id} /* XCLocalSwiftPackageReference "#{package_relative_path}" */)
pattern = /(\s*[A-F0-9]{24} \/\* #{Regexp.escape(package_name)} \*\/ = \{\n\s*isa = XCSwiftPackageProductDependency;\n)(?!\s*package = )(\s*productName = #{Regexp.escape(package_name)};\n\s*\};)/
updated = contents.sub(pattern) { "#{$1}\t\t\tpackage = #{package_comment};\n#{$2}" }
abort("failed to patch #{package_name} in #{pbxproj_path}") if updated == contents
File.write(pbxproj_path, updated)
RUBY
