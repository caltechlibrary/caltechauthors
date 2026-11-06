#!/bin/bash
#
# cloud_init_reboot_test.bash - static tests that both cloud-init files install and check the
# reboot scripts (plan nginx_symlinks_and_host_checks, task 4.3). It reads the YAML as text; no
# instance is needed. cloud-init.yaml (AWS) and cloud-init-multipass.yaml are kept in step, so every
# test runs against both.
#
# Usage: ./admin/cloud_init_reboot_test.bash
# EXIT STATUS: 0 every test passed; 1 a test failed.

set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
FILES="cloud-init.yaml cloud-init-multipass.yaml"
PASSED=0
FAILED=0

# expect FILE DESCRIPTION PATTERN: PATTERN is a fixed string that must appear in FILE.
expect() {
  if grep -qF -- "$3" "$HERE/$1"; then PASSED=$((PASSED+1)); echo "PASS  $1: $2"
  else FAILED=$((FAILED+1)); echo "FAIL  $1: $2 (missing: $3)"; fi
}

for f in $FILES; do
  expect "$f" "pandoc is installed (make install builds man pages with it)" "  - pandoc"
  expect "$f" "setup installs safe_to_reboot.bash to /usr/local/bin" "admin/safe_to_reboot.bash"
  expect "$f" "setup installs caltechauthors_down.bash to /usr/local/bin" "admin/caltechauthors_down.bash"
  expect "$f" "installed with install(1), mode 0755" "install -m 0755"
  expect "$f" "the checkout must carry the admin scripts" "admin/safe_to_reboot.bash ]"
  expect "$f" "verify_rdm_boot.bash checks the two RDM scripts" 'check "safe_to_reboot.bash and caltechauthors_down.bash are installed" reboot_scripts_installed'
  expect "$f" "verify_rdm_boot.bash checks check-for-reboot.bash" 'check "check-for-reboot.bash (admin-shell-scripts) is installed" check_for_reboot_installed'
  expect "$f" "the person-run step is named in the install notes" "make install prefix=/usr/local"
done

# the function bodies must be identical in both files
body() { sed -n "/^      reboot_scripts_installed() {/,/^      }/p;/^      check_for_reboot_installed() {/,/^      }/p" "$HERE/$1"; }
A=$(body cloud-init.yaml); B=$(body cloud-init-multipass.yaml)
if [ -n "$A" ] && [ "$A" = "$B" ]; then PASSED=$((PASSED+1)); echo "PASS  both files carry identical check functions"
else FAILED=$((FAILED+1)); echo "FAIL  the check functions are missing or differ between the two files"; fi

echo; echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
